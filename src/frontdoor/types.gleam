//// Frontdoor types — the shared vocabulary between cognitive (brain) and
//// every communication channel (mouths and ears).
////
//// The cognitive loop publishes `CognitiveOutput` to one fixed subject.
//// Frontdoor routes outputs to the originating destination via the
//// `cycle_id → source_id` mapping, and accepts inbound requests via the
//// `FrontdoorMessage` variants. External callers do not hold
//// `Subject(CognitiveReply)` — they hold a `Subject(Delivery)` registered
//// with Frontdoor.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import llm/types as llm_types
import scheduler/types as scheduler_types

/// Opaque token identifying a communication destination. Conventions:
///   - "ws:<uuid>"              for an open web-socket connection
///   - "tui"                    for the local terminal UI
///   - "scheduler:<job>:<uuid>" for a scheduler runner waiting on one job
///   - "comms:<msg_id>"         for a single inbound email being processed
pub type SourceId =
  String

pub type SourceKind {
  /// Interactive source — a human is present and can be asked questions.
  UserSource
  /// Autonomous source — no human is available. Questions raised inside a
  /// cycle owned by this kind are answered synthetically by Frontdoor.
  SchedulerSource
}

/// Origin of a human-facing question raised during a cycle. Preserved so
/// the delivery surface can label who is asking.
pub type QuestionOrigin {
  CognitiveLoopOrigin
  AgentOrigin(agent_name: String)
}

/// Everything the cognitive loop publishes for external consumption.
/// Delivered to Frontdoor via the shared `output_channel`.
pub type CognitiveOutput {
  /// Terminal reply for a cycle. Analogous to the old CognitiveReply
  /// but carries `cycle_id` so Frontdoor can route without needing a
  /// pre-wired reply subject.
  CognitiveReplyOutput(
    cycle_id: String,
    response: String,
    model: String,
    usage: Option(llm_types.Usage),
    tools_fired: List(String),
  )
  /// A question raised for a human answer. `question_id` is a fresh token
  /// the answer must reference to correlate with the waiting cycle.
  HumanQuestionOutput(
    cycle_id: String,
    question_id: String,
    question: String,
    origin: QuestionOrigin,
  )
}

/// What a subscribed destination receives from Frontdoor.
pub type Delivery {
  DeliverReply(
    cycle_id: String,
    response: String,
    model: String,
    usage: Option(llm_types.Usage),
    tools_fired: List(String),
  )
  DeliverQuestion(
    cycle_id: String,
    question_id: String,
    question: String,
    origin: QuestionOrigin,
  )
  /// Frontdoor is releasing this subscription (shutdown, supervisor
  /// reset, etc.). Destinations should treat this as an orderly close.
  DeliverClosed
}

/// Messages accepted by the Frontdoor actor.
pub type FrontdoorMessage {
  // -- destination lifecycle --
  Subscribe(source_id: SourceId, kind: SourceKind, sink: Subject(Delivery))
  Unsubscribe(source_id: SourceId)

  // -- inbound from external channels --
  InboundUserMessage(source_id: SourceId, text: String)
  /// Answer to a prior HumanQuestionOutput. `question_id` correlates.
  InboundUserAnswer(source_id: SourceId, question_id: String, text: String)
  InboundScheduler(
    source_id: SourceId,
    job_name: String,
    query: String,
    kind: scheduler_types.JobKind,
    for_: scheduler_types.ForTarget,
    title: String,
    body: String,
    tags: List(String),
  )

  // -- outbound from cognitive --
  Publish(output: CognitiveOutput)

  // -- bookkeeping from cognitive --
  /// "This cycle_id belongs to this source_id." Sent by cognitive when
  /// it begins processing an inbound message, so Frontdoor can route
  /// later outputs back to the originator.
  ClaimCycle(cycle_id: String, source_id: SourceId)
}
