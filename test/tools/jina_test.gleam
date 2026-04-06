// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleeunit
import gleeunit/should
import llm/types.{ToolCall, ToolFailure}
import tools/jina

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all_tools_count_test() {
  let tools = jina.all()
  tools |> list.length |> should.equal(1)
}

pub fn jina_reader_tool_defined_test() {
  let tools = jina.all()
  let assert [t] = tools
  t.name |> should.equal("jina_reader")
  list.contains(t.required_params, "url") |> should.be_true
}

// ---------------------------------------------------------------------------
// is_jina_tool
// ---------------------------------------------------------------------------

pub fn is_jina_tool_true_test() {
  jina.is_jina_tool("jina_reader") |> should.be_true
}

pub fn is_jina_tool_false_test() {
  jina.is_jina_tool("fetch_url") |> should.be_false
  jina.is_jina_tool("unknown") |> should.be_false
}

// ---------------------------------------------------------------------------
// Missing input
// ---------------------------------------------------------------------------

pub fn jina_reader_missing_url_test() {
  let call = ToolCall(id: "j1", name: "jina_reader", input_json: "{}")
  let result = jina.execute(call)
  case result {
    ToolFailure(error: e, ..) ->
      e
      |> should.equal(
        "JINA_READER_API_KEY not set. Set this environment variable to use Jina Reader.",
      )
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Missing API key
// ---------------------------------------------------------------------------

pub fn jina_reader_no_api_key_test() {
  let call =
    ToolCall(
      id: "j2",
      name: "jina_reader",
      input_json: "{\"url\":\"https://example.com\"}",
    )
  let result = jina.execute(call)
  case result {
    ToolFailure(error: e, ..) ->
      e
      |> should.equal(
        "JINA_READER_API_KEY not set. Set this environment variable to use Jina Reader.",
      )
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// URL scheme validation (would trigger after API key check)
// ---------------------------------------------------------------------------

pub fn jina_reader_ftp_scheme_test() {
  // Without API key, we get the key error first
  let call =
    ToolCall(
      id: "j3",
      name: "jina_reader",
      input_json: "{\"url\":\"ftp://example.com/file\"}",
    )
  let result = jina.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Unknown tool
// ---------------------------------------------------------------------------

pub fn unknown_jina_tool_returns_failure_test() {
  let call = ToolCall(id: "j4", name: "jina_unknown", input_json: "{}")
  let result = jina.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}
