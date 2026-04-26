//// Cog-loop tools for dispatching coding tasks to the OpenCode-backed
//// real coder (R5 of the rebuild).
////
//// Three tools land here:
////
////   dispatch_coder         — send one coding task, block for result
////   cancel_coder_session   — three-stage kill chain on a running session
////   list_coder_sessions    — read-only list of active dispatches
////
//// resume_coder_session is intentionally deferred to R7 — it depends
//// on ACP's session/load support which isn't wired in `coder/acp.gleam`
//// yet.
////
//// These tools live on the cognitive loop (and PM via the existing
//// team-member tool sharing). The cog loop / PM does CBR retrieval as
//// a separate step, formats the brief, then dispatches. We don't fold
//// CBR retrieval into the tool itself — keeps each tool single-purpose
//// and matches "no scaffolding for unattended LLMs".

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import coder/manager.{type CoderManager}
import coder/types as coder_types
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
import slog

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(llm_types.Tool) {
  [
    dispatch_coder_tool(),
    cancel_coder_session_tool(),
    list_coder_sessions_tool(),
  ]
}

fn dispatch_coder_tool() -> llm_types.Tool {
  tool.new("dispatch_coder")
  |> tool.with_description(
    "Dispatch a coding task to the sandboxed OpenCode agent. The agent "
    <> "operates in a podman container with the project bind-mounted; it "
    <> "reads, edits, runs tests, and commits autonomously, then returns "
    <> "a summary. Springdrift records the outcome as a CBR case.\n\n"
    <> "Use the optional max_* params to ask for a larger budget than the "
    <> "default; the manager clamps each value against operator-set "
    <> "ceilings and reports the clamps in the response. If the model "
    <> "hits the budget mid-task, the session is cancelled cleanly and "
    <> "the result returns with stop_reason='cancelled'.",
  )
  |> tool.add_string_param(
    "brief",
    "The task description for the coder. Include relevant file hints, "
      <> "success criteria, and any constraints. The agent has its own "
      <> "tools (read, edit, bash, grep, gh, git) so don't tell it HOW — "
      <> "tell it WHAT.",
    True,
  )
  |> tool.add_integer_param(
    "max_tokens",
    "Optional per-task token budget. Defaults to coder.budget."
      <> "default_max_tokens_per_task. Clamped to "
      <> "ceiling_max_tokens_per_task.",
    False,
  )
  |> tool.add_number_param(
    "max_cost_usd",
    "Optional per-task USD budget. Defaults to coder.budget."
      <> "default_max_cost_per_task_usd. Clamped to "
      <> "ceiling_max_cost_per_task_usd.",
    False,
  )
  |> tool.add_integer_param(
    "max_minutes",
    "Optional wall-clock budget in minutes. Defaults to coder.budget."
      <> "default_max_minutes_per_task. Clamped to "
      <> "ceiling_max_minutes_per_task.",
    False,
  )
  |> tool.add_integer_param(
    "max_turns",
    "Optional turn budget. Defaults to coder.budget."
      <> "default_max_turns_per_task. Clamped to "
      <> "ceiling_max_turns_per_task.",
    False,
  )
  |> tool.build()
}

fn cancel_coder_session_tool() -> llm_types.Tool {
  tool.new("cancel_coder_session")
  |> tool.with_description(
    "Cancel a running coder session by id. Runs the three-stage kill "
    <> "chain: ACP session/cancel (graceful) → ACP handle close (kills "
    <> "the subprocess) → manager teardown. The dispatching call returns "
    <> "with stop_reason='cancelled'. Use when a session is going off "
    <> "track or has been running too long.",
  )
  |> tool.add_string_param(
    "session_id",
    "The session_id returned by dispatch_coder, or seen in list_coder_sessions.",
    True,
  )
  |> tool.build()
}

fn list_coder_sessions_tool() -> llm_types.Tool {
  tool.new("list_coder_sessions")
  |> tool.with_description(
    "List sessions the coder manager is currently driving. Returns id, "
    <> "container, start time, accumulated cost and tokens. Read-only.",
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Defaults — used when the agent doesn't supply per-task overrides
// ---------------------------------------------------------------------------

pub type DispatchDefaults {
  DispatchDefaults(
    default_max_tokens: Int,
    default_max_cost_usd: Float,
    default_max_minutes: Int,
    default_max_turns: Int,
    ceiling_max_tokens: Int,
    ceiling_max_cost_usd: Float,
    ceiling_max_minutes: Int,
    ceiling_max_turns: Int,
  )
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

/// Synchronous entry for cancel + list (fast manager calls).
/// `dispatch_coder` is async — see `spawn_dispatch_worker` — and never
/// reaches this function.
pub fn execute(
  call: llm_types.ToolCall,
  manager: Option(CoderManager),
  cycle_id: Option(String),
) -> llm_types.ToolResult {
  slog.debug("coder/dispatch", "execute", "tool=" <> call.name, cycle_id)
  case manager {
    None ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Coder dispatch unavailable: real-coder mode not configured. "
          <> "Set [coder] image, project_root, model_id and ANTHROPIC_API_KEY.",
      )
    Some(mgr) ->
      case call.name {
        "cancel_coder_session" -> run_cancel(call, mgr)
        "list_coder_sessions" -> run_list(call, mgr)
        "dispatch_coder" ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "internal: dispatch_coder must be routed through "
              <> "spawn_dispatch_worker, not execute/3",
          )
        _ ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Unknown coder dispatch tool: " <> call.name,
          )
      }
  }
}

/// Identify the sync subset (cancel + list) so the cog loop can
/// partition them from `dispatch_coder` (async).
pub fn is_sync_coder_dispatch_tool(name: String) -> Bool {
  case name {
    "cancel_coder_session" | "list_coder_sessions" -> True
    _ -> False
  }
}

/// True iff this tool name is `dispatch_coder` — the async one.
/// Kept as a named predicate so the partition site stays readable.
pub fn is_dispatch_coder_tool(name: String) -> Bool {
  name == "dispatch_coder"
}

// ---------------------------------------------------------------------------
// dispatch_coder — async path
// ---------------------------------------------------------------------------

pub type DispatchSpawn {
  /// Parsing succeeded. The caller spawned the worker before returning;
  /// it must register a PendingCoderDispatch keyed on `task_id`. The
  /// `clamps` describe any operator-ceiling enforcement applied to the
  /// agent's request; carry them through to the eventual reply.
  DispatchSpawned(
    task_id: String,
    tool_use_id: String,
    brief: String,
    clamps: List(coder_types.BudgetClamp),
  )
  /// Input parsing failed; caller should synthesise a tool_result error
  /// block instead of registering anything.
  DispatchInvalid(tool_use_id: String, reason: String)
}

/// Parse a `dispatch_coder` tool call, build its budget, and spawn an
/// unlinked worker that calls `manager.dispatch_task`. The worker
/// publishes its outcome to `cognitive` as `CoderDispatchComplete`.
///
/// Returns metadata the cog loop needs to register a
/// `PendingCoderDispatch` and remember the budget clamps until the
/// dispatch returns.
pub fn spawn_dispatch_worker(
  call: llm_types.ToolCall,
  manager: CoderManager,
  defaults: DispatchDefaults,
  cognitive: Subject(types_target),
  task_id: String,
  wrap: fn(
    String,
    Result(coder_types.DispatchResult, coder_types.CoderError),
    List(coder_types.BudgetClamp),
  ) ->
    types_target,
) -> DispatchSpawn {
  case parse_dispatch_input(call.input_json) {
    Error(msg) ->
      DispatchInvalid(
        tool_use_id: call.id,
        reason: "Invalid dispatch_coder input: " <> msg,
      )
    Ok(parsed) -> {
      let #(budget, clamps) = resolve_budget(parsed, defaults)
      let brief = parsed.brief
      let clamps_for_msg = clamps
      process.spawn_unlinked(fn() {
        let result = manager.dispatch_task(manager, brief, budget)
        process.send(cognitive, wrap(task_id, result, clamps_for_msg))
      })
      DispatchSpawned(
        task_id: task_id,
        tool_use_id: call.id,
        brief: brief,
        clamps: clamps,
      )
    }
  }
}

pub type ParsedDispatch {
  ParsedDispatch(
    brief: String,
    max_tokens: Option(Int),
    max_cost_usd: Option(Float),
    max_minutes: Option(Int),
    max_turns: Option(Int),
  )
}

pub fn parse_dispatch_input(
  input_json: String,
) -> Result(ParsedDispatch, String) {
  let decoder = {
    use brief <- decode.field("brief", decode.string)
    use max_tokens <- decode.optional_field(
      "max_tokens",
      None,
      decode.int |> decode.map(Some),
    )
    use max_cost_usd <- decode.optional_field(
      "max_cost_usd",
      None,
      decode_optional_number(),
    )
    use max_minutes <- decode.optional_field(
      "max_minutes",
      None,
      decode.int |> decode.map(Some),
    )
    use max_turns <- decode.optional_field(
      "max_turns",
      None,
      decode.int |> decode.map(Some),
    )
    decode.success(ParsedDispatch(
      brief: brief,
      max_tokens: max_tokens,
      max_cost_usd: max_cost_usd,
      max_minutes: max_minutes,
      max_turns: max_turns,
    ))
  }
  case json.parse(input_json, decoder) {
    Ok(p) -> {
      case string.trim(p.brief) {
        "" -> Error("brief must be non-empty")
        _ -> Ok(p)
      }
    }
    Error(_) -> Error("requires `brief` (string)")
  }
}

fn decode_optional_number() -> decode.Decoder(Option(Float)) {
  decode.one_of(decode.float |> decode.map(Some), [
    decode.int |> decode.map(fn(i) { Some(int.to_float(i)) }),
  ])
}

/// Resolve per-task budget from the agent's request + operator
/// defaults + ceilings. Returns the resolved budget and the list of
/// clamps applied.
pub fn resolve_budget(
  parsed: ParsedDispatch,
  defaults: DispatchDefaults,
) -> #(coder_types.TaskBudget, List(coder_types.BudgetClamp)) {
  let #(tokens, c1) =
    clamp_int(
      "max_tokens",
      option.unwrap(parsed.max_tokens, defaults.default_max_tokens),
      defaults.ceiling_max_tokens,
    )
  let #(cost, c2) =
    clamp_float(
      "max_cost_usd",
      option.unwrap(parsed.max_cost_usd, defaults.default_max_cost_usd),
      defaults.ceiling_max_cost_usd,
    )
  let #(minutes, c3) =
    clamp_int(
      "max_minutes",
      option.unwrap(parsed.max_minutes, defaults.default_max_minutes),
      defaults.ceiling_max_minutes,
    )
  let #(turns, c4) =
    clamp_int(
      "max_turns",
      option.unwrap(parsed.max_turns, defaults.default_max_turns),
      defaults.ceiling_max_turns,
    )

  let clamps =
    [c1, c2, c3, c4]
    |> list.filter_map(fn(c) {
      case c {
        Some(clamp) -> Ok(clamp)
        None -> Error(Nil)
      }
    })

  #(
    coder_types.TaskBudget(
      max_tokens: tokens,
      max_cost_usd: cost,
      max_minutes: minutes,
      max_turns: turns,
    ),
    clamps,
  )
}

fn clamp_int(
  name: String,
  value: Int,
  ceiling: Int,
) -> #(Int, Option(coder_types.BudgetClamp)) {
  case value > ceiling {
    True -> #(
      ceiling,
      Some(coder_types.BudgetClamp(
        field: name,
        requested: int.to_string(value),
        clamped: int.to_string(ceiling),
      )),
    )
    False -> #(value, None)
  }
}

fn clamp_float(
  name: String,
  value: Float,
  ceiling: Float,
) -> #(Float, Option(coder_types.BudgetClamp)) {
  case value >. ceiling {
    True -> #(
      ceiling,
      Some(coder_types.BudgetClamp(
        field: name,
        requested: float.to_string(value),
        clamped: float.to_string(ceiling),
      )),
    )
    False -> #(value, None)
  }
}

pub fn format_dispatch_result(
  r: coder_types.DispatchResult,
  clamps: List(coder_types.BudgetClamp),
) -> String {
  let header =
    "session_id: "
    <> r.session_id
    <> "\nstop_reason: "
    <> r.stop_reason
    <> "\ntokens: total="
    <> int.to_string(r.total_tokens)
    <> " input="
    <> int.to_string(r.input_tokens)
    <> " output="
    <> int.to_string(r.output_tokens)
    <> "\ncost_usd: "
    <> float.to_string(r.cost_usd)
    <> "\nduration_ms: "
    <> int.to_string(r.duration_ms)
    <> "\n"

  let clamps_section = case clamps {
    [] -> ""
    cs ->
      "\nbudget clamps applied (operator ceiling enforced):\n"
      <> {
        cs
        |> list.map(fn(c) {
          "  - "
          <> c.field
          <> ": requested="
          <> c.requested
          <> " → clamped="
          <> c.clamped
        })
        |> string.join("\n")
      }
      <> "\n"
  }

  header <> clamps_section <> "\n--- coder response ---\n" <> r.response_text
}

// ---------------------------------------------------------------------------
// cancel_coder_session
// ---------------------------------------------------------------------------

fn run_cancel(
  call: llm_types.ToolCall,
  mgr: CoderManager,
) -> llm_types.ToolResult {
  let decoder = {
    use sid <- decode.field("session_id", decode.string)
    decode.success(sid)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "cancel_coder_session needs `session_id` (string)",
      )
    Ok(session_id) ->
      case manager.cancel_session(mgr, session_id) {
        Ok(Nil) ->
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Cancel requested for session "
              <> session_id
              <> ". The dispatching call will return with stop_reason='cancelled' shortly.",
          )
        Error(e) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "cancel failed: " <> coder_types.format_error(e),
          )
      }
  }
}

// ---------------------------------------------------------------------------
// list_coder_sessions
// ---------------------------------------------------------------------------

fn run_list(call: llm_types.ToolCall, mgr: CoderManager) -> llm_types.ToolResult {
  let summaries = manager.list_sessions(mgr)
  let body = case summaries {
    [] -> "No active coder sessions."
    sessions -> {
      let lines =
        sessions
        |> list.map(format_session_summary)
        |> string.join("\n")
      int.to_string(list.length(sessions)) <> " active session(s):\n" <> lines
    }
  }
  llm_types.ToolSuccess(tool_use_id: call.id, content: body)
}

fn format_session_summary(s: coder_types.SessionSummary) -> String {
  "  - "
  <> s.session_id
  <> " (container "
  <> s.container_id
  <> "): cost_usd="
  <> float.to_string(s.cost_usd_so_far)
  <> ", tokens="
  <> int.to_string(s.tokens_so_far)
  <> ", started_at_ms="
  <> int.to_string(s.started_at_ms)
}
