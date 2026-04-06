//// Affect monitor — called after each cognitive cycle to compute and store
//// an affect snapshot. Not an OTP actor — just a function.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import affect/compute.{type AffectSignals, AffectSignals}
import affect/store
import affect/types.{type AffectSnapshot}
import agent/cognitive_state.{type CognitiveState}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

/// Compute an affect snapshot after a cycle completes.
/// Gathers signals from CognitiveState, computes dimensions,
/// writes to JSONL, and returns the snapshot for sensorium injection.
pub fn after_cycle(
  state: CognitiveState,
  affect_dir: String,
) -> Option(AffectSnapshot) {
  // Load previous snapshot for EMA continuity
  let prev = store.latest(affect_dir)

  // Gather signals from cycle telemetry
  let signals = gather_signals(state)

  let cycle_id = case state.cycle_id {
    Some(cid) -> cid
    None -> ""
  }

  let snapshot =
    compute.compute_snapshot(signals, prev, cycle_id, get_datetime())

  // Persist
  store.append(affect_dir, snapshot)

  slog.debug(
    "affect/monitor",
    "after_cycle",
    "Affect: D:"
      <> int.to_string(float_round(snapshot.desperation))
      <> "% C:"
      <> int.to_string(float_round(snapshot.calm))
      <> "% Cf:"
      <> int.to_string(float_round(snapshot.confidence))
      <> "% F:"
      <> int.to_string(float_round(snapshot.frustration))
      <> "% P:"
      <> int.to_string(float_round(snapshot.pressure))
      <> types.trend_arrow(snapshot.trend),
    state.cycle_id,
  )

  Some(snapshot)
}

fn float_round(f: Float) -> Int {
  case f >=. 0.0 {
    True -> {
      let truncated = float_truncate(f)
      case f -. int.to_float(truncated) >=. 0.5 {
        True -> truncated + 1
        False -> truncated
      }
    }
    False -> 0
  }
}

@external(erlang, "erlang", "trunc")
fn float_truncate(f: Float) -> Int

/// Gather affect signals from CognitiveState telemetry.
fn gather_signals(state: CognitiveState) -> AffectSignals {
  // Tool call stats from this cycle
  let tool_total = list.length(state.cycle_tool_calls)
  let tool_failed = list.count(state.cycle_tool_calls, fn(t) { !t.success })

  // Same-tool retries: count tools that appear more than once AND failed
  let failed_tool_names =
    list.filter_map(state.cycle_tool_calls, fn(t) {
      case t.success {
        False -> Ok(t.name)
        True -> Error(Nil)
      }
    })
  let retry_count =
    list.length(failed_tool_names) - list.length(list.unique(failed_tool_names))

  // D' gate stats from this cycle
  let gate_rejections =
    list.count(state.dprime_decisions, fn(d) { d.decision == "reject" })
  let gate_modifications =
    list.count(state.dprime_decisions, fn(d) { d.decision == "modify" })

  // Delegation stats
  let delegation_total = list.length(state.agent_completions)
  let delegation_failed =
    list.count(state.agent_completions, fn(c) { result.is_error(c.result) })

  // Budget pressure from token usage (rough: if > 100k tokens in cycle, pressure rises)
  let cycle_tokens = state.cycle_tokens_in + state.cycle_tokens_out
  let budget_pressure = case cycle_tokens > 100_000 {
    True -> 0.8
    False ->
      case cycle_tokens > 50_000 {
        True -> 0.4
        False -> 0.0
      }
  }

  // Compute success rate from this cycle's tool and delegation outcomes
  let total_ops = tool_total + delegation_total
  let failed_ops = tool_failed + delegation_failed
  let success_rate = case total_ops > 0 {
    True -> int.to_float(total_ops - failed_ops) /. int.to_float(total_ops)
    False -> 0.7
  }

  // CBR hit rate: check if any retrieved case IDs exist on state
  let cbr_rate = case list.is_empty(state.retrieved_case_ids) {
    True -> 0.3
    False -> 0.7
  }

  AffectSignals(
    tool_calls_total: tool_total,
    tool_calls_failed: tool_failed,
    same_tool_retries: retry_count,
    gate_rejections:,
    gate_modifications:,
    delegations_total: delegation_total,
    delegations_failed: delegation_failed,
    recent_success_rate: success_rate,
    cbr_hit_rate: cbr_rate,
    budget_pressure:,
    consecutive_failure_cycles: 0,
    output_gate_rejections: state.output_gate_rejections,
  )
}
