import context
import gleeunit/should
import llm/types.{
  Assistant, Message, TextContent, ToolResultContent, ToolUseContent, User,
}

fn msg(text: String) -> types.Message {
  Message(role: User, content: [TextContent(text:)])
}

pub fn trim_within_limit_returns_unchanged_test() {
  let msgs = [msg("a"), msg("b"), msg("c")]
  context.trim(msgs, 5) |> should.equal(msgs)
}

pub fn trim_exactly_at_limit_returns_unchanged_test() {
  let msgs = [msg("a"), msg("b"), msg("c")]
  context.trim(msgs, 3) |> should.equal(msgs)
}

pub fn trim_exceeds_limit_drops_oldest_test() {
  let msgs = [msg("a"), msg("b"), msg("c"), msg("d"), msg("e")]
  context.trim(msgs, 3) |> should.equal([msg("c"), msg("d"), msg("e")])
}

pub fn trim_to_one_keeps_last_test() {
  let msgs = [msg("x"), msg("y"), msg("z")]
  context.trim(msgs, 1) |> should.equal([msg("z")])
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
    msg("a"),
    msg("b"),
    tool_use_msg,
    tool_result_msg,
    msg("d"),
    msg("final"),
  ]
  // 6 msgs, limit 3 → drop_count = 3. Boundary (last dropped) = tool_use_msg.
  // Adjustment: drop 4 instead of 3 → keeps [msg("d"), msg("final")].
  // Better to lose one extra message than send an orphaned tool_use to the API.
  let result = context.trim(msgs, 3)
  result |> should.equal([msg("d"), msg("final")])
}

pub fn trim_no_adjustment_when_boundary_is_text_test() {
  // When the boundary message is plain text, no adjustment needed.
  let msgs = [msg("a"), msg("b"), msg("c"), msg("d")]
  context.trim(msgs, 2) |> should.equal([msg("c"), msg("d")])
}
