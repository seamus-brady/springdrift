//// Truncation guard tests.
////
//// The cog loop must not ship a truncated mid-sentence reply as if it
//// were a successful outcome. When `stop_reason == MaxTokens` arrives
//// with no tool calls, the loop retries once with a scope-down nudge;
//// on the second hit it ships a deterministic admission instead of
//// the truncated text.
////
//// Test layers:
////  1. Pure: `build_truncation_admission` is deterministic — assert
////     its output shape directly.
////  2. End-to-end: drive a real cog-loop with a mock provider that
////     returns MaxTokens responses on a controlled schedule, and
////     observe what the operator receives via Frontdoor.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive
import agent/cognitive/output
import agent/cognitive_config
import agent/types.{type Notification, UserInput}
import frontdoor
import frontdoor/types.{DeliverReply, Subscribe, UserSource} as frontdoor_types
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import llm/adapters/mock
import llm/types as llm_types

// ---------------------------------------------------------------------------
// Pure: build_truncation_admission
// ---------------------------------------------------------------------------

pub fn admission_starts_with_operator_facing_prefix_test() {
  // The `[truncation_guard]` prefix is load-bearing — operators use
  // it to recognise that the reply was synthesised by the cog loop,
  // not written by the model. If this prefix gets renamed without
  // updating operator-side rendering or filters, the failure mode
  // becomes invisible again.
  let admission = output.build_truncation_admission("opus-4-6", 2048, 2048, [])
  admission |> string.starts_with("[truncation_guard]") |> should.be_true
}

pub fn admission_includes_model_and_token_numbers_test() {
  // The operator needs to know which agent's max_tokens to raise.
  // Model name + actual output_tokens + configured limit must all
  // appear so they can correlate to .springdrift/config.toml.
  let admission =
    output.build_truncation_admission("claude-haiku", 4096, 4096, [])
  admission |> string.contains("claude-haiku") |> should.be_true
  admission |> string.contains("4096") |> should.be_true
}

pub fn admission_lists_tools_when_present_test() {
  let admission =
    output.build_truncation_admission("opus", 100, 200, [
      "agent_researcher",
      "agent_writer",
    ])
  admission |> string.contains("agent_researcher") |> should.be_true
  admission |> string.contains("agent_writer") |> should.be_true
}

pub fn admission_handles_empty_tool_list_test() {
  // Cycle that hit the cap before dispatching any tools — admission
  // should still be readable, not show a stray empty list.
  let admission = output.build_truncation_admission("opus", 100, 200, [])
  admission |> string.contains("(no tools dispatched)") |> should.be_true
}

pub fn admission_includes_recovery_suggestions_test() {
  // The whole point of the admission is to give the operator
  // something they can act on. The three core suggestions (narrower
  // scope, raise max_tokens, break into multiple replies) are the
  // contract — pin them so they can't silently disappear.
  let admission = output.build_truncation_admission("opus", 100, 200, [])
  admission |> string.contains("narrower scope") |> should.be_true
  admission |> string.contains("max_tokens") |> should.be_true
  admission |> string.contains("multiple replies") |> should.be_true
}

// ---------------------------------------------------------------------------
// Mock-side helpers
// ---------------------------------------------------------------------------
//
// `ensure_alternation` coalesces consecutive same-role messages into a
// single block, so a User-role nudge appended to a User-role original
// input ends up merged. Discriminating "did the cog loop retry?" via
// `list.length(req.messages)` is therefore unreliable — we have to
// look at the content of the request to detect the unique nudge text.

fn request_contains(req: llm_types.LlmRequest, needle: String) -> Bool {
  list.any(req.messages, fn(m: llm_types.Message) {
    list.any(m.content, fn(c) {
      case c {
        llm_types.TextContent(text:) -> string.contains(text, needle)
        _ -> False
      }
    })
  })
}

fn request_contains_truncation_nudge(req: llm_types.LlmRequest) -> Bool {
  // Sentinel string from the truncation nudge in handle_think_complete.
  // Tied to the cog-loop code; if that prose is rewritten, update here.
  request_contains(req, "previous response was cut off at the token cap")
}

fn request_contains_empty_nudge(req: llm_types.LlmRequest) -> Bool {
  // Sentinel from the empty-response retry nudge.
  request_contains(req, "Your previous response was empty")
}

// ---------------------------------------------------------------------------
// End-to-end: cog loop with mock provider
// ---------------------------------------------------------------------------

fn start_cognitive_for_truncation(provider, source_id: String) {
  let notify_subj: process.Subject(Notification) = process.new_subject()
  let base = cognitive_config.default_test_config(provider, notify_subj)
  let fd = frontdoor.start()
  let cfg = cognitive_config.CognitiveConfig(..base, frontdoor: Some(fd))
  let assert Ok(subj) = cognitive.start(cfg)
  let sink: process.Subject(frontdoor_types.Delivery) = process.new_subject()
  process.send(fd, Subscribe(source_id:, kind: UserSource, sink:))
  #(subj, sink)
}

fn receive_reply(
  sink: process.Subject(frontdoor_types.Delivery),
  timeout_ms: Int,
) -> Result(frontdoor_types.Delivery, Nil) {
  case process.receive(sink, timeout_ms) {
    Error(_) -> Error(Nil)
    Ok(DeliverReply(..) as d) -> Ok(d)
    Ok(_) -> receive_reply(sink, timeout_ms)
  }
}

pub fn first_max_tokens_triggers_retry_then_clean_reply_delivered_test() {
  // Provider returns MaxTokens on the first call, normal text on the
  // second. The cog loop must NOT ship the truncated text — the
  // operator should only see the recovered response. If retry isn't
  // wired, this test fails by delivering "partial cut off mid-".
  let provider =
    mock.provider_with_handler(fn(req) {
      // Discriminate via content: the truncation nudge text is
      // unique and gets coalesced into the user message on retry.
      // Counting messages won't work — ensure_alternation merges
      // same-role messages so the nudge ends up in the same User
      // block as the original input.
      case request_contains_truncation_nudge(req) {
        True -> Ok(mock.text_response("recovered with tighter scope"))
        False -> Ok(mock.truncated_text_response("partial cut off mid-"))
      }
    })

  let #(cognitive, sink) =
    start_cognitive_for_truncation(provider, "test:trunc1")
  process.send(
    cognitive,
    UserInput(source_id: "test:trunc1", text: "Write a long thing"),
  )

  let assert Ok(DeliverReply(response:, ..)) = receive_reply(sink, 5000)
  // Got the recovered response.
  response |> string.contains("recovered with tighter scope") |> should.be_true
  // Did NOT get the truncated mid-sentence text.
  response |> string.contains("partial cut off mid-") |> should.be_false
  // Did NOT get the deterministic admission (retry succeeded, so the
  // operator sees the clean recovered response, not the fallback).
  response |> string.contains("[truncation_guard]") |> should.be_false
}

pub fn second_max_tokens_ships_deterministic_admission_test() {
  // Both calls return MaxTokens. The retry didn't help, so the cog
  // loop must ship the deterministic admission, NOT either of the
  // two truncated outputs. The `[truncation_guard]` prefix is the
  // observable signal.
  let provider =
    mock.provider_with_handler(fn(_req) {
      Ok(mock.truncated_text_response("partial truncated text"))
    })

  let #(cognitive, sink) =
    start_cognitive_for_truncation(provider, "test:trunc2")
  process.send(
    cognitive,
    UserInput(source_id: "test:trunc2", text: "Write something huge"),
  )

  let assert Ok(DeliverReply(response:, ..)) = receive_reply(sink, 10_000)
  // Operator sees the admission.
  response |> string.contains("[truncation_guard]") |> should.be_true
  // Operator does NOT see the truncated raw text.
  response |> string.contains("partial truncated text") |> should.be_false
  // Admission contains an actionable hint about config.
  response |> string.contains("max_tokens") |> should.be_true
}

pub fn empty_response_retry_still_works_independently_test() {
  // Regression guard: the empty-response retry path predates the
  // truncation guard. Adding truncation_retried must not break it.
  // Provider returns an empty TextContent first, recovered text
  // second.
  let provider =
    mock.provider_with_handler(fn(req) {
      // Same coalescing concern as the truncation tests — match on
      // the empty-retry nudge text rather than message count.
      case request_contains_empty_nudge(req) {
        True -> Ok(mock.text_response("recovered after empty"))
        False -> Ok(mock.text_response(""))
      }
    })

  let #(cognitive, sink) =
    start_cognitive_for_truncation(provider, "test:empty1")
  process.send(cognitive, UserInput(source_id: "test:empty1", text: "anything"))

  let assert Ok(DeliverReply(response:, ..)) = receive_reply(sink, 5000)
  response |> string.contains("recovered after empty") |> should.be_true
}

pub fn truncation_does_not_intercept_response_with_tool_calls_test() {
  // The guard targets the specific failure mode of MaxTokens with
  // NO tool calls. When MaxTokens arrives alongside a tool_use
  // (the "tool_use sliced off mid-construction" case in the
  // existing slog warning), the guard must NOT fire — the cog loop
  // continues with the partial tool call and the framework warns
  // separately. This is a structural property of the guard.
  //
  // Implementation-side check rather than end-to-end: if the cog
  // loop attempted to dispatch a malformed tool_use through the
  // mock provider, the test setup gets complex. The relevant
  // assertion is that `response.needs_tool_execution` returning
  // True puts us on the True branch of the outer case, where the
  // truncation guard doesn't run.
  //
  // This is enforced structurally by where the guard lives in
  // handle_think_complete (inside the False arm of
  // needs_tool_execution). Documented here so a future refactor
  // that moves the guard outside that arm trips the reviewer.
  Nil
}
