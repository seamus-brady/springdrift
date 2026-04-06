// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/config as dprime_config
import dprime/output_gate
import dprime/types.{
  type DprimeConfig, type DprimeState, type Feature, Accept, DprimeConfig,
  Feature, High, Low, Medium, Modify, Reject,
}
import gleam/option.{None}
import gleeunit
import gleeunit/should
import llm/adapters/mock

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn output_features() -> List(Feature) {
  [
    Feature(
      name: "unsourced_claims",
      importance: High,
      description: "Claims made without evidence or source attribution",
      critical: True,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    Feature(
      name: "causal_overreach",
      importance: Medium,
      description: "Unjustified causal claims",
      critical: False,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    Feature(
      name: "stale_data",
      importance: Low,
      description: "Using outdated information",
      critical: False,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
  ]
}

fn output_config() -> DprimeConfig {
  DprimeConfig(
    ..dprime_config.default(),
    features: output_features(),
    canary_enabled: False,
    modify_threshold: 0.4,
    reject_threshold: 0.8,
  )
}

fn output_state() -> DprimeState {
  dprime_config.initial_state(output_config())
}

fn clean_report_provider() {
  mock.provider_with_text(
    "<forecasts><forecast><feature>unsourced_claims</feature><magnitude>0</magnitude><rationale>well sourced</rationale></forecast><forecast><feature>causal_overreach</feature><magnitude>0</magnitude><rationale>careful language</rationale></forecast><forecast><feature>stale_data</feature><magnitude>0</magnitude><rationale>current</rationale></forecast></forecasts>",
  )
}

fn mixed_report_provider() {
  // High issues across multiple features to exceed modify_threshold
  mock.provider_with_text(
    "<forecasts><forecast><feature>unsourced_claims</feature><magnitude>3</magnitude><rationale>several claims lack sources</rationale></forecast><forecast><feature>causal_overreach</feature><magnitude>2</magnitude><rationale>some overreach</rationale></forecast><forecast><feature>stale_data</feature><magnitude>1</magnitude><rationale>slightly dated</rationale></forecast></forecasts>",
  )
}

fn bad_report_provider() {
  mock.provider_with_text(
    "<forecasts><forecast><feature>unsourced_claims</feature><magnitude>3</magnitude><rationale>no sources</rationale></forecast><forecast><feature>causal_overreach</feature><magnitude>3</magnitude><rationale>wild claims</rationale></forecast><forecast><feature>stale_data</feature><magnitude>3</magnitude><rationale>ancient data</rationale></forecast></forecasts>",
  )
}

// ---------------------------------------------------------------------------
// Accept path — clean report
// ---------------------------------------------------------------------------

pub fn accept_clean_report_test() {
  let state = output_state()
  let provider = clean_report_provider()
  let result =
    output_gate.evaluate(
      "A well-sourced report with citations.",
      "What is the weather?",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  result.decision |> should.equal(Accept)
  result.dprime_score |> should.equal(0.0)
  result.explanation |> should.equal("Output quality acceptable")
}

// ---------------------------------------------------------------------------
// Modify path — moderate issues
// ---------------------------------------------------------------------------

pub fn modify_on_moderate_issues_test() {
  let state = output_state()
  let provider = mixed_report_provider()
  let result =
    output_gate.evaluate(
      "A report with some unsourced claims.",
      "Summarize recent findings",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  result.decision |> should.equal(Modify)
  // Score = (3*3 + 2*2 + 1*1) / 18 = 14/18 ≈ 0.778
  // Should be >= modify (0.4) and < reject (0.8)
  { result.dprime_score >=. 0.4 } |> should.be_true()
  { result.dprime_score <. 0.8 } |> should.be_true()
}

pub fn modify_explanation_mentions_concerns_test() {
  let state = output_state()
  let provider = mixed_report_provider()
  let result =
    output_gate.evaluate(
      "report text",
      "query",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  result.decision |> should.equal(Modify)
  // Explanation should reference the flagged feature (magnitude >= 2)
  let has_quality_issues =
    result.explanation
    |> string_contains("Quality issues")
  has_quality_issues |> should.be_true()
}

// ---------------------------------------------------------------------------
// Reject path — severe issues
// ---------------------------------------------------------------------------

pub fn reject_on_severe_issues_test() {
  let state = output_state()
  let provider = bad_report_provider()
  let result =
    output_gate.evaluate(
      "Terrible report",
      "Important question",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  result.decision |> should.equal(Reject)
  { result.dprime_score >=. 0.8 } |> should.be_true()
}

pub fn reject_explanation_mentions_concerns_test() {
  let state = output_state()
  let provider = bad_report_provider()
  let result =
    output_gate.evaluate(
      "Terrible report",
      "query",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  result.decision |> should.equal(Reject)
  let has_rejected =
    result.explanation
    |> string_contains("Report rejected")
  has_rejected |> should.be_true()
}

// ---------------------------------------------------------------------------
// LLM error fallback — cautious forecasts (magnitude 0, fail-open)
// ---------------------------------------------------------------------------

pub fn llm_error_uses_cautious_fallback_test() {
  let state = output_state()
  let provider = mock.provider_with_error("API down")
  let result =
    output_gate.evaluate(
      "Some report",
      "query",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  // Fail-open: cautious forecasts default all magnitudes to 0.
  // D' = 0.0, below modify_threshold 0.4 → Accept
  result.decision |> should.equal(Accept)
}

pub fn parse_error_uses_cautious_fallback_test() {
  let state = output_state()
  let provider = mock.provider_with_text("this is not json at all")
  let result =
    output_gate.evaluate(
      "Some report",
      "query",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  // Fail-open: cautious fallback defaults all magnitudes to 0, D' = 0.0 → Accept
  result.decision |> should.equal(Accept)
}

// ---------------------------------------------------------------------------
// Result has correct layer
// ---------------------------------------------------------------------------

pub fn result_layer_is_deliberative_test() {
  let state = output_state()
  let provider = clean_report_provider()
  let result =
    output_gate.evaluate(
      "report",
      "query",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  result.layer |> should.equal(types.Deliberative)
}

// ---------------------------------------------------------------------------
// Canary result is None (output gate doesn't run canary)
// ---------------------------------------------------------------------------

pub fn no_canary_in_output_gate_test() {
  let state = output_state()
  let provider = clean_report_provider()
  let result =
    output_gate.evaluate(
      "report",
      "query",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  result.canary_result |> should.be_none()
}

// ---------------------------------------------------------------------------
// Forecasts are populated
// ---------------------------------------------------------------------------

pub fn forecasts_populated_test() {
  let state = output_state()
  let provider = clean_report_provider()
  let result =
    output_gate.evaluate(
      "report",
      "query",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
      False,
    )
  // Should have forecasts for all 3 features
  list.length(result.forecasts) |> should.equal(3)
}

// ---------------------------------------------------------------------------
// Custom thresholds respected
// ---------------------------------------------------------------------------

pub fn custom_thresholds_respected_test() {
  // Set very low thresholds so even mild issues trigger reject
  let config =
    DprimeConfig(
      ..output_config(),
      modify_threshold: 0.1,
      reject_threshold: 0.2,
    )
  let state = dprime_config.initial_state(config)
  let provider = mixed_report_provider()
  let result =
    output_gate.evaluate(
      "report",
      "query",
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
// Helpers
// ---------------------------------------------------------------------------

import gleam/list
import gleam/string

fn string_contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}
