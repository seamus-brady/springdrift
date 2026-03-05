//// D' meta-management — history tracking, stall detection, threshold tightening.
////
//// Part of the H-CogAff meta-management layer: monitors D' scores over time
//// and tightens thresholds when repeated borderline decisions are detected.

import dprime/types.{
  type DprimeState, type GateDecision, type GateResult, DprimeHistoryEntry,
  DprimeState,
}
import gleam/int
import gleam/list

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
  DprimeState(..state, history: trimmed)
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

/// Tighten both thresholds by 10% (multiply by 0.9).
/// Thresholds only ever tighten, never loosen.
pub fn tighten_thresholds(state: DprimeState) -> DprimeState {
  DprimeState(
    ..state,
    current_modify_threshold: state.current_modify_threshold *. 0.9,
    current_reject_threshold: state.current_reject_threshold *. 0.9,
  )
}

/// Escalate a decision based on meta-management analysis.
/// If should_tighten is true, MODIFY → REJECT. Otherwise unchanged.
pub fn maybe_escalate(
  state: DprimeState,
  decision: GateDecision,
) -> GateDecision {
  case should_tighten(state) {
    False -> decision
    True ->
      case decision {
        types.Modify -> types.Reject
        other -> other
      }
  }
}
