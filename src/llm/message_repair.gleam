//// Defensive repair for message history before it's handed to a
//// provider.
////
//// Anthropic's API rejects any request whose message history contains
//// a `tool_use` block without a matching `tool_result` block in the
//// immediately-following user message — the familiar 400 error
////
////   tool_use ids were found without tool_result blocks immediately
////   after: toolu_...
////
//// Every code path that appends an assistant message with tool_use
//// content is supposed to append a follow-up user message containing
//// tool_result blocks for each id. Most paths do; some don't. Once an
//// orphan lands in `CognitiveState.messages`, every subsequent cycle
//// re-sends the poisoned history and the API keeps rejecting.
////
//// This module is the last line of defence: a pure function that
//// walks a messages list, detects orphaned tool_use ids, and injects
//// synthesised `tool_result` stubs so the provider sees a
//// well-formed history.
////
//// The repair is a safety net, not a license to write sloppy upstream
//// code. Callers should `slog.warn` when `repair/1` actually changes
//// anything — each repair represents an upstream bug worth fixing.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/set.{type Set}
import llm/types.{
  type ContentBlock, type Message, Assistant, Message, ToolResultContent,
  ToolUseContent, User,
}

/// Synthetic content for an orphan repair. `is_error: True` so the
/// LLM knows the call didn't complete normally.
const orphan_stub_content = "[internal: tool call did not complete]"

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Scan the messages list and return the list of orphaned tool_use
/// ids — tool_use blocks in an assistant message whose immediately
/// following user message does not contain a `tool_result` with a
/// matching id. Empty list = well-formed.
pub fn find_orphans(messages: List(Message)) -> List(String) {
  collect_orphans(messages, [])
  |> list.reverse
}

/// Return a messages list where every orphan identified by
/// `find_orphans` has a matching synthetic `tool_result` block in a
/// user message immediately after the offending assistant message.
///
/// If the orphan-assistant is already followed by a user message, the
/// stub blocks are prepended to that message's content. Otherwise a
/// fresh user message is inserted.
pub fn repair(messages: List(Message)) -> List(Message) {
  // Single pass. Each assistant message is checked against the next
  // message; any tool_use whose id is missing from the following
  // user's tool_results gets a stub prepended. A trailing assistant
  // with tool_use and no follower gets a synthetic user message
  // appended.
  do_repair(messages, [])
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn collect_orphans(messages: List(Message), acc: List(String)) -> List(String) {
  case messages {
    [] -> acc
    [
      Message(role: Assistant, content: content),
      Message(role: User, content: next_content),
      ..rest
    ] -> {
      let tool_use_ids = tool_use_ids_in(content)
      let result_ids = result_ids_in(next_content)
      let orphans =
        list.filter(tool_use_ids, fn(id) { !set.contains(result_ids, id) })
      let next_acc = list.fold(orphans, acc, fn(a, id) { [id, ..a] })
      // The user message has been "consumed" as the expected match;
      // continue from after it.
      collect_orphans(rest, next_acc)
    }
    [Message(role: Assistant, content: content), ..rest] -> {
      // Assistant with no following user — every tool_use in content
      // is an orphan.
      let tool_use_ids = tool_use_ids_in(content)
      let next_acc = list.fold(tool_use_ids, acc, fn(a, id) { [id, ..a] })
      collect_orphans(rest, next_acc)
    }
    [_, ..rest] -> collect_orphans(rest, acc)
  }
}

fn do_repair(messages: List(Message), acc: List(Message)) -> List(Message) {
  case messages {
    [] -> list.reverse(acc)
    [
      Message(role: Assistant, content: a_content) as assistant,
      Message(role: User, content: u_content) as user_msg,
      ..rest
    ] -> {
      let tool_use_ids = tool_use_ids_in(a_content)
      let result_ids = result_ids_in(u_content)
      let orphan_ids =
        list.filter(tool_use_ids, fn(id) { !set.contains(result_ids, id) })
      case orphan_ids {
        [] -> do_repair(rest, [user_msg, assistant, ..acc])
        _ -> {
          let stubs = list.map(orphan_ids, stub_block)
          let patched_user =
            Message(role: User, content: list.append(stubs, u_content))
          do_repair(rest, [patched_user, assistant, ..acc])
        }
      }
    }
    [Message(role: Assistant, content: a_content) as assistant, ..rest] -> {
      // Assistant with no following user at all — inject a synthetic
      // user message containing stubs for every tool_use.
      let tool_use_ids = tool_use_ids_in(a_content)
      case tool_use_ids {
        [] -> do_repair(rest, [assistant, ..acc])
        ids -> {
          let stubs = list.map(ids, stub_block)
          let patched_user = Message(role: User, content: stubs)
          do_repair(rest, [patched_user, assistant, ..acc])
        }
      }
    }
    [other, ..rest] -> do_repair(rest, [other, ..acc])
  }
}

fn tool_use_ids_in(content: List(ContentBlock)) -> List(String) {
  list.filter_map(content, fn(block) {
    case block {
      ToolUseContent(id: id, ..) -> Ok(id)
      _ -> Error(Nil)
    }
  })
}

fn result_ids_in(content: List(ContentBlock)) -> Set(String) {
  list.filter_map(content, fn(block) {
    case block {
      ToolResultContent(tool_use_id: id, ..) -> Ok(id)
      _ -> Error(Nil)
    }
  })
  |> set.from_list
}

fn stub_block(id: String) -> ContentBlock {
  ToolResultContent(
    tool_use_id: id,
    content: orphan_stub_content,
    is_error: True,
  )
}
