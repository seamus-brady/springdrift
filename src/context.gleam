//// Context window management helpers.
////
//// Provides a sliding-window trim to keep the context within a configurable
//// message count, discarding the oldest messages first. The trim point is
//// adjusted forward to avoid splitting a ToolUseContent from its
//// corresponding ToolResultContent.

import gleam/int
import gleam/list
import gleam/option
import llm/types.{type Message, ToolUseContent}
import slog

/// Trim a message list to at most `max_messages` entries, keeping the most
/// recent ones. The cut point is adjusted to avoid orphaning tool use/result
/// pairs (which would cause a 400 from the Anthropic API).
pub fn trim(messages: List(Message), max_messages: Int) -> List(Message) {
  let total = list.length(messages)
  case total <= max_messages {
    True -> messages
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
