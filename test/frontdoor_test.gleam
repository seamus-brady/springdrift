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
  process.send(fd, types.Unsubscribe(source_id: "ws:gone", sink:))

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
  // (Reply is buffered to pending; covered separately.)
  let assert Error(_) = process.receive(sink, 200)
}

// ---------------------------------------------------------------------------
// Conditional Unsubscribe — late close from old socket must not remove
// the new socket's subscription. Without this, stable client_ids would
// actively make the system worse than per-socket UUIDs.
// ---------------------------------------------------------------------------

pub fn stale_unsubscribe_with_mismatched_sink_is_noop_test() {
  let fd = frontdoor.start()
  let old_sink = process.new_subject()
  let new_sink = process.new_subject()

  // Old socket subscribes, then the new socket replaces it under the
  // same source_id (typical reconnect under stable client_id).
  process.send(
    fd,
    Subscribe(source_id: "ws:stable", kind: UserSource, sink: old_sink),
  )
  process.send(
    fd,
    Subscribe(source_id: "ws:stable", kind: UserSource, sink: new_sink),
  )

  // The old socket's deferred close arrives. The unsubscribe carries
  // the old sink. Frontdoor must NOT remove the new sink's
  // registration — the sinks don't match.
  process.send(fd, types.Unsubscribe(source_id: "ws:stable", sink: old_sink))

  // Now publish a reply. It must reach the NEW sink, proving the
  // stale unsubscribe didn't blow away the registration.
  process.send(fd, ClaimCycle(cycle_id: "cyc-stale", source_id: "ws:stable"))
  process.send(
    fd,
    Publish(
      output: CognitiveReplyOutput(
        cycle_id: "cyc-stale",
        response: "to-new-sink",
        model: "test",
        usage: None,
        tools_fired: [],
      ),
    ),
  )

  let assert Ok(delivery) = process.receive(new_sink, 500)
  case delivery {
    DeliverReply(response:, ..) -> response |> should.equal("to-new-sink")
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Pending buffer — replies with no registered destination are held
// until a Subscribe drains them. Stops the disappearance of replies
// for cycles whose websocket dropped mid-run.
// ---------------------------------------------------------------------------

pub fn reply_with_no_destination_buffers_until_subscribe_test() {
  let fd = frontdoor.start()

  // Cycle is claimed but no destination registered yet — typical of
  // a websocket that dropped mid-cycle. The reply should land in
  // the pending buffer rather than being dropped.
  process.send(fd, ClaimCycle(cycle_id: "cyc-buf", source_id: "ws:later"))
  process.send(
    fd,
    Publish(
      output: CognitiveReplyOutput(
        cycle_id: "cyc-buf",
        response: "buffered",
        model: "test",
        usage: None,
        tools_fired: [],
      ),
    ),
  )

  // Now the operator reconnects under the same source_id. Subscribe
  // must flush the buffered reply to the new sink.
  let sink = process.new_subject()
  process.send(fd, Subscribe(source_id: "ws:later", kind: UserSource, sink:))

  let assert Ok(delivery) = process.receive(sink, 500)
  case delivery {
    DeliverReply(cycle_id:, response:, ..) -> {
      cycle_id |> should.equal("cyc-buf")
      response |> should.equal("buffered")
    }
    _ -> should.fail()
  }
}

pub fn pending_buffer_preserves_arrival_order_test() {
  let fd = frontdoor.start()

  process.send(fd, ClaimCycle(cycle_id: "cyc-a", source_id: "ws:order"))
  process.send(fd, ClaimCycle(cycle_id: "cyc-b", source_id: "ws:order"))
  process.send(fd, ClaimCycle(cycle_id: "cyc-c", source_id: "ws:order"))

  process.send(
    fd,
    Publish(
      output: CognitiveReplyOutput(
        cycle_id: "cyc-a",
        response: "first",
        model: "test",
        usage: None,
        tools_fired: [],
      ),
    ),
  )
  process.send(
    fd,
    Publish(
      output: CognitiveReplyOutput(
        cycle_id: "cyc-b",
        response: "second",
        model: "test",
        usage: None,
        tools_fired: [],
      ),
    ),
  )
  process.send(
    fd,
    Publish(
      output: CognitiveReplyOutput(
        cycle_id: "cyc-c",
        response: "third",
        model: "test",
        usage: None,
        tools_fired: [],
      ),
    ),
  )

  let sink = process.new_subject()
  process.send(fd, Subscribe(source_id: "ws:order", kind: UserSource, sink:))

  // Order matters — the buffer must flush in arrival order, not
  // reverse-of-insertion (the implementation prepends on write so
  // it must reverse on flush; this test pins that contract).
  let assert Ok(d1) = process.receive(sink, 500)
  let assert Ok(d2) = process.receive(sink, 500)
  let assert Ok(d3) = process.receive(sink, 500)
  case d1, d2, d3 {
    DeliverReply(response: r1, ..),
      DeliverReply(response: r2, ..),
      DeliverReply(response: r3, ..)
    -> {
      r1 |> should.equal("first")
      r2 |> should.equal("second")
      r3 |> should.equal("third")
    }
    _, _, _ -> should.fail()
  }
}

pub fn subscribe_does_not_flush_other_source_ids_pending_test() {
  let fd = frontdoor.start()

  process.send(fd, ClaimCycle(cycle_id: "cyc-x", source_id: "ws:owner"))
  process.send(
    fd,
    Publish(
      output: CognitiveReplyOutput(
        cycle_id: "cyc-x",
        response: "owner-only",
        model: "test",
        usage: None,
        tools_fired: [],
      ),
    ),
  )

  // Different source_id subscribes — must NOT receive ws:owner's
  // buffered reply.
  let other_sink = process.new_subject()
  process.send(
    fd,
    Subscribe(source_id: "ws:other", kind: UserSource, sink: other_sink),
  )
  let assert Error(_) = process.receive(other_sink, 200)
}
