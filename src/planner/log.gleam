//// Append-only planner log — daily JSONL files in .springdrift/memory/planner/.
////
//// Tasks use daily rotation (YYYY-MM-DD-tasks.jsonl) like facts and narrative.
//// Endeavours use daily rotation (YYYY-MM-DD-endeavours.jsonl).
//// State is derived by replaying operations via resolve_tasks/resolve_endeavours.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import narrative/appraisal_types
import planner/config as planner_config
import planner/types.{
  type Blocker, type Endeavour, type EndeavourOp, type EndeavourOrigin,
  type EndeavourStatus, type ForecastBreakdown, type Phase, type PhaseStatus,
  type PlanStep, type PlannerTask, type SessionStatus, type Stakeholder,
  type TaskOp, type TaskOrigin, type TaskStatus, type WorkSession, Abandoned,
  Active, AddBlocker, AddCycleId, AddEndeavourPostMortem, AddPhase,
  AddPostMortem, AddPreMortem, AddTaskStep, AddTaskToEndeavour, AllUpdates,
  Blocker, CancelSession, Complete, CompleteStep, CreateEndeavour, CreateTask,
  DeleteEndeavour, DeleteTask, Draft, Endeavour, EndeavourAbandoned,
  EndeavourActive, EndeavourBlocked, EndeavourComplete, EndeavourFailed, Failed,
  FlagRisk, ForecastBreakdown, OnBlocker, OnHold, OnMilestone, Open, Owner,
  Pending, Periodic, Phase, PhaseBlocked, PhaseComplete, PhaseInProgress,
  PhaseNotStarted, PhaseSkipped, PlanStep, PlannerTask, RecordMetrics,
  RecordSession, RemoveTaskStep, Replan, ResolveBlocker, Reviewer,
  ScheduleSession, SendUpdate, SessionCompleted, SessionFailed,
  SessionInProgress, SessionScheduled, SessionSkipped, StakeholderObserver,
  SystemEndeavour, SystemTask, UpdateEndeavourFields,
  UpdateEndeavourForecastBreakdown, UpdateEndeavourStatus,
  UpdateForecastBreakdown, UpdateForecastScore, UpdateForecasterConfig,
  UpdatePhase, UpdateTaskFields, UpdateTaskStatus, UserEndeavour, UserTask,
  WorkSession, default_approval_config, new_endeavour,
}
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

// ---------------------------------------------------------------------------
// Task operations — append
// ---------------------------------------------------------------------------

/// Append a TaskOp to a dated JSONL file (YYYY-MM-DD-tasks.jsonl).
pub fn append_task_op(dir: String, op: TaskOp) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> "-tasks.jsonl"
  let json_str = json.to_string(encode_task_op(op))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug("planner/log", "append_task_op", "Appended task op", None)
    Error(e) ->
      slog.log_error(
        "planner/log",
        "append_task_op",
        "Failed to append: " <> simplifile.describe_error(e),
        None,
      )
  }
}

// ---------------------------------------------------------------------------
// Endeavour operations — append
// ---------------------------------------------------------------------------

/// Append an EndeavourOp to a dated JSONL file (YYYY-MM-DD-endeavours.jsonl).
pub fn append_endeavour_op(dir: String, op: EndeavourOp) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> "-endeavours.jsonl"
  let json_str = json.to_string(encode_endeavour_op(op))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug(
        "planner/log",
        "append_endeavour_op",
        "Appended endeavour op",
        None,
      )
    Error(e) ->
      slog.log_error(
        "planner/log",
        "append_endeavour_op",
        "Failed to append: " <> simplifile.describe_error(e),
        None,
      )
  }
}

// ---------------------------------------------------------------------------
// Loading — tasks
// ---------------------------------------------------------------------------

/// Load task operations for a specific date.
pub fn load_task_ops_date(dir: String, date: String) -> List(TaskOp) {
  let path = dir <> "/" <> date <> "-tasks.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_task_jsonl(content)
  }
}

/// Load all task operations from all dated JSONL files, in chronological order.
pub fn load_all_task_ops(dir: String) -> List(TaskOp) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      files
      |> list.filter(fn(f) { string.ends_with(f, "-tasks.jsonl") })
      |> list.sort(string.compare)
      |> list.flat_map(fn(f) {
        let date = string.drop_end(f, 12)
        load_task_ops_date(dir, date)
      })
    }
  }
}

/// Resolve current task state by replaying all operations.
pub fn resolve_tasks(ops: List(TaskOp)) -> List(PlannerTask) {
  let tasks: Dict(String, PlannerTask) =
    list.fold(ops, dict.new(), fn(acc, op) {
      case op {
        CreateTask(task:) -> dict.insert(acc, task.task_id, task)

        UpdateTaskStatus(task_id:, status:, at:) ->
          update_task(acc, task_id, fn(t) {
            PlannerTask(..t, status:, updated_at: at)
          })

        CompleteStep(task_id:, step_index:, at:) ->
          update_task(acc, task_id, fn(t) {
            let steps =
              list.map(t.plan_steps, fn(s) {
                case s.index == step_index {
                  True ->
                    PlanStep(..s, status: Complete, completed_at: Some(at))
                  False -> s
                }
              })
            // Auto-complete task when all steps are done
            let all_complete = list.all(steps, fn(s) { s.status == Complete })
            let new_status = case all_complete {
              True -> Complete
              False -> t.status
            }
            PlannerTask(
              ..t,
              plan_steps: steps,
              status: new_status,
              updated_at: at,
            )
          })

        FlagRisk(task_id:, text:, at:) ->
          update_task(acc, task_id, fn(t) {
            PlannerTask(
              ..t,
              materialised_risks: list.append(t.materialised_risks, [text]),
              updated_at: at,
            )
          })

        AddCycleId(task_id:, cycle_id:) ->
          update_task(acc, task_id, fn(t) {
            case list.contains(t.cycle_ids, cycle_id) {
              True -> t
              False ->
                PlannerTask(
                  ..t,
                  cycle_ids: list.append(t.cycle_ids, [cycle_id]),
                )
            }
          })

        UpdateForecastScore(task_id:, score:) ->
          update_task(acc, task_id, fn(t) {
            PlannerTask(..t, forecast_score: Some(score))
          })

        UpdateTaskFields(task_id:, title:, description:, at:) ->
          update_task(acc, task_id, fn(t) {
            let new_title = option.unwrap(title, t.title)
            let new_desc = option.unwrap(description, t.description)
            PlannerTask(
              ..t,
              title: new_title,
              description: new_desc,
              updated_at: at,
            )
          })

        AddTaskStep(task_id:, description:, at:) ->
          update_task(acc, task_id, fn(t) {
            let next_index = list.length(t.plan_steps)
            let step =
              PlanStep(
                index: next_index,
                description:,
                status: Pending,
                completed_at: None,
                verification: None,
              )
            PlannerTask(
              ..t,
              plan_steps: list.append(t.plan_steps, [step]),
              updated_at: at,
            )
          })

        RemoveTaskStep(task_id:, step_index:, at:) ->
          update_task(acc, task_id, fn(t) {
            let steps =
              list.filter(t.plan_steps, fn(s) { s.index != step_index })
            PlannerTask(..t, plan_steps: steps, updated_at: at)
          })

        UpdateForecastBreakdown(task_id:, score:, breakdown:) ->
          update_task(acc, task_id, fn(t) {
            PlannerTask(
              ..t,
              forecast_score: Some(score),
              forecast_breakdown: Some(breakdown),
            )
          })

        DeleteTask(task_id:) -> dict.delete(acc, task_id)

        AddPreMortem(task_id:, pre_mortem:) ->
          update_task(acc, task_id, fn(t) {
            PlannerTask(..t, pre_mortem: Some(pre_mortem))
          })

        AddPostMortem(task_id:, post_mortem:) ->
          update_task(acc, task_id, fn(t) {
            PlannerTask(..t, post_mortem: Some(post_mortem))
          })
      }
    })

  dict.values(tasks)
}

fn update_task(
  tasks: Dict(String, PlannerTask),
  task_id: String,
  updater: fn(PlannerTask) -> PlannerTask,
) -> Dict(String, PlannerTask) {
  case dict.get(tasks, task_id) {
    Ok(t) -> dict.insert(tasks, task_id, updater(t))
    Error(_) -> tasks
  }
}

// ---------------------------------------------------------------------------
// Loading — endeavours
// ---------------------------------------------------------------------------

/// Load endeavour operations for a specific date.
pub fn load_endeavour_ops_date(dir: String, date: String) -> List(EndeavourOp) {
  let path = dir <> "/" <> date <> "-endeavours.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_endeavour_jsonl(content)
  }
}

/// Load all endeavour operations from all dated JSONL files.
pub fn load_all_endeavour_ops(dir: String) -> List(EndeavourOp) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      files
      |> list.filter(fn(f) { string.ends_with(f, "-endeavours.jsonl") })
      |> list.sort(string.compare)
      |> list.flat_map(fn(f) {
        let date = string.drop_end(f, 17)
        load_endeavour_ops_date(dir, date)
      })
    }
  }
}

/// Resolve current endeavour state by replaying all operations.
pub fn resolve_endeavours(ops: List(EndeavourOp)) -> List(Endeavour) {
  let endeavours: Dict(String, Endeavour) =
    list.fold(ops, dict.new(), fn(acc, op) {
      case op {
        CreateEndeavour(endeavour:) ->
          dict.insert(acc, endeavour.endeavour_id, endeavour)

        AddTaskToEndeavour(endeavour_id:, task_id:) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            case list.contains(e.task_ids, task_id) {
              True -> e
              False ->
                Endeavour(..e, task_ids: list.append(e.task_ids, [task_id]))
            }
          })

        UpdateEndeavourStatus(endeavour_id:, status:) ->
          update_endeavour(acc, endeavour_id, fn(e) { Endeavour(..e, status:) })

        UpdatePhase(endeavour_id:, phase_name:, status:) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            let phases =
              list.map(e.phases, fn(p) {
                case p.name == phase_name {
                  True -> Phase(..p, status:)
                  False -> p
                }
              })
            Endeavour(..e, phases:)
          })

        AddPhase(endeavour_id:, phase:) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            Endeavour(..e, phases: list.append(e.phases, [phase]))
          })

        AddBlocker(endeavour_id:, blocker:) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            Endeavour(..e, blockers: list.append(e.blockers, [blocker]))
          })

        ResolveBlocker(endeavour_id:, blocker_id:, resolution:, at:) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            let blockers =
              list.map(e.blockers, fn(b) {
                case b.id == blocker_id {
                  True ->
                    Blocker(
                      ..b,
                      resolved_at: Some(at),
                      resolution: Some(resolution),
                    )
                  False -> b
                }
              })
            Endeavour(..e, blockers:)
          })

        RecordSession(endeavour_id:, session:) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            Endeavour(
              ..e,
              work_sessions: list.append(e.work_sessions, [session]),
              total_cycles: e.total_cycles + session.actual_cycles,
              total_tokens: e.total_tokens + session.actual_tokens,
            )
          })

        ScheduleSession(endeavour_id:, session:) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            Endeavour(
              ..e,
              work_sessions: list.append(e.work_sessions, [session]),
              next_session: Some(session.scheduled_at),
            )
          })

        SendUpdate(endeavour_id:, at:, ..) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            Endeavour(..e, last_update_sent: Some(at))
          })

        Replan(endeavour_id:, new_phases:, ..) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            Endeavour(..e, phases: new_phases, replan_count: e.replan_count + 1)
          })

        RecordMetrics(endeavour_id:, cycles:, tokens:) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            Endeavour(
              ..e,
              total_cycles: e.total_cycles + cycles,
              total_tokens: e.total_tokens + tokens,
            )
          })

        UpdateForecasterConfig(
          endeavour_id:,
          feature_overrides:,
          threshold_override:,
        ) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            Endeavour(..e, feature_overrides:, threshold_override:)
          })

        UpdateEndeavourFields(
          endeavour_id:,
          goal:,
          success_criteria:,
          deadline:,
          update_cadence:,
          approval_config:,
        ) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            Endeavour(
              ..e,
              goal: option.unwrap(goal, e.goal),
              success_criteria: option.unwrap(
                success_criteria,
                e.success_criteria,
              ),
              deadline: case deadline {
                Some(d) -> Some(d)
                None -> e.deadline
              },
              update_cadence: case update_cadence {
                Some(c) -> Some(c)
                None -> e.update_cadence
              },
              approval_config: option.unwrap(approval_config, e.approval_config),
            )
          })

        CancelSession(endeavour_id:, session_id:, reason:, ..) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            let sessions =
              list.map(e.work_sessions, fn(s) {
                case s.session_id == session_id {
                  True -> WorkSession(..s, status: SessionSkipped(reason:))
                  False -> s
                }
              })
            Endeavour(..e, work_sessions: sessions)
          })

        UpdateEndeavourForecastBreakdown(endeavour_id:, score:, breakdown:) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            Endeavour(
              ..e,
              forecast_score: Some(score),
              forecast_breakdown: Some(breakdown),
            )
          })

        DeleteEndeavour(endeavour_id:) -> dict.delete(acc, endeavour_id)

        AddEndeavourPostMortem(endeavour_id:, post_mortem:) ->
          update_endeavour(acc, endeavour_id, fn(e) {
            Endeavour(..e, post_mortem: Some(post_mortem))
          })
      }
    })

  dict.values(endeavours)
}

fn update_endeavour(
  acc: Dict(String, Endeavour),
  endeavour_id: String,
  f: fn(Endeavour) -> Endeavour,
) -> Dict(String, Endeavour) {
  case dict.get(acc, endeavour_id) {
    Ok(e) -> dict.insert(acc, endeavour_id, f(e))
    Error(_) -> acc
  }
}

// ---------------------------------------------------------------------------
// JSON encoding — TaskOp
// ---------------------------------------------------------------------------

pub fn encode_task_op(op: TaskOp) -> json.Json {
  case op {
    CreateTask(task:) ->
      json.object([
        #("op", json.string("create_task")),
        #("task", encode_task(task)),
      ])

    UpdateTaskStatus(task_id:, status:, at:) ->
      json.object([
        #("op", json.string("update_task_status")),
        #("task_id", json.string(task_id)),
        #("status", json.string(encode_task_status(status))),
        #("at", json.string(at)),
      ])

    CompleteStep(task_id:, step_index:, at:) ->
      json.object([
        #("op", json.string("complete_step")),
        #("task_id", json.string(task_id)),
        #("step_index", json.int(step_index)),
        #("at", json.string(at)),
      ])

    FlagRisk(task_id:, text:, at:) ->
      json.object([
        #("op", json.string("flag_risk")),
        #("task_id", json.string(task_id)),
        #("text", json.string(text)),
        #("at", json.string(at)),
      ])

    AddCycleId(task_id:, cycle_id:) ->
      json.object([
        #("op", json.string("add_cycle_id")),
        #("task_id", json.string(task_id)),
        #("cycle_id", json.string(cycle_id)),
      ])

    UpdateForecastScore(task_id:, score:) ->
      json.object([
        #("op", json.string("update_forecast_score")),
        #("task_id", json.string(task_id)),
        #("score", json.float(score)),
      ])

    UpdateTaskFields(task_id:, title:, description:, at:) ->
      json.object([
        #("op", json.string("update_task_fields")),
        #("task_id", json.string(task_id)),
        #("title", case title {
          Some(t) -> json.string(t)
          None -> json.null()
        }),
        #("description", case description {
          Some(d) -> json.string(d)
          None -> json.null()
        }),
        #("at", json.string(at)),
      ])

    AddTaskStep(task_id:, description:, at:) ->
      json.object([
        #("op", json.string("add_task_step")),
        #("task_id", json.string(task_id)),
        #("description", json.string(description)),
        #("at", json.string(at)),
      ])

    RemoveTaskStep(task_id:, step_index:, at:) ->
      json.object([
        #("op", json.string("remove_task_step")),
        #("task_id", json.string(task_id)),
        #("step_index", json.int(step_index)),
        #("at", json.string(at)),
      ])

    UpdateForecastBreakdown(task_id:, score:, breakdown:) ->
      json.object([
        #("op", json.string("update_forecast_breakdown")),
        #("task_id", json.string(task_id)),
        #("score", json.float(score)),
        #("breakdown", json.array(breakdown, encode_breakdown)),
      ])

    DeleteTask(task_id:) ->
      json.object([
        #("op", json.string("delete_task")),
        #("task_id", json.string(task_id)),
      ])

    AddPreMortem(task_id:, pre_mortem:) ->
      json.object([
        #("op", json.string("add_pre_mortem")),
        #("task_id", json.string(task_id)),
        #("pre_mortem", appraisal_types.encode_pre_mortem(pre_mortem)),
      ])

    AddPostMortem(task_id:, post_mortem:) ->
      json.object([
        #("op", json.string("add_post_mortem")),
        #("task_id", json.string(task_id)),
        #("post_mortem", appraisal_types.encode_post_mortem(post_mortem)),
      ])
  }
}

fn encode_breakdown(b: ForecastBreakdown) -> json.Json {
  json.object([
    #("feature_name", json.string(b.feature_name)),
    #("magnitude", json.int(b.magnitude)),
    #("rationale", json.string(b.rationale)),
    #("weighted_score", json.float(b.weighted_score)),
  ])
}

pub fn encode_task(t: PlannerTask) -> json.Json {
  json.object([
    #("task_id", json.string(t.task_id)),
    #("endeavour_id", case t.endeavour_id {
      Some(id) -> json.string(id)
      None -> json.null()
    }),
    #("origin", json.string(encode_task_origin(t.origin))),
    #("title", json.string(t.title)),
    #("description", json.string(t.description)),
    #("status", json.string(encode_task_status(t.status))),
    #("plan_steps", json.array(t.plan_steps, encode_step)),
    #(
      "dependencies",
      json.array(t.dependencies, fn(d) {
        json.object([
          #("from", json.string(d.0)),
          #("to", json.string(d.1)),
        ])
      }),
    ),
    #("complexity", json.string(t.complexity)),
    #("risks", json.array(t.risks, json.string)),
    #("materialised_risks", json.array(t.materialised_risks, json.string)),
    #("created_at", json.string(t.created_at)),
    #("updated_at", json.string(t.updated_at)),
    #("cycle_ids", json.array(t.cycle_ids, json.string)),
    #("forecast_score", case t.forecast_score {
      Some(s) -> json.float(s)
      None -> json.null()
    }),
    #("forecast_breakdown", case t.forecast_breakdown {
      Some(bs) -> json.array(bs, encode_breakdown)
      None -> json.null()
    }),
    #("pre_mortem", appraisal_types.encode_optional_pre_mortem(t.pre_mortem)),
    #("post_mortem", appraisal_types.encode_optional_post_mortem(t.post_mortem)),
  ])
}

fn encode_step(s: PlanStep) -> json.Json {
  json.object([
    #("index", json.int(s.index)),
    #("description", json.string(s.description)),
    #("status", json.string(encode_task_status(s.status))),
    #("completed_at", case s.completed_at {
      Some(at) -> json.string(at)
      None -> json.null()
    }),
    #("verification", case s.verification {
      Some(v) -> json.string(v)
      None -> json.null()
    }),
  ])
}

fn encode_task_status(s: TaskStatus) -> String {
  case s {
    Pending -> "pending"
    Active -> "active"
    Complete -> "complete"
    Failed -> "failed"
    Abandoned -> "abandoned"
  }
}

fn encode_task_origin(o: TaskOrigin) -> String {
  case o {
    SystemTask -> "system"
    UserTask -> "user"
  }
}

// ---------------------------------------------------------------------------
// JSON encoding — EndeavourOp
// ---------------------------------------------------------------------------

pub fn encode_endeavour_op(op: EndeavourOp) -> json.Json {
  case op {
    CreateEndeavour(endeavour:) ->
      json.object([
        #("op", json.string("create_endeavour")),
        #("endeavour", encode_endeavour(endeavour)),
      ])
    AddTaskToEndeavour(endeavour_id:, task_id:) ->
      json.object([
        #("op", json.string("add_task")),
        #("endeavour_id", json.string(endeavour_id)),
        #("task_id", json.string(task_id)),
      ])
    UpdateEndeavourStatus(endeavour_id:, status:) ->
      json.object([
        #("op", json.string("update_endeavour_status")),
        #("endeavour_id", json.string(endeavour_id)),
        #("status", json.string(encode_endeavour_status(status))),
      ])
    UpdatePhase(endeavour_id:, phase_name:, status:) ->
      json.object([
        #("op", json.string("update_phase")),
        #("endeavour_id", json.string(endeavour_id)),
        #("phase_name", json.string(phase_name)),
        #("status", json.string(encode_phase_status(status))),
      ])
    AddPhase(endeavour_id:, phase:) ->
      json.object([
        #("op", json.string("add_phase")),
        #("endeavour_id", json.string(endeavour_id)),
        #("phase", encode_phase(phase)),
      ])
    AddBlocker(endeavour_id:, blocker:) ->
      json.object([
        #("op", json.string("add_blocker")),
        #("endeavour_id", json.string(endeavour_id)),
        #("blocker", encode_blocker(blocker)),
      ])
    ResolveBlocker(endeavour_id:, blocker_id:, resolution:, at:) ->
      json.object([
        #("op", json.string("resolve_blocker")),
        #("endeavour_id", json.string(endeavour_id)),
        #("blocker_id", json.string(blocker_id)),
        #("resolution", json.string(resolution)),
        #("at", json.string(at)),
      ])
    RecordSession(endeavour_id:, session:) ->
      json.object([
        #("op", json.string("record_session")),
        #("endeavour_id", json.string(endeavour_id)),
        #("session", encode_work_session(session)),
      ])
    ScheduleSession(endeavour_id:, session:) ->
      json.object([
        #("op", json.string("schedule_session")),
        #("endeavour_id", json.string(endeavour_id)),
        #("session", encode_work_session(session)),
      ])
    SendUpdate(endeavour_id:, stakeholder:, channel:, content:, at:) ->
      json.object([
        #("op", json.string("send_update")),
        #("endeavour_id", json.string(endeavour_id)),
        #("stakeholder", json.string(stakeholder)),
        #("channel", json.string(channel)),
        #("content", json.string(content)),
        #("at", json.string(at)),
      ])
    Replan(endeavour_id:, reason:, new_phases:) ->
      json.object([
        #("op", json.string("replan")),
        #("endeavour_id", json.string(endeavour_id)),
        #("reason", json.string(reason)),
        #("new_phases", json.array(new_phases, encode_phase)),
      ])
    RecordMetrics(endeavour_id:, cycles:, tokens:) ->
      json.object([
        #("op", json.string("record_metrics")),
        #("endeavour_id", json.string(endeavour_id)),
        #("cycles", json.int(cycles)),
        #("tokens", json.int(tokens)),
      ])
    UpdateForecasterConfig(
      endeavour_id:,
      feature_overrides:,
      threshold_override:,
    ) ->
      json.object([
        #("op", json.string("update_forecaster_config")),
        #("endeavour_id", json.string(endeavour_id)),
        #("feature_overrides", case feature_overrides {
          Some(fs) -> planner_config.encode_features(fs)
          None -> json.null()
        }),
        #("threshold_override", case threshold_override {
          Some(t) -> json.float(t)
          None -> json.null()
        }),
      ])
    UpdateEndeavourFields(
      endeavour_id:,
      goal:,
      success_criteria:,
      deadline:,
      update_cadence:,
      approval_config:,
    ) ->
      json.object([
        #("op", json.string("update_endeavour_fields")),
        #("endeavour_id", json.string(endeavour_id)),
        #("goal", case goal {
          Some(g) -> json.string(g)
          None -> json.null()
        }),
        #("success_criteria", case success_criteria {
          Some(sc) -> json.array(sc, json.string)
          None -> json.null()
        }),
        #("deadline", case deadline {
          Some(d) -> json.string(d)
          None -> json.null()
        }),
        #("update_cadence", case update_cadence {
          Some(c) -> json.string(c)
          None -> json.null()
        }),
        #("approval_config", case approval_config {
          Some(_) -> json.string("custom")
          None -> json.null()
        }),
      ])
    CancelSession(endeavour_id:, session_id:, reason:, at:) ->
      json.object([
        #("op", json.string("cancel_session")),
        #("endeavour_id", json.string(endeavour_id)),
        #("session_id", json.string(session_id)),
        #("reason", json.string(reason)),
        #("at", json.string(at)),
      ])
    UpdateEndeavourForecastBreakdown(endeavour_id:, score:, breakdown:) ->
      json.object([
        #("op", json.string("update_endeavour_forecast_breakdown")),
        #("endeavour_id", json.string(endeavour_id)),
        #("score", json.float(score)),
        #("breakdown", json.array(breakdown, encode_breakdown)),
      ])
    DeleteEndeavour(endeavour_id:) ->
      json.object([
        #("op", json.string("delete_endeavour")),
        #("endeavour_id", json.string(endeavour_id)),
      ])

    AddEndeavourPostMortem(endeavour_id:, post_mortem:) ->
      json.object([
        #("op", json.string("add_endeavour_post_mortem")),
        #("endeavour_id", json.string(endeavour_id)),
        #(
          "post_mortem",
          appraisal_types.encode_endeavour_post_mortem(post_mortem),
        ),
      ])
  }
}

pub fn encode_endeavour(e: Endeavour) -> json.Json {
  json.object([
    #("endeavour_id", json.string(e.endeavour_id)),
    #("origin", json.string(encode_endeavour_origin(e.origin))),
    #("title", json.string(e.title)),
    #("description", json.string(e.description)),
    #("status", json.string(encode_endeavour_status(e.status))),
    #("task_ids", json.array(e.task_ids, json.string)),
    #("created_at", json.string(e.created_at)),
    #("updated_at", json.string(e.updated_at)),
    #("goal", json.string(e.goal)),
    #("success_criteria", json.array(e.success_criteria, json.string)),
    #("deadline", case e.deadline {
      Some(d) -> json.string(d)
      None -> json.null()
    }),
    #("phases", json.array(e.phases, encode_phase)),
    #("work_sessions", json.array(e.work_sessions, encode_work_session)),
    #("next_session", case e.next_session {
      Some(s) -> json.string(s)
      None -> json.null()
    }),
    #("stakeholders", json.array(e.stakeholders, encode_stakeholder)),
    #("last_update_sent", case e.last_update_sent {
      Some(s) -> json.string(s)
      None -> json.null()
    }),
    #("update_cadence", case e.update_cadence {
      Some(s) -> json.string(s)
      None -> json.null()
    }),
    #("blockers", json.array(e.blockers, encode_blocker)),
    #("replan_count", json.int(e.replan_count)),
    #("original_phase_count", json.int(e.original_phase_count)),
    #("total_cycles", json.int(e.total_cycles)),
    #("total_tokens", json.int(e.total_tokens)),
    #("feature_overrides", case e.feature_overrides {
      Some(fs) -> planner_config.encode_features(fs)
      None -> json.null()
    }),
    #("threshold_override", case e.threshold_override {
      Some(t) -> json.float(t)
      None -> json.null()
    }),
    #("forecast_score", case e.forecast_score {
      Some(s) -> json.float(s)
      None -> json.null()
    }),
    #("forecast_breakdown", case e.forecast_breakdown {
      Some(bs) -> json.array(bs, encode_breakdown)
      None -> json.null()
    }),
    #(
      "post_mortem",
      appraisal_types.encode_optional_endeavour_post_mortem(e.post_mortem),
    ),
  ])
}

fn encode_endeavour_status(s: EndeavourStatus) -> String {
  case s {
    Open -> "open"
    Draft -> "draft"
    EndeavourActive -> "active"
    EndeavourBlocked -> "blocked"
    OnHold -> "on_hold"
    EndeavourComplete -> "complete"
    EndeavourFailed -> "failed"
    EndeavourAbandoned -> "abandoned"
  }
}

fn encode_endeavour_origin(o: EndeavourOrigin) -> String {
  case o {
    SystemEndeavour -> "system"
    UserEndeavour -> "user"
  }
}

fn encode_phase(p: Phase) -> json.Json {
  json.object([
    #("name", json.string(p.name)),
    #("description", json.string(p.description)),
    #("status", json.string(encode_phase_status(p.status))),
    #("task_ids", json.array(p.task_ids, json.string)),
    #("depends_on", json.array(p.depends_on, json.string)),
    #("milestone", case p.milestone {
      Some(m) -> json.string(m)
      None -> json.null()
    }),
    #("estimated_sessions", json.int(p.estimated_sessions)),
    #("actual_sessions", json.int(p.actual_sessions)),
  ])
}

fn encode_phase_status(s: PhaseStatus) -> String {
  case s {
    PhaseNotStarted -> "not_started"
    PhaseInProgress -> "in_progress"
    PhaseComplete -> "complete"
    PhaseBlocked(reason) -> "blocked:" <> reason
    PhaseSkipped(reason) -> "skipped:" <> reason
  }
}

fn encode_work_session(s: WorkSession) -> json.Json {
  json.object([
    #("session_id", json.string(s.session_id)),
    #("scheduled_at", json.string(s.scheduled_at)),
    #("status", json.string(encode_session_status(s.status))),
    #("phase", json.string(s.phase)),
    #("focus", json.string(s.focus)),
    #("max_cycles", json.int(s.max_cycles)),
    #("max_tokens", json.int(s.max_tokens)),
    #("actual_cycles", json.int(s.actual_cycles)),
    #("actual_tokens", json.int(s.actual_tokens)),
    #("outcome", case s.outcome {
      Some(o) -> json.string(o)
      None -> json.null()
    }),
  ])
}

fn encode_session_status(s: SessionStatus) -> String {
  case s {
    SessionScheduled -> "scheduled"
    SessionInProgress -> "in_progress"
    SessionCompleted(outcome) -> "completed:" <> outcome
    SessionSkipped(reason) -> "skipped:" <> reason
    SessionFailed(reason) -> "failed:" <> reason
  }
}

fn encode_blocker(b: Blocker) -> json.Json {
  json.object([
    #("id", json.string(b.id)),
    #("description", json.string(b.description)),
    #("detected_at", json.string(b.detected_at)),
    #("resolution_strategy", json.string(b.resolution_strategy)),
    #("requires_human", json.bool(b.requires_human)),
    #("resolved_at", case b.resolved_at {
      Some(s) -> json.string(s)
      None -> json.null()
    }),
    #("resolution", case b.resolution {
      Some(s) -> json.string(s)
      None -> json.null()
    }),
  ])
}

fn encode_stakeholder(s: Stakeholder) -> json.Json {
  json.object([
    #("name", json.string(s.name)),
    #("channel", json.string(s.channel)),
    #("address", case s.address {
      Some(a) -> json.string(a)
      None -> json.null()
    }),
    #("role", case s.role {
      Owner -> json.string("owner")
      Reviewer -> json.string("reviewer")
      StakeholderObserver -> json.string("observer")
    }),
    #("update_preference", case s.update_preference {
      OnMilestone -> json.string("on_milestone")
      OnBlocker -> json.string("on_blocker")
      Periodic(cadence) -> json.string("periodic:" <> cadence)
      AllUpdates -> json.string("all")
    }),
  ])
}

// ---------------------------------------------------------------------------
// JSON decoding — TaskOp (lenient with defaults)
// ---------------------------------------------------------------------------

pub fn task_op_decoder() -> decode.Decoder(TaskOp) {
  use op_type <- decode.field("op", decode.string)
  case op_type {
    "create_task" -> {
      use task <- decode.field("task", task_decoder())
      decode.success(CreateTask(task:))
    }
    "update_task_status" -> {
      use task_id <- decode.field("task_id", decode.string)
      use status <- decode.field("status", status_string_decoder())
      use at <- decode.field("at", decode.string)
      decode.success(UpdateTaskStatus(task_id:, status:, at:))
    }
    "complete_step" -> {
      use task_id <- decode.field("task_id", decode.string)
      use step_index <- decode.field("step_index", decode.int)
      use at <- decode.field("at", decode.string)
      decode.success(CompleteStep(task_id:, step_index:, at:))
    }
    "flag_risk" -> {
      use task_id <- decode.field("task_id", decode.string)
      use text <- decode.field("text", decode.string)
      use at <- decode.field("at", decode.string)
      decode.success(FlagRisk(task_id:, text:, at:))
    }
    "add_cycle_id" -> {
      use task_id <- decode.field("task_id", decode.string)
      use cycle_id <- decode.field("cycle_id", decode.string)
      decode.success(AddCycleId(task_id:, cycle_id:))
    }
    "update_forecast_score" -> {
      use task_id <- decode.field("task_id", decode.string)
      use score <- decode.field("score", flexible_float_decoder())
      decode.success(UpdateForecastScore(task_id:, score:))
    }
    "update_task_fields" -> {
      use task_id <- decode.field("task_id", decode.string)
      use title <- decode.field("title", decode.optional(decode.string))
      use description <- decode.field(
        "description",
        decode.optional(decode.string),
      )
      use at <- decode.field("at", decode.string)
      decode.success(UpdateTaskFields(task_id:, title:, description:, at:))
    }
    "add_task_step" -> {
      use task_id <- decode.field("task_id", decode.string)
      use description <- decode.field("description", decode.string)
      use at <- decode.field("at", decode.string)
      decode.success(AddTaskStep(task_id:, description:, at:))
    }
    "remove_task_step" -> {
      use task_id <- decode.field("task_id", decode.string)
      use step_index <- decode.field("step_index", decode.int)
      use at <- decode.field("at", decode.string)
      decode.success(RemoveTaskStep(task_id:, step_index:, at:))
    }
    "update_forecast_breakdown" -> {
      use task_id <- decode.field("task_id", decode.string)
      use score <- decode.field("score", flexible_float_decoder())
      use breakdown <- decode.field(
        "breakdown",
        decode.list(breakdown_decoder()),
      )
      decode.success(UpdateForecastBreakdown(task_id:, score:, breakdown:))
    }
    "delete_task" -> {
      use task_id <- decode.field("task_id", decode.string)
      decode.success(DeleteTask(task_id:))
    }
    "add_pre_mortem" -> {
      use task_id <- decode.field("task_id", decode.string)
      use pre_mortem <- decode.field(
        "pre_mortem",
        appraisal_types.pre_mortem_decoder(),
      )
      decode.success(AddPreMortem(task_id:, pre_mortem:))
    }
    "add_post_mortem" -> {
      use task_id <- decode.field("task_id", decode.string)
      use post_mortem <- decode.field(
        "post_mortem",
        appraisal_types.post_mortem_decoder(),
      )
      decode.success(AddPostMortem(task_id:, post_mortem:))
    }
    _ ->
      decode.failure(
        CreateTask(task: empty_task()),
        "Unknown task op: " <> op_type,
      )
  }
}

pub fn task_decoder() -> decode.Decoder(PlannerTask) {
  use task_id <- decode.field("task_id", decode.string)
  use endeavour_id <- decode.field(
    "endeavour_id",
    decode.optional(decode.string),
  )
  use origin <- decode.field(
    "origin",
    decode.optional(decode.string)
      |> decode.map(fn(o) { decode_task_origin(option.unwrap(o, "system")) }),
  )
  use title <- decode.field(
    "title",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use description <- decode.field(
    "description",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use status <- decode.field(
    "status",
    decode.optional(decode.string)
      |> decode.map(fn(s) { decode_task_status(option.unwrap(s, "pending")) }),
  )
  use plan_steps <- decode.field(
    "plan_steps",
    decode.optional(decode.list(step_decoder()))
      |> decode.map(option.unwrap(_, [])),
  )
  use dependencies <- decode.field(
    "dependencies",
    decode.optional(decode.list(dep_decoder()))
      |> decode.map(option.unwrap(_, [])),
  )
  use complexity <- decode.field(
    "complexity",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use risks <- decode.field(
    "risks",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use materialised_risks <- decode.field(
    "materialised_risks",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use created_at <- decode.field(
    "created_at",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use updated_at <- decode.field(
    "updated_at",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use cycle_ids <- decode.field(
    "cycle_ids",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use forecast_score <- decode.field(
    "forecast_score",
    decode.optional(flexible_float_decoder()),
  )
  use forecast_breakdown <- decode.optional_field(
    "forecast_breakdown",
    None,
    decode.optional(decode.list(breakdown_decoder())),
  )
  use pre_mortem <- decode.optional_field(
    "pre_mortem",
    None,
    appraisal_types.optional_pre_mortem_decoder(),
  )
  use post_mortem <- decode.optional_field(
    "post_mortem",
    None,
    appraisal_types.optional_post_mortem_decoder(),
  )
  decode.success(PlannerTask(
    task_id:,
    endeavour_id:,
    origin:,
    title:,
    description:,
    status:,
    plan_steps:,
    dependencies:,
    complexity:,
    risks:,
    materialised_risks:,
    created_at:,
    updated_at:,
    cycle_ids:,
    forecast_score:,
    forecast_breakdown:,
    pre_mortem:,
    post_mortem:,
  ))
}

fn step_decoder() -> decode.Decoder(PlanStep) {
  use index <- decode.field("index", decode.int)
  use description <- decode.field(
    "description",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use status <- decode.field(
    "status",
    decode.optional(decode.string)
      |> decode.map(fn(s) { decode_task_status(option.unwrap(s, "pending")) }),
  )
  use completed_at <- decode.field(
    "completed_at",
    decode.optional(decode.string),
  )
  use verification <- decode.optional_field(
    "verification",
    None,
    decode.optional(decode.string),
  )
  decode.success(PlanStep(
    index:,
    description:,
    status:,
    completed_at:,
    verification:,
  ))
}

fn dep_decoder() -> decode.Decoder(#(String, String)) {
  use from <- decode.field("from", decode.string)
  use to <- decode.field("to", decode.string)
  decode.success(#(from, to))
}

fn status_string_decoder() -> decode.Decoder(TaskStatus) {
  use s <- decode.then(decode.string)
  decode.success(decode_task_status(s))
}

/// Decode a float that might be encoded as an int (JSON has no int/float distinction).
fn flexible_float_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [
    decode.int |> decode.map(int.to_float),
  ])
}

fn decode_task_status(s: String) -> TaskStatus {
  case s {
    "active" -> Active
    "complete" -> Complete
    "failed" -> Failed
    "abandoned" -> Abandoned
    _ -> Pending
  }
}

fn decode_task_origin(o: String) -> TaskOrigin {
  case o {
    "user" -> UserTask
    _ -> SystemTask
  }
}

fn empty_task() -> PlannerTask {
  PlannerTask(
    task_id: "",
    endeavour_id: None,
    origin: SystemTask,
    title: "",
    description: "",
    status: Pending,
    plan_steps: [],
    dependencies: [],
    complexity: "",
    risks: [],
    materialised_risks: [],
    created_at: "",
    updated_at: "",
    cycle_ids: [],
    forecast_score: None,
    forecast_breakdown: None,
    pre_mortem: None,
    post_mortem: None,
  )
}

// ---------------------------------------------------------------------------
// JSON decoding — EndeavourOp (lenient with defaults)
// ---------------------------------------------------------------------------

pub fn endeavour_op_decoder() -> decode.Decoder(EndeavourOp) {
  use op_type <- decode.field("op", decode.string)
  case op_type {
    "create_endeavour" -> {
      use endeavour <- decode.field("endeavour", endeavour_decoder())
      decode.success(CreateEndeavour(endeavour:))
    }
    "add_task" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use task_id <- decode.field("task_id", decode.string)
      decode.success(AddTaskToEndeavour(endeavour_id:, task_id:))
    }
    "update_endeavour_status" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use status <- decode.field("status", endeavour_status_string_decoder())
      decode.success(UpdateEndeavourStatus(endeavour_id:, status:))
    }
    "update_phase" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use phase_name <- decode.field("phase_name", decode.string)
      use status <- decode.field("status", phase_status_string_decoder())
      decode.success(UpdatePhase(endeavour_id:, phase_name:, status:))
    }
    "add_phase" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use phase <- decode.field("phase", phase_decoder())
      decode.success(AddPhase(endeavour_id:, phase:))
    }
    "add_blocker" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use blocker <- decode.field("blocker", blocker_decoder())
      decode.success(AddBlocker(endeavour_id:, blocker:))
    }
    "resolve_blocker" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use blocker_id <- decode.field("blocker_id", decode.string)
      use resolution <- decode.field("resolution", decode.string)
      use at <- decode.field("at", decode.string)
      decode.success(ResolveBlocker(
        endeavour_id:,
        blocker_id:,
        resolution:,
        at:,
      ))
    }
    "record_session" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use session <- decode.field("session", work_session_decoder())
      decode.success(RecordSession(endeavour_id:, session:))
    }
    "schedule_session" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use session <- decode.field("session", work_session_decoder())
      decode.success(ScheduleSession(endeavour_id:, session:))
    }
    "send_update" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use stakeholder <- decode.field("stakeholder", decode.string)
      use channel <- decode.field("channel", decode.string)
      use content <- decode.field("content", decode.string)
      use at <- decode.field("at", decode.string)
      decode.success(SendUpdate(
        endeavour_id:,
        stakeholder:,
        channel:,
        content:,
        at:,
      ))
    }
    "replan" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use reason <- decode.field("reason", decode.string)
      use new_phases <- decode.field("new_phases", decode.list(phase_decoder()))
      decode.success(Replan(endeavour_id:, reason:, new_phases:))
    }
    "record_metrics" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use cycles <- decode.field("cycles", decode.int)
      use tokens <- decode.field("tokens", decode.int)
      decode.success(RecordMetrics(endeavour_id:, cycles:, tokens:))
    }
    "update_forecaster_config" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use feature_overrides <- decode.field(
        "feature_overrides",
        decode.optional(planner_config.features_decoder()),
      )
      use threshold_override <- decode.field(
        "threshold_override",
        decode.optional(decode.float),
      )
      decode.success(UpdateForecasterConfig(
        endeavour_id:,
        feature_overrides:,
        threshold_override:,
      ))
    }
    "update_endeavour_fields" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use goal <- decode.field("goal", decode.optional(decode.string))
      use success_criteria <- decode.field(
        "success_criteria",
        decode.optional(decode.list(decode.string)),
      )
      use deadline <- decode.field("deadline", decode.optional(decode.string))
      use update_cadence <- decode.field(
        "update_cadence",
        decode.optional(decode.string),
      )
      decode.success(UpdateEndeavourFields(
        endeavour_id:,
        goal:,
        success_criteria:,
        deadline:,
        update_cadence:,
        approval_config: None,
      ))
    }
    "cancel_session" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use session_id <- decode.field("session_id", decode.string)
      use reason <- decode.field("reason", decode.string)
      use at <- decode.field("at", decode.string)
      decode.success(CancelSession(endeavour_id:, session_id:, reason:, at:))
    }
    "update_endeavour_forecast_breakdown" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use score <- decode.field("score", flexible_float_decoder())
      use breakdown <- decode.field(
        "breakdown",
        decode.list(breakdown_decoder()),
      )
      decode.success(UpdateEndeavourForecastBreakdown(
        endeavour_id:,
        score:,
        breakdown:,
      ))
    }
    "delete_endeavour" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      decode.success(DeleteEndeavour(endeavour_id:))
    }
    "add_endeavour_post_mortem" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use post_mortem <- decode.field(
        "post_mortem",
        appraisal_types.endeavour_post_mortem_decoder(),
      )
      decode.success(AddEndeavourPostMortem(endeavour_id:, post_mortem:))
    }
    _ ->
      decode.failure(
        CreateEndeavour(endeavour: empty_endeavour()),
        "Unknown endeavour op: " <> op_type,
      )
  }
}

/// Lenient endeavour decoder — old records without new fields get defaults.
pub fn endeavour_decoder() -> decode.Decoder(Endeavour) {
  use endeavour_id <- decode.field("endeavour_id", decode.string)
  use origin <- decode.field(
    "origin",
    decode.optional(decode.string)
      |> decode.map(fn(o) {
        decode_endeavour_origin(option.unwrap(o, "system"))
      }),
  )
  use title <- decode.field(
    "title",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use description <- decode.field(
    "description",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use status <- decode.field(
    "status",
    decode.optional(decode.string)
      |> decode.map(fn(s) { decode_endeavour_status(option.unwrap(s, "open")) }),
  )
  use task_ids <- decode.field(
    "task_ids",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use created_at <- decode.field(
    "created_at",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use updated_at <- decode.field(
    "updated_at",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  // New fields — all optional with defaults for backward compatibility
  use goal <- decode.optional_field("goal", "", decode.string)
  use success_criteria <- decode.optional_field(
    "success_criteria",
    [],
    decode.list(decode.string),
  )
  use deadline <- decode.optional_field(
    "deadline",
    None,
    decode.optional(decode.string),
  )
  use replan_count <- decode.optional_field("replan_count", 0, decode.int)
  use original_phase_count <- decode.optional_field(
    "original_phase_count",
    0,
    decode.int,
  )
  use total_cycles <- decode.optional_field("total_cycles", 0, decode.int)
  use total_tokens <- decode.optional_field("total_tokens", 0, decode.int)
  use feature_overrides <- decode.optional_field(
    "feature_overrides",
    None,
    decode.optional(planner_config.features_decoder()),
  )
  use threshold_override <- decode.optional_field(
    "threshold_override",
    None,
    decode.optional(decode.float),
  )
  use endeavour_forecast_score <- decode.optional_field(
    "forecast_score",
    None,
    decode.optional(decode.float),
  )
  use endeavour_forecast_breakdown <- decode.optional_field(
    "forecast_breakdown",
    None,
    decode.optional(decode.list(breakdown_decoder())),
  )
  use update_cadence <- decode.optional_field(
    "update_cadence",
    None,
    decode.optional(decode.string),
  )
  use last_update_sent <- decode.optional_field(
    "last_update_sent",
    None,
    decode.optional(decode.string),
  )
  use next_session <- decode.optional_field(
    "next_session",
    None,
    decode.optional(decode.string),
  )
  use post_mortem <- decode.optional_field(
    "post_mortem",
    None,
    appraisal_types.optional_endeavour_post_mortem_decoder(),
  )
  decode.success(Endeavour(
    endeavour_id:,
    origin:,
    title:,
    description:,
    status:,
    task_ids:,
    created_at:,
    updated_at:,
    goal:,
    success_criteria:,
    deadline:,
    phases: [],
    work_sessions: [],
    next_session:,
    session_cadence: None,
    stakeholders: [],
    last_update_sent:,
    update_cadence:,
    blockers: [],
    replan_count:,
    original_phase_count:,
    approval_config: default_approval_config(),
    feature_overrides:,
    threshold_override:,
    forecast_score: endeavour_forecast_score,
    forecast_breakdown: endeavour_forecast_breakdown,
    total_cycles:,
    total_tokens:,
    post_mortem:,
  ))
}

fn endeavour_status_string_decoder() -> decode.Decoder(EndeavourStatus) {
  use s <- decode.then(decode.string)
  decode.success(decode_endeavour_status(s))
}

fn decode_endeavour_status(s: String) -> EndeavourStatus {
  case s {
    "complete" -> EndeavourComplete
    "abandoned" -> EndeavourAbandoned
    "draft" -> Draft
    "active" -> EndeavourActive
    "blocked" -> EndeavourBlocked
    "on_hold" -> OnHold
    "failed" -> EndeavourFailed
    _ -> Open
  }
}

fn decode_endeavour_origin(o: String) -> EndeavourOrigin {
  case o {
    "user" -> UserEndeavour
    _ -> SystemEndeavour
  }
}

fn empty_endeavour() -> Endeavour {
  new_endeavour("", SystemEndeavour, "", "", "")
}

// --- Phase decoder ---

fn phase_decoder() -> decode.Decoder(Phase) {
  use name <- decode.field("name", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use status <- decode.optional_field(
    "status",
    PhaseNotStarted,
    phase_status_string_decoder(),
  )
  use task_ids <- decode.optional_field(
    "task_ids",
    [],
    decode.list(decode.string),
  )
  use depends_on <- decode.optional_field(
    "depends_on",
    [],
    decode.list(decode.string),
  )
  use milestone <- decode.optional_field(
    "milestone",
    None,
    decode.optional(decode.string),
  )
  use estimated_sessions <- decode.optional_field(
    "estimated_sessions",
    1,
    decode.int,
  )
  use actual_sessions <- decode.optional_field("actual_sessions", 0, decode.int)
  decode.success(Phase(
    name:,
    description:,
    status:,
    task_ids:,
    depends_on:,
    milestone:,
    estimated_sessions:,
    actual_sessions:,
  ))
}

fn phase_status_string_decoder() -> decode.Decoder(PhaseStatus) {
  use s <- decode.then(decode.string)
  decode.success(decode_phase_status(s))
}

fn decode_phase_status(s: String) -> PhaseStatus {
  case s {
    "in_progress" -> PhaseInProgress
    "complete" -> PhaseComplete
    _ ->
      case string.starts_with(s, "blocked:") {
        True -> PhaseBlocked(reason: string.drop_start(s, 8))
        False ->
          case string.starts_with(s, "skipped:") {
            True -> PhaseSkipped(reason: string.drop_start(s, 8))
            False -> PhaseNotStarted
          }
      }
  }
}

// --- WorkSession decoder ---

fn work_session_decoder() -> decode.Decoder(WorkSession) {
  use session_id <- decode.field("session_id", decode.string)
  use scheduled_at <- decode.optional_field("scheduled_at", "", decode.string)
  use status <- decode.optional_field(
    "status",
    SessionScheduled,
    session_status_string_decoder(),
  )
  use phase <- decode.optional_field("phase", "", decode.string)
  use focus <- decode.optional_field("focus", "", decode.string)
  use max_cycles <- decode.optional_field("max_cycles", 5, decode.int)
  use max_tokens <- decode.optional_field("max_tokens", 100_000, decode.int)
  use actual_cycles <- decode.optional_field("actual_cycles", 0, decode.int)
  use actual_tokens <- decode.optional_field("actual_tokens", 0, decode.int)
  use outcome <- decode.optional_field(
    "outcome",
    None,
    decode.optional(decode.string),
  )
  decode.success(WorkSession(
    session_id:,
    scheduled_at:,
    status:,
    phase:,
    focus:,
    max_cycles:,
    max_tokens:,
    actual_cycles:,
    actual_tokens:,
    outcome:,
  ))
}

fn session_status_string_decoder() -> decode.Decoder(SessionStatus) {
  use s <- decode.then(decode.string)
  decode.success(decode_session_status(s))
}

fn decode_session_status(s: String) -> SessionStatus {
  case s {
    "scheduled" -> SessionScheduled
    "in_progress" -> SessionInProgress
    _ ->
      case string.starts_with(s, "completed:") {
        True -> SessionCompleted(outcome: string.drop_start(s, 10))
        False ->
          case string.starts_with(s, "skipped:") {
            True -> SessionSkipped(reason: string.drop_start(s, 8))
            False ->
              case string.starts_with(s, "failed:") {
                True -> SessionFailed(reason: string.drop_start(s, 7))
                False -> SessionScheduled
              }
          }
      }
  }
}

// --- Blocker decoder ---

fn blocker_decoder() -> decode.Decoder(Blocker) {
  use id <- decode.field("id", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use detected_at <- decode.optional_field("detected_at", "", decode.string)
  use resolution_strategy <- decode.optional_field(
    "resolution_strategy",
    "",
    decode.string,
  )
  use requires_human <- decode.optional_field(
    "requires_human",
    False,
    decode.bool,
  )
  use resolved_at <- decode.optional_field(
    "resolved_at",
    None,
    decode.optional(decode.string),
  )
  use resolution <- decode.optional_field(
    "resolution",
    None,
    decode.optional(decode.string),
  )
  decode.success(Blocker(
    id:,
    description:,
    detected_at:,
    resolution_strategy:,
    requires_human:,
    resolved_at:,
    resolution:,
  ))
}

fn breakdown_decoder() -> decode.Decoder(ForecastBreakdown) {
  use feature_name <- decode.field("feature_name", decode.string)
  use magnitude <- decode.optional_field("magnitude", 0, decode.int)
  use rationale <- decode.optional_field("rationale", "", decode.string)
  use weighted_score <- decode.optional_field(
    "weighted_score",
    0.0,
    decode.float,
  )
  decode.success(ForecastBreakdown(
    feature_name:,
    magnitude:,
    rationale:,
    weighted_score:,
  ))
}

// ---------------------------------------------------------------------------
// JSONL parsing
// ---------------------------------------------------------------------------

fn parse_task_jsonl(content: String) -> List(TaskOp) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, task_op_decoder()) {
      Ok(op) -> Ok(op)
      Error(_) -> Error(Nil)
    }
  })
}

fn parse_endeavour_jsonl(content: String) -> List(EndeavourOp) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, endeavour_op_decoder()) {
      Ok(op) -> Ok(op)
      Error(_) -> Error(Nil)
    }
  })
}
