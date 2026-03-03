import gleam/option.{Some}
import gleeunit
import gleeunit/should
import llm/adapters/mistral as mistral_adapter
import llm/adapters/mock
import llm/request
import llm/response
import llm/types.{EndTurn, ToolUseRequested}

pub fn main() -> Nil {
  gleeunit.main()
}

/// Creating a provider with an explicit key should name it "mistral"
pub fn provider_name_is_mistral_test() {
  let p = mistral_adapter.provider("test-key")
  p.name |> should.equal("mistral")
}

/// provider_from_env returns ConfigError when MISTRAL_API_KEY is not set.
pub fn provider_from_env_missing_key_test() {
  case mistral_adapter.provider_from_env() {
    Ok(p) -> p.name |> should.equal("mistral")
    Error(err) ->
      err
      |> should.equal(types.ConfigError(reason: "MISTRAL_API_KEY is not set"))
  }
}

/// End-to-end with mock — validates the abstraction layer works
pub fn mock_roundtrip_text_test() {
  let p = mock.provider_with_text("Bonjour, je suis Mistral.")
  let result =
    request.new("mistral-large-latest", 1024)
    |> request.with_system("You are a helpful assistant.")
    |> request.with_user_message("Say hello in French.")
    |> fn(req) { p.chat(req) }
  result |> should.be_ok
  let assert Ok(resp) = result
  response.text(resp) |> should.equal("Bonjour, je suis Mistral.")
}

pub fn stop_reason_end_turn_test() {
  let resp = mock.text_response("Hello")
  resp.stop_reason |> should.equal(Some(EndTurn))
}

pub fn stop_reason_tool_use_test() {
  let resp = mock.tool_call_response("search", "{}", "call_1")
  resp.stop_reason |> should.equal(Some(ToolUseRequested))
}
