//// Context window management helpers.
////
//// Provides a sliding-window trim to keep the context within a configurable
//// message count, discarding the oldest messages first. The trim point is
//// adjusted forward to avoid splitting a ToolUseContent from its
//// corresponding ToolResultContent, and consecutive same-role messages
//// are coalesced to maintain strict user/assistant alternation.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/int
import gleam/list
import gleam/option
import gleam/set
import gleam/string
import llm/types.{type Message, Message, ToolResultContent, ToolUseContent}
import slog

/// Trim a message list to at most `max_messages` entries, keeping the most
/// recent ones. The cut point is adjusted to avoid orphaning tool use/result
/// pairs (which would cause a 400 from the Anthropic API). After trimming,
/// consecutive same-role messages are coalesced to maintain strict alternation.
pub fn trim(messages: List(Message), max_messages: Int) -> List(Message) {
  let total = list.length(messages)
  case total <= max_messages {
    True -> ensure_alternation(messages)
    False -> {
      let drop_count = total - max_messages
      // If the message right at the cut point is an assistant message ending
      // with a ToolUseContent, the next message is likely its tool result.
      // Move the cut forward by one to keep them together.
      let adjusted_drop = adjust_cut(messages, drop_count)
      slog.debug(
        "context",
        "trim",
        "Trimming "
          <> int.to_string(total)
          <> " -> "
          <> int.to_string(total - adjusted_drop),
        option.None,
      )
      list.drop(messages, adjusted_drop)
      |> strip_orphaned_tool_results
      |> ensure_alternation
    }
  }
}

/// Coalesce consecutive same-role messages by merging their content blocks.
/// This prevents the Anthropic API from rejecting requests with
/// "messages must alternate between user and assistant roles".
/// Also ensures the first message has User role (Anthropic requirement).
pub fn ensure_alternation(messages: List(Message)) -> List(Message) {
  let coalesced = case messages {
    [] -> []
    [first, ..rest] -> coalesce_loop(rest, first, [])
  }
  // Anthropic requires the first message to be User role.
  // If the list starts with an Assistant message (can happen after trimming
  // or error recovery), drop it.
  case coalesced {
    [Message(role: types.Assistant, ..), ..rest_msgs] -> {
      slog.warn(
        "context",
        "ensure_alternation",
        "Dropped leading Assistant message to satisfy API first-message-must-be-User constraint",
        option.None,
      )
      rest_msgs
    }
    _ -> coalesced
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
        True -> {
          // Merge content blocks into the current message
          let merged =
            Message(
              role: current.role,
              content: list.append(current.content, next.content),
            )
          coalesce_loop(rest, merged, acc)
        }
        False -> coalesce_loop(rest, next, [current, ..acc])
      }
  }
}

/// If the last message being dropped contains ToolUseContent, skip one more
/// message to avoid orphaning the tool call from its result.
fn adjust_cut(messages: List(Message), drop_count: Int) -> Int {
  case list.drop(messages, drop_count - 1) {
    [boundary_msg, ..] ->
      case has_tool_use(boundary_msg) {
        True -> drop_count + 1
        False -> drop_count
      }
    _ -> drop_count
  }
}

fn has_tool_use(msg: Message) -> Bool {
  list.any(msg.content, fn(block) {
    case block {
      ToolUseContent(..) -> True
      _ -> False
    }
  })
}

/// Remove orphaned tool_result blocks whose tool_use_id has no matching
/// tool_use block in any assistant message. This prevents API 400 errors
/// after trimming drops the assistant message containing the tool_use.
fn strip_orphaned_tool_results(messages: List(Message)) -> List(Message) {
  // Collect all tool_use_ids from assistant messages
  let valid_ids =
    list.fold(messages, set.new(), fn(acc, msg) {
      case msg.role {
        types.Assistant ->
          list.fold(msg.content, acc, fn(s, block) {
            case block {
              ToolUseContent(id: id, ..) -> set.insert(s, id)
              _ -> s
            }
          })
        _ -> acc
      }
    })
  // Filter out tool_result blocks with orphaned IDs
  list.filter_map(messages, fn(msg) {
    case msg.role {
      types.User -> {
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
          _ -> Ok(Message(..msg, content: filtered))
        }
      }
      _ -> Ok(msg)
    }
  })
}

/// Estimate token count for a message list using character count ÷ 4.
/// This is a rough approximation but sufficient for safety trimming.
fn estimate_tokens(messages: List(Message)) -> Int {
  let chars =
    list.fold(messages, 0, fn(acc, msg) {
      acc
      + list.fold(msg.content, 0, fn(block_acc, block) {
        block_acc + content_block_chars(block)
      })
    })
  chars / 4
}

fn content_block_chars(block: types.ContentBlock) -> Int {
  case block {
    types.TextContent(text:) -> string.length(text)
    types.ToolUseContent(id: _, name: n, input_json: i) ->
      string.length(n) + string.length(i)
    types.ToolResultContent(tool_use_id: _, content:, is_error: _) ->
      string.length(content)
    types.ThinkingContent(text:) -> string.length(text)
    types.ImageContent(..) -> 1000
  }
}

/// Hard trim messages to stay within a token budget. Drops oldest messages
/// until the estimated token count is under the limit. This is the safety
/// net that prevents 400 errors from the API.
pub fn trim_to_token_budget(
  messages: List(Message),
  max_tokens: Int,
) -> List(Message) {
  case estimate_tokens(messages) <= max_tokens {
    True -> messages
    False -> {
      let total = list.length(messages)
      // Binary search would be faster but this runs at most ~20 iterations
      // for typical sessions. Drop messages one at a time from the front.
      trim_tokens_loop(messages, total, max_tokens)
    }
  }
}

fn trim_tokens_loop(
  messages: List(Message),
  total: Int,
  max_tokens: Int,
) -> List(Message) {
  case total <= 2 {
    True -> messages
    False -> {
      // Drop 10% of remaining messages each iteration for speed
      let drop_count = int.max(1, total / 10)
      let dropped = list.drop(messages, drop_count)
      let remaining = total - drop_count
      case estimate_tokens(dropped) <= max_tokens {
        True -> {
          slog.warn(
            "context",
            "trim_to_token_budget",
            "Token budget trim: "
              <> int.to_string(total)
              <> " -> "
              <> int.to_string(remaining)
              <> " messages (~"
              <> int.to_string(estimate_tokens(dropped))
              <> " tokens)",
            option.None,
          )
          dropped
          |> strip_orphaned_tool_results
          |> ensure_alternation
        }
        False -> trim_tokens_loop(dropped, remaining, max_tokens)
      }
    }
  }
}
