import context
import gleam/list
import gleeunit/should
import llm/types.{
  Assistant, Message, TextContent, ToolResultContent, ToolUseContent, User,
}

fn user_msg(text: String) -> types.Message {
  Message(role: User, content: [TextContent(text:)])
}

fn assistant_msg(text: String) -> types.Message {
  Message(role: Assistant, content: [TextContent(text:)])
}

/// Build an alternating user/assistant message list
fn alternating(texts: List(String)) -> List(types.Message) {
  list.index_map(texts, fn(text, i) {
    case i % 2 {
      0 -> user_msg(text)
      _ -> assistant_msg(text)
    }
  })
}

pub fn trim_within_limit_returns_unchanged_test() {
  let msgs = alternating(["a", "b", "c"])
  context.trim(msgs, 5) |> should.equal(msgs)
}

pub fn trim_exactly_at_limit_returns_unchanged_test() {
  let msgs = alternating(["a", "b", "c"])
  context.trim(msgs, 3) |> should.equal(msgs)
}

pub fn trim_exceeds_limit_drops_oldest_test() {
  let msgs = alternating(["a", "b", "c", "d", "e"])
  context.trim(msgs, 3)
  |> should.equal(alternating(["c", "d", "e"]))
}

pub fn trim_to_one_keeps_last_test() {
  let msgs = alternating(["x", "y", "z"])
  context.trim(msgs, 1) |> should.equal([user_msg("z")])
}

pub fn trim_empty_list_test() {
  context.trim([], 5) |> should.equal([])
}

pub fn trim_preserves_tool_use_result_pair_test() {
  // If the last dropped message has ToolUseContent, the trim should drop
  // one more to avoid orphaning it from its tool result.
  let tool_use_msg =
    Message(role: Assistant, content: [
      ToolUseContent(id: "t1", name: "calc", input_json: "{}"),
    ])
  let tool_result_msg =
    Message(role: User, content: [
      ToolResultContent(tool_use_id: "t1", content: "42", is_error: False),
    ])
  let msgs = [
    user_msg("a"),
    assistant_msg("b"),
    tool_use_msg,
    tool_result_msg,
    assistant_msg("d"),
    user_msg("final"),
  ]
  // 6 msgs, limit 3 → drop_count = 3. Boundary (last dropped) = tool_use_msg.
  // Adjustment: drop 4 instead of 3 → keeps [assistant("d"), user("final")].
  // Then ensure_alternation drops leading Assistant → [user("final")].
  let result = context.trim(msgs, 3)
  result |> should.equal([user_msg("final")])
}

pub fn trim_no_adjustment_when_boundary_is_text_test() {
  // When the boundary message is plain text, no adjustment needed.
  let msgs = alternating(["a", "b", "c", "d"])
  context.trim(msgs, 2) |> should.equal([user_msg("c"), assistant_msg("d")])
}

// ---------------------------------------------------------------------------
// ensure_alternation — coalesces consecutive same-role messages
// ---------------------------------------------------------------------------

pub fn alternation_already_correct_test() {
  let msgs = [user_msg("a"), assistant_msg("b"), user_msg("c")]
  context.ensure_alternation(msgs) |> should.equal(msgs)
}

pub fn alternation_merges_consecutive_user_messages_test() {
  let msgs = [user_msg("a"), user_msg("b"), assistant_msg("c")]
  let result = context.ensure_alternation(msgs)
  result
  |> should.equal([
    Message(role: User, content: [TextContent("a"), TextContent("b")]),
    assistant_msg("c"),
  ])
}

pub fn alternation_merges_consecutive_assistant_messages_test() {
  let msgs = [
    user_msg("a"),
    assistant_msg("b"),
    assistant_msg("c"),
    user_msg("d"),
  ]
  let result = context.ensure_alternation(msgs)
  result
  |> should.equal([
    user_msg("a"),
    Message(role: Assistant, content: [TextContent("b"), TextContent("c")]),
    user_msg("d"),
  ])
}

pub fn alternation_merges_three_consecutive_test() {
  let msgs = [user_msg("a"), user_msg("b"), user_msg("c"), assistant_msg("d")]
  let result = context.ensure_alternation(msgs)
  result
  |> should.equal([
    Message(role: User, content: [
      TextContent("a"),
      TextContent("b"),
      TextContent("c"),
    ]),
    assistant_msg("d"),
  ])
}

pub fn alternation_drops_leading_assistant_test() {
  // Anthropic requires first message to be User role
  let msgs = [assistant_msg("a"), user_msg("b"), assistant_msg("c")]
  context.ensure_alternation(msgs)
  |> should.equal([user_msg("b"), assistant_msg("c")])
}

pub fn alternation_empty_list_test() {
  context.ensure_alternation([]) |> should.equal([])
}

pub fn alternation_single_message_test() {
  context.ensure_alternation([user_msg("a")])
  |> should.equal([user_msg("a")])
}

pub fn trim_coalesces_after_cut_test() {
  // After trimming, if the first remaining messages have the same role,
  // they should be coalesced.
  // [user, assistant, user, user, assistant] with limit 3
  // drop 2 → [user, user, assistant] → coalesced to [user(merged), assistant]
  let msgs = [
    user_msg("a"),
    assistant_msg("b"),
    user_msg("c"),
    user_msg("d"),
    assistant_msg("e"),
  ]
  let result = context.trim(msgs, 3)
  result
  |> should.equal([
    Message(role: User, content: [TextContent("c"), TextContent("d")]),
    assistant_msg("e"),
  ])
}
