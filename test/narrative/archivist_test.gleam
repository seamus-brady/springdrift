import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import llm/adapters/mock
import narrative/archivist.{type ArchivistContext, ArchivistContext}
import narrative/types.{Success}

pub fn main() -> Nil {
  gleeunit.main()
}

fn make_ctx() -> ArchivistContext {
  ArchivistContext(
    cycle_id: "test-cycle-123",
    parent_cycle_id: None,
    user_input: "hello",
    final_response: "Hello! How can I help?",
    agent_completions: [],
    model_used: "mock-model",
    classification: "simple",
    total_input_tokens: 100,
    total_output_tokens: 50,
    tool_calls: 0,
    dprime_decisions: [],
    thread_index_json: "{}",
  )
}

// ---------------------------------------------------------------------------
// extract_json_object tests
// ---------------------------------------------------------------------------

pub fn extract_json_object_plain_json_test() {
  let json = "{\"summary\": \"hello\"}"
  archivist.extract_json_object(json)
  |> should.equal(json)
}

pub fn extract_json_object_with_markdown_fences_test() {
  let input = "```json\n{\"summary\": \"hello\"}\n```"
  archivist.extract_json_object(input)
  |> should.equal("{\"summary\": \"hello\"}")
}

pub fn extract_json_object_with_preamble_test() {
  let input = "Here is the JSON:\n{\"summary\": \"hello\"}"
  archivist.extract_json_object(input)
  |> should.equal("{\"summary\": \"hello\"}")
}

pub fn extract_json_object_with_trailing_text_test() {
  let input = "{\"summary\": \"hello\"}\n\nLet me know if you need changes."
  archivist.extract_json_object(input)
  |> should.equal("{\"summary\": \"hello\"}")
}

pub fn extract_json_object_with_preamble_and_trailing_test() {
  let input =
    "Sure! Here's the entry:\n```json\n{\"summary\": \"I helped\"}\n```\nDone."
  archivist.extract_json_object(input)
  |> should.equal("{\"summary\": \"I helped\"}")
}

pub fn extract_json_object_nested_braces_test() {
  let input = "{\"intent\": {\"classification\": \"conversation\"}}"
  archivist.extract_json_object(input)
  |> should.equal(input)
}

pub fn extract_json_object_no_braces_returns_input_test() {
  let input = "no json here"
  archivist.extract_json_object(input)
  |> should.equal(input)
}

// ---------------------------------------------------------------------------
// generate tests via mock provider
// ---------------------------------------------------------------------------

pub fn generate_valid_json_response_test() {
  let json =
    "{\"summary\": \"I greeted the user.\", \"intent\": {\"classification\": \"conversation\", \"description\": \"greeting\", \"domain\": \"general\"}, \"outcome\": {\"status\": \"success\", \"confidence\": 0.9, \"assessment\": \"Simple greeting handled\"}, \"keywords\": [\"greeting\"], \"metrics\": {\"total_duration_ms\": 0, \"input_tokens\": 100, \"output_tokens\": 50, \"thinking_tokens\": 0, \"tool_calls\": 0, \"agent_delegations\": 0, \"dprime_evaluations\": 0, \"model_used\": \"mock-model\"}}"
  let provider = mock.provider_with_text(json)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("I greeted the user.")
  entry.cycle_id |> should.equal("test-cycle-123")
  entry.outcome.status |> should.equal(Success)
}

pub fn generate_markdown_wrapped_json_test() {
  let json =
    "```json\n{\"summary\": \"I helped with a task.\", \"intent\": {\"classification\": \"exploration\"}, \"outcome\": {\"status\": \"success\", \"confidence\": 0.8}, \"keywords\": [\"help\"]}\n```"
  let provider = mock.provider_with_text(json)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("I helped with a task.")
}

pub fn generate_with_preamble_text_test() {
  let json =
    "Here is the narrative entry:\n{\"summary\": \"Processed a greeting.\", \"intent\": {\"classification\": \"conversation\"}, \"outcome\": {\"status\": \"success\", \"confidence\": 0.7}, \"keywords\": []}"
  let provider = mock.provider_with_text(json)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("Processed a greeting.")
}

pub fn generate_minimal_json_uses_defaults_test() {
  // Only summary — everything else should get defaults from lenient decoder
  let json = "{\"summary\": \"Minimal entry.\"}"
  let provider = mock.provider_with_text(json)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("Minimal entry.")
  entry.cycle_id |> should.equal("test-cycle-123")
  entry.keywords |> should.equal([])
  entry.delegation_chain |> should.equal([])
}

pub fn generate_completely_invalid_response_falls_back_test() {
  let provider = mock.provider_with_text("I cannot produce JSON, sorry!")
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", False)
  result |> should.be_some
  let assert Some(entry) = result
  // Fallback entry — should contain the koan-style message with user input
  let assert True =
    string.contains(entry.summary, "ink has run dry")
  let assert True =
    string.contains(entry.summary, "hello")
  entry.cycle_id |> should.equal("test-cycle-123")
}

pub fn generate_llm_failure_returns_none_test() {
  let provider = mock.provider_with_error("connection refused")
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", False)
  result |> should.be_none
}

pub fn generate_overrides_cycle_id_from_context_test() {
  // LLM returns a different cycle_id — should be overridden
  let json =
    "{\"cycle_id\": \"wrong-id\", \"summary\": \"Test.\", \"intent\": {\"classification\": \"conversation\"}, \"outcome\": {\"status\": \"success\", \"confidence\": 0.5}, \"keywords\": []}"
  let provider = mock.provider_with_text(json)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.cycle_id |> should.equal("test-cycle-123")
}

pub fn generate_with_delegation_chain_test() {
  let json =
    "{\"summary\": \"Delegated research.\", \"intent\": {\"classification\": \"data_query\"}, \"outcome\": {\"status\": \"success\", \"confidence\": 0.8}, \"delegation_chain\": [{\"agent\": \"researcher\", \"instruction\": \"find info\", \"outcome\": \"success\", \"contribution\": \"found data\"}], \"keywords\": [\"research\"]}"
  let provider = mock.provider_with_text(json)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("Delegated research.")
  let assert [step] = entry.delegation_chain
  step.agent |> should.equal("researcher")
  step.instruction |> should.equal("find info")
}

pub fn generate_empty_json_object_uses_all_defaults_test() {
  let json = "{}"
  let provider = mock.provider_with_text(json)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("")
  entry.cycle_id |> should.equal("test-cycle-123")
}

// ---------------------------------------------------------------------------
// sanitize_json_string tests
// ---------------------------------------------------------------------------

pub fn sanitize_json_noop_on_valid_json_test() {
  let json = "{\"summary\": \"hello world\"}"
  archivist.sanitize_json_string(json) |> should.equal(json)
}

pub fn sanitize_json_escapes_literal_newlines_test() {
  // A literal newline inside a JSON string value
  let bad = "{\"summary\": \"line one\nline two\"}"
  let fixed = archivist.sanitize_json_string(bad)
  fixed |> should.equal("{\"summary\": \"line one\\nline two\"}")
}

pub fn sanitize_json_escapes_literal_tabs_test() {
  let bad = "{\"summary\": \"col1\tcol2\"}"
  let fixed = archivist.sanitize_json_string(bad)
  fixed |> should.equal("{\"summary\": \"col1\\tcol2\"}")
}

pub fn sanitize_json_escapes_carriage_return_test() {
  let bad = "{\"summary\": \"line one\r\nline two\"}"
  let fixed = archivist.sanitize_json_string(bad)
  fixed |> should.equal("{\"summary\": \"line one\\r\\nline two\"}")
}

pub fn sanitize_json_preserves_already_escaped_test() {
  // Already properly escaped — should not double-escape
  let good = "{\"summary\": \"line one\\nline two\"}"
  archivist.sanitize_json_string(good) |> should.equal(good)
}

pub fn sanitize_json_preserves_escaped_quotes_test() {
  let good = "{\"summary\": \"he said \\\"hello\\\"\"}"
  archivist.sanitize_json_string(good) |> should.equal(good)
}

pub fn sanitize_json_does_not_touch_newlines_outside_strings_test() {
  // Newlines outside strings (between object keys) are fine in JSON
  let json = "{\n  \"summary\": \"hello\"\n}"
  archivist.sanitize_json_string(json) |> should.equal(json)
}

pub fn sanitize_json_handles_nested_objects_test() {
  let bad =
    "{\"intent\": {\"description\": \"multi\nline\"}, \"summary\": \"ok\"}"
  let fixed = archivist.sanitize_json_string(bad)
  fixed
  |> should.equal(
    "{\"intent\": {\"description\": \"multi\\nline\"}, \"summary\": \"ok\"}",
  )
}

pub fn sanitize_json_handles_empty_string_test() {
  archivist.sanitize_json_string("") |> should.equal("")
}

pub fn generate_json_with_literal_newlines_in_summary_test() {
  // Simulates the Mistral issue: JSON with literal newlines in string values
  let json =
    "{\"summary\": \"I explained how to create a planet.\nIt was a detailed response.\", \"intent\": {\"classification\": \"conversation\"}, \"outcome\": {\"status\": \"success\", \"confidence\": 0.8}, \"keywords\": [\"planet\"]}"
  let provider = mock.provider_with_text(json)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary
  |> should.equal(
    "I explained how to create a planet.\nIt was a detailed response.",
  )
}
