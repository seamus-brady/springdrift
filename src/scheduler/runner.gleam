//// BEAM-native scheduler — runs scheduled tasks using OTP timer processes.
////
//// Each scheduled job gets a recurring timer via `process.send_after`.
//// When a timer fires, the scheduler sends the query to the cognitive loop
//// and delivers the result via the configured delivery channel.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import frontdoor/types as frontdoor_types
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import scheduler/delivery
import scheduler/log as schedule_log
import scheduler/types.{
  type IdleConfig, type ScheduleTaskConfig, type ScheduledJob,
  type SchedulerMessage, Cancelled, Completed, Failed, ForAgent, GetStatus,
  JobComplete, JobFailed, Pending, ProfileJob, RecurringTask, Running,
  ScheduledJob, StopAll, StuckJobCheck, Tick, UserInputObserved, WebhookDelivery,
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
  meta_max_reflection_budget_pct: Int,
  frontdoor: Subject(frontdoor_types.FrontdoorMessage),
  idle_config: IdleConfig,
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
        // Recovery: a recurring job that was marked Completed
        // (typically by an accidental complete_item call) but still has
        // remaining fires gets re-armed as Pending. Without this, a
        // single misuse silently kills the schedule forever — restart
        // alone won't recover.
        let recovered = case
          job.status,
          job.interval_ms > 0,
          remaining_fires_left(job)
        {
          Completed, True, True -> {
            slog.warn(
              "scheduler",
              "start",
              "Recovering recurring job '"
                <> job.name
                <> "' from Completed status (fired_count="
                <> int.to_string(job.fired_count)
                <> "; remaining fires available). Was likely killed by "
                <> "an accidental complete_item.",
              None,
            )
            ScheduledJob(..job, status: Pending)
          }
          _, _, _ -> job
        }
        dict.insert(acc, recovered.name, recovered)
      })
      |> apply_auto_purge()

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
                required_tools: task.required_tools,
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
                required_tools: task.required_tools,
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
      meta_max_reflection_budget_pct,
      frontdoor,
      idle_config,
      None,
      dict.new(),
      [],
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
  meta_max_reflection_budget_pct: Int,
  frontdoor: Subject(frontdoor_types.FrontdoorMessage),
  idle_config: IdleConfig,
  last_user_input_at_ms: option.Option(Int),
  defer_start_ms: Dict(String, Int),
  cycle_timestamps: List(Int),
  meta_cycle_timestamps: List(Int),
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
      meta_max_reflection_budget_pct,
      frontdoor,
      idle_config,
      last_user_input_at_ms,
      defer_start_ms,
      cycle_timestamps,
      meta_cycle_timestamps,
      token_usage,
    )
  }
  let loop_with_tracking = fn(j, cts, mts, tu) {
    scheduler_loop(
      self,
      j,
      cognitive,
      schedule_dir,
      stuck_timeout_ms,
      max_cycles_per_hour,
      token_budget_per_hour,
      meta_max_reflection_budget_pct,
      frontdoor,
      idle_config,
      last_user_input_at_ms,
      defer_start_ms,
      cts,
      mts,
      tu,
    )
  }
  let loop_with_idle = fn(liu, defers) {
    scheduler_loop(
      self,
      jobs,
      cognitive,
      schedule_dir,
      stuck_timeout_ms,
      max_cycles_per_hour,
      token_budget_per_hour,
      meta_max_reflection_budget_pct,
      frontdoor,
      idle_config,
      liu,
      defers,
      cycle_timestamps,
      meta_cycle_timestamps,
      token_usage,
    )
  }
  let loop_full = fn(j, defers) {
    scheduler_loop(
      self,
      j,
      cognitive,
      schedule_dir,
      stuck_timeout_ms,
      max_cycles_per_hour,
      token_budget_per_hour,
      meta_max_reflection_budget_pct,
      frontdoor,
      idle_config,
      last_user_input_at_ms,
      defers,
      cycle_timestamps,
      meta_cycle_timestamps,
      token_usage,
    )
  }
  let loop_fire = fn(j, defers, cts, mts, tu) {
    scheduler_loop(
      self,
      j,
      cognitive,
      schedule_dir,
      stuck_timeout_ms,
      max_cycles_per_hour,
      token_budget_per_hour,
      meta_max_reflection_budget_pct,
      frontdoor,
      idle_config,
      last_user_input_at_ms,
      defers,
      cts,
      mts,
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

    UserInputObserved(at_ms:) -> {
      loop_with_idle(Some(at_ms), defer_start_ms)
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
              let recent_meta =
                list.filter(meta_cycle_timestamps, fn(ts) { ts > hour_ago })
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
              // Phase F follow-up: meta-learning budget cap. Enforces
              // the % cap when this tick is for a meta_learning_* job.
              let is_meta = is_meta_learning_job(name)
              let total_in_hour = list.length(recent_cycles)
              let meta_in_hour = list.length(recent_meta)
              let projected_pct = case is_meta, total_in_hour {
                True, t if t > 0 ->
                  { meta_in_hour + 1 } * 100 / { total_in_hour + 1 }
                _, _ -> 0
              }
              let meta_at_limit =
                is_meta
                && meta_max_reflection_budget_pct > 0
                && projected_pct > meta_max_reflection_budget_pct
              case cycles_at_limit || tokens_at_limit || meta_at_limit {
                True -> {
                  let reason = case
                    cycles_at_limit,
                    tokens_at_limit,
                    meta_at_limit
                  {
                    _, _, True -> "meta-learning budget"
                    True, True, _ -> "cycle + token budget"
                    True, False, _ -> "cycle limit"
                    False, True, _ -> "token budget"
                    False, False, _ -> "rate limit"
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
                  // Idle-gate: defer recurring ticks while the operator
                  // is actively typing, up to a max deferral window
                  // after which we fire anyway so long conversations
                  // cannot starve recurring work.
                  let should_defer = case
                    job.kind,
                    idle_config.idle_window_ms > 0
                  {
                    RecurringTask, True ->
                      case last_user_input_at_ms {
                        Some(ts) -> now - ts < idle_config.idle_window_ms
                        None -> False
                      }
                    _, _ -> False
                  }
                  let defer_started_at = case dict.get(defer_start_ms, name) {
                    Ok(started) -> started
                    Error(_) -> now
                  }
                  let deferral_exhausted =
                    should_defer
                    && now - defer_started_at >= idle_config.max_defer_ms
                  case should_defer && !deferral_exhausted {
                    True -> {
                      slog.info(
                        "scheduler",
                        "loop",
                        "Idle-gate: deferring job '"
                          <> name
                          <> "' (operator active; retry in "
                          <> int_to_string(idle_config.retry_interval_ms)
                          <> "ms)",
                        None,
                      )
                      schedule_tick(self, name, idle_config.retry_interval_ms)
                      let new_defers = case dict.get(defer_start_ms, name) {
                        Ok(_) -> defer_start_ms
                        Error(_) -> dict.insert(defer_start_ms, name, now)
                      }
                      loop_full(jobs, new_defers)
                    }
                    False -> {
                      case deferral_exhausted {
                        True ->
                          slog.warn(
                            "scheduler",
                            "loop",
                            "Idle-gate: max defer ("
                              <> int_to_string(idle_config.max_defer_ms)
                              <> "ms) exhausted for '"
                              <> name
                              <> "' — firing despite operator activity",
                            None,
                          )
                        False -> Nil
                      }
                      slog.info(
                        "scheduler",
                        "loop",
                        "Tick: running job '" <> name <> "'",
                        None,
                      )
                      // Clear any deferral bookkeeping for this job.
                      let cleared_defers = dict.delete(defer_start_ms, name)
                      // Mark as running
                      let updated_job = ScheduledJob(..job, status: Running)
                      let updated_jobs = dict.insert(jobs, name, updated_job)

                      // Spawn async query to cognitive loop
                      spawn_job(self, cognitive, frontdoor, job)

                      // Schedule stuck-job timeout check
                      process.send_after(
                        self,
                        stuck_timeout_ms,
                        StuckJobCheck(name:),
                      )

                      // Track this cycle for rate limiting
                      let new_timestamps = [now, ..recent_cycles]
                      let new_meta_timestamps = case is_meta {
                        True -> [now, ..recent_meta]
                        False -> recent_meta
                      }
                      loop_fire(
                        updated_jobs,
                        cleared_defers,
                        new_timestamps,
                        new_meta_timestamps,
                        recent_tokens,
                      )
                    }
                  }
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

    JobComplete(name:, result:, tokens_used:, tools_fired:) -> {
      case dict.get(jobs, name) {
        Error(_) -> loop(jobs)
        Ok(job) -> {
          // Phase 3b required_tools check. If the job declares
          // required tools, every one must appear in the cycle's
          // tools_fired list. Missing tools → reroute to JobFailed
          // so the scheduler tab reflects reality rather than
          // letting narrated success pass as real success.
          let missing_required =
            list.filter(job.required_tools, fn(t) {
              !list.contains(tools_fired, t)
            })
          case missing_required {
            [_, ..] -> {
              let reason =
                "required tool(s) did not fire: "
                <> string.join(missing_required, ", ")
              slog.warn(
                "scheduler",
                "loop",
                "Job '" <> name <> "' completed but rejecting — " <> reason,
                None,
              )
              process.send(self, types.JobFailed(name: name, reason: reason))
              loop(jobs)
            }
            [] -> {
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
              loop_with_tracking(
                updated_jobs,
                cycle_timestamps,
                meta_cycle_timestamps,
                new_tokens,
              )
            }
          }
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
          // Refuse to terminate recurring jobs that still have fires
          // remaining. CompleteJob historically marked any job Completed,
          // which silently killed recurring schedules when the agent
          // tried to acknowledge a single fire. To terminate a recurring
          // schedule deliberately, use cancel_item.
          let has_remaining_fires =
            job.interval_ms > 0 && remaining_fires_left(job)
          case has_remaining_fires {
            True -> {
              let msg =
                "Refusing to mark recurring job '"
                <> name
                <> "' as completed: it has remaining scheduled fires "
                <> "(fired_count="
                <> int.to_string(job.fired_count)
                <> case job.max_occurrences {
                  Some(max) -> ", max=" <> int.to_string(max)
                  None -> ", unlimited"
                }
                <> "). Use cancel_item to terminate the recurrence "
                <> "intentionally, or wait for it to exhaust on its own."
              slog.warn("scheduler", "loop", msg, None)
              process.send(reply_to, Error(msg))
              loop(jobs)
            }
            False -> {
              let completed_job = ScheduledJob(..job, status: Completed)
              let updated_jobs = dict.insert(jobs, name, completed_job)
              schedule_log.append(schedule_dir, completed_job, types.Complete)
              process.send(reply_to, Ok(Nil))
              slog.info(
                "scheduler",
                "loop",
                "Completed job '" <> name <> "'",
                None,
              )
              loop(updated_jobs)
            }
          }
        }
      }
    }

    types.PurgeCancelled(reply_to:) -> {
      let to_purge =
        dict.to_list(jobs)
        |> list.filter(fn(pair) {
          let #(_name, job) = pair
          case job.status {
            Cancelled -> True
            Completed ->
              // Only purge completed one-shots (no interval)
              job.interval_ms <= 0
            _ -> False
          }
        })
      let purge_count = list.length(to_purge)
      let updated_jobs =
        list.fold(to_purge, jobs, fn(acc, pair) {
          let #(name, _) = pair
          dict.delete(acc, name)
        })
      process.send(reply_to, purge_count)
      slog.info(
        "scheduler",
        "purge_cancelled",
        "Purged " <> int.to_string(purge_count) <> " cancelled/completed jobs",
        None,
      )
      loop(updated_jobs)
    }
  }
}

/// Phase F follow-up. Cap on the % of recent cycles that may be
/// meta-learning fires (jobs whose name starts with `meta_learning_`).
/// 0 disables the cap.
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
  frontdoor: Subject(frontdoor_types.FrontdoorMessage),
  job: ScheduledJob,
) -> Nil {
  let name = job.name
  process.spawn_unlinked(fn() {
    // Per-job source_id with a uuid suffix so concurrent invocations
    // of the same job name don't collide on the routing table.
    let source_id = "scheduler:" <> name <> ":" <> generate_uuid()
    let delivery_subj: Subject(frontdoor_types.Delivery) = process.new_subject()

    process.send(
      frontdoor,
      frontdoor_types.Subscribe(
        source_id:,
        kind: frontdoor_types.SchedulerSource,
        sink: delivery_subj,
      ),
    )

    // Legacy reply_to kept for now — cognitive still writes to it on
    // terminal reply. Discarded when reply_to leaves UserInput.
    let throwaway = process.new_subject()
    process.send(
      cognitive,
      agent_types.SchedulerInput(
        source_id:,
        job_name: name,
        query: job.query,
        kind: job.kind,
        for_: job.for_,
        title: job.title,
        body: job.body,
        tags: job.tags,
        reply_to: throwaway,
      ),
    )

    case process.receive(delivery_subj, 300_000) {
      Ok(frontdoor_types.DeliverReply(
        cycle_id: _,
        response:,
        model: _,
        usage:,
        tools_fired:,
      )) -> {
        let tokens = case usage {
          Some(u) -> u.input_tokens + u.output_tokens
          None -> 0
        }
        process.send(
          scheduler,
          JobComplete(
            name:,
            result: response,
            tokens_used: tokens,
            tools_fired:,
          ),
        )
      }
      Ok(frontdoor_types.DeliverQuestion(..)) -> {
        // SchedulerSource questions are dropped by Frontdoor — this
        // shouldn't arrive. Treat as a failure defensively.
        process.send(
          scheduler,
          JobFailed(
            name:,
            reason: "Unexpected question delivered to scheduler source",
          ),
        )
      }
      Ok(frontdoor_types.DeliverClosed) ->
        process.send(
          scheduler,
          JobFailed(name:, reason: "Frontdoor subscription closed"),
        )
      Error(_) ->
        process.send(scheduler, JobFailed(name:, reason: "Timeout (5 minutes)"))
    }

    // Clean up the per-job subscription so the routing table doesn't grow.
    process.send(frontdoor, frontdoor_types.Unsubscribe(source_id))
  })
  Nil
}

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

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

/// Phase F follow-up: meta-learning budget cap. Recognises jobs by the
/// `meta_learning_` name prefix (the convention from
/// `src/meta_learning/scheduler.gleam`).
fn is_meta_learning_job(name: String) -> Bool {
  string.starts_with(name, "meta_learning_")
}

/// True when this recurring job still has fire budget left (max not
/// reached, end-date not passed). Used by the startup recovery to
/// detect Completed-but-shouldn't-be jobs, and by the CompleteJob
/// handler to refuse termination of live recurrences.
fn remaining_fires_left(job: ScheduledJob) -> Bool {
  case job.max_occurrences {
    Some(max) -> job.fired_count < max
    None -> True
  }
  && {
    case job.recurrence_end_at {
      Some(end_at) -> ms_until_datetime(end_at) > 0
      None -> True
    }
  }
}

/// Default retention window for terminal one-shot jobs. Configurable
/// via the scheduler runner's start() arguments in a future hook;
/// today the default applies uniformly.
const purge_retention_ms = 2_592_000_000

// 30 days in ms

/// Drop one-shot Cancelled or Completed jobs older than the retention
/// window. Recurring jobs are NEVER purged — their history is the
/// schedule. Returns the trimmed dict.
fn apply_auto_purge(
  jobs: Dict(String, ScheduledJob),
) -> Dict(String, ScheduledJob) {
  let now = monotonic_now_ms()
  let cutoff = now - purge_retention_ms
  let #(kept, purged) =
    dict.fold(jobs, #(dict.new(), 0), fn(acc, name, job) {
      let #(keep, count) = acc
      let purgeable = case job.status, job.interval_ms > 0 {
        Cancelled, False -> True
        Completed, False -> True
        _, _ -> False
      }
      let last_active = case job.last_run_ms {
        Some(ts) -> ts
        None -> now
      }
      case purgeable && last_active < cutoff {
        True -> #(keep, count + 1)
        False -> #(dict.insert(keep, name, job), count)
      }
    })
  case purged > 0 {
    True ->
      slog.info(
        "scheduler",
        "start",
        "Auto-purged " <> int.to_string(purged) <> " stale terminal job(s)",
        None,
      )
    False -> Nil
  }
  kept
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
