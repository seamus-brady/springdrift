//// Meta-learning BEAM worker — runs a single maintenance job on its
//// own timer without routing through the cognitive loop or the agent
//// scheduler.
////
//// Two invocation modes, selected per-worker via `WorkerInvocation`:
////
////   - `DirectTool(tool_name)` — the worker calls a Remembrancer tool
////     function directly (no LLM). Used for the mechanical audits
////     (affect correlation, fabrication audit, voice drift) whose
////     entire work is a disk-only compute.
////
////   - `AgentDelegation(instruction, expected_tools)` — the worker
////     sends an `AgentTask` to the running Remembrancer agent and
////     awaits its `AgentComplete` outcome. Used for the judgement
////     jobs (consolidation, goal review, skill decay, strategy
////     review) that need LLM reasoning. The Remembrancer's current
////     `task_subject` is resolved per-tick via the supervisor so a
////     Transient restart doesn't wedge the worker against a dead
////     mailbox.
////
//// Robustness:
////   - `last_run_at` persists to `.springdrift/memory/meta_learning/
////     workers.json` after each successful tick. On startup the
////     initial delay is computed as `max(0, interval_ms - (now -
////     last_run_at))` so a VM restart doesn't retrigger a fresh run.
////   - Mid-compute crash: the timestamp is not updated, so the next
////     tick re-runs from a clean state. Tool functions are idempotent.
////   - Missing Remembrancer (disabled or between restarts) causes an
////     `AgentDelegation` tick to log-warn and skip; `last_run_at` is
////     not advanced, so the next tick retries.
////   - No supervision yet — `spawn_unlinked` matches the Forecaster
////     pattern. Crash recovery is "on next scheduled tick".

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{
  type AgentOutcome, type AgentTask, type CognitiveMessage,
  type SupervisorMessage, AgentComplete, AgentFailure, AgentSuccess, AgentTask,
  LookupAgentSubject,
}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/types as llm_types
import meta_learning/worker_state
import paths
import scheduler/delivery
import scheduler/types as scheduler_types
import simplifile
import slog
import tools/remembrancer as tools_remembrancer

// ---------------------------------------------------------------------------
// Config & messages
// ---------------------------------------------------------------------------

/// How the worker's tick dispatches its maintenance work.
pub type WorkerInvocation {
  /// Call a Remembrancer tool directly — pure compute, no LLM.
  DirectTool(tool_name: String)
  /// Dispatch a task to the running Remembrancer agent. `instruction`
  /// is the natural-language prompt; `expected_tools` lists tools the
  /// agent should invoke (reported in the log if absent, but the
  /// outcome still counts as successful).
  AgentDelegation(instruction: String, expected_tools: List(String))
}

/// One instance per maintenance job. `name` is the persistence key and
/// log prefix; `invocation` selects the dispatch path.
pub type WorkerConfig {
  WorkerConfig(name: String, invocation: WorkerInvocation, interval_ms: Int)
}

pub type WorkerMessage {
  Tick
  Shutdown
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

type State {
  State(
    self: Subject(WorkerMessage),
    config: WorkerConfig,
    remembrancer_ctx: tools_remembrancer.RemembrancerContext,
    state_file: String,
    supervisor: Option(Subject(SupervisorMessage)),
  )
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start a single meta-learning worker. Returns its subject so the
/// caller can signal Shutdown. `supervisor` may be None when only
/// DirectTool workers are in use; AgentDelegation workers log a
/// warning and skip ticks when it's None.
pub fn start(
  config: WorkerConfig,
  remembrancer_ctx: tools_remembrancer.RemembrancerContext,
  state_file: String,
  supervisor: Option(Subject(SupervisorMessage)),
) -> Subject(WorkerMessage) {
  let setup: Subject(Subject(WorkerMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(WorkerMessage) = process.new_subject()
    process.send(setup, self)

    // Compute initial delay from persisted last_run_at so a restart
    // doesn't fire a job that was run a minute ago.
    let initial_delay = compute_initial_delay(state_file, config)
    slog.info(
      "meta_learning/worker",
      "start",
      "Worker '"
        <> config.name
        <> "' starting (invocation="
        <> invocation_label(config.invocation)
        <> ", interval="
        <> int.to_string(config.interval_ms)
        <> "ms, initial_delay="
        <> int.to_string(initial_delay)
        <> "ms)",
      None,
    )
    schedule_tick(self, initial_delay)

    let state =
      State(self:, config:, remembrancer_ctx:, state_file:, supervisor:)
    loop(state)
  })
  case process.receive(setup, 5000) {
    Ok(subj) -> subj
    Error(_) -> panic as "meta_learning/worker failed to start within 5s"
  }
}

// ---------------------------------------------------------------------------
// Loop
// ---------------------------------------------------------------------------

fn loop(state: State) -> Nil {
  case process.receive(state.self, 60_000) {
    Error(_) -> loop(state)
    Ok(Shutdown) -> {
      slog.info(
        "meta_learning/worker",
        "shutdown",
        "Worker '" <> state.config.name <> "' stopped",
        None,
      )
      Nil
    }
    Ok(Tick) -> {
      handle_tick(state)
      schedule_tick(state.self, state.config.interval_ms)
      loop(state)
    }
  }
}

fn schedule_tick(self: Subject(WorkerMessage), delay_ms: Int) -> Nil {
  // Minimum 1ms to avoid busy-loop if a caller passes 0.
  let safe_delay = case delay_ms < 1 {
    True -> 1
    False -> delay_ms
  }
  process.send_after(self, safe_delay, Tick)
  Nil
}

// ---------------------------------------------------------------------------
// Tick handler — dispatch per invocation mode
// ---------------------------------------------------------------------------

fn handle_tick(state: State) -> Nil {
  case state.config.invocation {
    DirectTool(tool_name:) -> handle_direct_tool(state, tool_name)
    AgentDelegation(instruction:, expected_tools:) ->
      handle_agent_delegation(state, instruction, expected_tools)
  }
}

fn handle_direct_tool(state: State, tool_name: String) -> Nil {
  let call_id = "meta-worker-" <> state.config.name <> "-" <> generate_uuid()
  // Empty input_json: all mechanical tools have only optional params
  // (from_date / to_date / thresholds) and default to sensible windows
  // when omitted.
  let call = llm_types.ToolCall(id: call_id, name: tool_name, input_json: "{}")
  let worker_cycle_id = "meta-worker-" <> state.config.name <> "-" <> call_id
  let ctx =
    tools_remembrancer.RemembrancerContext(
      ..state.remembrancer_ctx,
      cycle_id: worker_cycle_id,
      agent_id: "meta-worker",
    )
  let result = tools_remembrancer.execute(call, ctx)
  case result {
    llm_types.ToolSuccess(..) -> {
      slog.info(
        "meta_learning/worker",
        "tick",
        "Worker '" <> state.config.name <> "' completed",
        None,
      )
      worker_state.set(state.state_file, state.config.name, get_datetime())
    }
    llm_types.ToolFailure(error: err, ..) ->
      slog.warn(
        "meta_learning/worker",
        "tick",
        "Worker '" <> state.config.name <> "' failed: " <> err,
        None,
      )
  }
}

fn handle_agent_delegation(
  state: State,
  instruction: String,
  expected_tools: List(String),
) -> Nil {
  case resolve_remembrancer_subject(state) {
    None ->
      slog.warn(
        "meta_learning/worker",
        "tick",
        "Worker '"
          <> state.config.name
          <> "' has no Remembrancer task_subject (agent disabled or "
          <> "restarting) — skipping tick",
        None,
      )
    Some(task_subject) ->
      dispatch_to_remembrancer(state, task_subject, instruction, expected_tools)
  }
}

fn dispatch_to_remembrancer(
  state: State,
  task_subject: Subject(AgentTask),
  instruction: String,
  expected_tools: List(String),
) -> Nil {
  let task_id = "meta-worker-" <> state.config.name <> "-" <> generate_uuid()
  let worker_cycle_id = "meta-worker-" <> state.config.name <> "-" <> task_id

  // The worker owns a dedicated reply_to so the Remembrancer's
  // AgentComplete lands in our mailbox rather than the cog loop's.
  let reply_to: Subject(CognitiveMessage) = process.new_subject()

  let task =
    AgentTask(
      task_id:,
      tool_use_id: task_id,
      instruction:,
      context: "",
      parent_cycle_id: worker_cycle_id,
      reply_to:,
      depth: 1,
      max_turns_override: None,
      // Off-cog maintenance; no deputy briefing needed.
      deputy_subject: None,
    )
  process.send(task_subject, task)

  // Wait for the agent to complete. Cap the wait at 30 minutes — a
  // Remembrancer job that runs longer indicates something is stuck.
  // We filter for AgentComplete and discard everything else (agent
  // framework could in principle send other CognitiveMessage variants).
  case await_agent_complete(reply_to, 30 * 60 * 1000) {
    Ok(outcome) -> handle_outcome(state, outcome, expected_tools)
    Error(reason) ->
      slog.warn(
        "meta_learning/worker",
        "tick",
        "Worker '"
          <> state.config.name
          <> "' agent delegation timed out or failed: "
          <> reason,
        None,
      )
  }
}

/// Block on the worker's reply_to until we get an AgentComplete or the
/// timeout expires. Other CognitiveMessage variants are discarded.
fn await_agent_complete(
  reply_to: Subject(CognitiveMessage),
  timeout_ms: Int,
) -> Result(AgentOutcome, String) {
  case process.receive(reply_to, timeout_ms) {
    Error(_) -> Error("timeout after " <> int.to_string(timeout_ms) <> "ms")
    Ok(AgentComplete(outcome:)) -> Ok(outcome)
    Ok(_) -> await_agent_complete(reply_to, timeout_ms)
  }
}

fn handle_outcome(
  state: State,
  outcome: AgentOutcome,
  expected_tools: List(String),
) -> Nil {
  case outcome {
    AgentSuccess(result:, tools_used:, ..) -> {
      let missing =
        list.filter(expected_tools, fn(t) { !list.contains(tools_used, t) })
      case missing {
        [] -> Nil
        _ ->
          slog.warn(
            "meta_learning/worker",
            "tick",
            "Worker '"
              <> state.config.name
              <> "' completed but expected tools were not called: "
              <> string.join(missing, ", "),
            None,
          )
      }
      write_outcome_file(state.config.name, result)
      slog.info(
        "meta_learning/worker",
        "tick",
        "Worker '" <> state.config.name <> "' completed via agent delegation",
        None,
      )
      worker_state.set(state.state_file, state.config.name, get_datetime())
    }
    AgentFailure(error:, ..) ->
      slog.warn(
        "meta_learning/worker",
        "tick",
        "Worker '"
          <> state.config.name
          <> "' agent delegation failed: "
          <> error,
        None,
      )
  }
}

/// Persist the agent's final report to `.springdrift/meta_learning/
/// outputs/` so the operator can read it without scraping logs.
fn write_outcome_file(worker_name: String, content: String) -> Nil {
  let dir = paths.meta_learning_outputs_dir()
  let _ = simplifile.create_directory_all(dir)
  let cfg = scheduler_types.FileDelivery(directory: dir, format: "markdown")
  case delivery.deliver(content, worker_name, cfg) {
    Ok(_) -> Nil
    Error(reason) ->
      slog.warn(
        "meta_learning/worker",
        "write_outcome_file",
        "Failed to write outcome for '" <> worker_name <> "': " <> reason,
        None,
      )
  }
}

// ---------------------------------------------------------------------------
// Supervisor lookup
// ---------------------------------------------------------------------------

fn resolve_remembrancer_subject(state: State) -> Option(Subject(AgentTask)) {
  case state.supervisor {
    None -> None
    Some(sup) -> {
      let reply_to: Subject(Option(Subject(AgentTask))) = process.new_subject()
      process.send(sup, LookupAgentSubject(name: "remembrancer", reply_to:))
      case process.receive(reply_to, 2000) {
        Ok(result) -> result
        Error(_) -> None
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Initial delay — consult the persisted timestamp
// ---------------------------------------------------------------------------

fn compute_initial_delay(state_file: String, config: WorkerConfig) -> Int {
  case worker_state.get(state_file, config.name) {
    Some(last_iso) -> {
      case worker_state.ms_since_iso(last_iso) {
        Some(elapsed_ms) ->
          case config.interval_ms - elapsed_ms {
            // Already overdue — fire soon, but not instantly on boot
            // (give the system a few seconds to settle).
            remaining if remaining < 10_000 -> 10_000
            remaining -> remaining
          }
        None -> initial_fresh_delay(config)
      }
    }
    None -> initial_fresh_delay(config)
  }
}

/// First-ever run on a fresh instance: wait one-tenth of the interval
/// (capped at 10 minutes) so audits don't fire immediately on the first
/// boot of a brand-new deployment. Meaningful data doesn't exist yet.
fn initial_fresh_delay(config: WorkerConfig) -> Int {
  let tenth = config.interval_ms / 10
  case tenth > 600_000 {
    True -> 600_000
    False -> tenth
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn invocation_label(inv: WorkerInvocation) -> String {
  case inv {
    DirectTool(tool_name:) -> "direct:" <> tool_name
    AgentDelegation(..) -> "agent:remembrancer"
  }
}
