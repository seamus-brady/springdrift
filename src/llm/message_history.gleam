//// Opaque, invariant-bearing wrapper around the cognitive loop's
//// message list.
////
//// **Why this exists.** Anthropic's API rejects requests whose history
//// violates one of these rules:
////
////   1. Every assistant `tool_use` block must be answered by a
////      `tool_result` (with matching `tool_use_id`) in the very next
////      user message.
////   2. Conversely, every user `tool_result` block's `tool_use_id`
////      must match a `tool_use` in the immediately-prior assistant
////      message — no orphan tool_results.
////   3. Messages must alternate user/assistant.
////   4. The first message must be user-role.
////
////   Violations get returned as 400 errors that look like
////   "messages.40.content.0: unexpected `tool_use_id` ..." and they
////   poison every subsequent cycle until something repairs the
////   stored history.
////
//// Historically the cog kept `state.messages: List(Message)` and let
//// every handler `list.append` directly. A reactive sweep at the LLM
//// boundary patched up *some* violations, but new code paths kept
//// introducing new shapes and the boundary sweep didn't always cover
//// them. The cog would die mid-cycle with an opaque API error and the
//// operator would have to restart it.
////
//// The fix: opaque `MessageHistory` with one chokepoint (`append`)
//// that maintains every invariant by construction. Nothing outside
//// this module can build or modify a `MessageHistory` except via the
//// typed API. The reactive sweep becomes redundant — it has nothing
//// left to repair.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import llm/types.{
  type ContentBlock, type Message, Assistant, Message, ToolResultContent,
  ToolUseContent, User,
}

// ---------------------------------------------------------------------------
// Opaque type
// ---------------------------------------------------------------------------

/// Append-only message history with provider-API invariants enforced
/// at every mutation. Construction is via `new/0`, `from_list/1`, or
/// any of the `add_*` functions — `MessageHistory(...)` is not exposed.
pub opaque type MessageHistory {
  MessageHistory(messages: List(Message))
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Empty history. Caller's first append should usually be a user
/// message; an assistant-first append is silently dropped (with a
/// repair record returned by `last_repair/1` if the caller cares).
pub fn new() -> MessageHistory {
  MessageHistory(messages: [])
}

/// Lift a raw `List(Message)` into a sanitised `MessageHistory`.
/// Used at startup to load persisted history off disk and at any
/// other boundary where untyped messages cross in (e.g. tests). The
/// repair pipeline runs once during ingest:
///
///   1. Drop a leading assistant message
///   2. Coalesce consecutive same-role messages
///   3. Strip orphan tool_results whose tool_use_id isn't in any
///      prior assistant message
///   4. Inject synthetic tool_results for any orphan tool_uses
pub fn from_list(messages: List(Message)) -> MessageHistory {
  MessageHistory(messages: sanitise(messages))
}

/// Equivalent to folding `add` over `msgs`. The same invariants apply;
/// each message goes through the chokepoint individually.
pub fn from_messages(msgs: List(Message)) -> MessageHistory {
  list.fold(msgs, new(), fn(h, m) { add(h, m) })
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

/// Number of messages in the history.
pub fn length(h: MessageHistory) -> Int {
  list.length(h.messages)
}

pub fn is_empty(h: MessageHistory) -> Bool {
  case h.messages {
    [] -> True
    _ -> False
  }
}

/// Most-recent message, if any. Useful for "did the last turn end
/// with an assistant tool_use?" decisions.
pub fn last(h: MessageHistory) -> Option(Message) {
  case list.reverse(h.messages) {
    [m, ..] -> Some(m)
    [] -> None
  }
}

/// Read-only iteration. The list is the canonical chronological order.
pub fn to_list(h: MessageHistory) -> List(Message) {
  h.messages
}

/// Wire-ready message list for the LLM provider. Currently identical
/// to `to_list/1` because the invariants are maintained at append
/// time; the separate function exists so future safety nets (e.g.
/// last-resort hard token trimming) can live on the send path without
/// changing the audit/log surface.
pub fn for_send(h: MessageHistory) -> List(Message) {
  h.messages
}

// ---------------------------------------------------------------------------
// Mutation — the chokepoint
// ---------------------------------------------------------------------------

/// Append a message. The invariants are enforced here:
///
/// * Leading assistant → silently dropped.
/// * Consecutive same-role → coalesced into one message (content
///   blocks concatenated). This prevents the "messages must
///   alternate" 400 from the API.
/// * User message containing tool_result blocks → any tool_result
///   whose tool_use_id has no matching tool_use in the
///   immediately-prior assistant message is dropped. If that empties
///   the message, the message itself is dropped.
///
/// The function is total: every input produces a valid `MessageHistory`.
pub fn add(h: MessageHistory, msg: Message) -> MessageHistory {
  case h.messages, msg.role {
    [], Assistant -> h
    [], _ -> MessageHistory(messages: [msg])
    prior_messages, _ -> {
      let prior_assistant_tool_use_ids =
        last_assistant_tool_use_ids(prior_messages)
      let cleaned = clean_msg(msg, prior_assistant_tool_use_ids)
      case cleaned {
        None -> h
        Some(c) -> {
          case list.reverse(prior_messages) {
            [last_msg, ..rest_rev] if last_msg.role == c.role ->
              MessageHistory(
                messages: list.reverse([
                  Message(
                    role: last_msg.role,
                    content: list.append(last_msg.content, c.content),
                  ),
                  ..rest_rev
                ]),
              )
            _ -> MessageHistory(messages: list.append(prior_messages, [c]))
          }
        }
      }
    }
  }
}

/// Append several messages in order. Each goes through `add/2`.
pub fn add_all(h: MessageHistory, msgs: List(Message)) -> MessageHistory {
  list.fold(msgs, h, fn(acc, m) { add(acc, m) })
}

/// Append a plain user-text turn. Convenience for the most common
/// case (operator typing or scheduler prepending a context block).
pub fn add_user_text(h: MessageHistory, text: String) -> MessageHistory {
  add(h, Message(role: User, content: [types.TextContent(text: text)]))
}

/// Append an assistant turn from raw content blocks. Prefer this
/// over `add` when constructing a fresh assistant message at the
/// call site — it makes the role explicit.
pub fn add_assistant(
  h: MessageHistory,
  content: List(ContentBlock),
) -> MessageHistory {
  add(h, Message(role: Assistant, content: content))
}

/// Append a user turn from raw content blocks. Tool_results inside
/// `content` are vetted against the prior assistant's tool_use ids;
/// orphans are stripped.
pub fn add_user(
  h: MessageHistory,
  content: List(ContentBlock),
) -> MessageHistory {
  add(h, Message(role: User, content: content))
}

// ---------------------------------------------------------------------------
// Internal — invariant enforcement
// ---------------------------------------------------------------------------

/// Pull the tool_use IDs from the last assistant message in the list,
/// if there is one. Returns an empty set if the last message is user
/// or there is no message — in either case any tool_result_id offered
/// by the next user message is orphan.
fn last_assistant_tool_use_ids(messages: List(Message)) -> Set(String) {
  case list.reverse(messages) {
    [Message(role: Assistant, content: c), ..] -> tool_use_ids_in(c)
    _ -> set.new()
  }
}

fn tool_use_ids_in(content: List(ContentBlock)) -> Set(String) {
  list.fold(content, set.new(), fn(acc, block) {
    case block {
      ToolUseContent(id: id, ..) -> set.insert(acc, id)
      _ -> acc
    }
  })
}

/// Strip orphan tool_result blocks from a user message. If the
/// resulting block list is empty, return None to signal "drop the
/// message entirely". Non-user messages pass through unchanged.
fn clean_msg(msg: Message, valid_tool_use_ids: Set(String)) -> Option(Message) {
  case msg.role {
    User -> {
      let cleaned_blocks =
        list.filter(msg.content, fn(block) {
          case block {
            ToolResultContent(tool_use_id: id, ..) ->
              set.contains(valid_tool_use_ids, id)
            _ -> True
          }
        })
      case cleaned_blocks {
        [] -> None
        _ -> Some(Message(role: User, content: cleaned_blocks))
      }
    }
    Assistant -> Some(msg)
  }
}

// ---------------------------------------------------------------------------
// Sanitisation — for `from_list`
// ---------------------------------------------------------------------------

/// Bring an arbitrary message list into a state where every API
/// invariant holds. Used once at ingest; downstream `add` calls
/// preserve the invariants.
fn sanitise(messages: List(Message)) -> List(Message) {
  messages
  |> drop_leading_assistant
  |> coalesce_same_role
  |> strip_orphan_tool_results
  |> inject_orphan_tool_use_stubs
}

fn drop_leading_assistant(messages: List(Message)) -> List(Message) {
  case messages {
    [Message(role: Assistant, ..), ..rest] -> rest
    _ -> messages
  }
}

fn coalesce_same_role(messages: List(Message)) -> List(Message) {
  case messages {
    [] -> []
    [first, ..rest] -> coalesce_loop(rest, first, [])
  }
}

fn coalesce_loop(
  remaining: List(Message),
  current: Message,
  acc: List(Message),
) -> List(Message) {
  case remaining {
    [] -> list.reverse([current, ..acc])
    [next, ..rest] ->
      case current.role == next.role {
        True ->
          coalesce_loop(
            rest,
            Message(
              role: current.role,
              content: list.append(current.content, next.content),
            ),
            acc,
          )
        False -> coalesce_loop(rest, next, [current, ..acc])
      }
  }
}

fn strip_orphan_tool_results(messages: List(Message)) -> List(Message) {
  let valid_ids =
    list.fold(messages, set.new(), fn(acc, msg) {
      case msg.role {
        Assistant ->
          list.fold(msg.content, acc, fn(s, block) {
            case block {
              ToolUseContent(id: id, ..) -> set.insert(s, id)
              _ -> s
            }
          })
        _ -> acc
      }
    })
  list.filter_map(messages, fn(msg) {
    case msg.role {
      User -> {
        let filtered =
          list.filter(msg.content, fn(block) {
            case block {
              ToolResultContent(tool_use_id: id, ..) ->
                set.contains(valid_ids, id)
              _ -> True
            }
          })
        case filtered {
          [] -> Error(Nil)
          _ -> Ok(Message(role: User, content: filtered))
        }
      }
      _ -> Ok(msg)
    }
  })
}

const orphan_stub_content = "[internal: tool call did not complete]"

/// For each assistant tool_use whose immediately-following user
/// message has no matching tool_result, inject a synthetic stub.
/// This handles the OPPOSITE direction from `strip_orphan_tool_results`.
fn inject_orphan_tool_use_stubs(messages: List(Message)) -> List(Message) {
  do_inject_stubs(messages, [])
}

fn do_inject_stubs(messages: List(Message), acc: List(Message)) -> List(Message) {
  case messages {
    [] -> list.reverse(acc)
    [
      Message(role: Assistant, content: a) as assistant,
      Message(role: User, content: u) as user_msg,
      ..rest
    ] -> {
      let tool_use_ids = list.filter_map(a, extract_tool_use_id)
      let result_ids = result_ids_set(u)
      let orphans =
        list.filter(tool_use_ids, fn(id) { !set.contains(result_ids, id) })
      case orphans {
        [] -> do_inject_stubs(rest, [user_msg, assistant, ..acc])
        _ -> {
          let stubs = list.map(orphans, stub_block)
          let patched = Message(role: User, content: list.append(stubs, u))
          do_inject_stubs(rest, [patched, assistant, ..acc])
        }
      }
    }
    [Message(role: Assistant, content: a) as assistant, ..rest] -> {
      // Trailing assistant — fabricate a follow-up user.
      let tool_use_ids = list.filter_map(a, extract_tool_use_id)
      case tool_use_ids {
        [] -> do_inject_stubs(rest, [assistant, ..acc])
        ids -> {
          let stubs = list.map(ids, stub_block)
          let patched_user = Message(role: User, content: stubs)
          do_inject_stubs(rest, [patched_user, assistant, ..acc])
        }
      }
    }
    [other, ..rest] -> do_inject_stubs(rest, [other, ..acc])
  }
}

fn extract_tool_use_id(block: ContentBlock) -> Result(String, Nil) {
  case block {
    ToolUseContent(id: id, ..) -> Ok(id)
    _ -> Error(Nil)
  }
}

fn result_ids_set(content: List(ContentBlock)) -> Set(String) {
  list.fold(content, set.new(), fn(acc, block) {
    case block {
      ToolResultContent(tool_use_id: id, ..) -> set.insert(acc, id)
      _ -> acc
    }
  })
}

fn stub_block(id: String) -> ContentBlock {
  ToolResultContent(
    tool_use_id: id,
    content: orphan_stub_content,
    is_error: True,
  )
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// Compact one-line description of the history shape. Useful in
/// debug logs when investigating "why did the cog send a poisoned
/// history" — except now it can't.
pub fn describe(h: MessageHistory) -> String {
  let counts =
    list.fold(h.messages, #(0, 0), fn(acc, msg) {
      let #(u, a) = acc
      case msg.role {
        User -> #(u + 1, a)
        Assistant -> #(u, a + 1)
      }
    })
  let #(u, a) = counts
  string.concat([
    "MessageHistory(",
    "n=",
    int_to_string(list.length(h.messages)),
    ", user=",
    int_to_string(u),
    ", assistant=",
    int_to_string(a),
    ")",
  ])
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String
