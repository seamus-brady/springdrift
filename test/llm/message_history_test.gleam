//// Tests for the invariant-bearing MessageHistory wrapper.
////
//// The whole point of this module is that the API contracts are
//// impossible to violate via its public surface. Each invariant gets a
//// dedicated test that constructs the exact malformation that used to
//// poison `state.messages` in the old `List(Message)` design and
//// confirms the new API silently corrects it (or refuses, depending
//// on the case).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleeunit/should
import llm/message_history as mh
import llm/types.{
  Assistant, Message, TextContent, ToolResultContent, ToolUseContent, User,
}

// ── Construction ──────────────────────────────────────────────────────────

pub fn new_is_empty_test() {
  mh.length(mh.new()) |> should.equal(0)
  mh.is_empty(mh.new()) |> should.be_true
}

pub fn from_list_empty_is_empty_test() {
  mh.length(mh.from_list([])) |> should.equal(0)
}

// ── Invariant 1: first message must be User ───────────────────────────────

pub fn add_assistant_to_empty_history_is_dropped_test() {
  // Anthropic rejects a history that starts with an assistant message.
  // The old List(Message) design relied on a sweep at the LLM boundary;
  // here, add() refuses up-front.
  let h = mh.new() |> mh.add_assistant([TextContent("hi")])
  mh.length(h) |> should.equal(0)
}

pub fn from_list_drops_leading_assistant_test() {
  let raw = [
    Message(role: Assistant, content: [TextContent("orphan")]),
    Message(role: User, content: [TextContent("hello")]),
  ]
  let h = mh.from_list(raw)
  case mh.to_list(h) {
    [Message(role: User, ..)] -> Nil
    _ -> {
      should.fail()
      Nil
    }
  }
}

// ── Invariant 2: alternation (no consecutive same-role) ───────────────────

pub fn consecutive_user_messages_coalesce_test() {
  let h =
    mh.new()
    |> mh.add_user_text("first")
    |> mh.add_user_text("second")
  mh.length(h) |> should.equal(1)
  case mh.to_list(h) {
    [Message(role: User, content: blocks)] ->
      list.length(blocks) |> should.equal(2)
    _ -> {
      should.fail()
      Nil
    }
  }
}

pub fn consecutive_assistant_messages_coalesce_test() {
  // First an assistant lands inside a valid user/assistant pair, then a
  // second assistant arrives — they should coalesce.
  let h =
    mh.new()
    |> mh.add_user_text("question")
    |> mh.add_assistant([TextContent("answer part 1")])
    |> mh.add_assistant([TextContent("answer part 2")])
  mh.length(h) |> should.equal(2)
}

// ── Invariant 3: orphan tool_result stripping ─────────────────────────────
//
// This is the bug class that caused the operator's cog to die with
// "messages.40.content.0: unexpected `tool_use_id`". The fix is
// structural: add() refuses to insert a tool_result whose tool_use_id
// isn't in the immediately-prior assistant message.

pub fn add_user_with_orphan_tool_result_strips_it_test() {
  let h =
    mh.new()
    |> mh.add_user_text("hi")
    // Add an assistant turn with no tool_use blocks.
    |> mh.add_assistant([TextContent("hi back")])
    // Now try to inject a user message with a tool_result whose
    // tool_use_id has no matching tool_use in the prior assistant.
    |> mh.add_user([
      ToolResultContent(tool_use_id: "ghost", content: "x", is_error: False),
    ])
  // The stripped tool_result emptied the message; the message was
  // dropped entirely. History stays clean.
  mh.length(h) |> should.equal(2)
}

pub fn add_user_keeps_paired_tool_result_test() {
  let h =
    mh.new()
    |> mh.add_user_text("call a tool")
    |> mh.add_assistant([
      ToolUseContent(id: "real", name: "calc", input_json: "{}"),
    ])
    |> mh.add_user([
      ToolResultContent(tool_use_id: "real", content: "42", is_error: False),
    ])
  mh.length(h) |> should.equal(3)
}

pub fn add_user_drops_orphan_keeps_valid_test() {
  // Mixed: one valid tool_result, one orphan. Strip orphan, keep valid.
  let h =
    mh.new()
    |> mh.add_user_text("call a tool")
    |> mh.add_assistant([
      ToolUseContent(id: "real", name: "calc", input_json: "{}"),
    ])
    |> mh.add_user([
      ToolResultContent(tool_use_id: "real", content: "42", is_error: False),
      ToolResultContent(tool_use_id: "ghost", content: "x", is_error: False),
    ])
  case mh.to_list(h) {
    [_, _, Message(role: User, content: blocks)] -> {
      list.length(blocks) |> should.equal(1)
      case blocks {
        [ToolResultContent(tool_use_id: id, ..)] -> id |> should.equal("real")
        _ -> {
          should.fail()
          Nil
        }
      }
    }
    _ -> {
      should.fail()
      Nil
    }
  }
}

// ── from_list: ingest sanitisation handles every direction ────────────────
//
// from_list is used at startup (load persisted history off disk) and
// elsewhere where untyped messages cross the boundary. It runs the
// full repair pipeline: drop leading assistant, coalesce, strip orphan
// tool_results, inject stubs for orphan tool_uses.

pub fn from_list_strips_orphan_tool_result_at_ingest_test() {
  // Direct reproduction of the cog-killing bug: a persisted history
  // contains a user message with a tool_result whose matching
  // tool_use was lost (e.g. context trimmed and never repaired). The
  // ingest path must clean it before construction returns.
  let raw = [
    Message(role: User, content: [TextContent("first")]),
    Message(role: Assistant, content: [TextContent("hello")]),
    Message(role: User, content: [
      ToolResultContent(tool_use_id: "ghost", content: "x", is_error: False),
    ]),
  ]
  let h = mh.from_list(raw)
  // The orphan-only user message gets emptied → dropped entirely.
  // Coalescing then merges the leading user with... no following user
  // (the assistant remains).
  let after = mh.to_list(h)
  list.any(after, fn(msg) {
    case msg.role {
      User ->
        list.any(msg.content, fn(b) {
          case b {
            ToolResultContent(tool_use_id: "ghost", ..) -> True
            _ -> False
          }
        })
      _ -> False
    }
  })
  |> should.be_false
}

pub fn from_list_injects_stub_for_orphan_tool_use_test() {
  // Opposite direction: an assistant emitted a tool_use but the
  // matching user with tool_result is missing. The ingest pipeline
  // synthesises a stub so the next API call doesn't 400.
  let raw = [
    Message(role: User, content: [TextContent("call calc")]),
    Message(role: Assistant, content: [
      ToolUseContent(id: "abandoned", name: "calc", input_json: "{}"),
    ]),
  ]
  let h = mh.from_list(raw)
  let after = mh.to_list(h)
  // Should now have 3 messages: user, assistant, synthetic-user-with-stub.
  list.length(after) |> should.equal(3)
  case list.last(after) {
    Ok(Message(role: User, content: blocks)) ->
      list.any(blocks, fn(b) {
        case b {
          ToolResultContent(tool_use_id: "abandoned", is_error: True, ..) ->
            True
          _ -> False
        }
      })
      |> should.be_true
    _ -> {
      should.fail()
      Nil
    }
  }
}

// ── for_send is wire-ready, to_list is identical (today) ──────────────────

pub fn for_send_equals_to_list_test() {
  let h =
    mh.new()
    |> mh.add_user_text("hi")
    |> mh.add_assistant([TextContent("yes")])
  mh.for_send(h) |> should.equal(mh.to_list(h))
}

// ── Last + length helpers ─────────────────────────────────────────────────

pub fn last_returns_most_recent_test() {
  let h =
    mh.new()
    |> mh.add_user_text("first")
    |> mh.add_assistant([TextContent("answer")])
  case mh.last(h) {
    option.Some(Message(role: Assistant, ..)) -> Nil
    _ -> {
      should.fail()
      Nil
    }
  }
}

pub fn length_counts_messages_test() {
  let h =
    mh.new()
    |> mh.add_user_text("a")
    |> mh.add_assistant([TextContent("b")])
    |> mh.add_user_text("c")
  mh.length(h) |> should.equal(3)
}

import gleam/option
