// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{Some}
import gleam/string
import gleeunit
import gleeunit/should
import llm/adapters/mistral as mistral_adapter
import llm/adapters/mock
import llm/request
import llm/response
import llm/tool
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

/// Verify tool encoding produces correct Mistral/OpenAI format JSON
pub fn encode_request_with_tools_test() {
  let t =
    tool.new("agent_researcher")
    |> tool.with_description("Research agent")
    |> tool.add_string_param("instruction", "Task for the agent", True)
    |> tool.add_string_param("context", "Relevant context", False)
    |> tool.build()

  let req =
    request.new("mistral-small-latest", 1024)
    |> request.with_system("You are helpful.")
    |> request.with_user_message("Search for X")
    |> request.with_tools([t])

  let body = mistral_adapter.encode_request(req)
  // tools key must be present
  body |> string.contains("\"tools\"") |> should.be_true
  // tool_choice must be present — "any" on first turn (no tool results)
  body |> string.contains("\"tool_choice\"") |> should.be_true
  body |> string.contains("\"any\"") |> should.be_true
  // function name must be present
  body |> string.contains("\"agent_researcher\"") |> should.be_true
}

/// After tool results exist, tool_choice should be "auto" so model can text-reply
pub fn encode_request_tool_choice_auto_after_results_test() {
  let t =
    tool.new("agent_researcher")
    |> tool.with_description("Research agent")
    |> tool.add_string_param("instruction", "Task", True)
    |> tool.build()

  let req =
    request.new("mistral-small-latest", 1024)
    |> request.with_system("You are helpful.")
    |> request.with_tools([t])
    |> request.with_tool_results(
      [
        types.ToolUseContent(
          id: "call_1",
          name: "agent_researcher",
          input_json: "{}",
        ),
      ],
      [types.ToolSuccess(tool_use_id: "call_1", content: "results here")],
    )

  let body = mistral_adapter.encode_request(req)
  // Should be "auto" now that tool results are in the conversation
  body |> string.contains("\"tool_choice\":\"auto\"") |> should.be_true
}
