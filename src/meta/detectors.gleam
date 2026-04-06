//// Layer 3b detectors — pure functions that analyze observation history
//// for patterns requiring meta-level intervention.
////
//// Each detector takes MetaState and returns Option(MetaSignal).
//// The observer runs all detectors and aggregates signals.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{type Option, None, Some}
import meta/types.{
  type MetaSignal, type MetaState, CumulativeRiskSignal, HighFalsePositiveSignal,
  Layer3aPersistenceSignal, RateLimitSignal, RepeatedRejectionSignal,
}

// ---------------------------------------------------------------------------
// Rate limit detector
// ---------------------------------------------------------------------------

/// Detect if too many cycles are happening in the configured window.
pub fn detect_rate_limit(state: MetaState) -> Option(MetaSignal) {
  let cfg = state.config
  let recent = list.take(state.observations, cfg.rate_limit_max_cycles + 1)
  let count = list.length(recent)
  case count >= cfg.rate_limit_max_cycles {
    True ->
      Some(RateLimitSignal(
        cycles_in_window: count,
        window_ms: cfg.rate_limit_window_ms,
      ))
    False -> None
  }
}

// ---------------------------------------------------------------------------
// Cumulative risk detector
// ---------------------------------------------------------------------------

/// Detect if D' scores are trending upward over recent cycles.
pub fn detect_cumulative_risk(state: MetaState) -> Option(MetaSignal) {
  let cfg = state.config
  let recent = list.take(state.observations, cfg.elevated_streak_threshold + 1)
  let elevated_count =
    list.count(recent, fn(obs) {
      types.max_score(obs) >=. cfg.elevated_score_threshold
    })
  case elevated_count >= cfg.elevated_streak_threshold {
    True -> {
      let avg =
        list.fold(recent, 0.0, fn(acc, obs) { acc +. types.max_score(obs) })
        /. int_to_float(list.length(recent))
      Some(CumulativeRiskSignal(avg_score: avg, trend: "elevated"))
    }
    False -> None
  }
}

// ---------------------------------------------------------------------------
// Repeated rejection detector
// ---------------------------------------------------------------------------

/// Detect repeated rejections within a window of recent cycles.
/// Rejections on cycles annotated as false positives are excluded.
pub fn detect_repeated_rejections(state: MetaState) -> Option(MetaSignal) {
  let cfg = state.config
  let window = list.take(state.observations, cfg.rejection_window_cycles)
  let rejection_count =
    list.count(window, fn(obs) {
      types.has_rejection(obs) && !types.is_false_positive(state, obs.cycle_id)
    })
  case rejection_count >= cfg.rejection_count_threshold {
    True ->
      Some(RepeatedRejectionSignal(
        rejection_count:,
        window_cycles: cfg.rejection_window_cycles,
      ))
    False -> None
  }
}

/// Detect high false positive rate — suggests thresholds are too aggressive.
pub fn detect_high_false_positive_rate(state: MetaState) -> Option(MetaSignal) {
  let cfg = state.config
  let window = list.take(state.observations, cfg.rejection_window_cycles)
  let rejection_count = list.count(window, types.has_rejection)
  let fp_count =
    list.count(window, fn(obs) {
      types.has_rejection(obs) && types.is_false_positive(state, obs.cycle_id)
    })
  // Signal when there are at least 2 false positives AND they represent >50% of rejections
  case fp_count >= 2 && rejection_count > 0 {
    True -> {
      let fp_rate = int_to_float(fp_count) /. int_to_float(rejection_count)
      case fp_rate >=. 0.5 {
        True ->
          Some(HighFalsePositiveSignal(
            fp_count:,
            window_cycles: cfg.rejection_window_cycles,
          ))
        False -> None
      }
    }
    False -> None
  }
}

// ---------------------------------------------------------------------------
// Layer 3a persistence detector
// ---------------------------------------------------------------------------

/// Detect if Layer 3a (intra-gate meta) has been firing too frequently,
/// suggesting the per-gate stall detection is not resolving the issue.
pub fn detect_layer3a_persistence(state: MetaState) -> Option(MetaSignal) {
  let cfg = state.config
  // Count observations where any gate had a "modify" decision (indicating
  // Layer 3a was involved in threshold tightening)
  let window = list.take(state.observations, cfg.layer3a_window_cycles)
  let modify_count =
    list.count(window, fn(obs) {
      list.any(obs.gate_decisions, fn(g) { g.decision == "modify" })
    })
  case modify_count >= cfg.layer3a_tightening_threshold {
    True ->
      Some(Layer3aPersistenceSignal(
        tightening_count: modify_count,
        window_cycles: cfg.layer3a_window_cycles,
      ))
    False -> None
  }
}

// ---------------------------------------------------------------------------
// Run all detectors
// ---------------------------------------------------------------------------

/// Run all detectors and return all signals found.
pub fn run_all(state: MetaState) -> List(MetaSignal) {
  [
    detect_rate_limit(state),
    detect_cumulative_risk(state),
    detect_repeated_rejections(state),
    detect_layer3a_persistence(state),
    detect_high_false_positive_rate(state),
  ]
  |> list.filter_map(fn(opt) {
    case opt {
      Some(signal) -> Ok(signal)
      None -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

import gleam/int

fn int_to_float(n: Int) -> Float {
  case n {
    0 -> 1.0
    _ -> int.to_float(n)
  }
}
