import context
import gleeunit/should
import llm/types.{Message, TextContent, User}

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
