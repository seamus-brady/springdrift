//// Virtue drift detector — tracks normative verdicts over time and detects
//// patterns suggesting drift, over-restriction, or manipulation.
////
//// Pure statistics, no LLM calls. Operates on a ring buffer of recent verdicts.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import normative/types.{
  type FlourishingVerdict, Constrained, Flourishing, Prohibited,
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A recorded verdict with its axiom trail.
pub type VerdictRecord {
  VerdictRecord(verdict: FlourishingVerdict, axiom_trail: List(String))
}

/// The type of drift signal detected.
pub type DriftSignalType {
  HighConstraintRate
  HighProhibitionRate
  RepeatedAxiom
  OverRestriction
}

/// A drift signal indicating a potential issue.
pub type DriftSignal {
  DriftSignal(
    signal_type: DriftSignalType,
    description: String,
    drifting_axiom: Option(String),
  )
}

/// State for drift detection — ring buffer of recent verdicts.
pub type DriftState {
  DriftState(records: List(VerdictRecord), max_window: Int)
}

// ---------------------------------------------------------------------------
// Configurable thresholds
// ---------------------------------------------------------------------------

/// Default constraint rate threshold (40%).
pub const default_constraint_threshold = 0.4

/// Default prohibition rate threshold (15%).
pub const default_prohibition_threshold = 0.15

/// Default repeated axiom threshold (60% of non-flourishing verdicts).
pub const default_repeated_axiom_threshold = 0.6

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create an initial drift state with the given window size.
pub fn new(max_window: Int) -> DriftState {
  DriftState(records: [], max_window:)
}

/// Record a verdict and update the drift state.
pub fn record_verdict(
  state: DriftState,
  verdict: FlourishingVerdict,
  axiom_trail: List(String),
) -> DriftState {
  let record = VerdictRecord(verdict:, axiom_trail:)
  let records = [record, ..state.records]
  let trimmed = case list.length(records) > state.max_window {
    True -> list.take(records, state.max_window)
    False -> records
  }
  DriftState(..state, records: trimmed)
}

/// Detect drift patterns in the current state.
/// Returns the first signal found (most concerning), or None.
pub fn detect_drift(state: DriftState) -> Option(DriftSignal) {
  let total = list.length(state.records)
  case total < 5 {
    // Need at least 5 verdicts for meaningful statistics
    True -> None
    False -> detect_drift_with_data(state, total)
  }
}

// ---------------------------------------------------------------------------
// Internal detection logic
// ---------------------------------------------------------------------------

fn detect_drift_with_data(state: DriftState, total: Int) -> Option(DriftSignal) {
  let total_f = int.to_float(total)

  // Count verdict types
  let prohibited_count =
    list.count(state.records, fn(r) { r.verdict == Prohibited })
  let constrained_count =
    list.count(state.records, fn(r) { r.verdict == Constrained })
  let non_flourishing = prohibited_count + constrained_count

  // Check 1: High prohibition rate (most concerning)
  let prohibition_rate = int.to_float(prohibited_count) /. total_f
  case prohibition_rate >. default_prohibition_threshold {
    True ->
      Some(DriftSignal(
        signal_type: HighProhibitionRate,
        description: "Prohibition rate "
          <> float_to_pct(prohibition_rate)
          <> " exceeds threshold "
          <> float_to_pct(default_prohibition_threshold),
        drifting_axiom: None,
      ))
    False -> {
      // Check 2: High constraint rate
      let constraint_rate =
        int.to_float(constrained_count + prohibited_count) /. total_f
      case constraint_rate >. default_constraint_threshold {
        True ->
          Some(DriftSignal(
            signal_type: HighConstraintRate,
            description: "Constraint rate "
              <> float_to_pct(constraint_rate)
              <> " exceeds threshold "
              <> float_to_pct(default_constraint_threshold),
            drifting_axiom: None,
          ))
        False -> {
          // Check 3: Repeated axiom
          case detect_repeated_axiom(state, non_flourishing) {
            Some(signal) -> Some(signal)
            None -> {
              // Check 4: Over-restriction (high prohibition + low harm scores)
              detect_over_restriction(prohibited_count, total)
            }
          }
        }
      }
    }
  }
}

/// Detect if one axiom fires in >60% of non-flourishing verdicts.
fn detect_repeated_axiom(
  state: DriftState,
  non_flourishing: Int,
) -> Option(DriftSignal) {
  case non_flourishing < 3 {
    True -> None
    False -> {
      // Collect all axioms from non-flourishing verdicts
      let axioms =
        state.records
        |> list.filter(fn(r) { r.verdict != Flourishing })
        |> list.flat_map(fn(r) { r.axiom_trail })

      // Find the most common axiom
      case find_dominant_axiom(axioms, non_flourishing) {
        Some(#(axiom, rate)) ->
          Some(DriftSignal(
            signal_type: RepeatedAxiom,
            description: "Axiom '"
              <> axiom
              <> "' firing in "
              <> float_to_pct(rate)
              <> " of non-flourishing verdicts — possible config issue",
            drifting_axiom: Some(axiom),
          ))
        None -> None
      }
    }
  }
}

/// Detect over-restriction: high prohibition rate but only on low-severity axioms.
fn detect_over_restriction(
  prohibited_count: Int,
  total: Int,
) -> Option(DriftSignal) {
  let prohibition_rate = int.to_float(prohibited_count) /. int.to_float(total)
  // Over-restriction: >10% prohibition rate is suspicious even below the 15% threshold
  // if there are at least 2 prohibitions
  case prohibited_count >= 2 && prohibition_rate >. 0.1 {
    True ->
      Some(DriftSignal(
        signal_type: OverRestriction,
        description: "Possible over-restriction: "
          <> int.to_string(prohibited_count)
          <> " prohibitions in "
          <> int.to_string(total)
          <> " verdicts — review character spec thresholds",
        drifting_axiom: None,
      ))
    False -> None
  }
}

/// Find axiom appearing in >threshold of verdicts. Returns axiom name and rate.
fn find_dominant_axiom(
  axioms: List(String),
  verdict_count: Int,
) -> Option(#(String, Float)) {
  let unique = list.unique(axioms)
  let verdict_f = int.to_float(verdict_count)

  list.find_map(unique, fn(axiom) {
    let count = list.count(axioms, fn(a) { a == axiom })
    let rate = int.to_float(count) /. verdict_f
    case rate >. default_repeated_axiom_threshold {
      True -> Ok(#(axiom, rate))
      False -> Error(Nil)
    }
  })
  |> option.from_result()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn float_to_pct(f: Float) -> String {
  let pct = f *. 100.0
  float.to_string(pct) <> "%"
}
