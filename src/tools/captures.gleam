//// Captures tools — MVP commitment tracker surface on the cognitive loop.
////
//// Three tools:
////   list_captures(status?)            — read pending (or filter)
////   clarify_capture(id, due, descr.)  — schedule a cycle for it (calendar route)
////   dismiss_capture(id, reason)       — drop with a reason
////
//// list_captures and dismiss_capture are local reads/writes — tool-gate
//// exempt. clarify_capture delegates to the scheduler, which carries its
//// own D' gate on the resulting scheduled cycle.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import captures/log as captures_log
import captures/types as captures_types
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
import paths
import scheduler/types as sched_types
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

// ---------------------------------------------------------------------------
// Context — captured in the tool executor closure
// ---------------------------------------------------------------------------

pub type CapturesContext {
  CapturesContext(
    captures_dir: String,
    librarian: Subject(LibrarianMessage),
    scheduler: Option(Subject(sched_types.SchedulerMessage)),
  )
}

// ---------------------------------------------------------------------------
// Tool registration
// ---------------------------------------------------------------------------

pub fn all() -> List(llm_types.Tool) {
  [list_captures_tool(), clarify_capture_tool(), dismiss_capture_tool()]
}

pub fn is_captures_tool(name: String) -> Bool {
  case name {
    "list_captures" | "clarify_capture" | "dismiss_capture" -> True
    _ -> False
  }
}

/// Captures tools are tool-gate exempt except for clarify_capture, which
/// delegates to the scheduler (itself D'-gated). list and dismiss are
/// local-only log writes.
pub fn is_dprime_exempt(name: String) -> Bool {
  case name {
    "list_captures" | "dismiss_capture" -> True
    _ -> False
  }
}

fn list_captures_tool() -> llm_types.Tool {
  tool.new("list_captures")
  |> tool.with_description(
    "List captures — auto-detected commitments or operator asks from past cycles. "
    <> "Defaults to pending only; pass status=all to see every capture including "
    <> "dismissed, clarified, and expired. Captures are short statements pulled "
    <> "from cycle prose by the post-cycle scanner.",
  )
  |> tool.add_enum_param(
    "status",
    "Filter by status (default: pending)",
    ["pending", "all"],
    False,
  )
  |> tool.build()
}

fn clarify_capture_tool() -> llm_types.Tool {
  tool.new("clarify_capture")
  |> tool.with_description(
    "Schedule a future cycle for a pending capture. The scheduler fires a "
    <> "cycle at due_at with the description as its input — the agent will "
    <> "see it as a new task to work on. Use this when a capture has a clear "
    <> "time and concrete action. The capture is marked clarified.",
  )
  |> tool.add_string_param("id", "The capture id (e.g. cap-ab12cd34)", True)
  |> tool.add_string_param(
    "due_at",
    "ISO-8601 timestamp when the cycle should fire (e.g. 2026-04-23T09:00:00Z)",
    True,
  )
  |> tool.add_string_param(
    "description",
    "The text the scheduled cycle will receive as input. Rephrase as a concrete action.",
    True,
  )
  |> tool.build()
}

fn dismiss_capture_tool() -> llm_types.Tool {
  tool.new("dismiss_capture")
  |> tool.with_description(
    "Dismiss a pending capture. Use this when the commitment is already done, "
    <> "no longer relevant, or was detected in error. Always include a short "
    <> "reason — it goes into the audit log.",
  )
  |> tool.add_string_param("id", "The capture id (e.g. cap-ab12cd34)", True)
  |> tool.add_string_param(
    "reason",
    "Short reason for dismissal (done, irrelevant, false_detection, etc.)",
    True,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

pub fn execute(
  call: llm_types.ToolCall,
  ctx: CapturesContext,
) -> llm_types.ToolResult {
  case call.name {
    "list_captures" -> run_list_captures(call, ctx)
    "clarify_capture" -> run_clarify_capture(call, ctx)
    "dismiss_capture" -> run_dismiss_capture(call, ctx)
    _ ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Unknown captures tool: " <> call.name,
      )
  }
}

// ---------------------------------------------------------------------------
// list_captures
// ---------------------------------------------------------------------------

fn run_list_captures(
  call: llm_types.ToolCall,
  ctx: CapturesContext,
) -> llm_types.ToolResult {
  let status = case json.parse(call.input_json, status_decoder()) {
    Ok(s) -> s
    Error(_) -> "pending"
  }
  let captures = case status {
    "all" -> captures_log.resolve_current(ctx.captures_dir)
    _ -> librarian.get_pending_captures(ctx.librarian)
  }
  let content = render_captures(captures, status)
  llm_types.ToolSuccess(tool_use_id: call.id, content: content)
}

fn status_decoder() -> decode.Decoder(String) {
  use s <- decode.optional_field("status", "pending", decode.string)
  decode.success(s)
}

fn render_captures(
  captures: List(captures_types.Capture),
  status: String,
) -> String {
  case captures {
    [] ->
      case status {
        "all" -> "No captures on record."
        _ -> "No pending captures."
      }
    _ -> {
      let header = case status {
        "all" ->
          "All captures ("
          <> int.to_string(list.length(captures))
          <> " total):\n"
        _ ->
          "Pending captures (" <> int.to_string(list.length(captures)) <> "):\n"
      }
      let lines =
        captures
        |> list.map(render_capture_line)
        |> string.join("\n")
      header <> lines
    }
  }
}

fn render_capture_line(c: captures_types.Capture) -> String {
  let due_part = case c.due_hint {
    Some(h) -> " [due hint: " <> h <> "]"
    None -> ""
  }
  let status_part = case c.status {
    captures_types.Pending -> ""
    captures_types.ClarifiedToCalendar(job_id) ->
      " [clarified → " <> job_id <> "]"
    captures_types.Dismissed(reason) -> " [dismissed: " <> reason <> "]"
    captures_types.Expired -> " [expired]"
  }
  "  " <> c.id <> ": " <> c.text <> due_part <> status_part
}

// ---------------------------------------------------------------------------
// clarify_capture — delegate to scheduler
// ---------------------------------------------------------------------------

fn run_clarify_capture(
  call: llm_types.ToolCall,
  ctx: CapturesContext,
) -> llm_types.ToolResult {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use due_at <- decode.field("due_at", decode.string)
    use description <- decode.field("description", decode.string)
    decode.success(#(id, due_at, description))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: expected {id, due_at, description}",
      )
    Ok(#(id, due_at, description)) -> {
      let id = string.trim(id)
      let due_at = string.trim(due_at)
      let description = string.trim(description)
      case id, due_at, description {
        "", _, _ ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "id must not be empty",
          )
        _, "", _ ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "due_at must not be empty",
          )
        _, _, "" ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "description must not be empty",
          )
        _, _, _ -> clarify_to_calendar(call, ctx, id, due_at, description)
      }
    }
  }
}

fn clarify_to_calendar(
  call: llm_types.ToolCall,
  ctx: CapturesContext,
  id: String,
  due_at: String,
  description: String,
) -> llm_types.ToolResult {
  // Validate the capture exists and is pending.
  let pending = librarian.get_pending_captures(ctx.librarian)
  case captures_log.find_by_id(pending, id) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Capture " <> id <> " not found in pending list",
      )
    Ok(capture) -> {
      case capture.status {
        captures_types.Pending ->
          case ctx.scheduler {
            None ->
              llm_types.ToolFailure(
                tool_use_id: call.id,
                error: "Scheduler unavailable; cannot clarify to calendar",
              )
            Some(sched) ->
              schedule_cycle(call, ctx, id, due_at, description, sched)
          }
        _ ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Capture " <> id <> " is not pending",
          )
      }
    }
  }
}

fn schedule_cycle(
  call: llm_types.ToolCall,
  ctx: CapturesContext,
  id: String,
  due_at: String,
  description: String,
  scheduler: Subject(sched_types.SchedulerMessage),
) -> llm_types.ToolResult {
  let job =
    sched_types.ScheduledJob(
      name: "capture-" <> id,
      query: description,
      interval_ms: 0,
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
      kind: sched_types.Reminder,
      due_at: Some(due_at),
      for_: sched_types.ForAgent,
      title: "Clarified capture " <> id,
      body: description,
      duration_minutes: 0,
      tags: ["capture"],
      created_at: get_datetime(),
      fired_count: 0,
      recurrence_end_at: None,
      max_occurrences: Some(1),
      required_tools: [],
    )
  let reply = process.new_subject()
  process.send(scheduler, sched_types.AddJob(job:, reply_to: reply))
  case process.receive(reply, 5000) {
    Ok(Ok(job_id)) -> {
      captures_log.append(
        ctx.captures_dir,
        captures_types.ClarifyToCalendar(id, job_id, description),
      )
      librarian.notify_remove_capture(ctx.librarian, id)
      slog.info(
        "tools/captures",
        "clarify_capture",
        "Capture "
          <> id
          <> " clarified → scheduler job "
          <> job_id
          <> " due "
          <> due_at,
        None,
      )
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Capture "
          <> id
          <> " clarified. Scheduler job "
          <> job_id
          <> " created for "
          <> due_at
          <> ".",
      )
    }
    Ok(Error(reason)) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Scheduler rejected job: " <> reason,
      )
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Timeout waiting for scheduler",
      )
  }
}

// ---------------------------------------------------------------------------
// dismiss_capture
// ---------------------------------------------------------------------------

fn run_dismiss_capture(
  call: llm_types.ToolCall,
  ctx: CapturesContext,
) -> llm_types.ToolResult {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(#(id, reason))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input: expected {id, reason}",
      )
    Ok(#(id, reason)) -> {
      let id = string.trim(id)
      let reason = string.trim(reason)
      case id, reason {
        "", _ ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "id must not be empty",
          )
        _, "" ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "reason must not be empty",
          )
        _, _ -> dismiss(call, ctx, id, reason)
      }
    }
  }
}

fn dismiss(
  call: llm_types.ToolCall,
  ctx: CapturesContext,
  id: String,
  reason: String,
) -> llm_types.ToolResult {
  let pending = librarian.get_pending_captures(ctx.librarian)
  case captures_log.find_by_id(pending, id) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Capture " <> id <> " not found in pending list",
      )
    Ok(c) ->
      case c.status {
        captures_types.Pending -> {
          captures_log.append(
            ctx.captures_dir,
            captures_types.Dismiss(id, reason),
          )
          librarian.notify_remove_capture(ctx.librarian, id)
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Capture " <> id <> " dismissed: " <> reason,
          )
        }
        _ ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Capture " <> id <> " is not pending",
          )
      }
  }
}

/// Helper exported for the expiry sweep — mark a capture `status_kind` in
/// current state. Currently unused by tools but useful for internal callers
/// that want to surface the status string.
pub fn status_kind(s: captures_types.CaptureStatus) -> String {
  case s {
    captures_types.Pending -> "pending"
    captures_types.ClarifiedToCalendar(_) -> "clarified_to_calendar"
    captures_types.Dismissed(_) -> "dismissed"
    captures_types.Expired -> "expired"
  }
}
