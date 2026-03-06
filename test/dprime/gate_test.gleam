import dprime/config as dprime_config
import dprime/gate
import dprime/types.{type DprimeState, Accept, DprimeConfig, Reactive, Reject}
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
  // Returns all-zero forecasts (safe)
  mock.provider_with_text(
    "[{\"feature\": \"user_safety\", \"magnitude\": 0, \"rationale\": \"safe\"}, {\"feature\": \"accuracy\", \"magnitude\": 0, \"rationale\": \"safe\"}, {\"feature\": \"legal_compliance\", \"magnitude\": 0, \"rationale\": \"safe\"}]",
  )
}

fn dangerous_response_provider() {
  // Returns high-magnitude forecasts (dangerous)
  mock.provider_with_text(
    "[{\"feature\": \"user_safety\", \"magnitude\": 3, \"rationale\": \"very dangerous\"}, {\"feature\": \"accuracy\", \"magnitude\": 3, \"rationale\": \"wrong\"}, {\"feature\": \"legal_compliance\", \"magnitude\": 3, \"rationale\": \"illegal\"}, {\"feature\": \"privacy\", \"magnitude\": 3, \"rationale\": \"severe leak\"}, {\"feature\": \"user_autonomy\", \"magnitude\": 3, \"rationale\": \"manipulative\"}, {\"feature\": \"task_completion\", \"magnitude\": 3, \"rationale\": \"fails\"}, {\"feature\": \"proportionality\", \"magnitude\": 3, \"rationale\": \"extreme\"}]",
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
    gate.evaluate("test", "", state, provider, "mock", "test-cycle", False)
  result.decision |> should.equal(Reject)
  result.layer |> should.equal(Reactive)
  result.canary_result |> should.not_equal(None)
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
    gate.evaluate("test", "", state, provider, "mock", "test-cycle", False)
  result.canary_result |> should.equal(None)
}

// ---------------------------------------------------------------------------
// GateResult fields populated
// ---------------------------------------------------------------------------

pub fn gate_result_has_forecasts_test() {
  let state = test_state()
  let provider = safe_response_provider()
  let result =
    gate.evaluate("test", "", state, provider, "mock", "test-cycle", False)
  let assert True = result.forecasts != []
}

pub fn gate_result_has_explanation_test() {
  let state = test_state()
  let provider = safe_response_provider()
  let result =
    gate.evaluate("test", "", state, provider, "mock", "test-cycle", False)
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
    )
  // Safe response → should accept
  result.decision |> should.equal(Accept)
}
