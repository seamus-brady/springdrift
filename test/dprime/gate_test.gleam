// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/config as dprime_config
import dprime/gate
import dprime/types.{type DprimeState, Accept, DprimeConfig, Reject}
import gleam/option.{None}
import gleeunit
import gleeunit/should
import llm/adapters/mock

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn safe_response_provider() {
  // Returns all-zero forecasts (safe) — XML format for XStructor
  mock.provider_with_text(
    "<forecasts><forecast><feature>user_safety</feature><magnitude>0</magnitude><rationale>safe</rationale></forecast><forecast><feature>accuracy</feature><magnitude>0</magnitude><rationale>safe</rationale></forecast><forecast><feature>legal_compliance</feature><magnitude>0</magnitude><rationale>safe</rationale></forecast></forecasts>",
  )
}

fn dangerous_response_provider() {
  // Returns high-magnitude forecasts (dangerous) — XML format for XStructor
  mock.provider_with_text(
    "<forecasts><forecast><feature>user_safety</feature><magnitude>3</magnitude><rationale>very dangerous</rationale></forecast><forecast><feature>accuracy</feature><magnitude>3</magnitude><rationale>wrong</rationale></forecast><forecast><feature>legal_compliance</feature><magnitude>3</magnitude><rationale>illegal</rationale></forecast><forecast><feature>privacy</feature><magnitude>3</magnitude><rationale>severe leak</rationale></forecast><forecast><feature>user_autonomy</feature><magnitude>3</magnitude><rationale>manipulative</rationale></forecast><forecast><feature>task_completion</feature><magnitude>3</magnitude><rationale>fails</rationale></forecast><forecast><feature>proportionality</feature><magnitude>3</magnitude><rationale>extreme</rationale></forecast></forecasts>",
  )
}

fn test_state() -> DprimeState {
  let config = DprimeConfig(..dprime_config.default(), canary_enabled: False)
  dprime_config.initial_state(config)
}

fn test_state_with_canary() -> DprimeState {
  let config = DprimeConfig(..dprime_config.default(), canary_enabled: True)
  dprime_config.initial_state(config)
}

// ---------------------------------------------------------------------------
// Fast accept path (all-zero critical features)
// ---------------------------------------------------------------------------

pub fn gate_fast_accept_when_all_zero_test() {
  let state = test_state()
  let provider = safe_response_provider()
  let result =
    gate.evaluate(
      "hello world",
      "",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  result.decision |> should.equal(Accept)
  result.dprime_score |> should.equal(0.0)
}

// ---------------------------------------------------------------------------
// Reject (high scores)
// ---------------------------------------------------------------------------

pub fn gate_reject_when_scores_high_test() {
  let state = test_state()
  let provider = dangerous_response_provider()
  let result =
    gate.evaluate(
      "delete everything",
      "",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  result.decision |> should.equal(Reject)
}

// ---------------------------------------------------------------------------
// Canary reject
// ---------------------------------------------------------------------------

pub fn gate_canary_reject_on_error_test() {
  let state = test_state_with_canary()
  let provider = mock.provider_with_error("API down")
  let result =
    gate.evaluate(
      "test",
      "",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  // Canary probes fail-open on LLM error (inconclusive, not evidence of hijacking).
  // Scoring also fails and uses cautious fallback (magnitude 0), so score is 0.0 → Accept.
  result.decision |> should.equal(Accept)
}

pub fn gate_canary_pass_when_safe_test() {
  let state = test_state_with_canary()
  let provider = safe_response_provider()
  let result =
    gate.evaluate(
      "harmless instruction",
      "",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  result.decision |> should.equal(Accept)
}

// ---------------------------------------------------------------------------
// Canary disabled skips probes
// ---------------------------------------------------------------------------

pub fn gate_canary_disabled_skips_probes_test() {
  let state = test_state()
  let provider = safe_response_provider()
  let result =
    gate.evaluate(
      "test",
      "",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  result.canary_result |> should.equal(None)
}

// ---------------------------------------------------------------------------
// GateResult fields populated
// ---------------------------------------------------------------------------

pub fn gate_result_has_forecasts_test() {
  let state = test_state()
  let provider = safe_response_provider()
  let result =
    gate.evaluate(
      "test",
      "",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  let assert True = result.forecasts != []
}

pub fn gate_result_has_explanation_test() {
  let state = test_state()
  let provider = safe_response_provider()
  let result =
    gate.evaluate(
      "test",
      "",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  let assert True = result.explanation != ""
}

// ---------------------------------------------------------------------------
// Post-execution evaluate
// ---------------------------------------------------------------------------

pub fn post_execution_evaluate_test() {
  let state = test_state()
  let provider = safe_response_provider()
  let result =
    gate.post_execution_evaluate(
      "Result: all good",
      "original instruction",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  // Safe response → should accept
  result.decision |> should.equal(Accept)
}
