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
    modify_threshold: 1.0,
    reject_threshold: 2.0,
  )
}

fn output_state() -> DprimeState {
  dprime_config.initial_state(output_config())
}

fn clean_report_provider() {
  mock.provider_with_text(
    "[{\"feature\": \"unsourced_claims\", \"magnitude\": 0, \"rationale\": \"well sourced\"}, {\"feature\": \"causal_overreach\", \"magnitude\": 0, \"rationale\": \"careful language\"}, {\"feature\": \"stale_data\", \"magnitude\": 0, \"rationale\": \"current\"}]",
  )
}

fn mixed_report_provider() {
  // High issues across multiple features to exceed modify_threshold
  // Score = (3*3 + 2*2 + 1*1) / 18 = 14/18 ≈ 0.78 — need lower threshold
  mock.provider_with_text(
    "[{\"feature\": \"unsourced_claims\", \"magnitude\": 3, \"rationale\": \"several claims lack sources\"}, {\"feature\": \"causal_overreach\", \"magnitude\": 2, \"rationale\": \"some overreach\"}, {\"feature\": \"stale_data\", \"magnitude\": 1, \"rationale\": \"slightly dated\"}]",
  )
}

fn bad_report_provider() {
  mock.provider_with_text(
    "[{\"feature\": \"unsourced_claims\", \"magnitude\": 3, \"rationale\": \"no sources\"}, {\"feature\": \"causal_overreach\", \"magnitude\": 3, \"rationale\": \"wild claims\"}, {\"feature\": \"stale_data\", \"magnitude\": 3, \"rationale\": \"ancient data\"}]",
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
    )
  result.decision |> should.equal(Modify)
  // Score = (3*3 + 2*2 + 1*1) / 9 = 14/9 ≈ 1.556
  // Should be >= modify (1.0) and < reject (2.0)
  { result.dprime_score >=. 1.0 } |> should.be_true()
  { result.dprime_score <. 2.0 } |> should.be_true()
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
    )
  result.decision |> should.equal(Reject)
  { result.dprime_score >=. 2.0 } |> should.be_true()
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
    )
  result.decision |> should.equal(Reject)
  let has_rejected =
    result.explanation
    |> string_contains("Report rejected")
  has_rejected |> should.be_true()
}

// ---------------------------------------------------------------------------
// LLM error fallback — cautious forecasts (magnitude 1)
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
    )
  // Cautious forecasts (magnitude 1 for all 3 features) should produce
  // a low D' score — likely Accept or Modify depending on thresholds
  // With 3 features at magnitude 1, tiers=1:
  // D' = (3*1 + 2*1 + 1*1) / 18 = 6/18 = 0.333...
  // This is below modify_threshold 1.0, so Accept
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
    )
  // Same as LLM error — cautious fallback
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
