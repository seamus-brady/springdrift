//// Context window management helpers.
////
//// Provides a sliding-window trim to keep the context within a configurable
//// message count, discarding the oldest messages first.

import gleam/int
import gleam/list
import gleam/option
import llm/types.{type Message}
import slog

/// Trim a message list to at most `max_messages` entries, keeping the most
/// recent ones. When the list is already within the limit it is returned
/// unchanged.
pub fn trim(messages: List(Message), max_messages: Int) -> List(Message) {
  let total = list.length(messages)
  case total <= max_messages {
    True -> messages
    False -> {
      slog.debug(
        "context",
        "trim",
        "Trimming "
          <> int.to_string(total)
          <> " -> "
          <> int.to_string(max_messages),
        option.None,
      )
      list.drop(messages, total - max_messages)
    }
  }
}
