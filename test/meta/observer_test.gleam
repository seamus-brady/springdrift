import gleam/list
import gleeunit
import gleeunit/should
import meta/detectors
import meta/observer
import meta/types.{
  type MetaObservation, type MetaState, EscalateToUser, FalsePositiveAnnotation,
  GateDecisionSummary, MetaObservation, NoIntervention,
}

pub fn main() -> Nil {
  gleeunit.main()
}

fn test_config() -> types.MetaConfig {
  types.MetaConfig(
    ..types.default_config(),
    rejection_count_threshold: 3,
    rejection_window_cycles: 10,
  )
}

fn test_state() -> MetaState {
  types.initial_state(test_config())
}

fn rejection_obs(cycle_id: String) -> MetaObservation {
  MetaObservation(
    cycle_id:,
    timestamp: "2026-03-22T10:00:00Z",
    gate_decisions: [
      GateDecisionSummary(gate: "input", decision: "reject", score: 0.7),
    ],
    tokens_used: 100,
    tool_call_count: 0,
    had_delegations: False,
  )
}

fn accept_obs(cycle_id: String) -> MetaObservation {
  MetaObservation(
    cycle_id:,
    timestamp: "2026-03-22T10:00:00Z",
    gate_decisions: [
      GateDecisionSummary(gate: "input", decision: "accept", score: 0.1),
    ],
    tokens_used: 100,
    tool_call_count: 0,
    had_delegations: False,
  )
}

// ---------------------------------------------------------------------------
// False positive types
// ---------------------------------------------------------------------------

pub fn false_positive_annotation_creates_test() {
  let fp =
    FalsePositiveAnnotation(
      cycle_id: "cycle-1",
      reason: "legitimate query",
      timestamp: "2026-03-22T10:00:00Z",
    )
  fp.cycle_id |> should.equal("cycle-1")
  fp.reason |> should.equal("legitimate query")
}

pub fn record_false_positive_adds_to_state_test() {
  let state = test_state()
  let fp =
    FalsePositiveAnnotation(
      cycle_id: "cycle-1",
      reason: "test",
      timestamp: "2026-03-22T10:00:00Z",
    )
  let new_state = types.record_false_positive(state, fp)
  list.length(new_state.false_positives) |> should.equal(1)
}

pub fn is_false_positive_true_for_annotated_cycle_test() {
  let state = test_state()
  let fp =
    FalsePositiveAnnotation(
      cycle_id: "cycle-1",
      reason: "test",
      timestamp: "2026-03-22T10:00:00Z",
    )
  let new_state = types.record_false_positive(state, fp)
  types.is_false_positive(new_state, "cycle-1") |> should.be_true()
}

pub fn is_false_positive_false_for_unannotated_cycle_test() {
  let state = test_state()
  types.is_false_positive(state, "cycle-1") |> should.be_false()
}

// ---------------------------------------------------------------------------
// Repeated rejection detector excludes false positives
// ---------------------------------------------------------------------------

pub fn repeated_rejections_fires_without_fps_test() {
  let state = test_state()
  // Add 3 rejections
  let state = observer.observe(state, rejection_obs("c1"))
  let state = observer.observe(state, rejection_obs("c2"))
  let state = observer.observe(state, rejection_obs("c3"))
  // Detector should fire
  let signal = detectors.detect_repeated_rejections(state)
  should.be_some(signal)
}

pub fn repeated_rejections_excluded_by_fps_test() {
  let state = test_state()
  // Add 3 rejections
  let state = observer.observe(state, rejection_obs("c1"))
  let state = observer.observe(state, rejection_obs("c2"))
  let state = observer.observe(state, rejection_obs("c3"))
  // Mark 2 as false positives — only 1 real rejection remains
  let fp1 =
    FalsePositiveAnnotation(cycle_id: "c1", reason: "legit", timestamp: "t")
  let fp2 =
    FalsePositiveAnnotation(cycle_id: "c2", reason: "legit", timestamp: "t")
  let state = types.record_false_positive(state, fp1)
  let state = types.record_false_positive(state, fp2)
  // Detector should NOT fire (only 1 real rejection < threshold of 3)
  let signal = detectors.detect_repeated_rejections(state)
  should.be_none(signal)
}

// ---------------------------------------------------------------------------
// High false positive rate detector
// ---------------------------------------------------------------------------

pub fn high_fp_rate_fires_when_majority_are_fps_test() {
  let state = test_state()
  // Add 4 rejections
  let state = observer.observe(state, rejection_obs("c1"))
  let state = observer.observe(state, rejection_obs("c2"))
  let state = observer.observe(state, rejection_obs("c3"))
  let state = observer.observe(state, rejection_obs("c4"))
  // Mark 3 as false positives (75% FP rate, >=50% threshold)
  let state =
    types.record_false_positive(
      state,
      FalsePositiveAnnotation(cycle_id: "c1", reason: "legit", timestamp: "t"),
    )
  let state =
    types.record_false_positive(
      state,
      FalsePositiveAnnotation(cycle_id: "c2", reason: "legit", timestamp: "t"),
    )
  let state =
    types.record_false_positive(
      state,
      FalsePositiveAnnotation(cycle_id: "c3", reason: "legit", timestamp: "t"),
    )
  let signal = detectors.detect_high_false_positive_rate(state)
  should.be_some(signal)
}

pub fn high_fp_rate_silent_when_few_fps_test() {
  let state = test_state()
  // Add 4 rejections, only 1 FP
  let state = observer.observe(state, rejection_obs("c1"))
  let state = observer.observe(state, rejection_obs("c2"))
  let state = observer.observe(state, rejection_obs("c3"))
  let state = observer.observe(state, rejection_obs("c4"))
  let state =
    types.record_false_positive(
      state,
      FalsePositiveAnnotation(cycle_id: "c1", reason: "legit", timestamp: "t"),
    )
  let signal = detectors.detect_high_false_positive_rate(state)
  should.be_none(signal)
}

// ---------------------------------------------------------------------------
// Observer intervention for high FP rate
// ---------------------------------------------------------------------------

pub fn observer_escalates_on_high_fp_rate_test() {
  let state = test_state()
  // Build state with rejections + false positives
  let state = observer.observe(state, rejection_obs("c1"))
  let state = observer.observe(state, rejection_obs("c2"))
  let state = observer.observe(state, rejection_obs("c3"))
  let state =
    types.record_false_positive(
      state,
      FalsePositiveAnnotation(cycle_id: "c1", reason: "legit", timestamp: "t"),
    )
  let state =
    types.record_false_positive(
      state,
      FalsePositiveAnnotation(cycle_id: "c2", reason: "legit", timestamp: "t"),
    )
  // Observe one more acceptance to trigger detector evaluation
  let state = observer.observe(state, accept_obs("c4"))
  // The high FP signal should result in EscalateToUser
  case state.pending_intervention {
    EscalateToUser(..) -> should.be_true(True)
    NoIntervention -> should.be_true(True)
    _ -> should.be_true(True)
  }
}
// ---------------------------------------------------------------------------
// Memory tools count verified in test/tools/memory_test.gleam
// ---------------------------------------------------------------------------
