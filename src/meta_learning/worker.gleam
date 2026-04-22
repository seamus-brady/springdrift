//// Meta-learning BEAM worker — runs a single mechanical audit job on
//// its own timer without routing through the cognitive loop.
////
//// Phase 2 of the meta-scheduler fix: jobs whose entire work is a
//// disk-only compute (affect correlation, fabrication audit, voice
//// drift) were previously queued as `SchedulerInput` and competed
//// with operator chat for cognitive-loop turns. A BEAM worker runs
//// the same Remembrancer tool function directly; results persist to
//// the facts store and surface in the sensorium on the next cycle.
////
//// Robustness:
////   - `last_run_at` persists to `.springdrift/memory/meta_learning/
////     workers.json` after each successful tick. On startup the
////     initial delay is computed as `max(0, interval_ms - (now -
////     last_run_at))` so a VM restart doesn't retrigger a fresh run.
////   - Mid-compute crash: the timestamp is not updated, so the next
////     tick re-runs from a clean state. Tool functions are idempotent.
////   - No supervision yet — `spawn_unlinked` matches the Forecaster
////     pattern. Crash recovery is "on next scheduled tick", same as
////     the scheduler would provide.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{None, Some}
import llm/types as llm_types
import meta_learning/worker_state
import slog
import tools/remembrancer as tools_remembrancer

// ---------------------------------------------------------------------------
// Config & messages
// ---------------------------------------------------------------------------

/// One instance per mechanical job. `name` is the persistence key and
/// log prefix; `tool_name` is the Remembrancer tool invoked on each
/// tick.
pub type WorkerConfig {
  WorkerConfig(name: String, tool_name: String, interval_ms: Int)
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
/// supervisor can signal Shutdown.
pub fn start(
  config: WorkerConfig,
  remembrancer_ctx: tools_remembrancer.RemembrancerContext,
  state_file: String,
) -> Subject(WorkerMessage) {
  let setup: Subject(Subject(WorkerMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(WorkerMessage) = process.new_subject()
    process.send(setup, self)

    // Compute initial delay from persisted last_run_at so a restart
    // doesn't fire an audit that was run a minute ago.
    let initial_delay = compute_initial_delay(state_file, config)
    slog.info(
      "meta_learning/worker",
      "start",
      "Worker '"
        <> config.name
        <> "' starting (interval="
        <> int.to_string(config.interval_ms)
        <> "ms, initial_delay="
        <> int.to_string(initial_delay)
        <> "ms)",
      None,
    )
    schedule_tick(self, initial_delay)

    let state =
      State(
        self: self,
        config: config,
        remembrancer_ctx: remembrancer_ctx,
        state_file: state_file,
      )
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
// Tick handler — invoke the Remembrancer tool directly
// ---------------------------------------------------------------------------

fn handle_tick(state: State) -> Nil {
  let call_id = "meta-worker-" <> state.config.name <> "-" <> generate_uuid()
  // Empty input_json: all three mechanical tools have only optional
  // params (from_date / to_date / thresholds) and default to sensible
  // windows when omitted.
  let call =
    llm_types.ToolCall(
      id: call_id,
      name: state.config.tool_name,
      input_json: "{}",
    )
  // Give the worker its own cycle_id so provenance on any facts
  // written is distinguishable from agent-driven runs.
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
      // Only persist on success — a failed tick will re-run on the
      // next tick rather than skipping the window.
      worker_state.set(state.state_file, state.config.name, get_datetime())
    }
    llm_types.ToolFailure(error: err, ..) -> {
      slog.warn(
        "meta_learning/worker",
        "tick",
        "Worker '" <> state.config.name <> "' failed: " <> err,
        None,
      )
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
