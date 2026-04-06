// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import llm/request
import llm/types.{Message, TextContent, ToolSuccess, ToolUseContent, User}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn new_has_empty_messages_test() {
  let req = request.new("test-model", 1024)
  req.messages |> should.equal([])
}

pub fn new_stores_model_and_max_tokens_test() {
  let req = request.new("claude-sonnet-4", 2048)
  req.model |> should.equal("claude-sonnet-4")
  req.max_tokens |> should.equal(2048)
}

pub fn with_user_message_appends_test() {
  let req =
    request.new("test-model", 1024)
    |> request.with_user_message("Hello!")
  req.messages
  |> should.equal([Message(role: User, content: [TextContent(text: "Hello!")])])
}

pub fn with_system_sets_system_test() {
  let req =
    request.new("test-model", 1024)
    |> request.with_system("You are helpful")
  req.system |> should.equal(Some("You are helpful"))
}

pub fn multi_turn_builds_correct_length_test() {
  let req =
    request.new("test-model", 1024)
    |> request.with_user_message("Hello")
    |> request.with_assistant_message("Hi there!")
    |> request.with_user_message("How are you?")
  list.length(req.messages) |> should.equal(3)
}

pub fn with_tool_results_adds_two_messages_test() {
  let req =
    request.new("test-model", 1024)
    |> request.with_user_message("Call a tool")
  let assistant_content = [
    ToolUseContent(id: "id1", name: "my_tool", input_json: "{}"),
  ]
  let results = [ToolSuccess(tool_use_id: "id1", content: "result")]
  let req2 = request.with_tool_results(req, assistant_content, results)
  // Started with 1 message, added 2 more (assistant turn + user turn)
  list.length(req2.messages) |> should.equal(3)
}
