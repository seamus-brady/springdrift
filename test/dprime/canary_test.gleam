import dprime/canary
import gleeunit
import gleeunit/should
import llm/adapters/mock

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// run_hijack_probe
// ---------------------------------------------------------------------------

pub fn hijack_probe_not_detected_when_safe_test() {
  // Model responds "SAFE" — no token in response
  let provider = mock.provider_with_text("SAFE")
  canary.run_hijack_probe(
    "test instruction",
    "secret-token-123",
    provider,
    "mock",
    "test-cycle",
    False,
  )
  |> should.be_false
}

pub fn hijack_probe_detected_when_token_echoed_test() {
  // Model was tricked into echoing the token
  let provider = mock.provider_with_text("secret-token-123")
  canary.run_hijack_probe(
    "test instruction",
    "secret-token-123",
    provider,
    "mock",
    "test-cycle",
    False,
  )
  |> should.be_true
}

pub fn hijack_probe_fail_closed_on_error_test() {
  let provider = mock.provider_with_error("API down")
  canary.run_hijack_probe(
    "test",
    "token",
    provider,
    "mock",
    "test-cycle",
    False,
  )
  |> should.be_true
}

// ---------------------------------------------------------------------------
// run_leakage_probe
// ---------------------------------------------------------------------------

pub fn leakage_probe_not_detected_when_safe_test() {
  let provider = mock.provider_with_text("SAFE")
  canary.run_leakage_probe(
    "test instruction",
    "secret-leak-456",
    provider,
    "mock",
    "test-cycle",
    False,
  )
  |> should.be_false
}

pub fn leakage_probe_detected_when_token_revealed_test() {
  let provider = mock.provider_with_text("The token is secret-leak-456")
  canary.run_leakage_probe(
    "test instruction",
    "secret-leak-456",
    provider,
    "mock",
    "test-cycle",
    False,
  )
  |> should.be_true
}

pub fn leakage_probe_fail_closed_on_error_test() {
  let provider = mock.provider_with_error("timeout")
  canary.run_leakage_probe(
    "test",
    "token",
    provider,
    "mock",
    "test-cycle",
    False,
  )
  |> should.be_true
}

// ---------------------------------------------------------------------------
// run_probes (full)
// ---------------------------------------------------------------------------

pub fn run_probes_clean_when_safe_test() {
  let provider = mock.provider_with_text("SAFE")
  let result =
    canary.run_probes(
      "harmless instruction",
      provider,
      "mock",
      "test-cycle",
      False,
    )
  result.hijack_detected |> should.be_false
  result.leakage_detected |> should.be_false
}

pub fn run_probes_fail_closed_on_error_test() {
  let provider = mock.provider_with_error("network failure")
  let result = canary.run_probes("test", provider, "mock", "test-cycle", False)
  // Both should be detected (fail closed)
  result.hijack_detected |> should.be_true
  result.leakage_detected |> should.be_true
}
