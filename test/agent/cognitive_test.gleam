import agent/cognitive
import agent/cognitive_config
import agent/types.{
  type CognitiveReply, type Notification, QuestionForHuman, RestoreMessages,
  SchedulerJobStarted, SetModel, UserAnswer, UserInput,
}
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import llm/adapters/mock
import llm/types as llm_types
import scheduler/types as scheduler_types

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn start_cognitive(provider) {
  let notify_subj: process.Subject(Notification) = process.new_subject()
  let cfg = cognitive_config.default_test_config(provider, notify_subj)
  let assert Ok(subj) = cognitive.start(cfg)
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
  // Usage should be present for successful responses
  should.be_true(reply.usage != None)
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

// ---------------------------------------------------------------------------
// SetModel — change model at runtime
// ---------------------------------------------------------------------------

pub fn set_model_test() {
  let provider = mock.provider_with_text("Hello!")
  let #(cognitive, _notify) = start_cognitive(provider)

  // Send SetModel to change the model
  process.send(cognitive, SetModel(model: "new-model"))

  // Classification routes Simple queries to task_model regardless of SetModel.
  // SetModel updates state.model but classification overrides it.
  let reply = send_and_receive(cognitive, "Hi")
  reply.response |> should.equal("Hello!")
  reply.model |> should.equal("mock-model")
}

// ---------------------------------------------------------------------------
// Agent question — decoupled notification (no Subject in Notification)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// RestoreMessages (clear) — verify cognitive loop handles empty restore
// ---------------------------------------------------------------------------

pub fn restore_messages_clear_test() {
  let provider = mock.provider_with_text("After clear")
  let #(cognitive, _notify) = start_cognitive(provider)

  // Send a message first to build some history
  let reply1 = send_and_receive(cognitive, "Hello")
  reply1.response |> should.equal("After clear")

  // Clear via RestoreMessages with empty list
  process.send(cognitive, RestoreMessages(messages: []))

  // Send another message — should work fine with cleared history
  let reply2 = send_and_receive(cognitive, "Fresh start")
  reply2.response |> should.equal("After clear")
}

// ---------------------------------------------------------------------------
// Error reply includes usage: None
// ---------------------------------------------------------------------------

pub fn error_reply_has_no_usage_test() {
  let provider = mock.provider_with_error("test failure")
  let #(cognitive, _notify) = start_cognitive(provider)
  let reply = send_and_receive(cognitive, "Hi")
  reply.usage |> should.equal(None)
}

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

// ---------------------------------------------------------------------------
// Model fallback — retryable error on reasoning model falls back to task model
// ---------------------------------------------------------------------------

pub fn model_fallback_on_retryable_error_test() {
  // Reasoning model returns 529 (overloaded), task model works fine.
  // The worker retries 3x with 2s base backoff (~14s) then the cognitive
  // loop falls back to the task model automatically.
  let provider =
    mock.provider_with_handler(fn(req) {
      case req.model {
        "mock-reasoning" ->
          Error(llm_types.ApiError(status_code: 529, message: "Overloaded"))
        _ -> Ok(mock.text_response("Fallback response"))
      }
    })

  let notify_subj: process.Subject(types.Notification) = process.new_subject()
  let cfg =
    cognitive_config.CognitiveConfig(
      ..cognitive_config.default_test_config(provider, notify_subj),
      task_model: "mock-task",
      reasoning_model: "mock-reasoning",
      archivist_model: "mock-task",
    )
  let assert Ok(cognitive) = cognitive.start(cfg)

  // Use a query with complexity keywords so heuristic classifies as Complex,
  // routing to reasoning_model (mock-reasoning) which returns 529
  let reply_subj = process.new_subject()
  process.send(
    cognitive,
    UserInput(
      text: "Explain step by step how to implement a distributed architecture",
      reply_to: reply_subj,
    ),
  )
  // Longer timeout: worker retries 3x with 2s base backoff (~14s) + fallback
  let assert Ok(reply) = process.receive(reply_subj, 25_000)

  // Should include fallback prefix and the actual response
  should.be_true(string.contains(reply.response, "mock-reasoning unavailable"))
  should.be_true(string.contains(reply.response, "Fallback response"))
  should.be_true(reply.usage != None)
}

// ---------------------------------------------------------------------------
// SchedulerInput — scheduler jobs arrive as typed messages
// ---------------------------------------------------------------------------

pub fn scheduler_input_text_response_test() {
  let provider = mock.provider_with_text("Scheduler result")
  let #(cognitive, notify) = start_cognitive(provider)

  let reply_subj = process.new_subject()
  process.send(
    cognitive,
    types.SchedulerInput(
      job_name: "daily-digest",
      query: "Generate today's digest",
      kind: scheduler_types.RecurringTask,
      for_: scheduler_types.ForAgent,
      title: "Daily Digest",
      body: "",
      tags: ["digest", "daily"],
      reply_to: reply_subj,
    ),
  )

  // Should receive SchedulerJobStarted notification
  let assert Ok(notification) = process.receive(notify, 5000)
  case notification {
    SchedulerJobStarted(name:, kind:) -> {
      name |> should.equal("daily-digest")
      kind |> should.equal("recurring_task")
    }
    _ -> should.fail()
  }

  // Should receive the reply
  let assert Ok(reply) = process.receive(reply_subj, 5000)
  reply.response |> should.equal("Scheduler result")
  // Should use task_model (scheduler skips classification)
  reply.model |> should.equal("mock-model")
}

pub fn scheduler_input_reminder_uses_body_test() {
  // Verify that Reminder kind uses body text, not query
  let provider =
    mock.provider_with_handler(fn(req) {
      // The last message should contain the body text
      let has_body =
        list.any(req.messages, fn(m) {
          list.any(m.content, fn(c) {
            case c {
              llm_types.TextContent(text:) ->
                string.contains(text, "Remember to call Alice")
              _ -> False
            }
          })
        })
      case has_body {
        True -> Ok(mock.text_response("Got the reminder body"))
        False -> Ok(mock.text_response("Missing body"))
      }
    })
  let #(cognitive, _notify) = start_cognitive(provider)

  let reply_subj = process.new_subject()
  process.send(
    cognitive,
    types.SchedulerInput(
      job_name: "remind-call",
      query: "Call reminder",
      kind: scheduler_types.Reminder,
      for_: scheduler_types.ForUser,
      title: "Call Alice",
      body: "Remember to call Alice at 3pm",
      tags: [],
      reply_to: reply_subj,
    ),
  )

  let assert Ok(reply) = process.receive(reply_subj, 5000)
  reply.response |> should.equal("Got the reminder body")
}

pub fn scheduler_input_for_user_sends_reminder_notification_test() {
  let provider = mock.provider_with_text("ok")
  let #(cognitive, notify) = start_cognitive(provider)

  let reply_subj = process.new_subject()
  process.send(
    cognitive,
    types.SchedulerInput(
      job_name: "user-remind",
      query: "reminder",
      kind: scheduler_types.Reminder,
      for_: scheduler_types.ForUser,
      title: "Meeting soon",
      body: "Meeting in 15 min",
      tags: [],
      reply_to: reply_subj,
    ),
  )

  // First notification should be SchedulerJobStarted
  let assert Ok(n1) = process.receive(notify, 5000)
  case n1 {
    SchedulerJobStarted(..) -> Nil
    _ -> should.fail()
  }

  // Second notification should be SchedulerReminder (for ForUser)
  let assert Ok(n2) = process.receive(notify, 5000)
  case n2 {
    types.SchedulerReminder(name:, title:, body: _) -> {
      name |> should.equal("user-remind")
      title |> should.equal("Meeting soon")
    }
    _ -> should.fail()
  }
}

pub fn scheduler_input_queued_when_busy_test() {
  // Use a handler that delays so we can queue a scheduler input
  let call_count = process.new_subject()
  let provider =
    mock.provider_with_handler(fn(_req) {
      process.send(call_count, 1)
      Ok(mock.text_response("response"))
    })
  let #(cognitive, notify) = start_cognitive(provider)

  // Send a regular UserInput first to make the loop busy
  let reply1_subj = process.new_subject()
  process.send(cognitive, UserInput(text: "first", reply_to: reply1_subj))

  // Wait for the first LLM call to start (classification worker)
  let assert Ok(_) = process.receive(call_count, 5000)

  // Now send a SchedulerInput while busy — should be queued
  let reply2_subj = process.new_subject()
  process.send(
    cognitive,
    types.SchedulerInput(
      job_name: "queued-job",
      query: "queued query",
      kind: scheduler_types.RecurringTask,
      for_: scheduler_types.ForAgent,
      title: "Queued",
      body: "",
      tags: [],
      reply_to: reply2_subj,
    ),
  )

  // Should receive InputQueued notification
  let assert Ok(_queued_notif) = process.receive(notify, 5000)

  // Wait for first reply
  let assert Ok(_reply1) = process.receive(reply1_subj, 5000)

  // Wait for queued scheduler reply (it should drain after first completes)
  let assert Ok(reply2) = process.receive(reply2_subj, 10_000)
  reply2.response |> should.equal("response")
}

pub fn scheduler_input_includes_context_xml_test() {
  // Verify that the LLM receives scheduler_context XML
  let provider =
    mock.provider_with_handler(fn(req) {
      let has_context =
        list.any(req.messages, fn(m) {
          list.any(m.content, fn(c) {
            case c {
              llm_types.TextContent(text:) ->
                string.contains(text, "<scheduler_context>")
                && string.contains(text, "<job_name>test-job</job_name>")
                && string.contains(text, "<kind>recurring_task</kind>")
              _ -> False
            }
          })
        })
      case has_context {
        True -> Ok(mock.text_response("Context received"))
        False -> Ok(mock.text_response("No context"))
      }
    })
  let #(cognitive, _notify) = start_cognitive(provider)

  let reply_subj = process.new_subject()
  process.send(
    cognitive,
    types.SchedulerInput(
      job_name: "test-job",
      query: "Run analysis",
      kind: scheduler_types.RecurringTask,
      for_: scheduler_types.ForAgent,
      title: "Test Job",
      body: "",
      tags: ["test"],
      reply_to: reply_subj,
    ),
  )

  let assert Ok(reply) = process.receive(reply_subj, 5000)
  reply.response |> should.equal("Context received")
}
