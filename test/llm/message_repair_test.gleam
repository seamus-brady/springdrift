//// Message-history repair: detecting and fixing orphaned tool_use
//// ids so the Anthropic API doesn't 400 on well-formed histories.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleeunit/should
import llm/message_repair
import llm/types.{
  Assistant, Message, TextContent, ToolResultContent, ToolUseContent, User,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn tool_use(id: String) -> types.ContentBlock {
  ToolUseContent(id: id, name: "dummy", input_json: "{}")
}

fn tool_result(id: String) -> types.ContentBlock {
  ToolResultContent(tool_use_id: id, content: "ok", is_error: False)
}

fn orphan_stub_matches(blocks: List(types.ContentBlock), id: String) -> Bool {
  list.any(blocks, fn(b) {
    case b {
      ToolResultContent(tool_use_id: tid, is_error: True, ..) -> tid == id
      _ -> False
    }
  })
}

// ---------------------------------------------------------------------------
// find_orphans
// ---------------------------------------------------------------------------

pub fn empty_history_has_no_orphans_test() {
  message_repair.find_orphans([]) |> should.equal([])
}

pub fn well_formed_history_has_no_orphans_test() {
  let msgs = [
    Message(role: User, content: [TextContent(text: "hi")]),
    Message(role: Assistant, content: [tool_use("t1")]),
    Message(role: User, content: [tool_result("t1")]),
  ]
  message_repair.find_orphans(msgs) |> should.equal([])
}

pub fn orphan_assistant_followed_by_user_without_result_test() {
  let msgs = [
    Message(role: Assistant, content: [tool_use("t1"), tool_use("t2")]),
    Message(role: User, content: [tool_result("t1")]),
  ]
  // t1 has a matching result, t2 doesn't.
  message_repair.find_orphans(msgs) |> should.equal(["t2"])
}

pub fn orphan_assistant_with_no_following_user_test() {
  let msgs = [Message(role: Assistant, content: [tool_use("t1")])]
  message_repair.find_orphans(msgs) |> should.equal(["t1"])
}

pub fn multiple_orphans_across_history_test() {
  let msgs = [
    Message(role: Assistant, content: [tool_use("a1")]),
    Message(role: User, content: [TextContent(text: "no result block")]),
    Message(role: Assistant, content: [tool_use("b1"), tool_use("b2")]),
    Message(role: User, content: [tool_result("b1")]),
  ]
  // a1 orphaned (no matching result in next user msg), b2 orphaned.
  message_repair.find_orphans(msgs) |> should.equal(["a1", "b2"])
}

// ---------------------------------------------------------------------------
// repair — leaves well-formed history untouched
// ---------------------------------------------------------------------------

pub fn repair_is_identity_when_no_orphans_test() {
  let msgs = [
    Message(role: User, content: [TextContent(text: "hi")]),
    Message(role: Assistant, content: [tool_use("t1")]),
    Message(role: User, content: [tool_result("t1")]),
    Message(role: Assistant, content: [TextContent(text: "done")]),
  ]
  message_repair.repair(msgs) |> should.equal(msgs)
}

// ---------------------------------------------------------------------------
// repair — injects stubs
// ---------------------------------------------------------------------------

pub fn repair_prepends_stub_to_following_user_test() {
  let msgs = [
    Message(role: Assistant, content: [tool_use("t1"), tool_use("t2")]),
    Message(role: User, content: [tool_result("t1")]),
  ]
  let repaired = message_repair.repair(msgs)
  // The user message after the orphan assistant must now contain a
  // tool_result for t2 (as the new stub) plus the original t1 result.
  let assert [_, Message(role: User, content: user_content)] = repaired
  orphan_stub_matches(user_content, "t2") |> should.equal(True)
  // Original t1 result is preserved.
  list.any(user_content, fn(b) {
    case b {
      ToolResultContent(tool_use_id: "t1", is_error: False, ..) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

pub fn repair_inserts_user_when_assistant_has_no_follower_test() {
  let msgs = [Message(role: Assistant, content: [tool_use("t1")])]
  let repaired = message_repair.repair(msgs)
  // A user message must now follow the assistant with a stub for t1.
  case repaired {
    [Message(role: Assistant, ..), Message(role: User, content: uc)] -> {
      orphan_stub_matches(uc, "t1") |> should.equal(True)
    }
    _ -> should.fail()
  }
}

pub fn repair_is_idempotent_test() {
  let msgs = [
    Message(role: Assistant, content: [tool_use("t1"), tool_use("t2")]),
    Message(role: User, content: [tool_result("t1")]),
  ]
  let once = message_repair.repair(msgs)
  let twice = message_repair.repair(once)
  once |> should.equal(twice)
  message_repair.find_orphans(once) |> should.equal([])
}
