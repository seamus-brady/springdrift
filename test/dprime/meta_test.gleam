import dprime/config as dprime_config
import dprime/meta
import dprime/types.{
  type DprimeConfig, type DprimeState, Accept, DprimeConfig, DprimeHistoryEntry,
  DprimeState, GateResult, Modify, Reactive, Reject,
}
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

fn test_config() -> DprimeConfig {
  DprimeConfig(
    ..dprime_config.default(),
    max_history: 10,
    stall_window: 3,
    stall_threshold: 0.25,
  )
}

fn test_state() -> DprimeState {
  dprime_config.initial_state(test_config())
}

fn test_gate_result(
  score: Float,
  decision: types.GateDecision,
) -> types.GateResult {
  GateResult(
    decision:,
    dprime_score: score,
    forecasts: [],
    explanation: "test",
    layer: Reactive,
    canary_result: None,
  )
}

// ---------------------------------------------------------------------------
// record
// ---------------------------------------------------------------------------

pub fn record_adds_entry_to_history_test() {
  let state = test_state()
  let result = test_gate_result(0.5, Modify)
  let new_state = meta.record(state, "cycle-1", result, "2026-03-04T10:00:00Z")
  list.length(new_state.history) |> should.equal(1)
}

pub fn record_prepends_newest_first_test() {
  let state = test_state()
  let r1 = test_gate_result(0.1, Accept)
  let r2 = test_gate_result(0.5, Modify)
  let s1 = meta.record(state, "cycle-1", r1, "2026-03-04T10:00:00Z")
  let s2 = meta.record(s1, "cycle-2", r2, "2026-03-04T10:01:00Z")
  let assert [first, ..] = s2.history
  first.cycle_id |> should.equal("cycle-2")
  first.score |> should.equal(0.5)
}

pub fn record_trims_to_max_history_test() {
  let config = DprimeConfig(..test_config(), max_history: 3)
  let state = dprime_config.initial_state(config)
  let r = test_gate_result(0.1, Accept)
  let s1 = meta.record(state, "c1", r, "t1")
  let s2 = meta.record(s1, "c2", r, "t2")
  let s3 = meta.record(s2, "c3", r, "t3")
  let s4 = meta.record(s3, "c4", r, "t4")
  list.length(s4.history) |> should.equal(3)
  // Oldest entry (c1) should be dropped
  let assert [h1, h2, h3] = s4.history
  h1.cycle_id |> should.equal("c4")
  h2.cycle_id |> should.equal("c3")
  h3.cycle_id |> should.equal("c2")
}

// ---------------------------------------------------------------------------
// should_tighten
// ---------------------------------------------------------------------------

pub fn should_tighten_false_when_not_enough_history_test() {
  let state = test_state()
  meta.should_tighten(state) |> should.be_false
}

pub fn should_tighten_false_when_scores_low_test() {
  let config = test_config()
  let state =
    DprimeState(
      config:,
      history: [
        DprimeHistoryEntry(
          cycle_id: "c1",
          score: 0.1,
          decision: Accept,
          timestamp: "t1",
        ),
        DprimeHistoryEntry(
          cycle_id: "c2",
          score: 0.1,
          decision: Accept,
          timestamp: "t2",
        ),
        DprimeHistoryEntry(
          cycle_id: "c3",
          score: 0.1,
          decision: Accept,
          timestamp: "t3",
        ),
      ],
      current_modify_threshold: 0.3,
      current_reject_threshold: 0.7,
    )
  // Average = 0.1 < 0.25 stall_threshold
  meta.should_tighten(state) |> should.be_false
}

pub fn should_tighten_true_when_scores_high_test() {
  let config = test_config()
  let state =
    DprimeState(
      config:,
      history: [
        DprimeHistoryEntry(
          cycle_id: "c1",
          score: 0.3,
          decision: Modify,
          timestamp: "t1",
        ),
        DprimeHistoryEntry(
          cycle_id: "c2",
          score: 0.3,
          decision: Modify,
          timestamp: "t2",
        ),
        DprimeHistoryEntry(
          cycle_id: "c3",
          score: 0.3,
          decision: Modify,
          timestamp: "t3",
        ),
      ],
      current_modify_threshold: 0.3,
      current_reject_threshold: 0.7,
    )
  // Average = 0.3 >= 0.25 stall_threshold
  meta.should_tighten(state) |> should.be_true
}

// ---------------------------------------------------------------------------
// tighten_thresholds
// ---------------------------------------------------------------------------

pub fn tighten_thresholds_multiplies_by_0_9_test() {
  let state = test_state()
  let tightened = meta.tighten_thresholds(state)
  // 0.3 * 0.9 = 0.27
  let diff_m = case tightened.current_modify_threshold -. 0.27 {
    d if d <. 0.0 -> 0.0 -. d
    d -> d
  }
  let assert True = diff_m <. 0.001
  // 0.7 * 0.9 = 0.63
  let diff_r = case tightened.current_reject_threshold -. 0.63 {
    d if d <. 0.0 -> 0.0 -. d
    d -> d
  }
  let assert True = diff_r <. 0.001
}

// ---------------------------------------------------------------------------
// maybe_escalate
// ---------------------------------------------------------------------------

pub fn maybe_escalate_modify_to_reject_when_stalled_test() {
  let config = test_config()
  let state =
    DprimeState(
      config:,
      history: [
        DprimeHistoryEntry(
          cycle_id: "c1",
          score: 0.5,
          decision: Modify,
          timestamp: "t1",
        ),
        DprimeHistoryEntry(
          cycle_id: "c2",
          score: 0.5,
          decision: Modify,
          timestamp: "t2",
        ),
        DprimeHistoryEntry(
          cycle_id: "c3",
          score: 0.5,
          decision: Modify,
          timestamp: "t3",
        ),
      ],
      current_modify_threshold: 0.3,
      current_reject_threshold: 0.7,
    )
  meta.maybe_escalate(state, Modify) |> should.equal(Reject)
}

pub fn maybe_escalate_accept_unchanged_when_stalled_test() {
  let config = test_config()
  let state =
    DprimeState(
      config:,
      history: [
        DprimeHistoryEntry(
          cycle_id: "c1",
          score: 0.5,
          decision: Modify,
          timestamp: "t1",
        ),
        DprimeHistoryEntry(
          cycle_id: "c2",
          score: 0.5,
          decision: Modify,
          timestamp: "t2",
        ),
        DprimeHistoryEntry(
          cycle_id: "c3",
          score: 0.5,
          decision: Modify,
          timestamp: "t3",
        ),
      ],
      current_modify_threshold: 0.3,
      current_reject_threshold: 0.7,
    )
  meta.maybe_escalate(state, Accept) |> should.equal(Accept)
}

pub fn maybe_escalate_no_change_when_not_stalled_test() {
  let state = test_state()
  meta.maybe_escalate(state, Modify) |> should.equal(Modify)
}
