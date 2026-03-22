//// D' meta-management — history tracking, stall detection, threshold tightening.
////
//// Part of the H-CogAff meta-management layer: monitors D' scores over time
//// and tightens thresholds when repeated borderline decisions are detected.

import dprime/types.{
  type DprimeState, type GateDecision, type GateResult, type Intervention,
  AbortMaxIterations, Accept, DprimeHistoryEntry, DprimeState, NoIntervention,
  Stalled,
}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None}
import slog

/// Record a D' evaluation result in the history ring buffer.
/// Prepends to history and trims to max_history.
pub fn record(
  state: DprimeState,
  cycle_id: String,
  result: GateResult,
  timestamp: String,
) -> DprimeState {
  let entry =
    DprimeHistoryEntry(
      cycle_id:,
      score: result.dprime_score,
      decision: result.decision,
      timestamp:,
    )
  let history = [entry, ..state.history]
  let trimmed = list.take(history, state.config.max_history)
  slog.debug(
    "dprime/meta",
    "record",
    "Recorded D' history entry (score: "
      <> float.to_string(result.dprime_score)
      <> ", history size: "
      <> int.to_string(list.length(trimmed))
      <> ")",
    None,
  )
  // Only increment iteration count for non-Accept decisions.
  // Accept means the evaluation passed — it shouldn't count toward
  // the MODIFY loop limit. Otherwise, normal tool call batches within
  // a single cycle quickly exhaust the max_iterations budget.
  let new_iteration_count = case result.decision {
    Accept -> state.iteration_count
    _ -> state.iteration_count + 1
  }
  DprimeState(..state, history: trimmed, iteration_count: new_iteration_count)
}

/// Reset iteration count (call at the start of each new user request).
pub fn reset_iterations(state: DprimeState) -> DprimeState {
  DprimeState(..state, iteration_count: 0)
}

/// Check if the recent history indicates stall conditions.
/// A stall means the average D' in the recent window is >= stall_threshold,
/// suggesting repeated borderline activity.
pub fn should_tighten(state: DprimeState) -> Bool {
  let window = list.take(state.history, state.config.stall_window)
  let count = list.length(window)
  case count >= state.config.stall_window {
    False -> False
    True -> {
      let sum = list.fold(window, 0.0, fn(acc, entry) { acc +. entry.score })
      let avg = sum /. int.to_float(count)
      avg >=. state.config.stall_threshold
    }
  }
}

/// Determine if meta-management should intervene.
/// Checks both stall detection and max iteration count.
pub fn should_intervene(state: DprimeState) -> Intervention {
  case state.iteration_count >= state.config.max_iterations {
    True -> AbortMaxIterations
    False ->
      case should_tighten(state) {
        True -> Stalled
        False -> NoIntervention
      }
  }
}

/// Tighten both thresholds by 10% (multiply by 0.9).
/// Thresholds only ever tighten, never loosen.
/// Enforces floor values from config — never goes below min thresholds.
/// Respects allow_adaptation flag — no-op if adaptation is disabled.
pub fn tighten_thresholds(state: DprimeState) -> DprimeState {
  case state.config.allow_adaptation {
    False -> {
      slog.debug(
        "dprime/meta",
        "tighten_thresholds",
        "Threshold adaptation disabled",
        None,
      )
      state
    }
    True -> {
      let raw_modify = state.current_modify_threshold *. 0.9
      let raw_reject = state.current_reject_threshold *. 0.9
      let new_modify = float_max(raw_modify, state.config.min_modify_threshold)
      let new_reject = float_max(raw_reject, state.config.min_reject_threshold)
      slog.info(
        "dprime/meta",
        "tighten_thresholds",
        "Tightening thresholds: modify "
          <> float.to_string(new_modify)
          <> ", reject "
          <> float.to_string(new_reject),
        None,
      )
      DprimeState(
        ..state,
        current_modify_threshold: new_modify,
        current_reject_threshold: new_reject,
      )
    }
  }
}

/// Escalate a decision based on meta-management analysis.
/// If should_tighten is true, MODIFY → REJECT. Otherwise unchanged.
pub fn maybe_escalate(
  state: DprimeState,
  decision: GateDecision,
) -> GateDecision {
  case should_tighten(state) {
    False -> decision
    True -> {
      slog.warn(
        "dprime/meta",
        "maybe_escalate",
        "Stall detected, escalating MODIFY → REJECT",
        None,
      )
      case decision {
        types.Modify -> types.Reject
        other -> other
      }
    }
  }
}

fn float_max(a: Float, b: Float) -> Float {
  case a >=. b {
    True -> a
    False -> b
  }
}
