//// Planner tools — task and endeavour management for the cognitive agent.
////
//// These tools let the agent track its own work: manage tasks with steps,
//// create endeavours for multi-task initiatives, and query active work.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/engine
import dprime/types as dprime_types
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/tool
import llm/types as llm_types
import narrative/appraiser
import narrative/librarian.{type LibrarianMessage}
import planner/config as planner_config
import planner/features
import planner/forecaster
import planner/log as planner_log
import planner/types.{
  Active, Blocker, EndeavourActive, EndeavourBlocked, Open, Pending, Phase,
  PhaseComplete, PhaseInProgress, PhaseNotStarted, PlanStep, PlannerTask,
  SessionScheduled, SystemEndeavour, WorkSession,
}
import slog

@external(erlang, "springdrift_ffi", "generate_uuid")
fn uuid_v4() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn iso_now() -> String

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

/// Planner tools on the cognitive loop — quick side-effect operations.
/// Heavier planning operations (create_endeavour, flag_risk, abandon_task,
/// add_task_to_endeavour, request_forecast_review) have moved to the Planner agent.
pub fn all() -> List(llm_types.Tool) {
  [
    complete_task_step_tool(),
    activate_task_tool(),
    get_active_work_tool(),
    get_task_detail_tool(),
    create_task_tool(),
    request_forecast_review_tool(),
  ]
}

/// Tools for the Planner agent — heavier planning operations that
/// warrant a full agent delegation. Also carries the lightweight
/// step-completion + activation tools so a PM delegation can close its
/// own work without bouncing back to the cognitive loop.
pub fn planner_agent_tools() -> List(llm_types.Tool) {
  [
    // Lightweight lifecycle — also present on the cognitive loop, but
    // replicated here so a PM delegation can complete the work it just
    // did without needing the orchestrator to make the close call.
    complete_task_step_tool(),
    activate_task_tool(),
    // Heavier operations — the original planner-agent-only set.
    create_endeavour_tool(),
    add_task_to_endeavour_tool(),
    flag_risk_tool(),
    abandon_task_tool(),
    request_forecast_review_tool(),
    // Endeavour management
    add_phase_tool(),
    advance_phase_tool(),
    schedule_work_session_tool(),
    report_blocker_tool(),
    resolve_blocker_tool(),
    get_endeavour_detail_tool(),
    // Forecaster introspection
    get_forecaster_config_tool(),
    update_forecaster_config_tool(),
    // Endeavour field updates
    update_endeavour_tool(),
    cancel_work_session_tool(),
    list_work_sessions_tool(),
    // Task editing
    update_task_tool(),
    add_task_step_tool(),
    remove_task_step_tool(),
    // Forecast + delete + cleanup
    get_forecast_breakdown_tool(),
    delete_task_tool(),
    delete_endeavour_tool(),
    purge_empty_tasks_tool(),
  ]
}

fn complete_task_step_tool() -> llm_types.Tool {
  tool.new("complete_task_step")
  |> tool.with_description("Mark a step complete on a task you're working on.")
  |> tool.add_string_param("task_id", "The task ID", True)
  |> tool.add_integer_param("step_index", "The step number to complete", True)
  |> tool.build()
}

fn flag_risk_tool() -> llm_types.Tool {
  tool.new("flag_risk")
  |> tool.with_description(
    "Record that a predicted risk has materialised on one of your tasks.",
  )
  |> tool.add_string_param("task_id", "The task ID", True)
  |> tool.add_string_param("risk_description", "What risk materialised", True)
  |> tool.build()
}

fn activate_task_tool() -> llm_types.Tool {
  tool.new("activate_task")
  |> tool.with_description("Set a pending task as your current focus.")
  |> tool.add_string_param("task_id", "The task ID to activate", True)
  |> tool.build()
}

fn abandon_task_tool() -> llm_types.Tool {
  tool.new("abandon_task")
  |> tool.with_description("Stop tracking a task that's no longer relevant.")
  |> tool.add_string_param("task_id", "The task ID to abandon", True)
  |> tool.add_string_param("reason", "Why this task is being abandoned", True)
  |> tool.build()
}

fn create_endeavour_tool() -> llm_types.Tool {
  tool.new("create_endeavour")
  |> tool.with_description(
    "Create a self-directed initiative that groups multiple independent tasks "
    <> "toward a larger goal. Use when you recognise your goal needs multiple "
    <> "separate plans, not just sequential steps.",
  )
  |> tool.add_string_param("title", "Short title for the endeavour", True)
  |> tool.add_string_param(
    "description",
    "What you're trying to achieve overall",
    True,
  )
  |> tool.build()
}

fn add_task_to_endeavour_tool() -> llm_types.Tool {
  tool.new("add_task_to_endeavour")
  |> tool.with_description("Associate a task with one of your endeavours.")
  |> tool.add_string_param("task_id", "The task ID", True)
  |> tool.add_string_param("endeavour_id", "The endeavour ID", True)
  |> tool.build()
}

fn get_active_work_tool() -> llm_types.Tool {
  tool.new("get_active_work")
  |> tool.with_description(
    "List your active tasks and endeavours with progress.",
  )
  |> tool.build()
}

fn get_task_detail_tool() -> llm_types.Tool {
  tool.new("get_task_detail")
  |> tool.with_description(
    "Full task detail: steps, risks, forecast score, cycle history.",
  )
  |> tool.add_string_param("task_id", "The task ID", True)
  |> tool.build()
}

fn create_task_tool() -> llm_types.Tool {
  tool.new("create_task")
  |> tool.with_description(
    "Create a lightweight task directly without invoking the planner agent. "
    <> "Use for simple, well-understood work that doesn't need plan reasoning. "
    <> "Steps are provided as a comma-separated string.",
  )
  |> tool.add_string_param("title", "Task title", True)
  |> tool.add_string_param("description", "What needs to be done", False)
  |> tool.add_string_param(
    "steps",
    "Comma-separated list of steps (e.g. 'Research X, Summarise findings, Draft report')",
    True,
  )
  |> tool.add_string_param(
    "complexity",
    "simple, medium, or complex (default: medium)",
    False,
  )
  |> tool.build()
}

fn request_forecast_review_tool() -> llm_types.Tool {
  tool.new("request_forecast_review")
  |> tool.with_description(
    "Review plan-health forecasts for active tasks. "
    <> "Returns D' scores and whether replanning is suggested. "
    <> "Omit task_id to review all active tasks.",
  )
  |> tool.add_string_param(
    "task_id",
    "Optional task ID to review a specific task (omit for all active tasks)",
    False,
  )
  |> tool.build()
}

// --- Endeavour management tools (Phases 2-7) ---

fn add_phase_tool() -> llm_types.Tool {
  tool.new("add_phase")
  |> tool.with_description(
    "Add a phase to an endeavour. Phases are ordered chunks of work.",
  )
  |> tool.add_string_param("endeavour_id", "The endeavour ID", True)
  |> tool.add_string_param("name", "Phase name (e.g. 'Research')", True)
  |> tool.add_string_param("description", "What this phase accomplishes", True)
  |> tool.add_string_param(
    "milestone",
    "What completing this phase means (optional)",
    False,
  )
  |> tool.add_integer_param(
    "estimated_sessions",
    "Estimated work sessions needed (default: 1)",
    False,
  )
  |> tool.build()
}

fn advance_phase_tool() -> llm_types.Tool {
  tool.new("advance_phase")
  |> tool.with_description(
    "Mark the current phase complete and advance to the next phase. "
    <> "Updates phase status and endeavour status.",
  )
  |> tool.add_string_param("endeavour_id", "The endeavour ID", True)
  |> tool.add_string_param(
    "phase_name",
    "Name of the phase to mark complete",
    True,
  )
  |> tool.build()
}

fn schedule_work_session_tool() -> llm_types.Tool {
  tool.new("schedule_work_session")
  |> tool.with_description(
    "Schedule the next autonomous work session for an endeavour. "
    <> "Creates a scheduler job that fires at the specified time.",
  )
  |> tool.add_string_param("endeavour_id", "The endeavour ID", True)
  |> tool.add_string_param("phase", "Which phase this session targets", True)
  |> tool.add_string_param("focus", "Specific objective for this session", True)
  |> tool.add_string_param(
    "scheduled_at",
    "ISO datetime for the session (e.g. '2026-04-02T09:00:00')",
    True,
  )
  |> tool.add_integer_param(
    "max_cycles",
    "Max cognitive cycles for this session (default: 5)",
    False,
  )
  |> tool.build()
}

fn report_blocker_tool() -> llm_types.Tool {
  tool.new("report_blocker")
  |> tool.with_description(
    "Report a blocker preventing progress on an endeavour. "
    <> "If requires_human is true, the operator will be notified.",
  )
  |> tool.add_string_param("endeavour_id", "The endeavour ID", True)
  |> tool.add_string_param("description", "What is blocking progress", True)
  |> tool.add_string_param(
    "resolution_strategy",
    "What you plan to do about it",
    True,
  )
  |> tool.add_boolean_param(
    "requires_human",
    "Whether this needs operator intervention (default: false)",
    False,
  )
  |> tool.build()
}

fn resolve_blocker_tool() -> llm_types.Tool {
  tool.new("resolve_blocker")
  |> tool.with_description("Mark a blocker as resolved on an endeavour.")
  |> tool.add_string_param("endeavour_id", "The endeavour ID", True)
  |> tool.add_string_param("blocker_id", "The blocker ID to resolve", True)
  |> tool.add_string_param("resolution", "How it was resolved", True)
  |> tool.build()
}

fn get_endeavour_detail_tool() -> llm_types.Tool {
  tool.new("get_endeavour_detail")
  |> tool.with_description(
    "Get full detail of an endeavour: phases, blockers, sessions, metrics.",
  )
  |> tool.add_string_param("endeavour_id", "The endeavour ID", True)
  |> tool.build()
}

fn get_forecaster_config_tool() -> llm_types.Tool {
  tool.new("get_forecaster_config")
  |> tool.with_description(
    "View forecaster feature set, weights, thresholds. "
    <> "Pass endeavour_id to see per-endeavour overrides.",
  )
  |> tool.add_string_param(
    "endeavour_id",
    "Optional: see effective config for this endeavour",
    False,
  )
  |> tool.build()
}

fn update_forecaster_config_tool() -> llm_types.Tool {
  tool.new("update_forecaster_config")
  |> tool.with_description(
    "Adjust per-endeavour forecaster settings. "
    <> "Change feature importance or replan threshold for a specific endeavour.",
  )
  |> tool.add_string_param("endeavour_id", "The endeavour to configure", True)
  |> tool.add_string_param(
    "feature_name",
    "Feature to change (e.g. 'step_completion_rate')",
    False,
  )
  |> tool.add_string_param(
    "importance",
    "New importance: 'high', 'medium', or 'low'",
    False,
  )
  |> tool.add_number_param(
    "threshold_override",
    "New replan threshold (0.0-1.0) for this endeavour",
    False,
  )
  |> tool.build()
}

fn update_endeavour_tool() -> llm_types.Tool {
  tool.new("update_endeavour")
  |> tool.with_description(
    "Update endeavour fields: goal, success criteria, deadline, update cadence.",
  )
  |> tool.add_string_param("endeavour_id", "The endeavour to update", True)
  |> tool.add_string_param("goal", "New goal (optional)", False)
  |> tool.add_string_param(
    "deadline",
    "New deadline ISO date (optional)",
    False,
  )
  |> tool.add_string_param(
    "update_cadence",
    "New update cadence: daily/weekly/on_milestone (optional)",
    False,
  )
  |> tool.build()
}

fn cancel_work_session_tool() -> llm_types.Tool {
  tool.new("cancel_work_session")
  |> tool.with_description("Cancel a scheduled work session on an endeavour.")
  |> tool.add_string_param("endeavour_id", "The endeavour ID", True)
  |> tool.add_string_param("session_id", "The session ID to cancel", True)
  |> tool.add_string_param("reason", "Why the session is being cancelled", True)
  |> tool.build()
}

fn list_work_sessions_tool() -> llm_types.Tool {
  tool.new("list_work_sessions")
  |> tool.with_description(
    "List work sessions for an endeavour with optional status filter.",
  )
  |> tool.add_string_param("endeavour_id", "The endeavour ID", True)
  |> tool.add_string_param(
    "status_filter",
    "Filter: scheduled/completed/failed/all (default: all)",
    False,
  )
  |> tool.build()
}

fn update_task_tool() -> llm_types.Tool {
  tool.new("update_task")
  |> tool.with_description("Edit a task's title or description.")
  |> tool.add_string_param("task_id", "The task ID", True)
  |> tool.add_string_param("title", "New title (optional)", False)
  |> tool.add_string_param("description", "New description (optional)", False)
  |> tool.build()
}

fn add_task_step_tool() -> llm_types.Tool {
  tool.new("add_task_step")
  |> tool.with_description("Add a new step to an existing task.")
  |> tool.add_string_param("task_id", "The task ID", True)
  |> tool.add_string_param("description", "What this step accomplishes", True)
  |> tool.build()
}

fn remove_task_step_tool() -> llm_types.Tool {
  tool.new("remove_task_step")
  |> tool.with_description("Remove a step from a task by index.")
  |> tool.add_string_param("task_id", "The task ID", True)
  |> tool.add_integer_param("step_index", "Index of the step to remove", True)
  |> tool.build()
}

fn get_forecast_breakdown_tool() -> llm_types.Tool {
  tool.new("get_forecast_breakdown")
  |> tool.with_description(
    "Get per-feature forecast breakdown for a task or endeavour. "
    <> "Shows each health feature's magnitude, weight, and rationale.",
  )
  |> tool.add_string_param(
    "id",
    "The task ID or endeavour ID to get breakdown for",
    True,
  )
  |> tool.build()
}

fn delete_task_tool() -> llm_types.Tool {
  tool.new("delete_task")
  |> tool.with_description(
    "Permanently delete a task. Use when a task was created in error "
    <> "or is completely irrelevant. Prefer abandon_task for normal cancellation.",
  )
  |> tool.add_string_param("task_id", "The task ID to delete", True)
  |> tool.build()
}

fn delete_endeavour_tool() -> llm_types.Tool {
  tool.new("delete_endeavour")
  |> tool.with_description(
    "Permanently delete an endeavour. Use when an endeavour was created in error. "
    <> "Does not delete associated tasks.",
  )
  |> tool.add_string_param("endeavour_id", "The endeavour ID to delete", True)
  |> tool.build()
}

fn purge_empty_tasks_tool() -> llm_types.Tool {
  tool.new("purge_empty_tasks")
  |> tool.with_description(
    "Remove all tasks with 0 steps and 0 cycles — empty shells from "
    <> "planner auto-creation. Returns the count of purged tasks.",
  )
  |> tool.build()
}

/// Is this a planner tool on the cognitive loop? Only includes the quick
/// operations that stay on the cognitive loop.
pub fn is_planner_tool(name: String) -> Bool {
  name == "complete_task_step"
  || name == "activate_task"
  || name == "get_active_work"
  || name == "get_task_detail"
  || name == "create_task"
  || name == "request_forecast_review"
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

pub fn execute(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
  appraiser_ctx: Option(appraiser.AppraiserContext),
) -> llm_types.ToolResult {
  case call.name {
    "complete_task_step" ->
      run_complete_step(call, planner_dir, lib, appraiser_ctx)
    "flag_risk" -> run_flag_risk(call, planner_dir, lib)
    "activate_task" -> run_activate_task(call, planner_dir, lib, appraiser_ctx)
    "abandon_task" -> run_abandon_task(call, planner_dir, lib, appraiser_ctx)
    "create_endeavour" -> run_create_endeavour(call, planner_dir, lib)
    "add_task_to_endeavour" -> run_add_task_to_endeavour(call, planner_dir, lib)
    "get_active_work" -> run_get_active_work(call, lib)
    "get_task_detail" -> run_get_task_detail(call, lib)
    "create_task" -> run_create_task_direct(call, planner_dir, lib)
    "request_forecast_review" ->
      run_request_forecast_review(call, planner_dir, lib)
    // Endeavour management (Phases 2-7)
    "add_phase" -> run_add_phase(call, planner_dir, lib)
    "advance_phase" -> run_advance_phase(call, planner_dir, lib)
    "schedule_work_session" -> run_schedule_work_session(call, planner_dir, lib)
    "report_blocker" -> run_report_blocker(call, planner_dir, lib)
    "resolve_blocker" -> run_resolve_blocker(call, planner_dir, lib)
    "get_endeavour_detail" -> run_get_endeavour_detail(call, lib)
    "get_forecaster_config" -> run_get_forecaster_config(call, planner_dir, lib)
    "update_forecaster_config" ->
      run_update_forecaster_config(call, planner_dir, lib)
    "update_endeavour" -> run_update_endeavour(call, planner_dir, lib)
    "cancel_work_session" -> run_cancel_work_session(call, planner_dir, lib)
    "list_work_sessions" -> run_list_work_sessions(call, lib)
    "update_task" -> run_update_task(call, planner_dir, lib)
    "add_task_step" -> run_add_task_step(call, planner_dir, lib)
    "remove_task_step" -> run_remove_task_step(call, planner_dir, lib)
    "get_forecast_breakdown" -> run_get_forecast_breakdown(call, lib)
    "delete_task" -> run_delete_task(call, planner_dir, lib)
    "delete_endeavour" -> run_delete_endeavour(call, planner_dir, lib)
    "purge_empty_tasks" -> run_purge_empty_tasks(call, planner_dir, lib)
    _ ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Unknown planner tool: " <> call.name,
      )
  }
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

fn run_complete_step(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
  appraiser_ctx: Option(appraiser.AppraiserContext),
) -> llm_types.ToolResult {
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    use step_index <- decode.field("step_index", decode.int)
    decode.success(#(task_id, step_index))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need task_id and step_index",
      )
    Ok(#(task_id, step_index)) ->
      case librarian.get_task_by_id(lib, task_id) {
        Error(_) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Task not found: " <> task_id,
          )
        Ok(_) -> {
          let now = iso_now()
          let op = types.CompleteStep(task_id:, step_index:, at: now)
          planner_log.append_task_op(planner_dir, op)
          librarian.notify_task_op(lib, op)
          slog.debug(
            "tools/planner",
            "complete_step",
            "Step " <> int.to_string(step_index) <> " completed on " <> task_id,
            None,
          )
          // Check for auto-completion → trigger post-mortem
          maybe_post_mortem_on_complete(lib, task_id, appraiser_ctx)
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Step "
              <> int.to_string(step_index)
              <> " marked complete on task "
              <> task_id,
          )
        }
      }
  }
}

fn maybe_post_mortem_on_complete(
  lib: Subject(LibrarianMessage),
  task_id: String,
  appraiser_ctx: Option(appraiser.AppraiserContext),
) -> Nil {
  case appraiser_ctx {
    None -> Nil
    Some(actx) ->
      case librarian.get_task_by_id(lib, task_id) {
        Ok(task) ->
          case task.status == types.Complete {
            True -> appraiser.spawn_post_mortem(task, actx)
            False -> Nil
          }
        Error(_) -> Nil
      }
  }
}

fn run_flag_risk(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    use risk_description <- decode.field("risk_description", decode.string)
    decode.success(#(task_id, risk_description))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need task_id and risk_description",
      )
    Ok(#(task_id, risk_description)) -> {
      let now = iso_now()
      let op = types.FlagRisk(task_id:, text: risk_description, at: now)
      planner_log.append_task_op(planner_dir, op)
      librarian.notify_task_op(lib, op)
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Risk flagged on task " <> task_id <> ": " <> risk_description,
      )
    }
  }
}

fn run_activate_task(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
  appraiser_ctx: Option(appraiser.AppraiserContext),
) -> llm_types.ToolResult {
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    decode.success(task_id)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need task_id",
      )
    Ok(task_id) ->
      case librarian.get_task_by_id(lib, task_id) {
        Error(_) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Task not found: " <> task_id,
          )
        Ok(_) -> {
          let now = iso_now()
          let op = types.UpdateTaskStatus(task_id:, status: Active, at: now)
          planner_log.append_task_op(planner_dir, op)
          librarian.notify_task_op(lib, op)
          // Trigger pre-mortem
          case appraiser_ctx {
            None -> Nil
            Some(actx) ->
              case librarian.get_task_by_id(lib, task_id) {
                Ok(task) -> appraiser.spawn_pre_mortem(task, actx)
                Error(_) -> Nil
              }
          }
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Task " <> task_id <> " activated",
          )
        }
      }
  }
}

fn run_abandon_task(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
  appraiser_ctx: Option(appraiser.AppraiserContext),
) -> llm_types.ToolResult {
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(#(task_id, reason))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need task_id and reason",
      )
    Ok(#(task_id, reason)) -> {
      let now = iso_now()
      let op =
        types.UpdateTaskStatus(task_id:, status: types.Abandoned, at: now)
      planner_log.append_task_op(planner_dir, op)
      librarian.notify_task_op(lib, op)
      // Also flag the reason as a risk for traceability
      let risk_op =
        types.FlagRisk(task_id:, text: "Abandoned: " <> reason, at: now)
      planner_log.append_task_op(planner_dir, risk_op)
      librarian.notify_task_op(lib, risk_op)
      // Trigger post-mortem for abandoned task
      case appraiser_ctx {
        None -> Nil
        Some(actx) ->
          case librarian.get_task_by_id(lib, task_id) {
            Ok(task) -> appraiser.spawn_post_mortem(task, actx)
            Error(_) -> Nil
          }
      }
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Task " <> task_id <> " abandoned: " <> reason,
      )
    }
  }
}

fn run_create_endeavour(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use title <- decode.field("title", decode.string)
    use description <- decode.field("description", decode.string)
    decode.success(#(title, description))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need title and description",
      )
    Ok(#(title, description)) -> {
      let now = iso_now()
      let endeavour_id = "end-" <> uuid_v4()
      let endeavour =
        types.new_endeavour(
          endeavour_id,
          SystemEndeavour,
          title,
          description,
          now,
        )
      let op = types.CreateEndeavour(endeavour:)
      planner_log.append_endeavour_op(planner_dir, op)
      librarian.notify_endeavour_op(lib, op)
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Endeavour created: " <> endeavour_id <> " — " <> title,
      )
    }
  }
}

fn run_add_task_to_endeavour(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    decode.success(#(task_id, endeavour_id))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need task_id and endeavour_id",
      )
    Ok(#(task_id, endeavour_id)) -> {
      let op = types.AddTaskToEndeavour(endeavour_id:, task_id:)
      planner_log.append_endeavour_op(planner_dir, op)
      librarian.notify_endeavour_op(lib, op)
      // Also update the task's endeavour_id if it doesn't have one
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Task " <> task_id <> " added to endeavour " <> endeavour_id,
      )
    }
  }
}

fn run_get_active_work(
  call: llm_types.ToolCall,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let tasks = librarian.get_active_tasks(lib)
  let endeavours = librarian.get_all_endeavours(lib)
  let active_endeavours = list.filter(endeavours, fn(e) { e.status == Open })

  let task_lines =
    list.map(tasks, fn(t) {
      let completed =
        list.count(t.plan_steps, fn(s) { s.status == types.Complete })
      let total = list.length(t.plan_steps)
      let score_str = case t.forecast_score {
        Some(s) -> " forecast=" <> string.inspect(s)
        None -> ""
      }
      let end_str = case t.endeavour_id {
        Some(eid) -> " endeavour=" <> eid
        None -> ""
      }
      "- "
      <> t.task_id
      <> " ["
      <> status_to_string(t.status)
      <> "] "
      <> t.title
      <> " ("
      <> int.to_string(completed)
      <> "/"
      <> int.to_string(total)
      <> " steps)"
      <> score_str
      <> end_str
    })

  let end_lines =
    list.map(active_endeavours, fn(e) {
      let task_count = list.length(e.task_ids)
      "- "
      <> e.endeavour_id
      <> " "
      <> e.title
      <> " ("
      <> int.to_string(task_count)
      <> " tasks)"
    })

  let content = case task_lines, end_lines {
    [], [] -> "No active work."
    _, [] -> "Tasks:\n" <> string.join(task_lines, "\n")
    [], _ -> "Endeavours:\n" <> string.join(end_lines, "\n")
    _, _ ->
      "Tasks:\n"
      <> string.join(task_lines, "\n")
      <> "\n\nEndeavours:\n"
      <> string.join(end_lines, "\n")
  }

  llm_types.ToolSuccess(tool_use_id: call.id, content:)
}

fn run_get_task_detail(
  call: llm_types.ToolCall,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    decode.success(task_id)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need task_id",
      )
    Ok(task_id) ->
      case librarian.get_task_by_id(lib, task_id) {
        Error(_) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Task not found: " <> task_id,
          )
        Ok(task) -> {
          let step_lines =
            list.map(task.plan_steps, fn(s) {
              let check = case s.status {
                types.Complete -> "[x]"
                _ -> "[ ]"
              }
              "  "
              <> check
              <> " "
              <> int.to_string(s.index)
              <> ". "
              <> s.description
            })
          let risk_lines = list.map(task.risks, fn(r) { "  - " <> r })
          let mat_risk_lines =
            list.map(task.materialised_risks, fn(r) { "  ! " <> r })
          let score_str = case task.forecast_score {
            Some(s) -> "Forecast: " <> string.inspect(s) <> "\n"
            None -> ""
          }
          let content =
            "Task: "
            <> task.task_id
            <> " ["
            <> status_to_string(task.status)
            <> "]\n"
            <> "Title: "
            <> task.title
            <> "\n"
            <> "Complexity: "
            <> task.complexity
            <> "\n"
            <> score_str
            <> "Steps:\n"
            <> string.join(step_lines, "\n")
            <> "\n"
            <> case risk_lines {
              [] -> ""
              _ -> "Risks:\n" <> string.join(risk_lines, "\n") <> "\n"
            }
            <> case mat_risk_lines {
              [] -> ""
              _ ->
                "Materialised risks:\n"
                <> string.join(mat_risk_lines, "\n")
                <> "\n"
            }
            <> "Cycles: "
            <> int.to_string(list.length(task.cycle_ids))

          llm_types.ToolSuccess(tool_use_id: call.id, content:)
        }
      }
  }
}

fn run_create_task_direct(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use title <- decode.field("title", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    use steps_str <- decode.field("steps", decode.string)
    use complexity <- decode.optional_field(
      "complexity",
      "medium",
      decode.string,
    )
    decode.success(#(title, description, steps_str, complexity))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need title and steps",
      )
    Ok(#(title, description, steps_str, complexity)) -> {
      let steps =
        string.split(steps_str, ",")
        |> list.map(string.trim)
        |> list.filter(fn(s) { s != "" })
      case steps {
        [] ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "At least one step is required",
          )
        _ -> {
          let desc = case description {
            "" -> string.join(steps, "; ")
            d -> d
          }
          let task_id =
            create_task(
              planner_dir,
              lib,
              title,
              desc,
              steps,
              [],
              [],
              complexity,
              [],
              types.UserTask,
              None,
              uuid_v4(),
            )
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Task created: "
              <> task_id
              <> " — "
              <> title
              <> " ("
              <> int.to_string(list.length(steps))
              <> " steps)",
          )
        }
      }
    }
  }
}

fn run_request_forecast_review(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use task_id <- decode.optional_field(
      "task_id",
      None,
      decode.optional(decode.string),
    )
    decode.success(task_id)
  }
  let target_id = case json.parse(call.input_json, decoder) {
    Ok(id) -> id
    Error(_) -> None
  }

  case target_id {
    Some(tid) ->
      case librarian.get_task_by_id(lib, tid) {
        Error(_) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Task not found: " <> tid,
          )
        Ok(task) -> do_forecast_review(call.id, [task], planner_dir, lib)
      }
    None -> {
      let all_tasks = librarian.get_active_tasks(lib)
      let active =
        list.filter(all_tasks, fn(t) {
          t.status == Active || t.status == Pending
        })
      do_forecast_review(call.id, active, planner_dir, lib)
    }
  }
}

fn do_forecast_review(
  tool_use_id: String,
  tasks: List(types.PlannerTask),
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  case tasks {
    [] ->
      llm_types.ToolSuccess(tool_use_id:, content: "No active tasks to review.")
    _ -> {
      let plan_features = features.plan_health_features()
      let replan_threshold = features.default_replan_threshold
      let review_lines =
        list.map(tasks, fn(task) {
          let forecasts = compute_task_forecasts(task)
          let dprime_score = engine.compute_dprime(forecasts, plan_features, 1)

          // Persist the updated score
          let op =
            types.UpdateForecastScore(
              task_id: task.task_id,
              score: dprime_score,
            )
          planner_log.append_task_op(planner_dir, op)
          librarian.notify_task_op(lib, op)

          let replan = dprime_score >=. replan_threshold
          let replan_str = case replan {
            True -> " ** REPLAN SUGGESTED **"
            False -> ""
          }

          let high_signals =
            forecasts
            |> list.filter(fn(f) { f.magnitude >= 4 })
            |> list.map(fn(f) {
              "    - " <> f.feature_name <> ": " <> f.rationale
            })
            |> string.join("\n")

          let signals_section = case high_signals {
            "" -> ""
            s -> "\n  Elevated signals:\n" <> s
          }

          "- "
          <> task.task_id
          <> " ["
          <> status_to_string(task.status)
          <> "] "
          <> task.title
          <> "\n  D' score: "
          <> float.to_string(dprime_score)
          <> " (threshold: "
          <> float.to_string(replan_threshold)
          <> ")"
          <> replan_str
          <> signals_section
        })

      let any_replan =
        list.any(tasks, fn(task) {
          let forecasts = compute_task_forecasts(task)
          let score = engine.compute_dprime(forecasts, plan_features, 1)
          score >=. replan_threshold
        })
      let summary = case any_replan {
        True ->
          "\n\nSummary: One or more tasks have elevated D' scores. Consider replanning."
        False -> "\n\nSummary: All tasks within normal parameters."
      }

      llm_types.ToolSuccess(
        tool_use_id:,
        content: "Forecast Review ("
          <> int.to_string(list.length(tasks))
          <> " tasks):\n"
          <> string.join(review_lines, "\n\n")
          <> summary,
      )
    }
  }
}

/// Compute heuristic forecasts for a task. Delegates to the Forecaster
/// actor's implementation so both tool-driven reviews and autonomous
/// forecaster ticks produce identical scores.
///
/// This used to have its own copy of the heuristic with magnitudes on a
/// 1–9 scale (step_rate: 1/4/7, dep: 1/5+blocked, complexity: 1/5,
/// risk: 1/3+n*2/9, scope: 1). The D' engine clamps magnitudes to
/// [0, 3], so all the high values collapsed to 3 while the "default
/// case" values of 1 stayed at 1. With five features all defaulting to
/// magnitude 1 and importances [3,3,2,2,1], every task received
/// D' = (3+3+2+2+1) / ((3+3+2+2+1)*3) = 11/33 = 0.3333… regardless
/// of actual state. The forecaster actor's implementation uses the
/// correct 0–3 scale and zero as the "no signal" default, restoring
/// per-task variation.
fn compute_task_forecasts(
  task: types.PlannerTask,
) -> List(dprime_types.Forecast) {
  forecaster.compute_heuristic_forecasts(task)
}

// ---------------------------------------------------------------------------
// Task creation (called from planner output hook)
// ---------------------------------------------------------------------------

/// Create a new task from planner output. Returns the task_id.
pub fn create_task(
  planner_dir: String,
  lib: Subject(LibrarianMessage),
  title: String,
  description: String,
  plan_steps: List(String),
  verifications: List(String),
  dependencies: List(#(String, String)),
  complexity: String,
  risks: List(String),
  origin: types.TaskOrigin,
  endeavour_id: Option(String),
  cycle_id: String,
) -> String {
  let now = iso_now()
  let task_id = "task-" <> uuid_v4()
  // Pad verifications to match steps length, then zip
  let padded_verifications =
    list.append(
      verifications,
      list.repeat("", list.length(plan_steps) - list.length(verifications)),
    )
  let step_pairs = list.zip(plan_steps, padded_verifications)
  let steps =
    list.index_map(step_pairs, fn(pair, idx) {
      let #(desc, verify_text) = pair
      let verify = case verify_text {
        "" -> None
        v -> Some(v)
      }
      PlanStep(
        index: idx + 1,
        description: desc,
        status: Pending,
        completed_at: None,
        verification: verify,
      )
    })
  let task =
    PlannerTask(
      task_id:,
      endeavour_id:,
      origin:,
      title:,
      description:,
      status: Pending,
      plan_steps: steps,
      dependencies:,
      complexity:,
      risks:,
      materialised_risks: [],
      created_at: now,
      updated_at: now,
      cycle_ids: [cycle_id],
      forecast_score: None,
      forecast_breakdown: None,
      pre_mortem: None,
      post_mortem: None,
    )
  let op = types.CreateTask(task:)
  planner_log.append_task_op(planner_dir, op)
  librarian.notify_task_op(lib, op)
  slog.info(
    "tools/planner",
    "create_task",
    "Created task " <> task_id <> ": " <> title,
    Some(cycle_id),
  )
  task_id
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn status_to_string(s: types.TaskStatus) -> String {
  case s {
    Pending -> "pending"
    Active -> "active"
    types.Complete -> "complete"
    types.Failed -> "failed"
    types.Abandoned -> "abandoned"
  }
}

// ---------------------------------------------------------------------------
// Endeavour management implementations (Phases 2-7)
// ---------------------------------------------------------------------------

fn run_add_phase(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    use name <- decode.field("name", decode.string)
    use description <- decode.field("description", decode.string)
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
    decode.success(#(
      endeavour_id,
      name,
      description,
      milestone,
      estimated_sessions,
    ))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need endeavour_id, name, description",
      )
    Ok(#(endeavour_id, name, description, milestone, estimated_sessions)) -> {
      let phase =
        Phase(
          name:,
          description:,
          status: PhaseNotStarted,
          task_ids: [],
          depends_on: [],
          milestone:,
          estimated_sessions:,
          actual_sessions: 0,
        )
      let op = types.AddPhase(endeavour_id:, phase:)
      planner_log.append_endeavour_op(planner_dir, op)
      librarian.notify_endeavour_op(lib, op)
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Phase '" <> name <> "' added to endeavour " <> endeavour_id,
      )
    }
  }
}

fn run_advance_phase(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    use phase_name <- decode.field("phase_name", decode.string)
    decode.success(#(endeavour_id, phase_name))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need endeavour_id and phase_name",
      )
    Ok(#(endeavour_id, phase_name)) -> {
      // Check approval gate for phase transitions
      let endeavour = librarian.get_endeavour(lib, endeavour_id)
      let needs_approval = case endeavour {
        Ok(e) ->
          case e.approval_config.phase_transition {
            types.RequireApproval -> True
            _ -> False
          }
        Error(_) -> False
      }
      case needs_approval {
        True ->
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "[APPROVAL REQUIRED] Phase transition on "
              <> endeavour_id
              <> " requires operator approval. Phase '"
              <> phase_name
              <> "' not yet advanced. Ask the operator to approve.",
          )
        False -> {
          // Mark the named phase as complete
          let op =
            types.UpdatePhase(endeavour_id:, phase_name:, status: PhaseComplete)
          planner_log.append_endeavour_op(planner_dir, op)
          librarian.notify_endeavour_op(lib, op)

          // Find the next phase and mark it in-progress
          let next_msg = case endeavour {
            Ok(e) -> {
              let next = find_next_phase(e.phases, phase_name)
              case next {
                Some(next_name) -> {
                  let op2 =
                    types.UpdatePhase(
                      endeavour_id:,
                      phase_name: next_name,
                      status: PhaseInProgress,
                    )
                  planner_log.append_endeavour_op(planner_dir, op2)
                  librarian.notify_endeavour_op(lib, op2)
                  " Next phase: " <> next_name
                }
                None -> " No more phases — endeavour may be complete."
              }
            }
            Error(_) -> ""
          }
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Phase '" <> phase_name <> "' marked complete." <> next_msg,
          )
        }
      }
    }
  }
}

fn find_next_phase(
  phases: List(types.Phase),
  completed_name: String,
) -> Option(String) {
  find_next_phase_loop(phases, completed_name, False)
}

fn find_next_phase_loop(
  phases: List(types.Phase),
  completed_name: String,
  found_current: Bool,
) -> Option(String) {
  case phases {
    [] -> None
    [phase, ..rest] ->
      case found_current {
        True -> Some(phase.name)
        False ->
          case phase.name == completed_name {
            True -> find_next_phase_loop(rest, completed_name, True)
            False -> find_next_phase_loop(rest, completed_name, False)
          }
      }
  }
}

fn run_schedule_work_session(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    use phase <- decode.field("phase", decode.string)
    use focus <- decode.field("focus", decode.string)
    use scheduled_at <- decode.field("scheduled_at", decode.string)
    use max_cycles <- decode.optional_field("max_cycles", 5, decode.int)
    decode.success(#(endeavour_id, phase, focus, scheduled_at, max_cycles))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need endeavour_id, phase, focus, scheduled_at",
      )
    Ok(#(endeavour_id, phase, focus, scheduled_at, max_cycles)) -> {
      let session_id = "sess-" <> uuid_v4()
      let session =
        WorkSession(
          session_id:,
          scheduled_at:,
          status: SessionScheduled,
          phase:,
          focus:,
          max_cycles:,
          max_tokens: max_cycles * 40_000,
          actual_cycles: 0,
          actual_tokens: 0,
          outcome: None,
        )
      let op = types.ScheduleSession(endeavour_id:, session:)
      planner_log.append_endeavour_op(planner_dir, op)
      librarian.notify_endeavour_op(lib, op)

      // Also update endeavour status to Active if it's Draft
      let endeavour = librarian.get_endeavour(lib, endeavour_id)
      case endeavour {
        Ok(e) ->
          case e.status {
            types.Draft -> {
              let status_op =
                types.UpdateEndeavourStatus(
                  endeavour_id:,
                  status: EndeavourActive,
                )
              planner_log.append_endeavour_op(planner_dir, status_op)
              librarian.notify_endeavour_op(lib, status_op)
            }
            _ -> Nil
          }
        Error(_) -> Nil
      }

      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Work session "
          <> session_id
          <> " scheduled for "
          <> scheduled_at
          <> " — phase: "
          <> phase
          <> ", focus: "
          <> focus,
      )
    }
  }
}

fn run_report_blocker(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    use description <- decode.field("description", decode.string)
    use resolution_strategy <- decode.field(
      "resolution_strategy",
      decode.string,
    )
    use requires_human <- decode.optional_field(
      "requires_human",
      False,
      decode.bool,
    )
    decode.success(#(
      endeavour_id,
      description,
      resolution_strategy,
      requires_human,
    ))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need endeavour_id, description, resolution_strategy",
      )
    Ok(#(endeavour_id, description, resolution_strategy, requires_human)) ->
      case librarian.get_endeavour_by_id(lib, endeavour_id) {
        Error(_) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Endeavour not found: " <> endeavour_id,
          )
        Ok(_) -> {
          let blocker_id = "blk-" <> uuid_v4()
          let blocker =
            Blocker(
              id: blocker_id,
              description:,
              detected_at: iso_now(),
              resolution_strategy:,
              requires_human:,
              resolved_at: None,
              resolution: None,
            )
          let op = types.AddBlocker(endeavour_id:, blocker:)
          planner_log.append_endeavour_op(planner_dir, op)
          librarian.notify_endeavour_op(lib, op)

          // Update endeavour status to Blocked
          let status_op =
            types.UpdateEndeavourStatus(endeavour_id:, status: EndeavourBlocked)
          planner_log.append_endeavour_op(planner_dir, status_op)
          librarian.notify_endeavour_op(lib, status_op)

          let human_note = case requires_human {
            True -> " [Requires operator intervention]"
            False -> ""
          }
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Blocker "
              <> blocker_id
              <> " reported on "
              <> endeavour_id
              <> ": "
              <> description
              <> human_note,
          )
        }
      }
  }
}

fn run_resolve_blocker(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    use blocker_id <- decode.field("blocker_id", decode.string)
    use resolution <- decode.field("resolution", decode.string)
    decode.success(#(endeavour_id, blocker_id, resolution))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need endeavour_id, blocker_id, resolution",
      )
    Ok(#(endeavour_id, blocker_id, resolution)) -> {
      let op =
        types.ResolveBlocker(
          endeavour_id:,
          blocker_id:,
          resolution:,
          at: iso_now(),
        )
      planner_log.append_endeavour_op(planner_dir, op)
      librarian.notify_endeavour_op(lib, op)

      // Check if all blockers are resolved; if so, set status back to Active
      let endeavour = librarian.get_endeavour(lib, endeavour_id)
      case endeavour {
        Ok(e) -> {
          let unresolved =
            list.filter(e.blockers, fn(b) {
              case b.resolved_at {
                None -> b.id != blocker_id
                Some(_) -> False
              }
            })
          case list.length(unresolved) {
            0 -> {
              let status_op =
                types.UpdateEndeavourStatus(
                  endeavour_id:,
                  status: EndeavourActive,
                )
              planner_log.append_endeavour_op(planner_dir, status_op)
              librarian.notify_endeavour_op(lib, status_op)
            }
            _ -> Nil
          }
        }
        Error(_) -> Nil
      }

      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Blocker " <> blocker_id <> " resolved: " <> resolution,
      )
    }
  }
}

fn run_get_endeavour_detail(
  call: llm_types.ToolCall,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    decode.success(endeavour_id)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need endeavour_id",
      )
    Ok(endeavour_id) -> {
      case librarian.get_endeavour(lib, endeavour_id) {
        Error(_) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Endeavour not found: " <> endeavour_id,
          )
        Ok(e) -> {
          let phase_lines =
            list.map(e.phases, fn(p) {
              let status_str = case p.status {
                PhaseNotStarted -> "not started"
                PhaseInProgress -> "in progress"
                PhaseComplete -> "complete"
                types.PhaseBlocked(reason) -> "blocked: " <> reason
                types.PhaseSkipped(reason) -> "skipped: " <> reason
              }
              "  - "
              <> p.name
              <> " ["
              <> status_str
              <> "] ("
              <> int.to_string(p.actual_sessions)
              <> "/"
              <> int.to_string(p.estimated_sessions)
              <> " sessions)"
            })

          let blocker_lines =
            list.map(e.blockers, fn(b) {
              let resolved = case b.resolved_at {
                Some(_) -> " [RESOLVED]"
                None ->
                  case b.requires_human {
                    True -> " [NEEDS HUMAN]"
                    False -> " [ACTIVE]"
                  }
              }
              "  - " <> b.id <> ": " <> b.description <> resolved
            })

          let session_lines =
            list.map(e.work_sessions, fn(s) {
              let status_str = case s.status {
                SessionScheduled -> "scheduled"
                types.SessionInProgress -> "in progress"
                types.SessionCompleted(o) -> "completed: " <> o
                types.SessionSkipped(r) -> "skipped: " <> r
                types.SessionFailed(r) -> "failed: " <> r
              }
              "  - "
              <> s.session_id
              <> " @ "
              <> s.scheduled_at
              <> " ["
              <> status_str
              <> "] focus: "
              <> s.focus
            })

          let status_str = case e.status {
            types.Draft -> "draft"
            EndeavourActive -> "active"
            EndeavourBlocked -> "blocked"
            types.OnHold -> "on hold"
            types.EndeavourComplete -> "complete"
            types.EndeavourFailed -> "failed"
            Open -> "open"
            types.EndeavourAbandoned -> "abandoned"
          }

          let detail =
            "Endeavour: "
            <> e.title
            <> "\nID: "
            <> e.endeavour_id
            <> "\nStatus: "
            <> status_str
            <> "\nGoal: "
            <> e.goal
            <> "\nSuccess criteria: "
            <> string.join(e.success_criteria, "; ")
            <> "\nDeadline: "
            <> option.unwrap(e.deadline, "none")
            <> "\nPhases ("
            <> int.to_string(list.length(e.phases))
            <> "):\n"
            <> string.join(phase_lines, "\n")
            <> "\nBlockers ("
            <> int.to_string(list.length(e.blockers))
            <> "):\n"
            <> string.join(blocker_lines, "\n")
            <> "\nSessions ("
            <> int.to_string(list.length(e.work_sessions))
            <> "):\n"
            <> string.join(session_lines, "\n")
            <> "\nMetrics: "
            <> int.to_string(e.total_cycles)
            <> " cycles, "
            <> int.to_string(e.total_tokens)
            <> " tokens, "
            <> int.to_string(e.replan_count)
            <> " replans"

          llm_types.ToolSuccess(tool_use_id: call.id, content: detail)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Forecaster introspection tools
// ---------------------------------------------------------------------------

fn run_get_forecaster_config(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.optional_field(
      "endeavour_id",
      None,
      decode.optional(decode.string),
    )
    decode.success(endeavour_id)
  }
  let endeavour_id = case json.parse(call.input_json, decoder) {
    Ok(eid) -> eid
    Error(_) -> None
  }

  // Load base config
  let base_path = planner_dir <> "/../planner_features.json"
  let base = planner_config.load(base_path)

  // Get per-endeavour overrides if requested
  let endeavour = case endeavour_id {
    Some(eid) ->
      case librarian.get_endeavour(lib, eid) {
        Ok(e) -> Some(e)
        Error(_) -> None
      }
    None -> None
  }

  let #(effective_features, effective_threshold) =
    planner_config.effective_features(base, endeavour)

  let feature_lines =
    list.map(effective_features, fn(f) {
      let imp = case f.importance {
        dprime_types.High -> "HIGH"
        dprime_types.Medium -> "MEDIUM"
        dprime_types.Low -> "LOW"
      }
      let crit = case f.critical {
        True -> " [CRITICAL]"
        False -> ""
      }
      "  - " <> f.name <> " (" <> imp <> crit <> "): " <> f.description
    })

  let override_note = case endeavour {
    Some(e) ->
      case e.feature_overrides {
        Some(_) -> "\n[Per-endeavour feature overrides active]"
        None -> ""
      }
      <> case e.threshold_override {
        Some(t) ->
          "\n[Per-endeavour threshold override: " <> float.to_string(t) <> "]"
        None -> ""
      }
    None -> ""
  }

  let result =
    "Forecaster Configuration\n"
    <> "Replan threshold: "
    <> float.to_string(effective_threshold)
    <> "\nFeatures ("
    <> int.to_string(list.length(effective_features))
    <> "):\n"
    <> string.join(feature_lines, "\n")
    <> override_note

  llm_types.ToolSuccess(tool_use_id: call.id, content: result)
}

fn run_update_forecaster_config(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    use feature_name <- decode.optional_field(
      "feature_name",
      None,
      decode.optional(decode.string),
    )
    use importance <- decode.optional_field(
      "importance",
      None,
      decode.optional(decode.string),
    )
    use threshold_override <- decode.optional_field(
      "threshold_override",
      None,
      decode.optional(decode.float),
    )
    decode.success(#(endeavour_id, feature_name, importance, threshold_override))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need endeavour_id",
      )
    Ok(#(endeavour_id, feature_name, importance, threshold_override)) -> {
      // Get current endeavour to build overrides
      let current = librarian.get_endeavour(lib, endeavour_id)
      let base_path = planner_dir <> "/../planner_features.json"
      let base = planner_config.load(base_path)

      let current_features = case current {
        Ok(e) ->
          case e.feature_overrides {
            Some(fs) -> fs
            None -> base.features
          }
        Error(_) -> base.features
      }

      // Apply feature importance change if requested
      let new_features = case feature_name, importance {
        Some(fname), Some(imp_str) -> {
          let new_imp = case imp_str {
            "high" -> dprime_types.High
            "low" -> dprime_types.Low
            _ -> dprime_types.Medium
          }
          Some(
            list.map(current_features, fn(f) {
              case f.name == fname {
                True -> dprime_types.Feature(..f, importance: new_imp)
                False -> f
              }
            }),
          )
        }
        _, _ -> {
          case current {
            Ok(e) -> e.feature_overrides
            Error(_) -> None
          }
        }
      }

      let op =
        types.UpdateForecasterConfig(
          endeavour_id:,
          feature_overrides: new_features,
          threshold_override:,
        )
      planner_log.append_endeavour_op(planner_dir, op)
      librarian.notify_endeavour_op(lib, op)

      let changes = case feature_name, importance {
        Some(fname), Some(imp) -> fname <> " importance → " <> imp <> ". "
        _, _ -> ""
      }
      let threshold_msg = case threshold_override {
        Some(t) -> "Threshold → " <> float.to_string(t) <> ". "
        None -> ""
      }

      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Forecaster config updated for "
          <> endeavour_id
          <> ": "
          <> changes
          <> threshold_msg,
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Endeavour field update tools
// ---------------------------------------------------------------------------

fn run_update_endeavour(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    use goal <- decode.optional_field(
      "goal",
      None,
      decode.optional(decode.string),
    )
    use deadline <- decode.optional_field(
      "deadline",
      None,
      decode.optional(decode.string),
    )
    use update_cadence <- decode.optional_field(
      "update_cadence",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(endeavour_id, goal, deadline, update_cadence))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need endeavour_id",
      )
    Ok(#(endeavour_id, goal, deadline, update_cadence)) -> {
      let op =
        types.UpdateEndeavourFields(
          endeavour_id:,
          goal:,
          success_criteria: None,
          deadline:,
          update_cadence:,
          approval_config: None,
        )
      planner_log.append_endeavour_op(planner_dir, op)
      librarian.notify_endeavour_op(lib, op)
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Endeavour " <> endeavour_id <> " updated.",
      )
    }
  }
}

fn run_cancel_work_session(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    use session_id <- decode.field("session_id", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(#(endeavour_id, session_id, reason))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need endeavour_id, session_id, reason",
      )
    Ok(#(endeavour_id, session_id, reason)) -> {
      let op =
        types.CancelSession(endeavour_id:, session_id:, reason:, at: iso_now())
      planner_log.append_endeavour_op(planner_dir, op)
      librarian.notify_endeavour_op(lib, op)
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Session " <> session_id <> " cancelled: " <> reason,
      )
    }
  }
}

fn run_list_work_sessions(
  call: llm_types.ToolCall,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    use status_filter <- decode.optional_field(
      "status_filter",
      "all",
      decode.string,
    )
    decode.success(#(endeavour_id, status_filter))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need endeavour_id",
      )
    Ok(#(endeavour_id, status_filter)) ->
      case librarian.get_endeavour(lib, endeavour_id) {
        Error(_) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Endeavour not found: " <> endeavour_id,
          )
        Ok(e) -> {
          let sessions = case status_filter {
            "scheduled" ->
              list.filter(e.work_sessions, fn(s) {
                s.status == SessionScheduled
              })
            "all" -> e.work_sessions
            _ -> e.work_sessions
          }
          let lines =
            list.map(sessions, fn(s) {
              let status_str = case s.status {
                SessionScheduled -> "scheduled"
                types.SessionInProgress -> "in_progress"
                types.SessionCompleted(o) -> "completed: " <> o
                types.SessionSkipped(r) -> "skipped: " <> r
                types.SessionFailed(r) -> "failed: " <> r
              }
              s.session_id
              <> " @ "
              <> s.scheduled_at
              <> " ["
              <> status_str
              <> "] phase: "
              <> s.phase
              <> " focus: "
              <> s.focus
              <> " ("
              <> int.to_string(s.actual_cycles)
              <> " cycles, "
              <> int.to_string(s.actual_tokens)
              <> " tokens)"
            })
          let result = case lines {
            [] -> "No work sessions found."
            _ ->
              "Work sessions ("
              <> int.to_string(list.length(lines))
              <> "):\n"
              <> string.join(lines, "\n")
          }
          llm_types.ToolSuccess(tool_use_id: call.id, content: result)
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Task editing tools
// ---------------------------------------------------------------------------

fn run_update_task(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    use title <- decode.optional_field(
      "title",
      None,
      decode.optional(decode.string),
    )
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(task_id, title, description))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need task_id",
      )
    Ok(#(task_id, title, description)) -> {
      let op =
        types.UpdateTaskFields(task_id:, title:, description:, at: iso_now())
      planner_log.append_task_op(planner_dir, op)
      librarian.notify_task_op(lib, op)
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Task " <> task_id <> " updated.",
      )
    }
  }
}

fn run_add_task_step(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    use description <- decode.field("description", decode.string)
    decode.success(#(task_id, description))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need task_id and description",
      )
    Ok(#(task_id, description)) -> {
      let op = types.AddTaskStep(task_id:, description:, at: iso_now())
      planner_log.append_task_op(planner_dir, op)
      librarian.notify_task_op(lib, op)
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Step added to task " <> task_id <> ": " <> description,
      )
    }
  }
}

fn run_remove_task_step(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    use step_index <- decode.field("step_index", decode.int)
    decode.success(#(task_id, step_index))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need task_id and step_index",
      )
    Ok(#(task_id, step_index)) -> {
      let op = types.RemoveTaskStep(task_id:, step_index:, at: iso_now())
      planner_log.append_task_op(planner_dir, op)
      librarian.notify_task_op(lib, op)
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Step "
          <> int.to_string(step_index)
          <> " removed from task "
          <> task_id,
      )
    }
  }
}

// ---------------------------------------------------------------------------
// get_forecast_breakdown
// ---------------------------------------------------------------------------

fn run_get_forecast_breakdown(
  call: llm_types.ToolCall,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use id <- decode.field("id", decode.string)
    decode.success(id)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need id",
      )
    Ok(id) -> {
      // Try task first, then endeavour
      case librarian.get_task_by_id(lib, id) {
        Ok(task) ->
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: format_task_breakdown(task),
          )
        Error(_) ->
          case librarian.get_endeavour_by_id(lib, id) {
            Ok(endeavour) ->
              llm_types.ToolSuccess(
                tool_use_id: call.id,
                content: format_endeavour_breakdown(endeavour),
              )
            Error(_) ->
              llm_types.ToolFailure(
                tool_use_id: call.id,
                error: "No task or endeavour found with ID: " <> id,
              )
          }
      }
    }
  }
}

fn format_breakdown_items(breakdown: List(types.ForecastBreakdown)) -> String {
  list.map(breakdown, fn(b) {
    "  "
    <> b.feature_name
    <> ": magnitude="
    <> int.to_string(b.magnitude)
    <> " weighted="
    <> float.to_string(b.weighted_score)
    <> " — "
    <> b.rationale
  })
  |> string.join("\n")
}

fn format_task_breakdown(task: types.PlannerTask) -> String {
  let score_str = case task.forecast_score {
    Some(s) -> float.to_string(s)
    None -> "not yet scored"
  }
  case task.forecast_breakdown {
    Some(items) ->
      "Task: "
      <> task.task_id
      <> " ("
      <> task.title
      <> ")\nForecast score: "
      <> score_str
      <> "\nBreakdown:\n"
      <> format_breakdown_items(items)
    None ->
      "Task: "
      <> task.task_id
      <> " ("
      <> task.title
      <> ")\nForecast score: "
      <> score_str
      <> "\nNo breakdown available yet — forecaster has not evaluated this task."
  }
}

fn format_endeavour_breakdown(e: types.Endeavour) -> String {
  let score_str = case e.forecast_score {
    Some(s) -> float.to_string(s)
    None -> "not yet scored"
  }
  case e.forecast_breakdown {
    Some(items) ->
      "Endeavour: "
      <> e.endeavour_id
      <> " ("
      <> e.title
      <> ")\nForecast score: "
      <> score_str
      <> "\nBreakdown:\n"
      <> format_breakdown_items(items)
    None ->
      "Endeavour: "
      <> e.endeavour_id
      <> " ("
      <> e.title
      <> ")\nForecast score: "
      <> score_str
      <> "\nNo breakdown available yet — forecaster has not evaluated this endeavour."
  }
}

// ---------------------------------------------------------------------------
// delete_task / delete_endeavour
// ---------------------------------------------------------------------------

fn run_delete_task(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    decode.success(task_id)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need task_id",
      )
    Ok(task_id) ->
      case librarian.get_task_by_id(lib, task_id) {
        Error(_) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Task not found: " <> task_id,
          )
        Ok(_task) -> {
          let op = types.DeleteTask(task_id:)
          planner_log.append_task_op(planner_dir, op)
          librarian.notify_task_op(lib, op)
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Task " <> task_id <> " deleted.",
          )
        }
      }
  }
}

fn run_delete_endeavour(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use endeavour_id <- decode.field("endeavour_id", decode.string)
    decode.success(endeavour_id)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: need endeavour_id",
      )
    Ok(endeavour_id) ->
      case librarian.get_endeavour_by_id(lib, endeavour_id) {
        Error(_) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Endeavour not found: " <> endeavour_id,
          )
        Ok(_e) -> {
          let op = types.DeleteEndeavour(endeavour_id:)
          planner_log.append_endeavour_op(planner_dir, op)
          librarian.notify_endeavour_op(lib, op)
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Endeavour "
              <> endeavour_id
              <> " deleted. Associated tasks are not affected.",
          )
        }
      }
  }
}

// ---------------------------------------------------------------------------
// purge_empty_tasks
// ---------------------------------------------------------------------------

fn run_purge_empty_tasks(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let all_tasks = librarian.get_active_tasks(lib)
  let empty_tasks =
    list.filter(all_tasks, fn(t) {
      list.is_empty(t.plan_steps) && list.is_empty(t.cycle_ids)
    })
  let count = list.length(empty_tasks)
  list.each(empty_tasks, fn(t) {
    let op = types.DeleteTask(task_id: t.task_id)
    planner_log.append_task_op(planner_dir, op)
    librarian.notify_task_op(lib, op)
  })
  llm_types.ToolSuccess(
    tool_use_id: call.id,
    content: "Purged "
      <> int.to_string(count)
      <> " empty task"
      <> case count {
      1 -> ""
      _ -> "s"
    }
      <> " (0 steps, 0 cycles).",
  )
}
