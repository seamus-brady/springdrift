//// Planner store index — ETS tables + operation handlers + startup replay.
////
//// Owns two ETS tables keyed by task_id / endeavour_id:
////   - planner_tasks       (set)  — task_id → PlannerTask
////   - planner_endeavours  (set)  — endeavour_id → Endeavour
////
//// This module is called from `narrative/librarian.gleam`'s message loop
//// and never runs on its own process — atomicity is guaranteed by the
//// single-process Librarian actor.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{Some}
import gleam/string
import planner/log as planner_log
import planner/types as planner_types
import simplifile

// ---------------------------------------------------------------------------
// Opaque table handle — shared between tasks and endeavours tables (they
// use the same store_ffi but hold different value types; per-op FFI
// declarations give us compile-time type safety per value type).
// ---------------------------------------------------------------------------

pub type Table

@external(erlang, "store_ffi", "new_unique_table")
pub fn new_table(name: String, table_type: String) -> Table

@external(erlang, "store_ffi", "delete_table")
pub fn delete_table(table: Table) -> Nil

@external(erlang, "store_ffi", "table_size")
pub fn table_size(table: Table) -> Int

// Task-typed operations
@external(erlang, "store_ffi", "insert")
pub fn task_insert(
  table: Table,
  key: String,
  value: planner_types.PlannerTask,
) -> Nil

@external(erlang, "store_ffi", "lookup")
pub fn task_lookup(
  table: Table,
  key: String,
) -> Result(planner_types.PlannerTask, Nil)

@external(erlang, "store_ffi", "all_values")
pub fn task_all_values(table: Table) -> List(planner_types.PlannerTask)

@external(erlang, "store_ffi", "delete_key")
pub fn task_delete_key(table: Table, key: String) -> Nil

// Endeavour-typed operations
@external(erlang, "store_ffi", "insert")
pub fn endeavour_insert(
  table: Table,
  key: String,
  value: planner_types.Endeavour,
) -> Nil

@external(erlang, "store_ffi", "lookup")
pub fn endeavour_lookup(
  table: Table,
  key: String,
) -> Result(planner_types.Endeavour, Nil)

@external(erlang, "store_ffi", "all_values")
pub fn endeavour_all_values(table: Table) -> List(planner_types.Endeavour)

@external(erlang, "store_ffi", "delete_key")
pub fn endeavour_delete(table: Table, key: String) -> Nil

// ---------------------------------------------------------------------------
// Operation handlers
// ---------------------------------------------------------------------------

/// Apply a single TaskOp to the tasks ETS table. A fast path handles the
/// common field-update ops directly; anything else replays the op through
/// `planner_log.resolve_tasks` to keep ETS in sync with a fresh resolve.
pub fn apply_task_op(tasks: Table, op: planner_types.TaskOp) -> Nil {
  case op {
    planner_types.CreateTask(task:) -> task_insert(tasks, task.task_id, task)

    planner_types.UpdateTaskStatus(task_id:, status:, at:) ->
      case task_lookup(tasks, task_id) {
        Ok(t) ->
          task_insert(
            tasks,
            task_id,
            planner_types.PlannerTask(..t, status:, updated_at: at),
          )
        Error(_) -> Nil
      }

    planner_types.CompleteStep(task_id:, step_index:, at:) ->
      case task_lookup(tasks, task_id) {
        Ok(t) -> {
          let steps =
            list.map(t.plan_steps, fn(s) {
              case s.index == step_index {
                True ->
                  planner_types.PlanStep(
                    ..s,
                    status: planner_types.Complete,
                    completed_at: Some(at),
                  )
                False -> s
              }
            })
          let all_complete =
            list.all(steps, fn(s) { s.status == planner_types.Complete })
          let new_status = case all_complete {
            True -> planner_types.Complete
            False -> t.status
          }
          task_insert(
            tasks,
            task_id,
            planner_types.PlannerTask(
              ..t,
              plan_steps: steps,
              status: new_status,
              updated_at: at,
            ),
          )
        }
        Error(_) -> Nil
      }

    planner_types.FlagRisk(task_id:, text:, at:) ->
      case task_lookup(tasks, task_id) {
        Ok(t) ->
          task_insert(
            tasks,
            task_id,
            planner_types.PlannerTask(
              ..t,
              materialised_risks: list.append(t.materialised_risks, [text]),
              updated_at: at,
            ),
          )
        Error(_) -> Nil
      }

    planner_types.AddCycleId(task_id:, cycle_id:) ->
      case task_lookup(tasks, task_id) {
        Ok(t) ->
          case list.contains(t.cycle_ids, cycle_id) {
            True -> Nil
            False ->
              task_insert(
                tasks,
                task_id,
                planner_types.PlannerTask(
                  ..t,
                  cycle_ids: list.append(t.cycle_ids, [cycle_id]),
                ),
              )
          }
        Error(_) -> Nil
      }

    planner_types.UpdateForecastScore(task_id:, score:) ->
      case task_lookup(tasks, task_id) {
        Ok(t) ->
          task_insert(
            tasks,
            task_id,
            planner_types.PlannerTask(..t, forecast_score: Some(score)),
          )
        Error(_) -> Nil
      }

    planner_types.DeleteTask(task_id:) -> task_delete_key(tasks, task_id)

    planner_types.UpdateForecastBreakdown(task_id:, score:, breakdown:) ->
      case task_lookup(tasks, task_id) {
        Ok(t) ->
          task_insert(
            tasks,
            task_id,
            planner_types.PlannerTask(
              ..t,
              forecast_score: Some(score),
              forecast_breakdown: Some(breakdown),
            ),
          )
        Error(_) -> Nil
      }

    planner_types.AddPreMortem(task_id:, pre_mortem:) ->
      case task_lookup(tasks, task_id) {
        Ok(t) ->
          task_insert(
            tasks,
            task_id,
            planner_types.PlannerTask(..t, pre_mortem: option.Some(pre_mortem)),
          )
        Error(_) -> Nil
      }

    planner_types.AddPostMortem(task_id:, post_mortem:) ->
      case task_lookup(tasks, task_id) {
        Ok(t) ->
          task_insert(
            tasks,
            task_id,
            planner_types.PlannerTask(
              ..t,
              post_mortem: option.Some(post_mortem),
            ),
          )
        Error(_) -> Nil
      }

    // Remaining task ops — apply via resolve pattern
    other_op -> {
      let tid = case other_op {
        planner_types.UpdateTaskFields(task_id: id, ..) -> id
        planner_types.AddTaskStep(task_id: id, ..) -> id
        planner_types.RemoveTaskStep(task_id: id, ..) -> id
        // Already handled above — unreachable
        _ -> ""
      }
      case tid {
        "" -> Nil
        _ ->
          case task_lookup(tasks, tid) {
            Ok(t) -> {
              let resolved =
                planner_log.resolve_tasks([
                  planner_types.CreateTask(task: t),
                  other_op,
                ])
              case resolved {
                [updated, ..] -> task_insert(tasks, tid, updated)
                _ -> Nil
              }
            }
            Error(_) -> Nil
          }
      }
    }
  }
}

/// Apply a single EndeavourOp to the endeavours ETS table.
pub fn apply_endeavour_op(
  endeavours: Table,
  op: planner_types.EndeavourOp,
) -> Nil {
  case op {
    planner_types.CreateEndeavour(endeavour:) ->
      endeavour_insert(endeavours, endeavour.endeavour_id, endeavour)

    planner_types.AddTaskToEndeavour(endeavour_id:, task_id:) ->
      case endeavour_lookup(endeavours, endeavour_id) {
        Ok(e) ->
          case list.contains(e.task_ids, task_id) {
            True -> Nil
            False ->
              endeavour_insert(
                endeavours,
                endeavour_id,
                planner_types.Endeavour(
                  ..e,
                  task_ids: list.append(e.task_ids, [task_id]),
                ),
              )
          }
        Error(_) -> Nil
      }

    planner_types.UpdateEndeavourStatus(endeavour_id:, status:) ->
      case endeavour_lookup(endeavours, endeavour_id) {
        Ok(e) ->
          endeavour_insert(
            endeavours,
            endeavour_id,
            planner_types.Endeavour(..e, status:),
          )
        Error(_) -> Nil
      }

    planner_types.DeleteEndeavour(endeavour_id:) ->
      endeavour_delete(endeavours, endeavour_id)

    planner_types.UpdateEndeavourForecastBreakdown(
      endeavour_id:,
      score:,
      breakdown:,
    ) ->
      case endeavour_lookup(endeavours, endeavour_id) {
        Ok(e) ->
          endeavour_insert(
            endeavours,
            endeavour_id,
            planner_types.Endeavour(
              ..e,
              forecast_score: option.Some(score),
              forecast_breakdown: option.Some(breakdown),
            ),
          )
        Error(_) -> Nil
      }

    planner_types.UpdateForecasterConfig(
      endeavour_id:,
      feature_overrides:,
      threshold_override:,
    ) ->
      case endeavour_lookup(endeavours, endeavour_id) {
        Ok(e) ->
          endeavour_insert(
            endeavours,
            endeavour_id,
            planner_types.Endeavour(
              ..e,
              feature_overrides:,
              threshold_override:,
            ),
          )
        Error(_) -> Nil
      }

    planner_types.UpdateEndeavourFields(
      endeavour_id:,
      goal:,
      success_criteria:,
      deadline:,
      update_cadence:,
      approval_config:,
    ) ->
      case endeavour_lookup(endeavours, endeavour_id) {
        Ok(e) -> {
          let updated =
            planner_types.Endeavour(
              ..e,
              goal: option.unwrap(goal, e.goal),
              success_criteria: option.unwrap(
                success_criteria,
                e.success_criteria,
              ),
              deadline: case deadline {
                option.Some(d) -> option.Some(d)
                option.None -> e.deadline
              },
              update_cadence: case update_cadence {
                option.Some(c) -> option.Some(c)
                option.None -> e.update_cadence
              },
              approval_config: option.unwrap(approval_config, e.approval_config),
            )
          endeavour_insert(endeavours, endeavour_id, updated)
        }
        Error(_) -> Nil
      }

    planner_types.CancelSession(endeavour_id:, session_id:, reason:, ..) ->
      case endeavour_lookup(endeavours, endeavour_id) {
        Ok(e) -> {
          let updated_sessions =
            list.map(e.work_sessions, fn(s) {
              case s.session_id == session_id {
                True ->
                  planner_types.WorkSession(
                    ..s,
                    status: planner_types.SessionSkipped(reason:),
                  )
                False -> s
              }
            })
          endeavour_insert(
            endeavours,
            endeavour_id,
            planner_types.Endeavour(..e, work_sessions: updated_sessions),
          )
        }
        Error(_) -> Nil
      }

    planner_types.AddEndeavourPostMortem(endeavour_id:, post_mortem:) ->
      case endeavour_lookup(endeavours, endeavour_id) {
        Ok(e) ->
          endeavour_insert(
            endeavours,
            endeavour_id,
            planner_types.Endeavour(..e, post_mortem: option.Some(post_mortem)),
          )
        Error(_) -> Nil
      }

    // Remaining ops — apply via resolve pattern (re-create + apply)
    other_op -> {
      let eid = case other_op {
        planner_types.UpdatePhase(endeavour_id: id, ..) -> id
        planner_types.AddPhase(endeavour_id: id, ..) -> id
        planner_types.AddBlocker(endeavour_id: id, ..) -> id
        planner_types.ResolveBlocker(endeavour_id: id, ..) -> id
        planner_types.RecordSession(endeavour_id: id, ..) -> id
        planner_types.ScheduleSession(endeavour_id: id, ..) -> id
        planner_types.SendUpdate(endeavour_id: id, ..) -> id
        planner_types.Replan(endeavour_id: id, ..) -> id
        planner_types.RecordMetrics(endeavour_id: id, ..) -> id
        // Already handled above — unreachable but required for exhaustiveness
        _ -> ""
      }
      case eid {
        "" -> Nil
        _ ->
          case endeavour_lookup(endeavours, eid) {
            Ok(e) -> {
              let resolved =
                planner_log.resolve_endeavours([
                  planner_types.CreateEndeavour(endeavour: e),
                  other_op,
                ])
              case resolved {
                [updated, ..] -> endeavour_insert(endeavours, eid, updated)
                _ -> Nil
              }
            }
            Error(_) -> Nil
          }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Startup replay
// ---------------------------------------------------------------------------

/// Replay task + endeavour ops from disk, resolving to current state and
/// populating both ETS tables. `max_files` caps how many date-stamped files
/// are replayed (0 = all).
pub fn replay_from_disk(
  tasks: Table,
  endeavours: Table,
  planner_dir: String,
  max_files: Int,
) -> Nil {
  case simplifile.read_directory(planner_dir) {
    Error(_) -> Nil
    Ok(files) -> {
      let task_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, "-tasks.jsonl") })
        |> list.sort(string.compare)
      let limited_tasks = limit_files(task_files, max_files)
      let task_ops =
        list.flat_map(limited_tasks, fn(f) {
          let date = string.drop_end(f, 12)
          planner_log.load_task_ops_date(planner_dir, date)
        })
      let resolved_tasks = planner_log.resolve_tasks(task_ops)
      list.each(resolved_tasks, fn(t) { task_insert(tasks, t.task_id, t) })

      let endeavour_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, "-endeavours.jsonl") })
        |> list.sort(string.compare)
      let limited_endeavours = limit_files(endeavour_files, max_files)
      let endeavour_ops =
        list.flat_map(limited_endeavours, fn(f) {
          let date = string.drop_end(f, 17)
          planner_log.load_endeavour_ops_date(planner_dir, date)
        })
      let resolved_endeavours = planner_log.resolve_endeavours(endeavour_ops)
      list.each(resolved_endeavours, fn(e) {
        endeavour_insert(endeavours, e.endeavour_id, e)
      })
    }
  }
}

fn limit_files(files: List(String), max_files: Int) -> List(String) {
  case max_files > 0 {
    True -> {
      let len = list.length(files)
      case len > max_files {
        True -> list.drop(files, len - max_files)
        False -> files
      }
    }
    False -> files
  }
}
