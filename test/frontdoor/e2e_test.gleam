//// End-to-end tests covering the Frontdoor wire-up from cognitive
//// through the Subscribe / ClaimCycle / Publish round-trip.
////
//// The scenarios here are regression guards: unit tests in
//// test/frontdoor_test.gleam cover Frontdoor routing in isolation;
//// these tests drive the real cognitive loop against a mock provider
//// and assert that Frontdoor keeps the right sink routing even when
//// multiple subscribers are connected (the chat-hijack bug from #90
//// ship).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive
import agent/cognitive_config
import agent/types.{type Notification, UserAnswer, UserInput}
import frontdoor
import frontdoor/types.{
  type Delivery, DeliverQuestion, DeliverReply, Subscribe, UserSource,
} as _
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import llm/adapters/mock

fn start_with_frontdoor(provider) {
  let notify: Subject(Notification) = process.new_subject()
  let base = cognitive_config.default_test_config(provider, notify)
  let fd = frontdoor.start()
  let cfg = cognitive_config.CognitiveConfig(..base, frontdoor: Some(fd))
  let assert Ok(cog) = cognitive.start(cfg)
  #(cog, fd)
}

fn subscribe_user(fd, source_id: String) -> Subject(Delivery) {
  let sink: Subject(Delivery) = process.new_subject()
  process.send(fd, Subscribe(source_id:, kind: UserSource, sink:))
  sink
}

// ---------------------------------------------------------------------------
// Two concurrent UserSource subscribers — only the claiming one receives
// the reply. This is the regression guard for the hijack bug that
// motivated Frontdoor: when the legacy broadcast fanned `QuestionForHuman`
// out to every WebSocket connection, every browser would enter
// `waitingForAnswer` and claim the operator's next message.
// ---------------------------------------------------------------------------

pub fn isolated_reply_routing_test() {
  let provider = mock.provider_with_text("reply to alice")
  let #(cog, fd) = start_with_frontdoor(provider)

  let alice_sink = subscribe_user(fd, "ws:alice")
  let bob_sink = subscribe_user(fd, "ws:bob")

  // Alice sends. Bob is a bystander — must not receive anything.
  let throwaway = process.new_subject()
  process.send(
    cog,
    UserInput(source_id: "ws:alice", text: "hello", reply_to: throwaway),
  )

  let assert Ok(delivery) = process.receive(alice_sink, 5000)
  case delivery {
    DeliverReply(response:, ..) -> response |> should.equal("reply to alice")
    _ -> should.fail()
  }

  // Bob's sink must be silent. Small window — the reply would have
  // landed already if the routing were wrong.
  let assert Error(_) = process.receive(bob_sink, 200)
}

// ---------------------------------------------------------------------------
// Question path: the cycle is claimed by one subscriber, the cognitive
// loop raises a human question via `request_human_input`, and the
// question lands on that subscriber's sink only. The operator's answer
// flows back through UserAnswer and the cycle terminates with a reply.
// ---------------------------------------------------------------------------

pub fn isolated_question_routing_test() {
  let provider =
    mock.provider_with_handler(fn(req) {
      case list.length(req.messages) > 2 {
        True -> Ok(mock.text_response("thanks alice"))
        False ->
          Ok(mock.tool_call_response(
            "request_human_input",
            "{\"question\": \"are you alice?\"}",
            "q-1",
          ))
      }
    })
  let #(cog, fd) = start_with_frontdoor(provider)

  let alice_sink = subscribe_user(fd, "ws:alice")
  let bob_sink = subscribe_user(fd, "ws:bob")

  let reply_subj = process.new_subject()
  process.send(
    cog,
    UserInput(source_id: "ws:alice", text: "hi", reply_to: reply_subj),
  )

  // Alice sees the question; Bob does not.
  let assert Ok(q) = process.receive(alice_sink, 5000)
  case q {
    DeliverQuestion(question:, ..) -> question |> should.equal("are you alice?")
    _ -> should.fail()
  }
  let assert Error(_) = process.receive(bob_sink, 200)

  // Alice answers — cycle completes and the reply routes to Alice only.
  process.send(cog, UserAnswer(answer: "yes"))

  let assert Ok(final) = process.receive(alice_sink, 5000)
  case final {
    DeliverReply(response:, ..) -> response |> should.equal("thanks alice")
    _ -> should.fail()
  }
  let assert Error(_) = process.receive(bob_sink, 200)
}
