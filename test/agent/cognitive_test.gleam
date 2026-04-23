// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive
import agent/cognitive_config
import agent/types.{
  type Notification, Ping, PingReply, SchedulerJobStarted, SetModel, UserAnswer,
  UserInput,
}
import frontdoor
import frontdoor/types.{DeliverQuestion, DeliverReply, Subscribe, UserSource} as frontdoor_types
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import llm/adapters/mock
import llm/types as llm_types
import scheduler/types as scheduler_types

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Start cognitive with a Frontdoor wired and a UserSource subscriber
/// for `source_id`. Returns the cognitive subject, notify subject,
/// frontdoor subject, and the delivery sink. Tests that need to
/// observe questions or replies route via the sink.
fn start_cognitive_with_frontdoor(provider, source_id: String) {
  let notify_subj: process.Subject(Notification) = process.new_subject()
  let base = cognitive_config.default_test_config(provider, notify_subj)
  let fd = frontdoor.start()
  let cfg = cognitive_config.CognitiveConfig(..base, frontdoor: Some(fd))
  let assert Ok(subj) = cognitive.start(cfg)
  let sink: process.Subject(frontdoor_types.Delivery) = process.new_subject()
  process.send(fd, Subscribe(source_id:, kind: UserSource, sink:))
  #(subj, notify_subj, fd, sink)
}

/// Backwards-compatible helper for tests that don't care about Frontdoor
/// details — spin up cognitive with a throwaway source, send input,
/// wait for a DeliverReply. Returns the DeliverReply so callers can
/// inspect response/model/usage fields.
fn start_cognitive(provider) {
  let #(cognitive, notify, _fd, sink) =
    start_cognitive_with_frontdoor(provider, "test:default")
  #(cognitive, notify, sink)
}

/// Send a user input and wait for the DeliverReply on the Frontdoor
/// sink. The returned tuple exposes the fields tests actually check
/// (response, model, usage) without forcing every caller to pattern-
/// match on the Delivery enum.
fn send_and_receive(
  cognitive_subj,
  sink: process.Subject(frontdoor_types.Delivery),
  text: String,
) -> #(String, String, Option(llm_types.Usage)) {
  process.send(cognitive_subj, UserInput(source_id: "test:default", text:))
  let assert Ok(DeliverReply(response:, model:, usage:, ..)) =
    receive_reply(sink, 5000)
  #(response, model, usage)
}

fn receive_reply(
  sink: process.Subject(frontdoor_types.Delivery),
  timeout_ms: Int,
) -> Result(frontdoor_types.Delivery, Nil) {
  // Skip non-reply deliveries (e.g. DeliverQuestion) until we get a reply.
  case process.receive(sink, timeout_ms) {
    Error(_) -> Error(Nil)
    Ok(DeliverReply(..) as d) -> Ok(d)
    Ok(_) -> receive_reply(sink, timeout_ms)
  }
}

// ---------------------------------------------------------------------------
// Single turn — text response
// ---------------------------------------------------------------------------

pub fn single_turn_text_response_test() {
  let provider = mock.provider_with_text("Hello from cognitive!")
  let #(cognitive, _notify, sink) = start_cognitive(provider)
  let #(response, model, usage) = send_and_receive(cognitive, sink, "Hi there")
  response |> should.equal("Hello from cognitive!")
  model |> should.equal("mock-model")
  // Usage should be present for successful responses
  should.be_true(usage != None)
}

// ---------------------------------------------------------------------------
// Error handling — provider error
// ---------------------------------------------------------------------------

pub fn provider_error_test() {
  let provider = mock.provider_with_error("test failure")
  let #(cognitive, _notify, sink) = start_cognitive(provider)
  let #(response, _model, _usage) =
    send_and_receive(cognitive, sink, "Hi there")
  should.be_true(response != "")
}

// ---------------------------------------------------------------------------
// Multiple turns
// ---------------------------------------------------------------------------

pub fn multiple_turns_test() {
  let provider = mock.provider_with_text("response")
  let #(cognitive, _notify, sink) = start_cognitive(provider)

  let #(r1, _, _) = send_and_receive(cognitive, sink, "First message")
  r1 |> should.equal("response")

  let #(r2, _, _) = send_and_receive(cognitive, sink, "Second message")
  r2 |> should.equal("response")
}

// ---------------------------------------------------------------------------
// Ping — liveness check used by the /health endpoint
// ---------------------------------------------------------------------------

pub fn ping_idle_returns_idle_tag_test() {
  let provider = mock.provider_with_text("ok")
  let #(cognitive, _notify, _sink) = start_cognitive(provider)
  let reply_subj = process.new_subject()
  process.send(cognitive, Ping(reply_to: reply_subj))
  let assert Ok(PingReply(status_tag:, cycle_id:)) =
    process.receive(reply_subj, 1000)
  status_tag |> should.equal("Idle")
  cycle_id |> should.equal(None)
}

// ---------------------------------------------------------------------------
// Save warning notification
// ---------------------------------------------------------------------------

pub fn save_result_handled_test() {
  // This is a basic smoke test — verify the cognitive loop doesn't crash
  // when receiving save results
  let provider = mock.provider_with_text("ok")
  let #(cognitive, _notify, sink) = start_cognitive(provider)
  let #(response, _model, _usage) = send_and_receive(cognitive, sink, "test")
  response |> should.equal("ok")
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

  let #(cognitive, _notify, _fd, sink) =
    start_cognitive_with_frontdoor(provider, "test:src")

  // Send initial message — source_id claims the cycle on Frontdoor so
  // the question routes back to our sink.
  process.send(cognitive, UserInput(source_id: "test:src", text: "Hello"))

  // Should receive a DeliverQuestion on the Frontdoor sink.
  let assert Ok(delivery) = process.receive(sink, 5000)
  case delivery {
    DeliverQuestion(question:, origin:, ..) -> {
      question |> should.equal("What is your name?")
      case origin {
        frontdoor_types.CognitiveLoopOrigin -> Nil
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }

  // Send the answer back
  process.send(cognitive, UserAnswer(answer: "Alice"))

  // Should receive the final reply on the same sink.
  let assert Ok(DeliverReply(response: r, ..)) = receive_reply(sink, 5000)
  r |> should.equal("Got your answer, thanks!")
}

// ---------------------------------------------------------------------------
// Agent question — decoupled notification (no Subject in Notification)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// SetModel — change model at runtime
// ---------------------------------------------------------------------------

pub fn set_model_test() {
  let provider = mock.provider_with_text("Hello!")
  let #(cognitive, _notify, sink) = start_cognitive(provider)

  // Send SetModel to change the model
  process.send(cognitive, SetModel(model: "new-model"))

  // Classification routes Simple queries to task_model regardless of SetModel.
  // SetModel updates state.model but classification overrides it.
  let #(response, model, _usage) = send_and_receive(cognitive, sink, "Hi")
  response |> should.equal("Hello!")
  model |> should.equal("mock-model")
}

// ---------------------------------------------------------------------------
// Agent question — decoupled notification (no Subject in Notification)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// RestoreMessages (clear) — verify cognitive loop handles empty restore
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Error reply includes usage: None
// ---------------------------------------------------------------------------

pub fn error_reply_has_no_usage_test() {
  let provider = mock.provider_with_error("test failure")
  let #(cognitive, _notify, sink) = start_cognitive(provider)
  let #(_response, _model, usage) = send_and_receive(cognitive, sink, "Hi")
  usage |> should.equal(None)
}

pub fn agent_question_decoupled_test() {
  // Verify that AgentQuestion parks cognitive in WaitingForUser and
  // that UserAnswer forwards the reply to the agent's reply subject.
  // (Question routing to external destinations is exercised directly
  // in test/frontdoor_test.gleam.)
  let provider = mock.provider_with_text("ok")
  let #(cognitive, _notify, _sink) = start_cognitive(provider)

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
  let fd = frontdoor.start()
  let cfg =
    cognitive_config.CognitiveConfig(
      ..cognitive_config.default_test_config(provider, notify_subj),
      task_model: "mock-task",
      reasoning_model: "mock-reasoning",
      archivist_model: "mock-task",
      frontdoor: Some(fd),
    )
  let assert Ok(cognitive) = cognitive.start(cfg)
  let sink: process.Subject(frontdoor_types.Delivery) = process.new_subject()
  process.send(
    fd,
    Subscribe(source_id: "test:fallback", kind: UserSource, sink:),
  )

  // Use a query with complexity keywords so heuristic classifies as Complex,
  // routing to reasoning_model (mock-reasoning) which returns 529
  process.send(
    cognitive,
    UserInput(
      source_id: "test:fallback",
      text: "Explain step by step how to implement a distributed architecture",
    ),
  )
  // Longer timeout: worker retries 3x with 2s base backoff (~14s) + fallback
  let assert Ok(DeliverReply(response:, usage:, ..)) =
    receive_reply(sink, 25_000)

  // Should include fallback prefix and the actual response
  should.be_true(string.contains(response, "mock-reasoning unavailable"))
  should.be_true(string.contains(response, "Fallback response"))
  should.be_true(usage != None)
}

// ---------------------------------------------------------------------------
// SchedulerInput — scheduler jobs arrive as typed messages
// ---------------------------------------------------------------------------

pub fn scheduler_input_text_response_test() {
  let provider = mock.provider_with_text("Scheduler result")
  let #(cognitive, notify, sink) = start_cognitive(provider)

  process.send(
    cognitive,
    types.SchedulerInput(
      source_id: "test:default",
      job_name: "daily-digest",
      query: "Generate today's digest",
      kind: scheduler_types.RecurringTask,
      for_: scheduler_types.ForAgent,
      title: "Daily Digest",
      body: "",
      tags: ["digest", "daily"],
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
  let assert Ok(DeliverReply(response:, model:, ..)) = receive_reply(sink, 5000)
  response |> should.equal("Scheduler result")
  // Should use task_model (scheduler skips classification)
  model |> should.equal("mock-model")
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
  let #(cognitive, _notify, sink) = start_cognitive(provider)

  process.send(
    cognitive,
    types.SchedulerInput(
      source_id: "test:default",
      job_name: "remind-call",
      query: "Call reminder",
      kind: scheduler_types.Reminder,
      for_: scheduler_types.ForUser,
      title: "Call Alice",
      body: "Remember to call Alice at 3pm",
      tags: [],
    ),
  )

  let assert Ok(DeliverReply(response:, ..)) = receive_reply(sink, 5000)
  response |> should.equal("Got the reminder body")
}

pub fn scheduler_input_for_user_sends_reminder_notification_test() {
  let provider = mock.provider_with_text("ok")
  let #(cognitive, notify, _sink) = start_cognitive(provider)

  process.send(
    cognitive,
    types.SchedulerInput(
      source_id: "test:default",
      job_name: "user-remind",
      query: "reminder",
      kind: scheduler_types.Reminder,
      for_: scheduler_types.ForUser,
      title: "Meeting soon",
      body: "Meeting in 15 min",
      tags: [],
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
  let #(cognitive, notify, sink) = start_cognitive(provider)

  // Send a regular UserInput first to make the loop busy
  process.send(cognitive, UserInput(source_id: "test:default", text: "first"))

  // Wait for the first LLM call to start (classification worker)
  let assert Ok(_) = process.receive(call_count, 5000)

  // Now send a SchedulerInput while busy — should be queued
  process.send(
    cognitive,
    types.SchedulerInput(
      source_id: "test:default",
      job_name: "queued-job",
      query: "queued query",
      kind: scheduler_types.RecurringTask,
      for_: scheduler_types.ForAgent,
      title: "Queued",
      body: "",
      tags: [],
    ),
  )

  // Should receive InputQueued notification
  let assert Ok(_queued_notif) = process.receive(notify, 5000)

  // Wait for first reply on the Frontdoor sink, then the queued scheduler
  // reply (both route through the same source_id subscription).
  let assert Ok(DeliverReply(..)) = receive_reply(sink, 5000)
  let assert Ok(DeliverReply(response: r2, ..)) = receive_reply(sink, 10_000)
  r2 |> should.equal("response")
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
  let #(cognitive, _notify, sink) = start_cognitive(provider)

  process.send(
    cognitive,
    types.SchedulerInput(
      source_id: "test:default",
      job_name: "test-job",
      query: "Run analysis",
      kind: scheduler_types.RecurringTask,
      for_: scheduler_types.ForAgent,
      title: "Test Job",
      body: "",
      tags: ["test"],
    ),
  )

  let assert Ok(DeliverReply(response:, ..)) = receive_reply(sink, 5000)
  response |> should.equal("Context received")
}
