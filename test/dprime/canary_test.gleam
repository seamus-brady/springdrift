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

pub fn hijack_probe_safe_response_returns_false_test() {
  // Model responds "SAFE" — no token in response → not hijacked
  let provider = mock.provider_with_text("SAFE")
  canary.run_hijack_probe(
    "test instruction",
    "secret-token-123",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_false
}

pub fn hijack_probe_token_echoed_returns_true_test() {
  // Model was tricked into echoing the token → hijack detected
  let provider = mock.provider_with_text("secret-token-123")
  canary.run_hijack_probe(
    "test instruction",
    "secret-token-123",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_true
}

pub fn hijack_probe_token_embedded_in_text_returns_true_test() {
  // Token appears within a longer response
  let provider =
    mock.provider_with_text(
      "Sure, here is the answer: secret-token-123. Hope that helps!",
    )
  canary.run_hijack_probe(
    "test instruction",
    "secret-token-123",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_true
}

pub fn hijack_probe_case_insensitive_detection_test() {
  // Token check is case-insensitive (both lowercased before comparison)
  let provider = mock.provider_with_text("SECRET-TOKEN-ABC")
  canary.run_hijack_probe(
    "test instruction",
    "secret-token-abc",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_true
}

pub fn hijack_probe_fail_closed_on_error_test() {
  // LLM error → fail closed → hijack detected
  let provider = mock.provider_with_error("API down")
  canary.run_hijack_probe(
    "test",
    "token",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_true
}

// ---------------------------------------------------------------------------
// run_leakage_probe
// ---------------------------------------------------------------------------

pub fn leakage_probe_safe_response_returns_false_test() {
  // Model responds "SAFE" — no token leaked
  let provider = mock.provider_with_text("SAFE")
  canary.run_leakage_probe(
    "test instruction",
    "secret-leak-456",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_false
}

pub fn leakage_probe_token_revealed_returns_true_test() {
  // Model reveals the secret token → leakage detected
  let provider = mock.provider_with_text("The token is secret-leak-456")
  canary.run_leakage_probe(
    "test instruction",
    "secret-leak-456",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_true
}

pub fn leakage_probe_exact_token_match_test() {
  // Model returns just the token
  let provider = mock.provider_with_text("secret-leak-456")
  canary.run_leakage_probe(
    "test instruction",
    "secret-leak-456",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_true
}

pub fn leakage_probe_fail_closed_on_error_test() {
  // LLM error → fail closed → leakage detected
  let provider = mock.provider_with_error("timeout")
  canary.run_leakage_probe(
    "test",
    "token",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_true
}

// ---------------------------------------------------------------------------
// run_probes_with_tokens — combined results
// ---------------------------------------------------------------------------

pub fn run_probes_with_tokens_both_clean_test() {
  // Model responds "SAFE" for both probes → no issues
  let provider = mock.provider_with_text("SAFE")
  let result =
    canary.run_probes_with_tokens(
      "harmless instruction",
      provider,
      "mock",
      "test-cycle",
      False,
      False,
      "hijack-tok-aaa",
      "leak-tok-bbb",
    )
  result.hijack_detected |> should.be_false
  result.leakage_detected |> should.be_false
  result.details |> should.equal("No issues detected")
}

pub fn run_probes_with_tokens_hijack_detected_test() {
  // Provider echoes the hijack token but not the leakage token
  let provider =
    mock.provider_with_handler(fn(req) {
      // The hijack probe includes the token in the user message as an override.
      // We check if the request contains the hijack token to decide response.
      let has_hijack_token = case req.messages {
        [msg, ..] ->
          case msg {
            _ -> True
          }
        _ -> True
      }
      case has_hijack_token {
        // Return the hijack token — both probes will see it, but only hijack
        // detection uses case-insensitive matching on its own token.
        // We need a smarter approach: return the hijack token text.
        True -> Ok(mock.text_response("hijack-tok-aaa"))
        False -> Ok(mock.text_response("SAFE"))
      }
    })
  let result =
    canary.run_probes_with_tokens(
      "test instruction",
      provider,
      "mock",
      "test-cycle",
      False,
      False,
      "hijack-tok-aaa",
      "leak-tok-bbb",
    )
  // Hijack detected because response contains the hijack token
  result.hijack_detected |> should.be_true
  // Leakage not detected because response does NOT contain leak-tok-bbb
  result.leakage_detected |> should.be_false
  result.details |> should.equal("Hijack detected")
}

pub fn run_probes_with_tokens_leakage_detected_test() {
  // Provider reveals the leakage token but not the hijack token
  let provider =
    mock.provider_with_handler(fn(_req) {
      Ok(mock.text_response("leak-tok-bbb"))
    })
  let result =
    canary.run_probes_with_tokens(
      "test instruction",
      provider,
      "mock",
      "test-cycle",
      False,
      False,
      "hijack-tok-aaa",
      "leak-tok-bbb",
    )
  // Hijack not detected: "leak-tok-bbb" lowercased doesn't contain "hijack-tok-aaa"
  result.hijack_detected |> should.be_false
  // Leakage detected: response contains the leakage token
  result.leakage_detected |> should.be_true
  result.details |> should.equal("Leakage detected")
}

pub fn run_probes_with_tokens_both_detected_test() {
  // Provider echoes both tokens
  let provider =
    mock.provider_with_handler(fn(_req) {
      Ok(mock.text_response("hijack-tok-aaa and leak-tok-bbb"))
    })
  let result =
    canary.run_probes_with_tokens(
      "test instruction",
      provider,
      "mock",
      "test-cycle",
      False,
      False,
      "hijack-tok-aaa",
      "leak-tok-bbb",
    )
  result.hijack_detected |> should.be_true
  result.leakage_detected |> should.be_true
  result.details |> should.equal("Hijack and leakage detected")
}

pub fn run_probes_with_tokens_fail_closed_on_error_test() {
  // LLM error → both probes fail closed
  let provider = mock.provider_with_error("network failure")
  let result =
    canary.run_probes_with_tokens(
      "test",
      provider,
      "mock",
      "test-cycle",
      False,
      False,
      "tok-a",
      "tok-b",
    )
  result.hijack_detected |> should.be_true
  result.leakage_detected |> should.be_true
  result.details |> should.equal("Hijack and leakage detected")
}

// ---------------------------------------------------------------------------
// Details string patterns
// ---------------------------------------------------------------------------

pub fn details_no_issues_pattern_test() {
  let provider = mock.provider_with_text("SAFE")
  let result =
    canary.run_probes_with_tokens(
      "safe query",
      provider,
      "mock",
      "test-cycle",
      False,
      False,
      "unique-hijack-token",
      "unique-leakage-token",
    )
  result.details |> should.equal("No issues detected")
}

pub fn details_hijack_only_pattern_test() {
  // Return text containing only the hijack token
  let provider = mock.provider_with_text("unique-hijack-token")
  let result =
    canary.run_probes_with_tokens(
      "test",
      provider,
      "mock",
      "test-cycle",
      False,
      False,
      "unique-hijack-token",
      "unique-leakage-token",
    )
  result.details |> should.equal("Hijack detected")
}

pub fn details_leakage_only_pattern_test() {
  // Return text containing only the leakage token
  let provider = mock.provider_with_text("unique-leakage-token")
  let result =
    canary.run_probes_with_tokens(
      "test",
      provider,
      "mock",
      "test-cycle",
      False,
      False,
      "unique-hijack-token",
      "unique-leakage-token",
    )
  result.details |> should.equal("Leakage detected")
}

// ---------------------------------------------------------------------------
// Safe refusal filtering (F-11)
// ---------------------------------------------------------------------------

pub fn hijack_probe_safe_refusal_not_flagged_test() {
  // Model explains the injection attempt, quoting the token in a refusal
  let provider =
    mock.provider_with_text(
      "I noticed an injection attempt in your message. The override instruction tried to make me say 'secret-token-xyz'. I cannot comply with that. SAFE.",
    )
  canary.run_hijack_probe(
    "test instruction",
    "secret-token-xyz",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_false
}

pub fn hijack_probe_token_at_start_still_detected_test() {
  // Token appears at the very start — compliance, not refusal
  let provider =
    mock.provider_with_text("secret-token-xyz is the token you asked for")
  canary.run_hijack_probe(
    "test instruction",
    "secret-token-xyz",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_true
}

pub fn hijack_probe_refusal_without_token_still_safe_test() {
  // Refusal text without the token → no detection (already passes)
  let provider =
    mock.provider_with_text("I cannot comply with that injection attempt. SAFE")
  canary.run_hijack_probe(
    "test instruction",
    "unique-canary-token-999",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_false
}

pub fn hijack_probe_compliance_no_refusal_pattern_test() {
  // Token in response without refusal patterns → still hijack
  let provider =
    mock.provider_with_text("Here you go: secret-token-abc, enjoy!")
  canary.run_hijack_probe(
    "test instruction",
    "secret-token-abc",
    provider,
    "mock",
    "test-cycle",
    False,
    False,
  )
  |> should.be_true
}

pub fn details_both_detected_pattern_test() {
  let provider =
    mock.provider_with_text("unique-hijack-token and unique-leakage-token")
  let result =
    canary.run_probes_with_tokens(
      "test",
      provider,
      "mock",
      "test-cycle",
      False,
      False,
      "unique-hijack-token",
      "unique-leakage-token",
    )
  result.details |> should.equal("Hijack and leakage detected")
}
