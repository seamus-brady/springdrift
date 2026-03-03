import gleam/option.{Some}
import gleeunit
import gleeunit/should
import llm/adapters/local as local_adapter
import llm/adapters/mock
import llm/request
import llm/response
import llm/types.{EndTurn, ToolUseRequested}

pub fn main() -> Nil {
  gleeunit.main()
}

/// Default provider should name itself "local"
pub fn provider_name_is_local_test() {
  let p = local_adapter.provider()
  p.name |> should.equal("local")
}

/// provider_with_base_url should also name itself "local"
pub fn provider_with_base_url_name_test() {
  let p = local_adapter.provider_with_base_url("http://myhost:1234/v1")
  p.name |> should.equal("local")
}

/// provider_from_env always succeeds (no API key required)
pub fn provider_from_env_always_ok_test() {
  let result = local_adapter.provider_from_env()
  result |> should.be_ok
  let assert Ok(p) = result
  p.name |> should.equal("local")
}

/// End-to-end with mock — validates the abstraction layer works
pub fn mock_roundtrip_text_test() {
  let p = mock.provider_with_text("Hello from local LLM!")
  let result =
    request.new("llama3.1", 1024)
    |> request.with_system("You are a helpful assistant.")
    |> request.with_user_message("Say hello.")
    |> fn(req) { p.chat(req) }
  result |> should.be_ok
  let assert Ok(resp) = result
  response.text(resp) |> should.equal("Hello from local LLM!")
}

pub fn stop_reason_end_turn_test() {
  let resp = mock.text_response("Hello")
  resp.stop_reason |> should.equal(Some(EndTurn))
}

pub fn stop_reason_tool_use_test() {
  let resp = mock.tool_call_response("search", "{}", "call_1")
  resp.stop_reason |> should.equal(Some(ToolUseRequested))
}
