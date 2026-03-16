//// BEAM-native scheduler — runs scheduled tasks using OTP timer processes.
////
//// Each scheduled job gets a recurring timer via `process.send_after`.
//// When a timer fires, the scheduler sends the query to the cognitive loop
//// and delivers the result via the configured delivery channel.

import agent/types as agent_types
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import profile/types as profile_types
import scheduler/delivery
import scheduler/persist
import scheduler/types.{
  type ScheduledJob, type SchedulerMessage, Completed, Failed, GetStatus,
  JobComplete, JobFailed, Pending, Running, ScheduledJob, StopAll, StuckJobCheck,
  Tick,
}
import slog

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms() -> Int

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

/// Start the scheduler process with the given tasks.
/// Optionally loads checkpoint state and adjusts initial delays based on elapsed time.
/// Returns a Subject for sending scheduler messages.
pub fn start(
  tasks: List(profile_types.ScheduleTaskConfig),
  cognitive: Subject(agent_types.CognitiveMessage),
  checkpoint_path: String,
  stuck_timeout_ms: Int,
) -> Result(Subject(SchedulerMessage), Nil) {
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(SchedulerMessage) = process.new_subject()
    process.send(setup, self)

    // Try to load checkpoint for recovery
    let checkpoint_jobs = case persist.load(checkpoint_path) {
      Ok(checkpoint) -> {
        let config_names = list.map(tasks, fn(t) { t.name })
        persist.reconcile(checkpoint.jobs, config_names)
      }
      Error(_) -> []
    }

    let now = monotonic_now_ms()

    // Build initial job state, restoring from checkpoint where available
    let jobs =
      list.fold(tasks, dict.new(), fn(acc, task) {
        let restored = list.find(checkpoint_jobs, fn(j) { j.name == task.name })
        let job = case restored {
          Ok(saved) ->
            ScheduledJob(
              ..saved,
              query: task.query,
              interval_ms: task.interval_ms,
              delivery: task.delivery,
              only_if_changed: task.only_if_changed,
            )
          Error(_) ->
            ScheduledJob(
              name: task.name,
              query: task.query,
              interval_ms: task.interval_ms,
              delivery: task.delivery,
              only_if_changed: task.only_if_changed,
              status: Pending,
              last_run_ms: None,
              last_result: None,
              run_count: 0,
              error_count: 0,
            )
        }
        dict.insert(acc, task.name, job)
      })

    // Schedule initial ticks, accounting for elapsed time since last run
    list.each(tasks, fn(task) {
      let delay = case
        list.find(checkpoint_jobs, fn(j) { j.name == task.name })
      {
        Ok(saved) ->
          case saved.last_run_ms {
            Some(last_ms) -> {
              let elapsed = now - last_ms
              let remaining = task.interval_ms - elapsed
              case remaining > 0 {
                True -> remaining
                False -> 0
              }
            }
            None -> initial_delay(task)
          }
        Error(_) -> initial_delay(task)
      }
      schedule_tick(self, task.name, delay)
    })

    slog.info(
      "scheduler",
      "start",
      "Scheduler started with " <> int_to_string(list.length(tasks)) <> " tasks",
      None,
    )

    // Enter event loop
    scheduler_loop(self, jobs, cognitive, checkpoint_path, stuck_timeout_ms)
  })

  case process.receive(setup, 5000) {
    Ok(subj) -> Ok(subj)
    Error(_) -> {
      slog.log_error(
        "scheduler",
        "start",
        "Scheduler failed to start within 5s",
        None,
      )
      Error(Nil)
    }
  }
}

fn scheduler_loop(
  self: Subject(SchedulerMessage),
  jobs: Dict(String, ScheduledJob),
  cognitive: Subject(agent_types.CognitiveMessage),
  checkpoint_path: String,
  stuck_timeout_ms: Int,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(self)

  let msg = process.selector_receive_forever(selector)
  let loop = fn(j) {
    scheduler_loop(self, j, cognitive, checkpoint_path, stuck_timeout_ms)
  }
  case msg {
    StopAll -> {
      slog.info("scheduler", "loop", "Scheduler stopped", None)
      Nil
    }

    GetStatus(reply_to:) -> {
      let status_list = dict.values(jobs)
      process.send(reply_to, status_list)
      loop(jobs)
    }

    Tick(name:) -> {
      case dict.get(jobs, name) {
        Error(_) -> loop(jobs)
        Ok(job) ->
          case job.status {
            Running -> {
              slog.warn(
                "scheduler",
                "loop",
                "Tick: job '" <> name <> "' still running, skipping overlap",
                None,
              )
              // Reschedule tick for next interval
              schedule_tick(self, name, job.interval_ms)
              loop(jobs)
            }
            _ -> {
              slog.info(
                "scheduler",
                "loop",
                "Tick: running job '" <> name <> "'",
                None,
              )
              // Mark as running
              let updated_job = ScheduledJob(..job, status: Running)
              let updated_jobs = dict.insert(jobs, name, updated_job)

              // Spawn async query to cognitive loop
              spawn_job(self, cognitive, job)

              // Schedule stuck-job timeout check
              process.send_after(self, stuck_timeout_ms, StuckJobCheck(name:))

              loop(updated_jobs)
            }
          }
      }
    }

    StuckJobCheck(name:) -> {
      case dict.get(jobs, name) {
        Error(_) -> loop(jobs)
        Ok(job) ->
          case job.status {
            Running -> {
              slog.log_error(
                "scheduler",
                "loop",
                "Stuck job timeout: '"
                  <> name
                  <> "' still running after "
                  <> int_to_string(stuck_timeout_ms)
                  <> "ms",
                None,
              )
              let updated_job =
                ScheduledJob(
                  ..job,
                  status: Failed(reason: "Stuck job timeout"),
                  error_count: job.error_count + 1,
                )
              let updated_jobs = dict.insert(jobs, name, updated_job)

              // Schedule next tick
              schedule_tick(self, name, job.interval_ms)

              // Save checkpoint
              let _ = persist.save(checkpoint_path, dict.values(updated_jobs))

              loop(updated_jobs)
            }
            // Already completed or failed — ignore
            _ -> loop(jobs)
          }
      }
    }

    JobComplete(name:, result:) -> {
      case dict.get(jobs, name) {
        Error(_) -> loop(jobs)
        Ok(job) -> {
          let now = monotonic_now_ms()

          // Check only_if_changed
          let should_deliver = case job.only_if_changed {
            True ->
              case job.last_result {
                Some(prev) -> prev != result
                None -> True
              }
            False -> True
          }

          case should_deliver {
            True -> {
              let content = case job.delivery {
                profile_types.WebhookDelivery(..) ->
                  build_webhook_payload(name, result, get_datetime())
                _ -> result
              }
              case delivery.deliver(content, name, job.delivery) {
                Ok(path) ->
                  slog.info(
                    "scheduler",
                    "loop",
                    "Job '" <> name <> "' delivered to " <> path,
                    None,
                  )
                Error(err) ->
                  slog.warn(
                    "scheduler",
                    "loop",
                    "Job '" <> name <> "' delivery failed: " <> err,
                    None,
                  )
              }
            }
            False ->
              slog.info(
                "scheduler",
                "loop",
                "Job '" <> name <> "' skipped (unchanged)",
                None,
              )
          }

          let updated_job =
            ScheduledJob(
              ..job,
              status: Completed,
              last_run_ms: Some(now),
              last_result: Some(result),
              run_count: job.run_count + 1,
            )
          let updated_jobs = dict.insert(jobs, name, updated_job)

          // Schedule next tick
          schedule_tick(self, name, job.interval_ms)

          // Save checkpoint after completion
          let _ = persist.save(checkpoint_path, dict.values(updated_jobs))

          loop(updated_jobs)
        }
      }
    }

    JobFailed(name:, reason:) -> {
      case dict.get(jobs, name) {
        Error(_) -> loop(jobs)
        Ok(job) -> {
          slog.warn(
            "scheduler",
            "loop",
            "Job '" <> name <> "' failed: " <> reason,
            None,
          )
          let updated_job =
            ScheduledJob(
              ..job,
              status: Failed(reason:),
              error_count: job.error_count + 1,
            )
          let updated_jobs = dict.insert(jobs, name, updated_job)

          // Schedule next tick (retry on next interval)
          schedule_tick(self, name, job.interval_ms)

          // Save checkpoint after failure
          let _ = persist.save(checkpoint_path, dict.values(updated_jobs))

          loop(updated_jobs)
        }
      }
    }
  }
}

fn spawn_job(
  scheduler: Subject(SchedulerMessage),
  cognitive: Subject(agent_types.CognitiveMessage),
  job: ScheduledJob,
) -> Nil {
  let name = job.name
  let query = job.query
  process.spawn_unlinked(fn() {
    let reply_subj: Subject(agent_types.CognitiveReply) = process.new_subject()
    process.send(
      cognitive,
      agent_types.UserInput(text: query, reply_to: reply_subj),
    )
    case process.receive(reply_subj, 300_000) {
      Ok(reply) ->
        process.send(scheduler, JobComplete(name:, result: reply.response))
      Error(_) ->
        process.send(scheduler, JobFailed(name:, reason: "Timeout (5 minutes)"))
    }
  })
  Nil
}

fn initial_delay(task: profile_types.ScheduleTaskConfig) -> Int {
  // For now, start immediately (delay = 0).
  // Future: parse start_at to compute delay from current time.
  let _ = task.start_at
  0
}

fn schedule_tick(
  self: Subject(SchedulerMessage),
  name: String,
  delay_ms: Int,
) -> Nil {
  // Ensure minimum 1ms delay to avoid busy-looping
  let safe_delay = case delay_ms < 1 {
    True -> 1
    False -> delay_ms
  }
  process.send_after(self, safe_delay, Tick(name:))
  Nil
}

import gleam/int

fn int_to_string(n: Int) -> String {
  int.to_string(n)
}

fn build_webhook_payload(
  job_name: String,
  report: String,
  run_at: String,
) -> String {
  "{\"job\": \""
  <> job_name
  <> "\", \"timestamp\": \""
  <> run_at
  <> "\", \"report\": "
  <> json.to_string(json.string(report))
  <> "}"
}
