//// Context window management helpers.
////
//// Provides a sliding-window trim to keep the context within a configurable
//// message count, discarding the oldest messages first. The trim point is
//// adjusted forward to avoid splitting a ToolUseContent from its
//// corresponding ToolResultContent, and consecutive same-role messages
//// are coalesced to maintain strict user/assistant alternation.

import gleam/int
import gleam/list
import gleam/option
import llm/types.{type Message, Message, ToolUseContent}
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
