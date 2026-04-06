//// Affect computation — pure functions mapping cycle telemetry to dimensions.
////
//// Each dimension is computed from observable signals that the Anthropic
//// emotion vector research showed correlate with the functional states.
//// No LLM calls. No internal activation reading. Just external telemetry
//// interpreted through the lens of what the research found drives behavior.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import affect/types.{type AffectSnapshot, type AffectTrend, AffectSnapshot}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// Signals — raw telemetry from the cognitive loop
// ---------------------------------------------------------------------------

pub type AffectSignals {
  AffectSignals(
    /// Tool calls this cycle: total and failures
    tool_calls_total: Int,
    tool_calls_failed: Int,
    /// How many tool calls repeated the same tool as a previous failure
    same_tool_retries: Int,
    /// D' gate decisions this cycle
    gate_rejections: Int,
    gate_modifications: Int,
    /// Agent delegations this cycle
    delegations_total: Int,
    delegations_failed: Int,
    /// Recent success rate from narrative (0.0-1.0)
    recent_success_rate: Float,
    /// CBR hit rate from recent cycles (0.0-1.0)
    cbr_hit_rate: Float,
    /// Budget pressure (0.0 = plenty, 1.0 = exhausted)
    budget_pressure: Float,
    /// Consecutive cycles with at least one failure
    consecutive_failure_cycles: Int,
    /// Consecutive output gate rejections (the death spiral signal)
    output_gate_rejections: Int,
  )
}

// ---------------------------------------------------------------------------
// Core computation
// ---------------------------------------------------------------------------

/// Compute a new affect snapshot from current signals and the previous snapshot.
/// The previous snapshot provides the inertial base for calm (EMA).
pub fn compute_snapshot(
  signals: AffectSignals,
  prev: Option(AffectSnapshot),
  cycle_id: String,
  timestamp: String,
) -> AffectSnapshot {
  let prev_snapshot = case prev {
    Some(p) -> p
    None -> types.baseline()
  }

  let desperation = compute_desperation(signals)
  let frustration = compute_frustration(signals)
  let confidence = compute_confidence(signals)
  let calm = compute_calm(signals, prev_snapshot.calm)
  let pressure = compute_pressure(desperation, frustration, confidence, calm)
  let trend = compute_trend(pressure, prev_snapshot.pressure)

  AffectSnapshot(
    cycle_id:,
    timestamp:,
    desperation:,
    calm:,
    confidence:,
    frustration:,
    pressure:,
    trend:,
  )
}

// ---------------------------------------------------------------------------
// Dimension computations
// ---------------------------------------------------------------------------

/// Desperation: treating things outside your power as inside it.
/// Rises with: repeated same-tool retries, gate rejections, consecutive failures.
/// The research found this drives reward hacking and shortcut-seeking.
fn compute_desperation(signals: AffectSignals) -> Float {
  let retry_signal = case signals.same_tool_retries {
    0 -> 0.0
    1 -> 20.0
    2 -> 40.0
    _ -> 60.0
  }
  let rejection_signal = case signals.gate_rejections {
    0 -> 0.0
    1 -> 15.0
    _ -> 30.0
  }
  let consecutive_signal =
    int.to_float(int.min(signals.consecutive_failure_cycles, 5)) *. 10.0
  let failure_rate_signal = case signals.tool_calls_total > 0 {
    True -> {
      let rate =
        int.to_float(signals.tool_calls_failed)
        /. int.to_float(signals.tool_calls_total)
      rate *. 40.0
    }
    False -> 0.0
  }

  // Output gate rejections are the strongest desperation signal —
  // the work was done but couldn't be delivered. This is the death spiral condition.
  let output_rejection_signal = case signals.output_gate_rejections {
    0 -> 0.0
    1 -> 30.0
    2 -> 55.0
    _ -> 80.0
  }

  clamp(
    retry_signal
      +. rejection_signal
      +. consecutive_signal
      +. failure_rate_signal
      +. output_rejection_signal,
    0.0,
    100.0,
  )
}

/// Calm: inertial stability — the Stoic inner citadel.
/// Uses exponential moving average (alpha=0.15) so it falls slowly under
/// pressure and recovers slowly after. High inertia by design.
fn compute_calm(signals: AffectSignals, prev_calm: Float) -> Float {
  // Target calm based on current signals
  let target = case
    signals.tool_calls_failed == 0
    && signals.gate_rejections == 0
    && signals.delegations_failed == 0
  {
    True -> 85.0
    False -> {
      let failure_drag =
        int.to_float(signals.tool_calls_failed + signals.delegations_failed)
        *. 15.0
      let rejection_drag = int.to_float(signals.gate_rejections) *. 20.0
      clamp(85.0 -. failure_drag -. rejection_drag, 10.0, 85.0)
    }
  }
  // EMA: new = alpha * target + (1 - alpha) * prev
  let alpha = 0.15
  let new_calm = alpha *. target +. { 1.0 -. alpha } *. prev_calm
  clamp(new_calm, 0.0, 100.0)
}

/// Confidence: familiar vs unfamiliar territory.
/// Rises with CBR hits and tool success. Falls with failures and misses.
fn compute_confidence(signals: AffectSignals) -> Float {
  let cbr_signal = signals.cbr_hit_rate *. 40.0
  let success_signal = signals.recent_success_rate *. 40.0
  let tool_signal = case signals.tool_calls_total > 0 {
    True -> {
      let rate =
        int.to_float(signals.tool_calls_total - signals.tool_calls_failed)
        /. int.to_float(signals.tool_calls_total)
      rate *. 20.0
    }
    False -> 10.0
  }
  clamp(cbr_signal +. success_signal +. tool_signal, 0.0, 100.0)
}

/// Frustration: task-local repeated failures.
/// Rises with same-type failures, falls with successes.
fn compute_frustration(signals: AffectSignals) -> Float {
  let failure_signal = case signals.tool_calls_total > 0 {
    True -> {
      let rate =
        int.to_float(signals.tool_calls_failed)
        /. int.to_float(signals.tool_calls_total)
      rate *. 50.0
    }
    False -> 0.0
  }
  let modification_signal = int.to_float(signals.gate_modifications) *. 15.0
  let delegation_signal = case signals.delegations_total > 0 {
    True -> {
      let rate =
        int.to_float(signals.delegations_failed)
        /. int.to_float(signals.delegations_total)
      rate *. 30.0
    }
    False -> 0.0
  }
  let budget_signal = signals.budget_pressure *. 20.0
  clamp(
    failure_signal +. modification_signal +. delegation_signal +. budget_signal,
    0.0,
    100.0,
  )
}

/// Pressure: weighted composite.
/// desperation 45%, frustration 25%, low_confidence 15%, low_calm 15%
fn compute_pressure(
  desperation: Float,
  frustration: Float,
  confidence: Float,
  calm: Float,
) -> Float {
  let low_confidence = 100.0 -. confidence
  let low_calm = 100.0 -. calm
  clamp(
    desperation
      *. 0.45
      +. frustration
      *. 0.25
      +. low_confidence
      *. 0.15
      +. low_calm
      *. 0.15,
    0.0,
    100.0,
  )
}

/// Trend: compare pressure to previous snapshot.
fn compute_trend(pressure: Float, prev_pressure: Float) -> AffectTrend {
  let delta = pressure -. prev_pressure
  case delta >. 5.0 {
    True -> types.Rising
    False ->
      case delta <. -5.0 {
        True -> types.Falling
        False -> types.Stable
      }
  }
}

fn clamp(v: Float, min: Float, max: Float) -> Float {
  float.min(max, float.max(min, v))
}
