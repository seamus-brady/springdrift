import dprime/scorer
import dprime/types.{Feature, High, Low, Medium}
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import llm/adapters/mock

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// build_scoring_prompt
// ---------------------------------------------------------------------------

pub fn build_scoring_prompt_includes_instruction_test() {
  let features = [
    Feature(
      name: "safety",
      importance: High,
      description: "User safety",
      critical: True,
    ),
  ]
  let prompt = scorer.build_scoring_prompt("delete all files", "", features)
  string.contains(prompt, "delete all files") |> should.be_true
}

pub fn build_scoring_prompt_includes_features_test() {
  let features = [
    Feature(
      name: "safety",
      importance: High,
      description: "User safety",
      critical: True,
    ),
    Feature(
      name: "accuracy",
      importance: Medium,
      description: "Factual correctness",
      critical: False,
    ),
  ]
  let prompt = scorer.build_scoring_prompt("test", "", features)
  string.contains(prompt, "safety") |> should.be_true
  string.contains(prompt, "accuracy") |> should.be_true
}

pub fn build_scoring_prompt_includes_context_when_present_test() {
  let features = [
    Feature(
      name: "safety",
      importance: High,
      description: "User safety",
      critical: True,
    ),
  ]
  let prompt =
    scorer.build_scoring_prompt("test", "some context here", features)
  string.contains(prompt, "some context here") |> should.be_true
}

pub fn build_scoring_prompt_omits_context_when_empty_test() {
  let features = [
    Feature(
      name: "safety",
      importance: High,
      description: "User safety",
      critical: True,
    ),
  ]
  let prompt = scorer.build_scoring_prompt("test", "", features)
  string.contains(prompt, "Context:") |> should.be_false
}

// ---------------------------------------------------------------------------
// parse_forecasts
// ---------------------------------------------------------------------------

pub fn parse_forecasts_valid_json_test() {
  let json =
    "[{\"feature\": \"safety\", \"magnitude\": 2, \"rationale\": \"could harm data\"}]"
  let result = scorer.parse_forecasts(json)
  result |> should.be_ok
  let assert Ok(forecasts) = result
  list.length(forecasts) |> should.equal(1)
  let assert [f] = forecasts
  f.feature_name |> should.equal("safety")
  f.magnitude |> should.equal(2)
}

pub fn parse_forecasts_with_markdown_fences_test() {
  let json =
    "```json\n[{\"feature\": \"safety\", \"magnitude\": 1, \"rationale\": \"ok\"}]\n```"
  let result = scorer.parse_forecasts(json)
  result |> should.be_ok
  let assert Ok(forecasts) = result
  list.length(forecasts) |> should.equal(1)
}

pub fn parse_forecasts_clamps_magnitude_test() {
  let json =
    "[{\"feature\": \"safety\", \"magnitude\": 5, \"rationale\": \"high\"}]"
  let result = scorer.parse_forecasts(json)
  result |> should.be_ok
  let assert Ok([f]) = result
  f.magnitude |> should.equal(3)
}

pub fn parse_forecasts_clamps_negative_test() {
  let json =
    "[{\"feature\": \"safety\", \"magnitude\": -1, \"rationale\": \"neg\"}]"
  let result = scorer.parse_forecasts(json)
  result |> should.be_ok
  let assert Ok([f]) = result
  f.magnitude |> should.equal(0)
}

pub fn parse_forecasts_invalid_json_test() {
  scorer.parse_forecasts("not json at all") |> should.be_error
}

pub fn parse_forecasts_empty_array_test() {
  let result = scorer.parse_forecasts("[]")
  result |> should.be_ok
  let assert Ok(forecasts) = result
  list.length(forecasts) |> should.equal(0)
}

pub fn parse_forecasts_multiple_features_test() {
  let json =
    "[{\"feature\": \"safety\", \"magnitude\": 2, \"rationale\": \"a\"}, {\"feature\": \"accuracy\", \"magnitude\": 0, \"rationale\": \"b\"}]"
  let result = scorer.parse_forecasts(json)
  result |> should.be_ok
  let assert Ok(forecasts) = result
  list.length(forecasts) |> should.equal(2)
}

// ---------------------------------------------------------------------------
// default_forecasts
// ---------------------------------------------------------------------------

pub fn default_forecasts_all_zero_test() {
  let features = [
    Feature(name: "safety", importance: High, description: "", critical: True),
    Feature(name: "scope", importance: Low, description: "", critical: False),
  ]
  let forecasts = scorer.default_forecasts(features)
  list.length(forecasts) |> should.equal(2)
  list.all(forecasts, fn(f) { f.magnitude == 0 }) |> should.be_true
}

// ---------------------------------------------------------------------------
// score_features — mock provider integration
// ---------------------------------------------------------------------------

pub fn score_features_with_mock_provider_test() {
  let features = [
    Feature(
      name: "safety",
      importance: High,
      description: "User safety",
      critical: True,
    ),
  ]
  let json_response =
    "[{\"feature\": \"safety\", \"magnitude\": 1, \"rationale\": \"minor concern\"}]"
  let provider = mock.provider_with_text(json_response)
  let forecasts =
    scorer.score_features(
      "test instruction",
      "",
      features,
      provider,
      "mock-model",
    )
  list.length(forecasts) |> should.equal(1)
  let assert [f] = forecasts
  f.feature_name |> should.equal("safety")
  f.magnitude |> should.equal(1)
}

pub fn score_features_falls_back_on_error_test() {
  let features = [
    Feature(
      name: "safety",
      importance: High,
      description: "User safety",
      critical: True,
    ),
  ]
  let provider = mock.provider_with_error("API down")
  let forecasts =
    scorer.score_features("test", "", features, provider, "mock-model")
  list.length(forecasts) |> should.equal(1)
  let assert [f] = forecasts
  f.magnitude |> should.equal(0)
}

pub fn score_features_falls_back_on_invalid_response_test() {
  let features = [
    Feature(
      name: "safety",
      importance: High,
      description: "User safety",
      critical: True,
    ),
  ]
  let provider = mock.provider_with_text("I can't evaluate that")
  let forecasts =
    scorer.score_features("test", "", features, provider, "mock-model")
  list.length(forecasts) |> should.equal(1)
  list.all(forecasts, fn(f) { f.magnitude == 0 }) |> should.be_true
}
