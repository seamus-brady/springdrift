import dprime/config as dprime_config
import dprime/deliberative
import dprime/types.{Accept, Candidate, DprimeConfig}
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import llm/adapters/mock

pub fn main() -> Nil {
  gleeunit.main()
}

fn test_state() {
  let config = DprimeConfig(..dprime_config.default(), canary_enabled: False)
  dprime_config.initial_state(config)
}

// ---------------------------------------------------------------------------
// candidate_count
// ---------------------------------------------------------------------------

pub fn candidate_count_below_modify_test() {
  let config = dprime_config.default()
  // Below modify threshold (1.2) → 1 candidate
  deliberative.candidate_count(0.5, config) |> should.equal(1)
}

pub fn candidate_count_above_modify_test() {
  let config = dprime_config.default()
  // Above modify threshold (1.2) → min(3, max_candidates)
  deliberative.candidate_count(1.5, config) |> should.equal(3)
}

// ---------------------------------------------------------------------------
// build_situation_model
// ---------------------------------------------------------------------------

pub fn build_situation_model_returns_text_test() {
  let provider = mock.provider_with_text("User wants X. Context: Y.")
  let result =
    deliberative.build_situation_model(
      "test instruction",
      "some context",
      provider,
      "mock",
      "test-cycle",
      False,
    )
  let assert True = result != ""
}

pub fn build_situation_model_fallback_on_error_test() {
  let provider = mock.provider_with_error("API down")
  let result =
    deliberative.build_situation_model(
      "test instruction",
      "",
      provider,
      "mock",
      "test-cycle",
      False,
    )
  // Falls back to instruction
  result |> should.equal("test instruction")
}

// ---------------------------------------------------------------------------
// generate_candidates
// ---------------------------------------------------------------------------

pub fn generate_candidates_parses_json_test() {
  let json =
    "[{\"description\": \"Approach A\", \"projected_outcome\": \"Good\"}, {\"description\": \"Approach B\", \"projected_outcome\": \"OK\"}]"
  let provider = mock.provider_with_text(json)
  let candidates =
    deliberative.generate_candidates(
      "situation model",
      2,
      provider,
      "mock",
      "test-cycle",
      False,
    )
  list.length(candidates) |> should.equal(2)
}

pub fn generate_candidates_fallback_on_error_test() {
  let provider = mock.provider_with_error("API down")
  let candidates =
    deliberative.generate_candidates(
      "situation model",
      2,
      provider,
      "mock",
      "test-cycle",
      False,
    )
  // Falls back to single candidate from situation model
  list.length(candidates) |> should.equal(1)
}

pub fn generate_candidates_fallback_on_invalid_json_test() {
  let provider = mock.provider_with_text("not valid json")
  let candidates =
    deliberative.generate_candidates(
      "my situation",
      2,
      provider,
      "mock",
      "test-cycle",
      False,
    )
  list.length(candidates) |> should.equal(1)
  let assert [c] = candidates
  c.description |> should.equal("my situation")
}

// ---------------------------------------------------------------------------
// evaluate_candidates
// ---------------------------------------------------------------------------

pub fn evaluate_candidates_selects_lowest_dprime_test() {
  // Provider returns all-zero for any scoring call → D' = 0 → Accept
  let provider =
    mock.provider_with_text(
      "[{\"feature\": \"user_safety\", \"magnitude\": 0, \"rationale\": \"safe\"}]",
    )
  let state = test_state()
  let candidates = [
    Candidate(description: "Safe approach", projected_outcome: "Good"),
  ]
  let result =
    deliberative.evaluate_candidates(
      candidates,
      state,
      None,
      provider,
      "mock",
      "test-cycle",
      False,
    )
  result.decision |> should.equal(Accept)
}

// ---------------------------------------------------------------------------
// post_execution_check
// ---------------------------------------------------------------------------

pub fn post_execution_check_safe_result_test() {
  let provider =
    mock.provider_with_text(
      "[{\"feature\": \"user_safety\", \"magnitude\": 0, \"rationale\": \"safe\"}]",
    )
  let state = test_state()
  let result =
    deliberative.post_execution_check(
      "All went well",
      "original instruction",
      state,
      provider,
      "mock",
      "test-cycle",
      False,
    )
  result.decision |> should.equal(Accept)
}

// ---------------------------------------------------------------------------
// explain_modification
// ---------------------------------------------------------------------------

pub fn explain_modification_no_concerns_test() {
  let features = dprime_config.default().features
  let forecasts =
    list.map(features, fn(f) {
      types.Forecast(feature_name: f.name, magnitude: 0, rationale: "fine")
    })
  let provider = mock.provider_with_text("explanation text")
  let result =
    deliberative.explain_modification(
      forecasts,
      features,
      provider,
      "mock",
      "test-cycle",
      False,
    )
  result |> should.equal("No specific concerns identified")
}

pub fn explain_modification_with_concerns_test() {
  let features = dprime_config.default().features
  let forecasts = [
    types.Forecast(
      feature_name: "user_safety",
      magnitude: 2,
      rationale: "could harm",
    ),
    types.Forecast(feature_name: "accuracy", magnitude: 0, rationale: "fine"),
  ]
  let provider = mock.provider_with_text("Please be careful about safety")
  let result =
    deliberative.explain_modification(
      forecasts,
      features,
      provider,
      "mock",
      "test-cycle",
      False,
    )
  let assert True = result != ""
}
