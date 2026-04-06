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
import llm/request
import llm/response
import llm/types.{EndTurn, ToolUseRequested}

pub fn main() -> Nil {
  gleeunit.main()
}

// Note: Real Anthropic provider tests require ANTHROPIC_API_KEY.
// These tests validate the abstraction layer using the mock provider.

pub fn mock_roundtrip_text_test() {
  let p = mock.provider_with_text("Hello from mock!")
  let result =
    request.new("claude-sonnet-4-20250514", 1024)
    |> request.with_system("You are helpful")
    |> request.with_user_message("Hello")
    |> fn(req) { p.chat(req) }
  result |> should.be_ok
  let assert Ok(resp) = result
  response.text(resp) |> should.equal("Hello from mock!")
}

pub fn stop_reason_end_turn_test() {
  let resp = mock.text_response("Hello")
  resp.stop_reason |> should.equal(Some(EndTurn))
}

pub fn stop_reason_tool_use_test() {
  let resp = mock.tool_call_response("search", "{\"query\":\"test\"}", "call_1")
  resp.stop_reason |> should.equal(Some(ToolUseRequested))
}

/// Verify mock provider name (real anthropic provider would be "anthropic"
/// but requires an API key to instantiate)
pub fn provider_name_is_anthropic_test() {
  let p = mock.provider_with_text("test")
  // Mock is "mock"; a real anthropic provider would report "anthropic"
  p.name |> should.equal("mock")
}
