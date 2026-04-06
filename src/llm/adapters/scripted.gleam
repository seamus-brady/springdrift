//// Scripted mock LLM provider — returns a sequence of pre-configured responses.
////
//// Unlike `mock.provider_with_handler` which requires manual request inspection,
//// the scripted provider pops responses from an ordered list. This makes
//// multi-turn integration tests deterministic and easy to read.
////
//// Uses an ETS table as a mutable queue so the provider function (which is a
//// pure fn(LlmRequest) -> Result) can pop the next response without threading
//// state through the caller.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/erlang/process
import gleam/option.{Some}
import llm/provider.{type Provider, Provider}
import llm/types.{
  type LlmError, type LlmResponse, EndTurn, LlmResponse, TextContent,
  ToolUseContent, ToolUseRequested, UnknownError, Usage,
}

/// Opaque handle to a scripted response queue.
pub opaque type Script {
  Script(table: process.Pid)
}

// ---------------------------------------------------------------------------
// ETS FFI — simple ordered queue backed by an ETS table
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_test_ffi", "script_new")
fn script_new(responses: List(Result(LlmResponse, LlmError))) -> process.Pid

@external(erlang, "springdrift_test_ffi", "script_pop")
fn script_pop(table: process.Pid) -> Result(Result(LlmResponse, LlmError), Nil)

/// Create a new script from an ordered list of responses.
pub fn new(responses: List(Result(LlmResponse, LlmError))) -> Script {
  Script(table: script_new(responses))
}

/// Build a Provider that pops from this script on each call.
/// When the script is exhausted, returns an error.
pub fn provider(script: Script) -> Provider {
  let table = script.table
  Provider(name: "scripted", chat: fn(_req) {
    case script_pop(table) {
      Ok(result) -> result
      Error(_) -> Error(UnknownError(reason: "Scripted provider exhausted"))
    }
  })
}

// ---------------------------------------------------------------------------
// Response builders (re-exported convenience)
// ---------------------------------------------------------------------------

/// Build a successful text response.
pub fn ok_text(text: String) -> Result(LlmResponse, LlmError) {
  Ok(LlmResponse(
    id: "scripted_text",
    content: [TextContent(text:)],
    model: "scripted",
    stop_reason: Some(EndTurn),
    usage: Usage(
      input_tokens: 10,
      output_tokens: 10,
      thinking_tokens: 0,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
    ),
  ))
}

/// Build a successful tool-call response.
pub fn ok_tool_call(
  name: String,
  input_json: String,
  id: String,
) -> Result(LlmResponse, LlmError) {
  Ok(LlmResponse(
    id: "scripted_tool",
    content: [ToolUseContent(id:, name:, input_json:)],
    model: "scripted",
    stop_reason: Some(ToolUseRequested),
    usage: Usage(
      input_tokens: 15,
      output_tokens: 20,
      thinking_tokens: 0,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
    ),
  ))
}

/// Build an error response.
pub fn err(error: LlmError) -> Result(LlmResponse, LlmError) {
  Error(error)
}
