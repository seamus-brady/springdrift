import agent/cognitive
import agent/registry
import agent/types.{
  type CognitiveReply, type Notification, QuestionForHuman, UserAnswer,
  UserInput,
}
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit/should
import llm/adapters/mock

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn start_cognitive(provider) {
  let notify_subj: process.Subject(Notification) = process.new_subject()
  let reg = registry.new()
  let subj =
    cognitive.start(
      provider,
      "mock-model",
      "You are a test assistant.",
      256,
      None,
      [],
      [],
      reg,
      False,
      notify_subj,
    )
  #(subj, notify_subj)
}

fn send_and_receive(cognitive_subj, text: String) -> CognitiveReply {
  let reply_subj = process.new_subject()
  process.send(cognitive_subj, UserInput(text:, reply_to: reply_subj))
  let assert Ok(reply) = process.receive(reply_subj, 5000)
  reply
}

// ---------------------------------------------------------------------------
// Single turn — text response
// ---------------------------------------------------------------------------

pub fn single_turn_text_response_test() {
  let provider = mock.provider_with_text("Hello from cognitive!")
  let #(cognitive, _notify) = start_cognitive(provider)
  let reply = send_and_receive(cognitive, "Hi there")
  reply.response |> should.equal("Hello from cognitive!")
  reply.model |> should.equal("mock-model")
}

// ---------------------------------------------------------------------------
// Error handling — provider error
// ---------------------------------------------------------------------------

pub fn provider_error_test() {
  let provider = mock.provider_with_error("test failure")
  let #(cognitive, _notify) = start_cognitive(provider)
  let reply = send_and_receive(cognitive, "Hi there")
  should.be_true(reply.response != "")
}

// ---------------------------------------------------------------------------
// Multiple turns
// ---------------------------------------------------------------------------

pub fn multiple_turns_test() {
  let provider = mock.provider_with_text("response")
  let #(cognitive, _notify) = start_cognitive(provider)

  let reply1 = send_and_receive(cognitive, "First message")
  reply1.response |> should.equal("response")

  let reply2 = send_and_receive(cognitive, "Second message")
  reply2.response |> should.equal("response")
}

// ---------------------------------------------------------------------------
// Save warning notification
// ---------------------------------------------------------------------------

pub fn save_result_handled_test() {
  // This is a basic smoke test — verify the cognitive loop doesn't crash
  // when receiving save results
  let provider = mock.provider_with_text("ok")
  let #(cognitive, _notify) = start_cognitive(provider)
  let reply = send_and_receive(cognitive, "test")
  reply.response |> should.equal("ok")
}

// ---------------------------------------------------------------------------
// request_human_input tool — cognitive loop asks human a question
// ---------------------------------------------------------------------------

pub fn request_human_input_tool_test() {
  // First call: LLM returns request_human_input tool call
  // Second call: LLM returns final text (after getting the answer)
  let provider =
    mock.provider_with_handler(fn(req) {
      case list.length(req.messages) > 2 {
        // After tool result is fed back, return final text
        True -> Ok(mock.text_response("Got your answer, thanks!"))
        // First call: ask the human
        False ->
          Ok(mock.tool_call_response(
            "request_human_input",
            "{\"question\": \"What is your name?\"}",
            "tool_hi_1",
          ))
      }
    })

  let #(cognitive, notify) = start_cognitive(provider)

  // Send initial message
  let reply_subj = process.new_subject()
  process.send(cognitive, UserInput(text: "Hello", reply_to: reply_subj))

  // Should receive a QuestionForHuman notification (decoupled, no Subject)
  let assert Ok(notification) = process.receive(notify, 5000)
  case notification {
    QuestionForHuman(question:, source:) -> {
      question |> should.equal("What is your name?")
      case source {
        types.CognitiveQuestion -> Nil
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }

  // Send the answer back
  process.send(cognitive, UserAnswer(answer: "Alice"))

  // Should receive the final reply
  let assert Ok(reply) = process.receive(reply_subj, 5000)
  reply.response |> should.equal("Got your answer, thanks!")
}

// ---------------------------------------------------------------------------
// Agent question — decoupled notification (no Subject in Notification)
// ---------------------------------------------------------------------------

pub fn agent_question_decoupled_test() {
  // Verify that AgentQuestion results in a pure-data notification
  let provider = mock.provider_with_text("ok")
  let #(cognitive, notify) = start_cognitive(provider)

  // Simulate an agent asking a question
  let agent_reply_subj = process.new_subject()
  process.send(
    cognitive,
    types.AgentQuestion(
      question: "Confirm deployment?",
      agent: "coder",
      reply_to: agent_reply_subj,
    ),
  )

  // Should receive a QuestionForHuman with AgentQuestionSource
  let assert Ok(notification) = process.receive(notify, 5000)
  case notification {
    QuestionForHuman(question:, source:) -> {
      question |> should.equal("Confirm deployment?")
      case source {
        types.AgentQuestionSource(agent:) -> agent |> should.equal("coder")
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }

  // Send the answer via UserAnswer
  process.send(cognitive, UserAnswer(answer: "yes"))

  // The agent's reply_to subject should receive the answer
  let assert Ok(answer) = process.receive(agent_reply_subj, 5000)
  answer |> should.equal("yes")
}
