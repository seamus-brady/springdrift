import chat/service.{type ServiceReply}
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import llm/adapters/mock
import llm/types.{UnknownError}
import tools/builtin

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn start_service(provider) {
  service.start(
    provider,
    "mock-model",
    "You are a test assistant.",
    256,
    5,
    3,
    None,
    builtin.all(),
    [],
    "mock-model",
    "mock-model",
    False,
    False,
  )
}

fn send_and_receive(chat, text: String) -> ServiceReply {
  let reply_subj = process.new_subject()
  let question_channel = process.new_subject()
  let tool_channel = process.new_subject()
  let model_question_channel = process.new_subject()
  process.send(
    chat,
    service.SendMessage(
      text:,
      reply_to: reply_subj,
      question_channel:,
      tool_channel:,
      model_question_channel:,
    ),
  )
  let assert Ok(reply) = process.receive(reply_subj, 5000)
  reply
}

// ---------------------------------------------------------------------------
// single_turn_no_tools
// ---------------------------------------------------------------------------

pub fn single_turn_no_tools_test() {
  let provider = mock.provider_with_text("Hello from mock!")
  let chat = start_service(provider)
  let reply = send_and_receive(chat, "Hi there")
  reply.llm_result |> should.be_ok
  reply.save_error |> should.equal(None)
}

// ---------------------------------------------------------------------------
// multi_turn_tool_call
// ---------------------------------------------------------------------------

pub fn multi_turn_tool_call_test() {
  // First call (1 message in history): return a calculator tool-use.
  // Second call (more messages after tool result): return text.
  let provider =
    mock.provider_with_handler(fn(req) {
      case list.length(req.messages) {
        1 ->
          Ok(mock.tool_call_response(
            "calculator",
            "{\"a\":1,\"operator\":\"+\",\"b\":2}",
            "tool_123",
          ))
        _ -> Ok(mock.text_response("The answer is 3."))
      }
    })
  let chat = start_service(provider)
  let reply = send_and_receive(chat, "What is 1 + 2?")
  reply.llm_result |> should.be_ok
}

// ---------------------------------------------------------------------------
// max_turns_reached
// ---------------------------------------------------------------------------

pub fn max_turns_reached_test() {
  // Provider always returns a tool_use; loop should hit max_turns limit.
  let provider =
    mock.provider_with_handler(fn(_req) {
      Ok(mock.tool_call_response("get_today_date", "{}", "tool_loop"))
    })
  // Use max_turns: 2 so the test terminates quickly
  let chat =
    service.start(
      provider,
      "mock-model",
      "You are a test assistant.",
      256,
      2,
      3,
      None,
      builtin.all(),
      [],
      "mock-model",
      "mock-model",
      False,
      False,
    )
  let reply = send_and_receive(chat, "What date is it forever?")
  // The react_loop wraps errors in an error message and returns Ok to the
  // service, which then sends ServiceReply with an Error llm_result.
  let result = reply.llm_result
  result |> should.be_error
  let assert Error(err) = result
  err |> should.equal(UnknownError("Agent loop: maximum turns reached"))
}

// ---------------------------------------------------------------------------
// consecutive_error_circuit_breaker
// ---------------------------------------------------------------------------

pub fn consecutive_error_circuit_breaker_test() {
  // Provider always returns tool_use for an unknown tool -> ToolFailure each time.
  // With max_consecutive_errors: 2, after 2 consecutive failures it should abort.
  let provider =
    mock.provider_with_handler(fn(_req) {
      Ok(mock.tool_call_response("unknown_tool", "{}", "tool_err"))
    })
  let chat =
    service.start(
      provider,
      "mock-model",
      "You are a test assistant.",
      256,
      10,
      2,
      None,
      builtin.all(),
      [],
      "mock-model",
      "mock-model",
      False,
      False,
    )
  let reply = send_and_receive(chat, "Do something impossible")
  reply.llm_result |> should.be_error
  let assert Error(err) = reply.llm_result
  err
  |> should.equal(UnknownError("Agent loop: too many consecutive tool errors"))
}

// ---------------------------------------------------------------------------
// consecutive_errors_reset_on_success
// ---------------------------------------------------------------------------

pub fn consecutive_errors_reset_on_success_test() {
  // Two tool failures (unknown_tool), then a text response.
  // We use message count to determine which response to return.
  // After first tool failure: 3 messages (user, asst+tool_use, user+tool_result)
  // After second tool failure: 5 messages
  // max_consecutive_errors: 3 so two failures don't trip the breaker.
  let provider =
    mock.provider_with_handler(fn(req) {
      case list.length(req.messages) {
        1 -> Ok(mock.tool_call_response("unknown_tool", "{}", "tool_fail_1"))
        3 -> Ok(mock.tool_call_response("unknown_tool", "{}", "tool_fail_2"))
        _ -> Ok(mock.text_response("Done."))
      }
    })
  let chat =
    service.start(
      provider,
      "mock-model",
      "You are a test assistant.",
      256,
      10,
      3,
      None,
      builtin.all(),
      [],
      "mock-model",
      "mock-model",
      False,
      False,
    )
  let reply = send_and_receive(chat, "Try some tools")
  reply.llm_result |> should.be_ok
}
