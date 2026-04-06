// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{Some}
import gleeunit
import gleeunit/should
import llm/adapters/mock
import llm/adapters/openai as openai_adapter
import llm/request
import llm/response
import llm/types.{EndTurn, ToolUseRequested}

pub fn main() -> Nil {
  gleeunit.main()
}

/// Creating a provider with an explicit key should succeed and name it "openai"
pub fn provider_name_is_openai_test() {
  let p = openai_adapter.provider("sk-test-key")
  p.name |> should.equal("openai")
}

/// provider_from_env returns ConfigError when OPENAI_API_KEY is not set.
/// (Safe to run in CI — if the var IS set this test is skipped via the Ok branch.)
pub fn provider_from_env_missing_key_test() {
  case openai_adapter.provider_from_env() {
    // Key happened to be set in this environment — that's fine
    Ok(p) -> p.name |> should.equal("openai")
    // Key not set — confirm we get a ConfigError
    Error(err) ->
      err
      |> should.equal(types.ConfigError(reason: "OPENAI_API_KEY is not set"))
  }
}

/// provider_from_openrouter_env returns ConfigError when key is absent
pub fn provider_from_openrouter_env_missing_key_test() {
  case openai_adapter.provider_from_openrouter_env() {
    Ok(p) -> p.name |> should.equal("openai")
    Error(err) ->
      err
      |> should.equal(types.ConfigError(reason: "OPENROUTER_API_KEY is not set"))
  }
}

/// End-to-end with mock — validates the abstraction layer works regardless of provider
pub fn mock_roundtrip_text_test() {
  let p = mock.provider_with_text("Paris is the capital of France.")
  let result =
    request.new("gpt-4o", 1024)
    |> request.with_system("You are a helpful assistant.")
    |> request.with_user_message("What is the capital of France?")
    |> fn(req) { p.chat(req) }
  result |> should.be_ok
  let assert Ok(resp) = result
  response.text(resp) |> should.equal("Paris is the capital of France.")
}

pub fn stop_reason_end_turn_test() {
  let resp = mock.text_response("Hello")
  resp.stop_reason |> should.equal(Some(EndTurn))
}

pub fn stop_reason_tool_use_test() {
  let resp = mock.tool_call_response("search", "{}", "call_1")
  resp.stop_reason |> should.equal(Some(ToolUseRequested))
}

/// Confirm constants are defined and non-empty
pub fn base_url_constants_test() {
  openai_adapter.openai_base_url |> should.equal("https://api.openai.com/v1")
  openai_adapter.openrouter_base_url
  |> should.equal("https://openrouter.ai/api/v1")
}

pub fn model_constants_test() {
  openai_adapter.gpt_4o |> should.equal("gpt-4o")
  openai_adapter.gpt_4o_mini |> should.equal("gpt-4o-mini")
  openai_adapter.o3_mini |> should.equal("o3-mini")
}
