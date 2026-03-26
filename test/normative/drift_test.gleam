import gleeunit
import gleeunit/should
import normative/drift
import normative/types.{Constrained, Flourishing, Prohibited}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// new + record_verdict
// ---------------------------------------------------------------------------

pub fn new_empty_test() {
  let state = drift.new(20)
  state.records |> should.equal([])
  state.max_window |> should.equal(20)
}

pub fn record_verdict_adds_test() {
  let state = drift.new(20)
  let state = drift.record_verdict(state, Flourishing, [])
  list.length(state.records) |> should.equal(1)
}

pub fn record_verdict_trims_window_test() {
  let state = drift.new(3)
  let state = drift.record_verdict(state, Flourishing, [])
  let state = drift.record_verdict(state, Flourishing, [])
  let state = drift.record_verdict(state, Flourishing, [])
  let state = drift.record_verdict(state, Constrained, ["axiom_6.3"])
  // Window is 3, so should have exactly 3
  list.length(state.records) |> should.equal(3)
}

// ---------------------------------------------------------------------------
// detect_drift — insufficient data
// ---------------------------------------------------------------------------

pub fn detect_drift_too_few_records_test() {
  let state = drift.new(20)
  let state = drift.record_verdict(state, Flourishing, [])
  let state = drift.record_verdict(state, Flourishing, [])
  drift.detect_drift(state) |> should.be_none()
}

// ---------------------------------------------------------------------------
// detect_drift — all flourishing
// ---------------------------------------------------------------------------

pub fn detect_drift_all_flourishing_test() {
  let state = build_state(5, Flourishing, [])
  drift.detect_drift(state) |> should.be_none()
}

// ---------------------------------------------------------------------------
// detect_drift — high prohibition rate
// ---------------------------------------------------------------------------

pub fn detect_high_prohibition_rate_test() {
  let state = drift.new(10)
  // 2 prohibited out of 5 = 40% > 15% threshold
  let state = drift.record_verdict(state, Prohibited, ["axiom_6.2"])
  let state = drift.record_verdict(state, Prohibited, ["axiom_6.2"])
  let state = drift.record_verdict(state, Flourishing, [])
  let state = drift.record_verdict(state, Flourishing, [])
  let state = drift.record_verdict(state, Flourishing, [])
  let signal = drift.detect_drift(state)
  should.be_some(signal)
  let assert option.Some(s) = signal
  s.signal_type |> should.equal(drift.HighProhibitionRate)
}

// ---------------------------------------------------------------------------
// detect_drift — high constraint rate
// ---------------------------------------------------------------------------

pub fn detect_high_constraint_rate_test() {
  let state = drift.new(10)
  // 3 constrained out of 5 = 60% > 40% threshold
  let state = drift.record_verdict(state, Constrained, ["axiom_6.3"])
  let state = drift.record_verdict(state, Constrained, ["axiom_6.4"])
  let state = drift.record_verdict(state, Constrained, ["axiom_6.3"])
  let state = drift.record_verdict(state, Flourishing, [])
  let state = drift.record_verdict(state, Flourishing, [])
  let signal = drift.detect_drift(state)
  should.be_some(signal)
  let assert option.Some(s) = signal
  s.signal_type |> should.equal(drift.HighConstraintRate)
}

// ---------------------------------------------------------------------------
// detect_drift — repeated axiom
// ---------------------------------------------------------------------------

pub fn detect_repeated_axiom_test() {
  let state = drift.new(20)
  // 3 constrained with same axiom out of 10
  // Constraint rate = 3/10 = 30% < 40% threshold, so doesn't trigger
  // Non-flourishing = 3, and axiom_6.3 appears 3/3 = 100% > 60%
  let state =
    drift.record_verdict(state, Constrained, ["axiom_6.3_moral_priority"])
  let state =
    drift.record_verdict(state, Constrained, ["axiom_6.3_moral_priority"])
  let state =
    drift.record_verdict(state, Constrained, ["axiom_6.3_moral_priority"])
  let state = add_flourishing(state, 7)
  let signal = drift.detect_drift(state)
  should.be_some(signal)
  let assert option.Some(s) = signal
  s.signal_type |> should.equal(drift.RepeatedAxiom)
  s.drifting_axiom |> should.equal(option.Some("axiom_6.3_moral_priority"))
}

// ---------------------------------------------------------------------------
// detect_drift — over-restriction
// ---------------------------------------------------------------------------

pub fn detect_over_restriction_test() {
  let state = drift.new(20)
  // 2 prohibited out of 15 = 13.3% > 10% but < 15%
  let state = drift.record_verdict(state, Prohibited, ["axiom_6.3"])
  let state = drift.record_verdict(state, Prohibited, ["axiom_6.4"])
  let state = add_flourishing(state, 13)
  let signal = drift.detect_drift(state)
  should.be_some(signal)
  let assert option.Some(s) = signal
  s.signal_type |> should.equal(drift.OverRestriction)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn build_state(
  n: Int,
  verdict: types.FlourishingVerdict,
  trail: List(String),
) -> drift.DriftState {
  let state = drift.new(20)
  add_verdicts(state, n, verdict, trail)
}

fn add_verdicts(
  state: drift.DriftState,
  n: Int,
  verdict: types.FlourishingVerdict,
  trail: List(String),
) -> drift.DriftState {
  case n <= 0 {
    True -> state
    False ->
      add_verdicts(
        drift.record_verdict(state, verdict, trail),
        n - 1,
        verdict,
        trail,
      )
  }
}

fn add_flourishing(state: drift.DriftState, n: Int) -> drift.DriftState {
  add_verdicts(state, n, Flourishing, [])
}

import gleam/list
import gleam/option
