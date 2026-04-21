//// Scheduler agent — manages reminders, todos, and appointments at runtime.
////
//// The scheduler agent translates natural language scheduling requests into
//// typed messages to the scheduler runner process. It is registered as an
//// AgentSpec so the cognitive loop can delegate to it like any other agent.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider}
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import paths
import scheduler/types as sched_types

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "ms_until_datetime")
fn ms_until_datetime(iso: String) -> Int

@external(erlang, "springdrift_ffi", "advance_datetime_ms")
fn advance_datetime_ms(iso: String, ms: Int) -> String

const system_prompt = "You are the Scheduler — a time management agent for this system.

You manage the schedule on behalf of the primary agent and the user.
You have tools to add reminders, todos, and appointments, and to list,
complete, cancel, or update existing items.

## Conventions

- Always call get_current_datetime before scheduling anything.
  You need the current time to compute a correct due_at value.

- due_at must be ISO 8601: \"YYYY-MM-DDTHH:MM:SS\" (local time).

- for_ is either \"agent\" or \"user\":
    \"agent\"  — fires as input back into the primary agent's cognitive loop
    \"user\"   — fires as a notification in the user interface

  When the user says \"remind me\", use \"user\".
  When the system says \"remind yourself\", use \"agent\".

- For recurring reminders, set interval_ms (milliseconds). For a daily
  reminder: 86400000. For hourly: 3600000.

- Todos have no timer. They are tracked for listing only.

- Appointments fire a reminder at the start time and carry a duration.

- Always return the item name/ID so the orchestrator can reference it later.

- Prefer schedule_from_spec over schedule_reminder when you have explicit
  parameters. schedule_from_spec takes structured params (no NL ambiguity)
  and returns structured confirmation with fire time previews.

- Use inspect_job to verify a job was created correctly or to debug
  failures. It returns full job state including fired_count and status.

## After your task

Respond concisely:
- What was created, updated, or cancelled
- The item name/ID
- The due_at in human-readable form if applicable"

pub fn spec(
  provider: Provider,
  model: String,
  runner: Subject(sched_types.SchedulerMessage),
) -> agent_types.AgentSpec {
  agent_types.AgentSpec(
    name: "scheduler",
    human_name: "Scheduler",
    description: "Manage reminders, todos, and appointments. "
      <> "Set one-shot or recurring reminders that fire at a specific time — "
      <> "as input to the cognitive loop (for agent self-reminders) or as "
      <> "user notifications. Maintain a todo list. Schedule appointments. "
      <> "List, cancel, complete, or reschedule existing items.",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 1024,
    max_turns: 6,
    max_consecutive_errors: 2,
    max_context_messages: Some(10),
    tools: scheduler_tools(),
    restart: agent_types.Permanent,
    tool_executor: scheduler_executor(runner),
    inter_turn_delay_ms: 100,
    redact_secrets: True,
  )
}

fn scheduler_executor(
  runner: Subject(sched_types.SchedulerMessage),
) -> fn(ToolCall) -> ToolResult {
  fn(call: ToolCall) -> ToolResult {
    case call.name {
      "get_current_datetime" -> {
        let result = get_datetime()
        ToolSuccess(tool_use_id: call.id, content: result)
      }
      _ -> execute_scheduler_tool(call, runner)
    }
  }
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

fn scheduler_tools() -> List(Tool) {
  [
    schedule_from_spec_tool(),
    schedule_reminder_tool(),
    add_todo_tool(),
    add_appointment_tool(),
    complete_item_tool(),
    cancel_item_tool(),
    list_schedule_tool(),
    update_item_tool(),
    inspect_job_tool(),
    purge_cancelled_tool(),
    datetime_tool(),
  ]
}

fn datetime_tool() -> Tool {
  tool.new("get_current_datetime")
  |> tool.with_description("Get the current date and time in ISO 8601 format.")
  |> tool.build()
}

fn schedule_from_spec_tool() -> Tool {
  tool.new("schedule_from_spec")
  |> tool.with_description(
    "Schedule a job from a structured spec. Preferred over schedule_reminder "
    <> "for precise control — no NL interpretation, explicit parameters. "
    <> "Returns structured confirmation with job ID and next fire times.",
  )
  |> tool.add_string_param(
    "kind",
    "\"reminder\" | \"todo\" | \"appointment\" | \"recurring\"",
    True,
  )
  |> tool.add_string_param("title", "Short label", True)
  |> tool.add_string_param("body", "Detail text or query to execute", True)
  |> tool.add_string_param(
    "due_at",
    "First fire time, ISO 8601: YYYY-MM-DDTHH:MM:SS",
    True,
  )
  |> tool.add_string_param(
    "for_",
    "\"agent\" (cognitive loop input) or \"user\" (notification)",
    True,
  )
  |> tool.add_integer_param(
    "interval_ms",
    "Repeat interval in milliseconds. 0 = one-shot. 300000 = 5 min. 3600000 = 1 hour. 86400000 = daily.",
    True,
  )
  |> tool.add_integer_param(
    "max_occurrences",
    "Total number of fires. 0 = unlimited. 4 = fire exactly 4 times then stop.",
    True,
  )
  |> tool.add_string_param(
    "tags",
    "Comma-separated tags for filtering and grouping",
    False,
  )
  |> tool.add_integer_param(
    "duration_minutes",
    "Duration in minutes (appointments only, 0 otherwise)",
    False,
  )
  |> tool.build()
}

fn schedule_reminder_tool() -> Tool {
  tool.new("schedule_reminder")
  |> tool.with_description(
    "Schedule a reminder that fires at a specific time. "
    <> "Can be one-shot or recurring.",
  )
  |> tool.add_string_param("title", "Short label for the reminder", True)
  |> tool.add_string_param("body", "Detail text shown when it fires", False)
  |> tool.add_string_param(
    "due_at",
    "ISO 8601 datetime: YYYY-MM-DDTHH:MM:SS",
    True,
  )
  |> tool.add_string_param(
    "for_",
    "\"agent\" (cognitive loop) or \"user\" (notification)",
    True,
  )
  |> tool.add_integer_param(
    "interval_ms",
    "Repeat every N ms after firing; 0 for one-shot",
    False,
  )
  |> tool.add_integer_param(
    "max_occurrences",
    "Maximum number of times to fire (0 or omit for unlimited recurring)",
    False,
  )
  |> tool.add_string_param("tags", "Comma-separated tags", False)
  |> tool.build()
}

fn add_todo_tool() -> Tool {
  tool.new("add_todo")
  |> tool.with_description(
    "Add a todo item. Todos have no timer — they are tracked for listing only.",
  )
  |> tool.add_string_param("title", "Short label for the todo", True)
  |> tool.add_string_param("body", "Detail text", False)
  |> tool.add_string_param(
    "due_at",
    "Soft deadline (no timer fires). ISO 8601.",
    False,
  )
  |> tool.add_string_param("for_", "\"agent\" or \"user\"", True)
  |> tool.add_string_param("tags", "Comma-separated tags", False)
  |> tool.build()
}

fn add_appointment_tool() -> Tool {
  tool.new("add_appointment")
  |> tool.with_description(
    "Schedule an appointment with a start time and duration.",
  )
  |> tool.add_string_param("title", "Short label for the appointment", True)
  |> tool.add_string_param("body", "Detail text", False)
  |> tool.add_string_param(
    "at",
    "Start time in ISO 8601: YYYY-MM-DDTHH:MM:SS",
    True,
  )
  |> tool.add_integer_param(
    "duration_minutes",
    "Duration in minutes (default: 60)",
    False,
  )
  |> tool.add_string_param("for_", "\"agent\" or \"user\"", True)
  |> tool.add_string_param("tags", "Comma-separated tags", False)
  |> tool.build()
}

fn complete_item_tool() -> Tool {
  tool.new("complete_item")
  |> tool.with_description(
    "Mark a one-shot scheduled item (Reminder, Todo, Appointment) as "
    <> "completed. Refuses to act on recurring tasks that still have "
    <> "fires remaining — calling complete_item on a recurring task "
    <> "would silently kill its schedule. To terminate a recurring "
    <> "task intentionally, use cancel_item instead.",
  )
  |> tool.add_string_param("name", "Item ID to complete", True)
  |> tool.build()
}

fn cancel_item_tool() -> Tool {
  tool.new("cancel_item")
  |> tool.with_description("Cancel a scheduled item.")
  |> tool.add_string_param("name", "Item ID to cancel", True)
  |> tool.build()
}

fn list_schedule_tool() -> Tool {
  tool.new("list_schedule")
  |> tool.with_description(
    "List scheduled items with optional filters. "
    <> "Returns a formatted list grouped by kind.",
  )
  |> tool.add_string_param(
    "filter",
    "\"all\" | \"pending\" | \"overdue\" | \"completed\" | \"cancelled\"",
    True,
  )
  |> tool.add_string_param(
    "kind",
    "\"all\" | \"reminder\" | \"todo\" | \"appointment\" | \"recurring\" (default \"all\")",
    False,
  )
  |> tool.add_string_param(
    "for_",
    "\"all\" | \"agent\" | \"user\" (default \"all\")",
    False,
  )
  |> tool.add_integer_param(
    "max_results",
    "Maximum items to return (default 20)",
    False,
  )
  |> tool.build()
}

fn update_item_tool() -> Tool {
  tool.new("update_item")
  |> tool.with_description(
    "Update an existing scheduled item's title, body, or due_at.",
  )
  |> tool.add_string_param("name", "Item ID to update", True)
  |> tool.add_string_param("title", "New title (optional)", False)
  |> tool.add_string_param("body", "New body text (optional)", False)
  |> tool.add_string_param("due_at", "New due_at in ISO 8601 (optional)", False)
  |> tool.build()
}

fn inspect_job_tool() -> Tool {
  tool.new("inspect_job")
  |> tool.with_description(
    "Inspect a specific scheduled job. Returns full details including "
    <> "status, recurrence info, fire count, and next fire time.",
  )
  |> tool.add_string_param("name", "Job ID to inspect", True)
  |> tool.build()
}

fn purge_cancelled_tool() -> Tool {
  tool.new("purge_cancelled")
  |> tool.with_description(
    "Remove all cancelled and completed one-shot jobs from the schedule. "
    <> "Cleans up stale items that clutter list_schedule. "
    <> "Returns the number of items purged.",
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Tool execution
// ---------------------------------------------------------------------------

fn execute_scheduler_tool(
  call: ToolCall,
  runner: Subject(sched_types.SchedulerMessage),
) -> ToolResult {
  case call.name {
    "schedule_from_spec" -> handle_schedule_from_spec(call, runner)
    "schedule_reminder" -> handle_schedule_reminder(call, runner)
    "add_todo" -> handle_add_todo(call, runner)
    "add_appointment" -> handle_add_appointment(call, runner)
    "complete_item" -> handle_complete_item(call, runner)
    "cancel_item" -> handle_cancel_item(call, runner)
    "list_schedule" -> handle_list_schedule(call, runner)
    "update_item" -> handle_update_item(call, runner)
    "inspect_job" -> handle_inspect_job(call, runner)
    "purge_cancelled" -> handle_purge_cancelled(call, runner)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

fn handle_schedule_reminder(
  call: ToolCall,
  runner: Subject(sched_types.SchedulerMessage),
) -> ToolResult {
  let title = get_str(call, "title", "Reminder")
  let body = get_str(call, "body", "")
  let due_at = get_str(call, "due_at", "")
  let for_str = get_str(call, "for_", "user")
  let for_ = parse_for_target(for_str)
  let interval_ms = get_int(call, "interval_ms", 0)
  let max_occurrences_val = get_int(call, "max_occurrences", 0)
  let tags = parse_tags(get_str(call, "tags", ""))
  let name = generate_name("remind", title)

  let max_occ = case max_occurrences_val {
    0 -> None
    n -> Some(n)
  }

  let job =
    make_job(
      name,
      body,
      interval_ms,
      sched_types.Reminder,
      Some(due_at),
      for_,
      title,
      body,
      0,
      tags,
      max_occ,
    )

  let reply_subj = process.new_subject()
  process.send(runner, sched_types.AddJob(job:, reply_to: reply_subj))
  case process.receive(reply_subj, 5000) {
    Ok(Ok(id)) ->
      ToolSuccess(
        tool_use_id: call.id,
        content: "Reminder '"
          <> title
          <> "' scheduled."
          <> "\n  ID: "
          <> id
          <> "\n  Due: "
          <> due_at
          <> "\n  Interval: "
          <> case interval_ms {
          0 -> "one-shot"
          ms -> format_duration_ms(ms)
        }
          <> "\n  Max fires: "
          <> case max_occurrences_val {
          0 -> "unlimited"
          n -> int.to_string(n)
        }
          <> "\n  For: "
          <> for_str,
      )
    Ok(Error(reason)) -> ToolFailure(tool_use_id: call.id, error: reason)
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Timeout waiting for scheduler")
  }
}

fn handle_schedule_from_spec(
  call: ToolCall,
  runner: Subject(sched_types.SchedulerMessage),
) -> ToolResult {
  let kind_str = get_str(call, "kind", "reminder")
  let title = get_str(call, "title", "")
  let body = get_str(call, "body", "")
  let due_at = get_str(call, "due_at", "")
  let for_str = get_str(call, "for_", "agent")
  let for_ = parse_for_target(for_str)
  let interval_ms = get_int(call, "interval_ms", 0)
  let max_occurrences_val = get_int(call, "max_occurrences", 0)
  let tags = parse_tags(get_str(call, "tags", ""))
  let duration_minutes = get_int(call, "duration_minutes", 0)

  let kind = case kind_str {
    "todo" -> sched_types.Todo
    "appointment" -> sched_types.Appointment
    "recurring" -> sched_types.RecurringTask
    _ -> sched_types.Reminder
  }

  let prefix = case kind {
    sched_types.Todo -> "todo"
    sched_types.Appointment -> "appt"
    sched_types.RecurringTask -> "task"
    _ -> "remind"
  }
  let name = generate_name(prefix, title)

  let max_occ = case max_occurrences_val {
    0 -> None
    n -> Some(n)
  }

  let job =
    make_job(
      name,
      body,
      interval_ms,
      kind,
      Some(due_at),
      for_,
      title,
      body,
      duration_minutes,
      tags,
      max_occ,
    )

  let reply_subj = process.new_subject()
  process.send(runner, sched_types.AddJob(job:, reply_to: reply_subj))
  case process.receive(reply_subj, 5000) {
    Ok(Ok(id)) -> {
      // Build structured confirmation
      let interval_str = case interval_ms {
        0 -> "one-shot"
        ms -> format_duration_ms(ms)
      }
      let max_str = case max_occurrences_val {
        0 -> "unlimited"
        n -> int.to_string(n)
      }
      // Calculate next fire times for recurring jobs
      let fires_preview = case interval_ms > 0 && max_occurrences_val > 0 {
        True -> {
          let fire_times =
            build_fire_times(due_at, interval_ms, max_occurrences_val)
          "\n  Next fires: " <> string.join(fire_times, ", ")
        }
        False -> ""
      }
      ToolSuccess(
        tool_use_id: call.id,
        content: "Job created from spec."
          <> "\n  ID: "
          <> id
          <> "\n  Kind: "
          <> kind_str
          <> "\n  Title: "
          <> title
          <> "\n  Due: "
          <> due_at
          <> "\n  Interval: "
          <> interval_str
          <> "\n  Max fires: "
          <> max_str
          <> "\n  For: "
          <> for_str
          <> "\n  Tags: "
          <> string.join(tags, ", ")
          <> fires_preview,
      )
    }
    Ok(Error(reason)) -> ToolFailure(tool_use_id: call.id, error: reason)
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Timeout waiting for scheduler")
  }
}

fn handle_add_todo(
  call: ToolCall,
  runner: Subject(sched_types.SchedulerMessage),
) -> ToolResult {
  let title = get_str(call, "title", "Todo")
  let body = get_str(call, "body", "")
  let due_at_str = get_str(call, "due_at", "")
  let for_ = parse_for_target(get_str(call, "for_", "user"))
  let tags = parse_tags(get_str(call, "tags", ""))
  let name = generate_name("todo", title)
  let due_at = case due_at_str {
    "" -> None
    d -> Some(d)
  }

  let job =
    make_job(
      name,
      body,
      0,
      sched_types.Todo,
      due_at,
      for_,
      title,
      body,
      0,
      tags,
      None,
    )

  let reply_subj = process.new_subject()
  process.send(runner, sched_types.AddJob(job:, reply_to: reply_subj))
  case process.receive(reply_subj, 5000) {
    Ok(Ok(id)) ->
      ToolSuccess(
        tool_use_id: call.id,
        content: "Todo '" <> title <> "' added. ID: " <> id,
      )
    Ok(Error(reason)) -> ToolFailure(tool_use_id: call.id, error: reason)
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Timeout waiting for scheduler")
  }
}

fn handle_add_appointment(
  call: ToolCall,
  runner: Subject(sched_types.SchedulerMessage),
) -> ToolResult {
  let title = get_str(call, "title", "Appointment")
  let body = get_str(call, "body", "")
  let at = get_str(call, "at", "")
  let duration_minutes = get_int(call, "duration_minutes", 60)
  let for_ = parse_for_target(get_str(call, "for_", "user"))
  let tags = parse_tags(get_str(call, "tags", ""))
  let name = generate_name("appt", title)

  let job =
    make_job(
      name,
      body,
      0,
      sched_types.Appointment,
      Some(at),
      for_,
      title,
      body,
      duration_minutes,
      tags,
      None,
    )

  let reply_subj = process.new_subject()
  process.send(runner, sched_types.AddJob(job:, reply_to: reply_subj))
  case process.receive(reply_subj, 5000) {
    Ok(Ok(id)) ->
      ToolSuccess(
        tool_use_id: call.id,
        content: "Appointment '"
          <> title
          <> "' at "
          <> at
          <> " for "
          <> int.to_string(duration_minutes)
          <> " min. ID: "
          <> id,
      )
    Ok(Error(reason)) -> ToolFailure(tool_use_id: call.id, error: reason)
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Timeout waiting for scheduler")
  }
}

fn handle_complete_item(
  call: ToolCall,
  runner: Subject(sched_types.SchedulerMessage),
) -> ToolResult {
  let name = get_str(call, "name", "")
  let reply_subj = process.new_subject()
  process.send(runner, sched_types.CompleteJob(name:, reply_to: reply_subj))
  case process.receive(reply_subj, 5000) {
    Ok(Ok(_)) ->
      ToolSuccess(
        tool_use_id: call.id,
        content: "Item '" <> name <> "' marked completed.",
      )
    Ok(Error(reason)) -> ToolFailure(tool_use_id: call.id, error: reason)
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Timeout waiting for scheduler")
  }
}

fn handle_cancel_item(
  call: ToolCall,
  runner: Subject(sched_types.SchedulerMessage),
) -> ToolResult {
  let name = get_str(call, "name", "")
  let reply_subj = process.new_subject()
  process.send(runner, sched_types.RemoveJob(name:, reply_to: reply_subj))
  case process.receive(reply_subj, 5000) {
    Ok(Ok(_)) ->
      ToolSuccess(
        tool_use_id: call.id,
        content: "Item '" <> name <> "' cancelled.",
      )
    Ok(Error(reason)) -> ToolFailure(tool_use_id: call.id, error: reason)
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Timeout waiting for scheduler")
  }
}

fn handle_list_schedule(
  call: ToolCall,
  runner: Subject(sched_types.SchedulerMessage),
) -> ToolResult {
  let filter = get_str(call, "filter", "all")
  let kind_str = get_str(call, "kind", "all")
  let for_str = get_str(call, "for_", "all")
  let max_results = get_int(call, "max_results", 20)

  let kinds = case kind_str {
    "reminder" -> [sched_types.Reminder]
    "todo" -> [sched_types.Todo]
    "appointment" -> [sched_types.Appointment]
    "recurring" -> [sched_types.RecurringTask]
    _ -> []
  }
  let statuses = case filter {
    "pending" -> [sched_types.Pending]
    "completed" -> [sched_types.Completed]
    "cancelled" -> [sched_types.Cancelled]
    _ -> []
  }
  let for_ = case for_str {
    "agent" -> Some(sched_types.ForAgent)
    "user" -> Some(sched_types.ForUser)
    _ -> None
  }
  let overdue_only = filter == "overdue"

  let query =
    sched_types.JobQuery(kinds:, statuses:, for_:, overdue_only:, max_results:)
  let reply_subj = process.new_subject()
  process.send(runner, sched_types.GetJobs(query:, reply_to: reply_subj))
  case process.receive(reply_subj, 5000) {
    Ok(jobs) ->
      ToolSuccess(tool_use_id: call.id, content: format_schedule_list(jobs))
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Timeout waiting for scheduler")
  }
}

fn handle_inspect_job(
  call: ToolCall,
  runner: Subject(sched_types.SchedulerMessage),
) -> ToolResult {
  let name = get_str(call, "name", "")
  let reply_subj = process.new_subject()
  process.send(runner, sched_types.GetStatus(reply_to: reply_subj))
  case process.receive(reply_subj, 5000) {
    Ok(jobs) -> {
      case list.find(jobs, fn(j) { j.name == name }) {
        Ok(job) ->
          ToolSuccess(tool_use_id: call.id, content: format_job_detail(job))
        Error(_) ->
          ToolFailure(tool_use_id: call.id, error: "Job not found: " <> name)
      }
    }
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Timeout waiting for scheduler")
  }
}

fn format_job_detail(job: sched_types.ScheduledJob) -> String {
  let kind_str = sched_types.encode_job_kind(job.kind)
  let status_str = sched_types.encode_job_status(job.status)
  let for_str = sched_types.encode_for_target(job.for_)
  let due_str = case job.due_at {
    Some(due) -> {
      let ms = ms_until_datetime(due)
      due
      <> case ms < 0 {
        True -> " (OVERDUE)"
        False -> " (in " <> format_duration_ms(ms) <> ")"
      }
    }
    None -> "none"
  }
  let interval_str = case job.interval_ms > 0 {
    True -> format_duration_ms(job.interval_ms)
    False -> "one-shot"
  }
  let fires_str = case job.max_occurrences {
    Some(max) -> int.to_string(job.fired_count) <> "/" <> int.to_string(max)
    None -> int.to_string(job.fired_count) <> " (unlimited)"
  }
  let end_str = case job.recurrence_end_at {
    Some(end_at) -> end_at
    None -> "none"
  }
  let tags_str = case job.tags {
    [] -> "none"
    ts -> string.join(ts, ", ")
  }
  let last_result_str = case job.last_result {
    Some(r) -> string.slice(r, 0, 200)
    None -> "none"
  }

  "Job: "
  <> job.name
  <> "\n  Title: "
  <> job.title
  <> "\n  Kind: "
  <> kind_str
  <> "\n  Status: "
  <> status_str
  <> "\n  For: "
  <> for_str
  <> "\n  Due: "
  <> due_str
  <> "\n  Interval: "
  <> interval_str
  <> "\n  Fired: "
  <> fires_str
  <> "\n  Run count: "
  <> int.to_string(job.run_count)
  <> "\n  Error count: "
  <> int.to_string(job.error_count)
  <> "\n  Recurrence end: "
  <> end_str
  <> "\n  Tags: "
  <> tags_str
  <> "\n  Created: "
  <> job.created_at
  <> "\n  Last result: "
  <> last_result_str
}

fn handle_update_item(
  call: ToolCall,
  runner: Subject(sched_types.SchedulerMessage),
) -> ToolResult {
  let name = get_str(call, "name", "")
  let title_str = get_str(call, "title", "")
  let body_str = get_str(call, "body", "")
  let due_at_str = get_str(call, "due_at", "")

  let updates =
    sched_types.JobUpdate(
      title: case title_str {
        "" -> None
        t -> Some(t)
      },
      body: case body_str {
        "" -> None
        b -> Some(b)
      },
      due_at: case due_at_str {
        "" -> None
        d -> Some(d)
      },
      tags: None,
    )

  let reply_subj = process.new_subject()
  process.send(
    runner,
    sched_types.UpdateJob(name:, updates:, reply_to: reply_subj),
  )
  case process.receive(reply_subj, 5000) {
    Ok(Ok(_)) ->
      ToolSuccess(
        tool_use_id: call.id,
        content: "Item '" <> name <> "' updated.",
      )
    Ok(Error(reason)) -> ToolFailure(tool_use_id: call.id, error: reason)
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Timeout waiting for scheduler")
  }
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

fn format_schedule_list(jobs: List(sched_types.ScheduledJob)) -> String {
  case jobs {
    [] -> "No scheduled items found."
    _ -> {
      let reminders =
        list.filter(jobs, fn(j) { j.kind == sched_types.Reminder })
      let appointments =
        list.filter(jobs, fn(j) { j.kind == sched_types.Appointment })
      let recurring =
        list.filter(jobs, fn(j) { j.kind == sched_types.RecurringTask })
      let todos = list.filter(jobs, fn(j) { j.kind == sched_types.Todo })

      let sections = []
      let sections = case reminders {
        [] -> sections
        rs ->
          list.append(sections, [
            "## Reminders ("
            <> int.to_string(list.length(rs))
            <> ")\n\n"
            <> format_items(rs),
          ])
      }
      let sections = case appointments {
        [] -> sections
        appts ->
          list.append(sections, [
            "## Appointments ("
            <> int.to_string(list.length(appts))
            <> ")\n\n"
            <> format_items(appts),
          ])
      }
      let sections = case recurring {
        [] -> sections
        recs ->
          list.append(sections, [
            "## Recurring tasks ("
            <> int.to_string(list.length(recs))
            <> ")\n\n"
            <> format_items(recs),
          ])
      }
      let sections = case todos {
        [] -> sections
        tds ->
          list.append(sections, [
            "## Todos ("
            <> int.to_string(list.length(tds))
            <> ")\n\n"
            <> format_items(tds),
          ])
      }
      string.join(sections, "\n\n")
    }
  }
}

fn format_items(jobs: List(sched_types.ScheduledJob)) -> String {
  jobs
  |> list.map(fn(j) {
    let for_label = case j.for_ {
      sched_types.ForAgent -> "[agent]"
      sched_types.ForUser -> "[user]"
    }
    let time_info = case j.due_at {
      Some(due) -> {
        let ms = ms_until_datetime(due)
        let suffix = case ms < 0 {
          True -> " (OVERDUE)"
          False -> " (in " <> format_duration_ms(ms) <> ")"
        }
        " — due " <> due <> suffix
      }
      None -> ""
    }
    let status_label = case j.status {
      sched_types.Completed -> " [DONE]"
      sched_types.Cancelled -> " [CANCELLED]"
      sched_types.Failed(r) -> " [FAILED: " <> r <> "]"
      _ -> ""
    }
    let recurrence_info = case j.interval_ms > 0 {
      True -> {
        let interval_str =
          " — repeats every " <> format_duration_ms(j.interval_ms)
        let fires_str = case j.max_occurrences {
          Some(max) ->
            " ("
            <> int.to_string(j.fired_count)
            <> "/"
            <> int.to_string(max)
            <> " fires)"
          None -> " (" <> int.to_string(j.fired_count) <> " fires)"
        }
        interval_str <> fires_str
      }
      False -> ""
    }
    "- ["
    <> j.name
    <> "] \""
    <> j.title
    <> "\""
    <> time_info
    <> " "
    <> for_label
    <> recurrence_info
    <> status_label
  })
  |> string.join("\n")
}

fn format_duration_ms(ms: Int) -> String {
  let total_minutes = ms / 60_000
  let hours = total_minutes / 60
  let minutes = total_minutes % 60
  case hours {
    0 -> int.to_string(minutes) <> "m"
    _ -> int.to_string(hours) <> "h " <> int.to_string(minutes) <> "m"
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_job(
  name: String,
  query: String,
  interval_ms: Int,
  kind: sched_types.JobKind,
  due_at: Option(String),
  for_: sched_types.ForTarget,
  title: String,
  body: String,
  duration_minutes: Int,
  tags: List(String),
  max_occurrences: Option(Int),
) -> sched_types.ScheduledJob {
  sched_types.ScheduledJob(
    name:,
    query:,
    interval_ms:,
    delivery: sched_types.FileDelivery(
      directory: paths.scheduler_outputs_dir(),
      format: "markdown",
    ),
    only_if_changed: False,
    status: sched_types.Pending,
    last_run_ms: None,
    last_result: None,
    run_count: 0,
    error_count: 0,
    job_source: sched_types.AgentJob,
    kind:,
    due_at:,
    for_:,
    title:,
    body:,
    duration_minutes:,
    tags:,
    created_at: get_datetime(),
    fired_count: 0,
    recurrence_end_at: None,
    max_occurrences:,
    // Agent-created jobs don't declare required tools at construction
    // time — the scheduling prompt is free-form. Operators can set
    // required_tools via schedule.toml for jobs defined there.
    required_tools: [],
  )
}

fn get_str(call: ToolCall, key: String, default: String) -> String {
  case json.parse(call.input_json, string_field_decoder(key)) {
    Ok(v) -> v
    Error(_) -> default
  }
}

fn string_field_decoder(key: String) -> decode.Decoder(String) {
  use value <- decode.optional_field(key, "", decode.string)
  decode.success(value)
}

fn get_int(call: ToolCall, key: String, default: Int) -> Int {
  case json.parse(call.input_json, int_field_decoder(key, default)) {
    Ok(v) -> v
    Error(_) -> default
  }
}

fn int_field_decoder(key: String, default: Int) -> decode.Decoder(Int) {
  use value <- decode.optional_field(key, default, decode.int)
  decode.success(value)
}

fn parse_for_target(s: String) -> sched_types.ForTarget {
  case s {
    "user" -> sched_types.ForUser
    _ -> sched_types.ForAgent
  }
}

fn parse_tags(s: String) -> List(String) {
  case s {
    "" -> []
    _ ->
      s
      |> string.split(",")
      |> list.map(string.trim)
      |> list.filter(fn(t) { t != "" })
  }
}

fn generate_name(prefix: String, title: String) -> String {
  let slug =
    title
    |> string.lowercase
    |> string.replace(" ", "-")
    |> string.slice(0, 30)
  let uuid_suffix = string.slice(generate_uuid(), 0, 6)
  prefix <> "-" <> slug <> "-" <> uuid_suffix
}

/// Build a preview of upcoming fire times for a recurring job.
fn build_fire_times(
  due_at: String,
  interval_ms: Int,
  max_occurrences: Int,
) -> List(String) {
  let count = int.min(max_occurrences, 8)
  build_fire_times_loop(due_at, interval_ms, count, [])
}

fn build_fire_times_loop(
  current: String,
  interval_ms: Int,
  remaining: Int,
  acc: List(String),
) -> List(String) {
  case remaining <= 0 {
    True -> list.reverse(acc)
    False -> {
      let next = advance_datetime_ms(current, interval_ms)
      build_fire_times_loop(next, interval_ms, remaining - 1, [current, ..acc])
    }
  }
}

fn handle_purge_cancelled(
  call: ToolCall,
  runner: Subject(sched_types.SchedulerMessage),
) -> ToolResult {
  let reply_to = process.new_subject()
  process.send(runner, sched_types.PurgeCancelled(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(count) ->
      ToolSuccess(
        tool_use_id: call.id,
        content: "Purged "
          <> int.to_string(count)
          <> " cancelled/completed job"
          <> case count {
          1 -> ""
          _ -> "s"
        }
          <> " from the schedule.",
      )
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Timeout waiting for purge")
  }
}
