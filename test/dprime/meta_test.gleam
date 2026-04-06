// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/config as dprime_config
import dprime/meta
import dprime/types.{
  type DprimeConfig, type DprimeState, AbortMaxIterations, Accept, DprimeConfig,
  DprimeHistoryEntry, DprimeState, GateResult, Modify, NoIntervention, Reactive,
  Reject, Stalled,
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
    allow_adaptation: True,
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

pub fn record_increments_iteration_count_test() {
  let state = test_state()
  let result = test_gate_result(0.5, Modify)
  let new_state = meta.record(state, "cycle-1", result, "2026-03-04T10:00:00Z")
  new_state.iteration_count |> should.equal(1)
}

pub fn record_accept_does_not_increment_iteration_count_test() {
  let state = test_state()
  let result = test_gate_result(0.1, Accept)
  let s1 = meta.record(state, "cycle-1", result, "2026-03-04T10:00:00Z")
  s1.iteration_count |> should.equal(0)
  let s2 = meta.record(s1, "cycle-2", result, "2026-03-04T10:01:00Z")
  s2.iteration_count |> should.equal(0)
  // But Modify still increments
  let modify_result = test_gate_result(0.5, Modify)
  let s3 = meta.record(s2, "cycle-3", modify_result, "2026-03-04T10:02:00Z")
  s3.iteration_count |> should.equal(1)
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
  let assert [h1, h2, h3] = s4.history
  h1.cycle_id |> should.equal("c4")
  h2.cycle_id |> should.equal("c3")
  h3.cycle_id |> should.equal("c2")
}

// ---------------------------------------------------------------------------
// reset_iterations
// ---------------------------------------------------------------------------

pub fn reset_iterations_test() {
  let state = test_state()
  // Use Modify since Accept no longer increments iteration_count
  let r = test_gate_result(0.5, Modify)
  let s1 = meta.record(state, "c1", r, "t1")
  s1.iteration_count |> should.equal(1)
  let s2 = meta.reset_iterations(s1)
  s2.iteration_count |> should.equal(0)
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
      current_modify_threshold: 0.35,
      current_reject_threshold: 0.55,
      iteration_count: 0,
    )
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
      current_modify_threshold: 0.35,
      current_reject_threshold: 0.55,
      iteration_count: 0,
    )
  meta.should_tighten(state) |> should.be_true
}

// ---------------------------------------------------------------------------
// should_intervene
// ---------------------------------------------------------------------------

pub fn should_intervene_none_when_fresh_test() {
  let state = test_state()
  meta.should_intervene(state) |> should.equal(NoIntervention)
}

pub fn should_intervene_abort_when_max_iterations_test() {
  let config = DprimeConfig(..test_config(), max_iterations: 2)
  let state =
    DprimeState(..dprime_config.initial_state(config), iteration_count: 2)
  meta.should_intervene(state) |> should.equal(AbortMaxIterations)
}

pub fn should_intervene_stalled_when_history_high_test() {
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
      current_modify_threshold: 0.35,
      current_reject_threshold: 0.55,
      iteration_count: 1,
    )
  meta.should_intervene(state) |> should.equal(Stalled)
}

// ---------------------------------------------------------------------------
// tighten_thresholds
// ---------------------------------------------------------------------------

pub fn tighten_thresholds_multiplies_by_0_9_test() {
  let state = test_state()
  let tightened = meta.tighten_thresholds(state)
  // 0.35 * 0.9 = 0.315
  let diff_m = case tightened.current_modify_threshold -. 0.315 {
    d if d <. 0.0 -> 0.0 -. d
    d -> d
  }
  let assert True = diff_m <. 0.001
  // 0.55 * 0.9 = 0.495
  let diff_r = case tightened.current_reject_threshold -. 0.495 {
    d if d <. 0.0 -> 0.0 -. d
    d -> d
  }
  let assert True = diff_r <. 0.001
}

pub fn tighten_thresholds_respects_floor_test() {
  let config =
    DprimeConfig(
      ..test_config(),
      min_modify_threshold: 1.0,
      min_reject_threshold: 1.7,
    )
  let state =
    DprimeState(
      ..dprime_config.initial_state(config),
      current_modify_threshold: 1.05,
      current_reject_threshold: 1.75,
    )
  let tightened = meta.tighten_thresholds(state)
  // 1.05 * 0.9 = 0.945 → clamped to floor 1.0
  let assert True = tightened.current_modify_threshold >=. 1.0
  // 1.75 * 0.9 = 1.575 → clamped to floor 1.7 (since 1.575 < 1.7)
  let assert True = tightened.current_reject_threshold >=. 1.7
}

pub fn tighten_thresholds_noop_when_adaptation_disabled_test() {
  let config = DprimeConfig(..test_config(), allow_adaptation: False)
  let state = dprime_config.initial_state(config)
  let original_modify = state.current_modify_threshold
  let original_reject = state.current_reject_threshold
  let tightened = meta.tighten_thresholds(state)
  tightened.current_modify_threshold |> should.equal(original_modify)
  tightened.current_reject_threshold |> should.equal(original_reject)
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
      current_modify_threshold: 0.35,
      current_reject_threshold: 0.55,
      iteration_count: 0,
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
      current_modify_threshold: 0.35,
      current_reject_threshold: 0.55,
      iteration_count: 0,
    )
  meta.maybe_escalate(state, Accept) |> should.equal(Accept)
}

pub fn maybe_escalate_no_change_when_not_stalled_test() {
  let state = test_state()
  meta.maybe_escalate(state, Modify) |> should.equal(Modify)
}
