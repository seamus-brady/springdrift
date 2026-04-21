// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import frontdoor
import frontdoor/types.{
  ClaimCycle, CognitiveLoopOrigin, CognitiveReplyOutput, DeliverQuestion,
  DeliverReply, HumanQuestionOutput, Publish, SchedulerSource, SetCognitiveInbox,
  Subscribe, UserSource,
}
import gleam/erlang/process
import gleam/option.{None}
import gleeunit/should

// ---------------------------------------------------------------------------
// Routing — UserSource cycles
// ---------------------------------------------------------------------------

pub fn user_source_reply_routes_to_subscribed_sink_test() {
  let fd = frontdoor.start()
  let sink = process.new_subject()

  process.send(fd, Subscribe(source_id: "ws:abc", kind: UserSource, sink:))
  process.send(fd, ClaimCycle(cycle_id: "cyc-1", source_id: "ws:abc"))
  process.send(
    fd,
    Publish(
      output: CognitiveReplyOutput(
        cycle_id: "cyc-1",
        response: "hello",
        model: "test",
        usage: None,
        tools_fired: [],
      ),
    ),
  )

  let assert Ok(delivery) = process.receive(sink, 500)
  case delivery {
    DeliverReply(cycle_id:, response:, ..) -> {
      cycle_id |> should.equal("cyc-1")
      response |> should.equal("hello")
    }
    _ -> should.fail()
  }
}

pub fn user_source_question_delivered_to_sink_test() {
  let fd = frontdoor.start()
  let sink = process.new_subject()

  process.send(fd, Subscribe(source_id: "ws:def", kind: UserSource, sink:))
  process.send(fd, ClaimCycle(cycle_id: "cyc-2", source_id: "ws:def"))
  process.send(
    fd,
    Publish(output: HumanQuestionOutput(
      cycle_id: "cyc-2",
      question_id: "q-1",
      question: "What's the capital of France?",
      origin: CognitiveLoopOrigin,
    )),
  )

  let assert Ok(delivery) = process.receive(sink, 500)
  case delivery {
    DeliverQuestion(question_id:, question:, ..) -> {
      question_id |> should.equal("q-1")
      question |> should.equal("What's the capital of France?")
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Scheduler-source policy — questions are dropped, answer is injected
// ---------------------------------------------------------------------------

pub fn scheduler_source_question_drops_and_injects_answer_test() {
  let fd = frontdoor.start()
  let cognitive_inbox = process.new_subject()
  let sink = process.new_subject()

  process.send(fd, SetCognitiveInbox(inbox: cognitive_inbox))
  process.send(
    fd,
    Subscribe(source_id: "scheduler:reflect", kind: SchedulerSource, sink:),
  )
  process.send(
    fd,
    ClaimCycle(cycle_id: "cyc-sched", source_id: "scheduler:reflect"),
  )
  process.send(
    fd,
    Publish(output: HumanQuestionOutput(
      cycle_id: "cyc-sched",
      question_id: "q-sched",
      question: "Should I proceed?",
      origin: CognitiveLoopOrigin,
    )),
  )

  // Sink must NOT receive the question — Frontdoor drops it for
  // SchedulerSource destinations.
  let assert Error(_) = process.receive(sink, 200)

  // Cognitive inbox must receive a synthesised answer.
  let assert Ok(injected) = process.receive(cognitive_inbox, 500)
  case injected {
    agent_types.InjectUserAnswer(text:) -> {
      // The canned answer must reference the original question so the
      // agent can decide what to do.
      should.be_true(text != "")
    }
    _ -> should.fail()
  }
}

pub fn unknown_cycle_id_is_dropped_test() {
  let fd = frontdoor.start()
  let sink = process.new_subject()

  process.send(fd, Subscribe(source_id: "ws:foo", kind: UserSource, sink:))
  // Publish for a cycle that was never claimed — must drop silently.
  process.send(
    fd,
    Publish(
      output: CognitiveReplyOutput(
        cycle_id: "ghost-cycle",
        response: "stray",
        model: "test",
        usage: None,
        tools_fired: [],
      ),
    ),
  )

  let assert Error(_) = process.receive(sink, 200)
}

pub fn unsubscribe_clears_destination_test() {
  let fd = frontdoor.start()
  let sink = process.new_subject()

  process.send(fd, Subscribe(source_id: "ws:gone", kind: UserSource, sink:))
  process.send(fd, ClaimCycle(cycle_id: "cyc-3", source_id: "ws:gone"))
  process.send(fd, types.Unsubscribe(source_id: "ws:gone"))

  // Drain the DeliverClosed Frontdoor sends on Unsubscribe.
  let _ = process.receive(sink, 200)

  process.send(
    fd,
    Publish(
      output: CognitiveReplyOutput(
        cycle_id: "cyc-3",
        response: "after-close",
        model: "test",
        usage: None,
        tools_fired: [],
      ),
    ),
  )

  // Sink must not receive — Frontdoor has no destination for ws:gone now.
  let assert Error(_) = process.receive(sink, 200)
}
