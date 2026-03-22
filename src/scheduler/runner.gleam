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
import scheduler/delivery
import scheduler/log as schedule_log
import scheduler/types.{
  type ScheduleTaskConfig, type ScheduledJob, type SchedulerMessage, Cancelled,
  Completed, Failed, ForAgent, GetStatus, JobComplete, JobFailed, Pending,
  ProfileJob, RecurringTask, Running, ScheduledJob, StopAll, StuckJobCheck, Tick,
  WebhookDelivery,
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
  tasks: List(ScheduleTaskConfig),
  cognitive: Subject(agent_types.CognitiveMessage),
  schedule_dir: String,
  stuck_timeout_ms: Int,
  max_cycles_per_hour: Int,
  token_budget_per_hour: Int,
) -> Result(Subject(SchedulerMessage), Nil) {
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(SchedulerMessage) = process.new_subject()
    process.send(setup, self)

    // Load persisted jobs from JSONL operation log (survives restarts)
    let persisted_jobs = schedule_log.resolve_current(schedule_dir)

    let now = monotonic_now_ms()

    // Build job state: start with ALL persisted jobs, then overlay config tasks
    let base_jobs =
      list.fold(persisted_jobs, dict.new(), fn(acc, job) {
        dict.insert(acc, job.name, job)
      })

    // Overlay config tasks (update query/interval/delivery if config changed)
    let jobs =
      list.fold(tasks, base_jobs, fn(acc, task) {
        case dict.get(acc, task.name) {
          Ok(saved) ->
            dict.insert(
              acc,
              task.name,
              ScheduledJob(
                ..saved,
                query: task.query,
                interval_ms: task.interval_ms,
                delivery: task.delivery,
                only_if_changed: task.only_if_changed,
              ),
            )
          Error(_) ->
            dict.insert(
              acc,
              task.name,
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
                job_source: ProfileJob,
                kind: RecurringTask,
                due_at: None,
                for_: ForAgent,
                title: task.name,
                body: "",
                duration_minutes: 0,
                tags: [],
                created_at: get_datetime(),
                fired_count: 0,
                recurrence_end_at: None,
                max_occurrences: None,
              ),
            )
        }
      })

    // Re-arm timers for all active jobs (persisted + config)
    let _ =
      dict.each(jobs, fn(name, job) {
        case job.status {
          Completed | Cancelled | Failed(_) -> Nil
          _ ->
            case job.kind {
              RecurringTask ->
                case job.interval_ms > 0 {
                  True -> {
                    let delay = case job.last_run_ms {
                      Some(last_ms) -> {
                        let elapsed = now - last_ms
                        let remaining = job.interval_ms - elapsed
                        case remaining > 0 {
                          True -> remaining
                          False -> 0
                        }
                      }
                      None -> 0
                    }
                    schedule_tick(self, name, delay)
                  }
                  False -> Nil
                }
              types.Reminder | types.Appointment ->
                case job.due_at {
                  Some(due) -> {
                    let delay = ms_until_datetime(due)
                    schedule_tick(self, name, case delay < 1 {
                      True -> 1
                      False -> delay
                    })
                  }
                  None -> Nil
                }
              types.Todo -> Nil
            }
        }
      })

    let job_count = dict.size(jobs)
    slog.info(
      "scheduler",
      "start",
      "Scheduler started with " <> int_to_string(job_count) <> " jobs",
      None,
    )

    // Enter event loop
    scheduler_loop(
      self,
      jobs,
      cognitive,
      schedule_dir,
      stuck_timeout_ms,
      max_cycles_per_hour,
      token_budget_per_hour,
      [],
      [],
    )
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
  schedule_dir: String,
  stuck_timeout_ms: Int,
  max_cycles_per_hour: Int,
  token_budget_per_hour: Int,
  cycle_timestamps: List(Int),
  token_usage: List(#(Int, Int)),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(self)

  let msg = process.selector_receive_forever(selector)
  let loop = fn(j) {
    scheduler_loop(
      self,
      j,
      cognitive,
      schedule_dir,
      stuck_timeout_ms,
      max_cycles_per_hour,
      token_budget_per_hour,
      cycle_timestamps,
      token_usage,
    )
  }
  let loop_with_tracking = fn(j, cts, tu) {
    scheduler_loop(
      self,
      j,
      cognitive,
      schedule_dir,
      stuck_timeout_ms,
      max_cycles_per_hour,
      token_budget_per_hour,
      cts,
      tu,
    )
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
            Cancelled | Completed -> loop(jobs)
            _ -> {
              // Rate limit check
              let now = monotonic_now_ms()
              let hour_ago = now - 3_600_000
              let recent_cycles =
                list.filter(cycle_timestamps, fn(ts) { ts > hour_ago })
              let recent_tokens =
                list.filter(token_usage, fn(tu) { tu.0 > hour_ago })
              let total_tokens =
                list.fold(recent_tokens, 0, fn(acc, tu) { acc + tu.1 })
              let cycles_at_limit =
                max_cycles_per_hour > 0
                && list.length(recent_cycles) >= max_cycles_per_hour
              let tokens_at_limit =
                token_budget_per_hour > 0
                && total_tokens >= token_budget_per_hour
              case cycles_at_limit || tokens_at_limit {
                True -> {
                  let reason = case cycles_at_limit, tokens_at_limit {
                    True, True -> "cycle + token budget"
                    True, False -> "cycle limit"
                    False, True -> "token budget"
                    False, False -> "rate limit"
                  }
                  slog.warn(
                    "scheduler",
                    "loop",
                    "Rate limit ("
                      <> reason
                      <> "): skipping job '"
                      <> name
                      <> "', rescheduling",
                    None,
                  )
                  schedule_tick(self, name, job.interval_ms)
                  loop(jobs)
                }
                False -> {
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
                  process.send_after(
                    self,
                    stuck_timeout_ms,
                    StuckJobCheck(name:),
                  )

                  // Track this cycle for rate limiting
                  let new_timestamps = [now, ..recent_cycles]
                  loop_with_tracking(
                    updated_jobs,
                    new_timestamps,
                    recent_tokens,
                  )
                }
              }
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
              let should_recur =
                job.interval_ms > 0
                && {
                  case job.max_occurrences {
                    Some(max) -> job.fired_count < max
                    None -> True
                  }
                }
                && {
                  case job.recurrence_end_at {
                    Some(end_at) -> ms_until_datetime(end_at) > 0
                    None -> True
                  }
                }
              let updated_job =
                ScheduledJob(
                  ..job,
                  status: case should_recur {
                    True -> Failed(reason: "Stuck job timeout")
                    False -> Completed
                  },
                  error_count: job.error_count + 1,
                )
              let updated_jobs = dict.insert(jobs, name, updated_job)

              // Only schedule next tick if recurring
              case should_recur {
                True -> schedule_tick(self, name, job.interval_ms)
                False -> Nil
              }

              schedule_log.append(schedule_dir, updated_job, types.Fire)

              loop(updated_jobs)
            }
            // Already completed or failed — ignore
            _ -> loop(jobs)
          }
      }
    }

    JobComplete(name:, result:, tokens_used:) -> {
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
                WebhookDelivery(..) ->
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

          let new_fired = job.fired_count + 1
          let should_recur =
            job.interval_ms > 0
            && {
              case job.max_occurrences {
                Some(max) -> new_fired < max
                None -> True
              }
            }
            && {
              case job.recurrence_end_at {
                Some(end_at) -> ms_until_datetime(end_at) > 0
                None -> True
              }
            }

          let updated_job =
            ScheduledJob(
              ..job,
              status: case should_recur {
                True -> Pending
                False -> Completed
              },
              last_run_ms: Some(now),
              last_result: Some(result),
              run_count: job.run_count + 1,
              fired_count: new_fired,
            )
          let updated_jobs = dict.insert(jobs, name, updated_job)

          // Only schedule next tick if recurring
          case should_recur {
            True -> schedule_tick(self, name, job.interval_ms)
            False -> Nil
          }

          schedule_log.append(schedule_dir, updated_job, types.Complete)

          // Track token usage for rate limiting
          let hour_ago = now - 3_600_000
          let recent_tokens =
            list.filter(token_usage, fn(tu) { tu.0 > hour_ago })
          let new_tokens = case tokens_used > 0 {
            True -> [#(now, tokens_used), ..recent_tokens]
            False -> recent_tokens
          }
          loop_with_tracking(updated_jobs, cycle_timestamps, new_tokens)
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
          let should_recur =
            job.interval_ms > 0
            && {
              case job.max_occurrences {
                Some(max) -> job.fired_count < max
                None -> True
              }
            }
            && {
              case job.recurrence_end_at {
                Some(end_at) -> ms_until_datetime(end_at) > 0
                None -> True
              }
            }
          let updated_job =
            ScheduledJob(
              ..job,
              status: case should_recur {
                True -> Failed(reason:)
                False -> Completed
              },
              error_count: job.error_count + 1,
            )
          let updated_jobs = dict.insert(jobs, name, updated_job)

          // Only schedule next tick if recurring
          case should_recur {
            True -> schedule_tick(self, name, job.interval_ms)
            False -> Nil
          }

          schedule_log.append(schedule_dir, updated_job, types.Update)

          loop(updated_jobs)
        }
      }
    }

    types.AddJob(job:, reply_to:) -> {
      case dict.get(jobs, job.name) {
        Ok(_) -> {
          process.send(reply_to, Error("Job already exists: " <> job.name))
          loop(jobs)
        }
        Error(_) -> {
          let updated_jobs = dict.insert(jobs, job.name, job)
          // Arm timer for due_at items
          case job.kind {
            RecurringTask ->
              case job.interval_ms > 0 {
                True -> schedule_tick(self, job.name, job.interval_ms)
                False -> Nil
              }
            types.Reminder | types.Appointment ->
              case job.due_at {
                Some(due) -> {
                  let delay = ms_until_datetime(due)
                  schedule_tick(self, job.name, case delay < 1 {
                    True -> 1
                    False -> delay
                  })
                }
                None -> Nil
              }
            types.Todo -> Nil
          }
          schedule_log.append(schedule_dir, job, types.Create)
          process.send(reply_to, Ok(job.name))
          slog.info("scheduler", "loop", "Added job '" <> job.name <> "'", None)
          loop(updated_jobs)
        }
      }
    }

    types.RemoveJob(name:, reply_to:) -> {
      case dict.get(jobs, name) {
        Error(_) -> {
          process.send(reply_to, Error("Job not found: " <> name))
          loop(jobs)
        }
        Ok(job) -> {
          let cancelled_job = ScheduledJob(..job, status: Cancelled)
          let updated_jobs = dict.insert(jobs, name, cancelled_job)
          schedule_log.append(schedule_dir, cancelled_job, types.Cancel)
          process.send(reply_to, Ok(Nil))
          slog.info("scheduler", "loop", "Removed job '" <> name <> "'", None)
          loop(updated_jobs)
        }
      }
    }

    types.UpdateJob(name:, updates:, reply_to:) -> {
      case dict.get(jobs, name) {
        Error(_) -> {
          process.send(reply_to, Error("Job not found: " <> name))
          loop(jobs)
        }
        Ok(job) -> {
          let updated_job =
            ScheduledJob(
              ..job,
              title: option.unwrap(updates.title, job.title),
              body: option.unwrap(updates.body, job.body),
              due_at: case updates.due_at {
                Some(d) -> Some(d)
                None -> job.due_at
              },
              tags: option.unwrap(updates.tags, job.tags),
            )
          // Re-arm timer if due_at changed
          case updates.due_at {
            Some(new_due) ->
              case updated_job.kind {
                types.Reminder | types.Appointment -> {
                  let delay = ms_until_datetime(new_due)
                  schedule_tick(self, name, case delay < 1 {
                    True -> 1
                    False -> delay
                  })
                }
                _ -> Nil
              }
            None -> Nil
          }
          let updated_jobs = dict.insert(jobs, name, updated_job)
          schedule_log.append(schedule_dir, updated_job, types.Update)
          process.send(reply_to, Ok(Nil))
          loop(updated_jobs)
        }
      }
    }

    types.GetJobs(query:, reply_to:) -> {
      let all_jobs = dict.values(jobs)
      let filtered =
        all_jobs
        |> list.filter(fn(j) {
          let kind_ok = case query.kinds {
            [] -> True
            ks -> list.contains(ks, j.kind)
          }
          let status_ok = case query.statuses {
            [] -> True
            ss -> list.any(ss, fn(s) { status_eq(s, j.status) })
          }
          let for_ok = case query.for_ {
            None -> True
            Some(f) -> j.for_ == f
          }
          let overdue_ok = case query.overdue_only {
            False -> True
            True ->
              case j.due_at {
                Some(due) -> ms_until_datetime(due) < 0
                None -> False
              }
          }
          kind_ok && status_ok && for_ok && overdue_ok
        })
        |> list.take(query.max_results)
      process.send(reply_to, filtered)
      loop(jobs)
    }

    types.GetBudgetRemaining(reply_to:) -> {
      let now = monotonic_now_ms()
      let hour_ago = now - 3_600_000
      let recent_cycles =
        list.filter(cycle_timestamps, fn(ts) { ts > hour_ago })
      let recent_tokens = list.filter(token_usage, fn(tu) { tu.0 > hour_ago })
      let total_tokens = list.fold(recent_tokens, 0, fn(acc, tu) { acc + tu.1 })
      process.send(
        reply_to,
        types.BudgetStatus(
          cycles_used: list.length(recent_cycles),
          cycles_limit: max_cycles_per_hour,
          tokens_used: total_tokens,
          tokens_limit: token_budget_per_hour,
        ),
      )
      loop(jobs)
    }

    types.CompleteJob(name:, reply_to:) -> {
      case dict.get(jobs, name) {
        Error(_) -> {
          process.send(reply_to, Error("Job not found: " <> name))
          loop(jobs)
        }
        Ok(job) -> {
          let completed_job = ScheduledJob(..job, status: Completed)
          let updated_jobs = dict.insert(jobs, name, completed_job)
          schedule_log.append(schedule_dir, completed_job, types.Complete)
          process.send(reply_to, Ok(Nil))
          slog.info("scheduler", "loop", "Completed job '" <> name <> "'", None)
          loop(updated_jobs)
        }
      }
    }
  }
}

fn status_eq(a: types.JobStatus, b: types.JobStatus) -> Bool {
  case a, b {
    Pending, Pending -> True
    Running, Running -> True
    Completed, Completed -> True
    Cancelled, Cancelled -> True
    Failed(_), Failed(_) -> True
    _, _ -> False
  }
}

@external(erlang, "springdrift_ffi", "ms_until_datetime")
fn ms_until_datetime(iso: String) -> Int

fn spawn_job(
  scheduler: Subject(SchedulerMessage),
  cognitive: Subject(agent_types.CognitiveMessage),
  job: ScheduledJob,
) -> Nil {
  let name = job.name
  process.spawn_unlinked(fn() {
    let reply_subj: Subject(agent_types.CognitiveReply) = process.new_subject()
    process.send(
      cognitive,
      agent_types.SchedulerInput(
        job_name: name,
        query: job.query,
        kind: job.kind,
        for_: job.for_,
        title: job.title,
        body: job.body,
        tags: job.tags,
        reply_to: reply_subj,
      ),
    )
    case process.receive(reply_subj, 300_000) {
      Ok(reply) -> {
        let tokens = case reply.usage {
          Some(usage) -> usage.input_tokens + usage.output_tokens
          None -> 0
        }
        process.send(
          scheduler,
          JobComplete(name:, result: reply.response, tokens_used: tokens),
        )
      }
      Error(_) ->
        process.send(scheduler, JobFailed(name:, reason: "Timeout (5 minutes)"))
    }
  })
  Nil
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
