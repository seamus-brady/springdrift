//// Planner tools — task and endeavour management for the cognitive agent.
////
//// These tools let the agent track its own work: manage tasks with steps,
//// create endeavours for multi-task initiatives, and query active work.

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/tool
import llm/types as llm_types
import narrative/librarian.{type LibrarianMessage}
import planner/log as planner_log
import planner/types.{
  Active, Endeavour, Open, Pending, PlanStep, PlannerTask, SystemEndeavour,
}
import slog

@external(erlang, "springdrift_ffi", "generate_uuid")
fn uuid_v4() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn iso_now() -> String

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(llm_types.Tool) {
  [
    complete_task_step_tool(),
    flag_risk_tool(),
    activate_task_tool(),
    abandon_task_tool(),
    create_endeavour_tool(),
    add_task_to_endeavour_tool(),
    get_active_work_tool(),
    get_task_detail_tool(),
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

/// Check if a tool call name is a planner tool (for dispatch partitioning).
pub fn is_planner_tool(name: String) -> Bool {
  name == "complete_task_step"
  || name == "flag_risk"
  || name == "activate_task"
  || name == "abandon_task"
  || name == "create_endeavour"
  || name == "add_task_to_endeavour"
  || name == "get_active_work"
  || name == "get_task_detail"
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

pub fn execute(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  case call.name {
    "complete_task_step" -> run_complete_step(call, planner_dir, lib)
    "flag_risk" -> run_flag_risk(call, planner_dir, lib)
    "activate_task" -> run_activate_task(call, planner_dir, lib)
    "abandon_task" -> run_abandon_task(call, planner_dir, lib)
    "create_endeavour" -> run_create_endeavour(call, planner_dir, lib)
    "add_task_to_endeavour" -> run_add_task_to_endeavour(call, planner_dir, lib)
    "get_active_work" -> run_get_active_work(call, lib)
    "get_task_detail" -> run_get_task_detail(call, lib)
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
    Ok(task_id) -> {
      let now = iso_now()
      let op = types.UpdateTaskStatus(task_id:, status: Active, at: now)
      planner_log.append_task_op(planner_dir, op)
      librarian.notify_task_op(lib, op)
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Task " <> task_id <> " activated",
      )
    }
  }
}

fn run_abandon_task(
  call: llm_types.ToolCall,
  planner_dir: String,
  lib: Subject(LibrarianMessage),
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
        Endeavour(
          endeavour_id:,
          origin: SystemEndeavour,
          title:,
          description:,
          status: Open,
          task_ids: [],
          created_at: now,
          updated_at: now,
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
  dependencies: List(#(String, String)),
  complexity: String,
  risks: List(String),
  origin: types.TaskOrigin,
  endeavour_id: Option(String),
  cycle_id: String,
) -> String {
  let now = iso_now()
  let task_id = "task-" <> uuid_v4()
  let steps =
    list.index_map(plan_steps, fn(desc, idx) {
      PlanStep(
        index: idx + 1,
        description: desc,
        status: Pending,
        completed_at: None,
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
