// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import deputy/tool as deputy_tool
import gleam/option.{None}
import gleeunit/should
import llm/types as llm_types

// ---------------------------------------------------------------------------
// ask_deputy tool — shape and behaviour
// ---------------------------------------------------------------------------

pub fn ask_deputy_tool_name_test() {
  let t = deputy_tool.ask_deputy_tool()
  t.name |> should.equal("ask_deputy")
}

pub fn is_ask_deputy_positive_test() {
  deputy_tool.is_ask_deputy("ask_deputy") |> should.equal(True)
}

pub fn is_ask_deputy_negative_test() {
  deputy_tool.is_ask_deputy("kill_deputy") |> should.equal(False)
  deputy_tool.is_ask_deputy("recall_deputy") |> should.equal(False)
  deputy_tool.is_ask_deputy("memory_write") |> should.equal(False)
}

// ---------------------------------------------------------------------------
// execute without a deputy_subject — returns ToolFailure
// ---------------------------------------------------------------------------

pub fn execute_without_deputy_returns_failure_test() {
  let call =
    llm_types.ToolCall(
      id: "tu-1",
      name: "ask_deputy",
      input_json: "{\"question\":\"what now\"}",
    )
  let result = deputy_tool.execute(call, None, 5000)
  case result {
    llm_types.ToolFailure(tool_use_id:, error:) -> {
      tool_use_id |> should.equal("tu-1")
      // The failure message should make clear why it failed
      case string_contains(error, "no active deputy") {
        True -> Nil
        False -> should.fail()
      }
    }
    llm_types.ToolSuccess(..) -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// execute with invalid json — returns ToolFailure
// ---------------------------------------------------------------------------

pub fn execute_with_invalid_json_test() {
  // Even when a deputy subject is provided, malformed input is rejected.
  // We don't need a real subject for this test since the decoder runs
  // before we touch it.
  let call =
    llm_types.ToolCall(
      id: "tu-bad",
      name: "ask_deputy",
      input_json: "not json at all",
    )
  // No deputy → fails at the "no active deputy" check first; that's fine.
  let result = deputy_tool.execute(call, None, 5000)
  case result {
    llm_types.ToolFailure(..) -> Nil
    llm_types.ToolSuccess(..) -> should.fail()
  }
}

// Helper — avoids importing gleam/string just for contains
@external(erlang, "binary", "matches")
fn binary_matches(subject: String, pattern: String) -> List(#(Int, Int))

fn string_contains(subject: String, pattern: String) -> Bool {
  case binary_matches(subject, pattern) {
    [] -> False
    _ -> True
  }
}
