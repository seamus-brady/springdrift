//// Frontdoor — the sole intermediary between the cognitive loop and every
//// external communication channel.
////
//// The cognitive loop publishes `CognitiveOutput` values to Frontdoor and
//// holds no references to callers. Each external channel (web socket,
//// TUI, scheduler runner, comms poller) registers a `source_id` and a
//// sink subject; Frontdoor routes outputs to the correct sink via a
//// `cycle_id → source_id` mapping.
////
//// The actor is single-process, so the routing table is safe without
//// locking. Supervision is inherited from the main application — a
//// crash loses in-flight routing, and sinks re-subscribe on reconnect.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{InjectUserAnswer} as agent_types
import frontdoor/types.{
  type CognitiveOutput, type Delivery, type FrontdoorMessage, type SourceId,
  type SourceKind, ClaimCycle, CognitiveReplyOutput, DeliverClosed,
  DeliverQuestion, DeliverReply, HumanQuestionOutput, InboundScheduler,
  InboundUserAnswer, InboundUserMessage, Publish, SchedulerSource,
  SetCognitiveInbox, Subscribe, Unsubscribe, UserSource,
}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import slog

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

type Destination {
  Destination(kind: SourceKind, sink: Subject(Delivery))
}

type State {
  State(
    /// Registered destinations keyed by source_id.
    destinations: Dict(SourceId, Destination),
    /// cycle_id → source_id, populated by ClaimCycle, consumed on Publish.
    cycle_owners: Dict(String, SourceId),
    /// Cognitive loop inbox for injected answers — wired via
    /// `SetCognitiveInbox` during startup. Without it, SchedulerSource
    /// questions are logged and dropped; with it, Frontdoor replies
    /// synthetically so the autonomous cycle does not hang.
    cognitive_inbox: option.Option(Subject(agent_types.CognitiveMessage)),
  )
}

fn initial_state() -> State {
  State(
    destinations: dict.new(),
    cycle_owners: dict.new(),
    cognitive_inbox: None,
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the Frontdoor actor. Returns a subject suitable for publishing
/// outputs and for subscribing destinations. The subject is created
/// inside the spawned process so it can actually receive on it; the
/// setup channel is the standard Gleam-OTP pattern for handing the
/// child-owned subject back to the parent.
pub fn start() -> Subject(FrontdoorMessage) {
  let setup: Subject(Subject(FrontdoorMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let subj: Subject(FrontdoorMessage) = process.new_subject()
    process.send(setup, subj)
    loop(subj, initial_state())
  })
  case process.receive(setup, 5000) {
    Ok(subj) -> subj
    Error(_) -> panic as "Frontdoor failed to start within 5s"
  }
}

// ---------------------------------------------------------------------------
// Actor loop
// ---------------------------------------------------------------------------

fn loop(self: Subject(FrontdoorMessage), state: State) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(self)
  let msg = process.selector_receive_forever(selector)
  let next = handle(msg, state)
  loop(self, next)
}

fn handle(msg: FrontdoorMessage, state: State) -> State {
  case msg {
    SetCognitiveInbox(inbox:) -> {
      slog.debug("frontdoor", "set_cognitive_inbox", "wired", None)
      State(..state, cognitive_inbox: Some(inbox))
    }

    Subscribe(source_id:, kind:, sink:) -> {
      slog.debug("frontdoor", "subscribe", source_id, None)
      State(
        ..state,
        destinations: dict.insert(
          state.destinations,
          source_id,
          Destination(kind:, sink:),
        ),
      )
    }

    Unsubscribe(source_id:) -> {
      slog.debug("frontdoor", "unsubscribe", source_id, None)
      case dict.get(state.destinations, source_id) {
        Ok(dest) -> process.send(dest.sink, DeliverClosed)
        Error(_) -> Nil
      }
      State(..state, destinations: dict.delete(state.destinations, source_id))
    }

    ClaimCycle(cycle_id:, source_id:) -> {
      State(
        ..state,
        cycle_owners: dict.insert(state.cycle_owners, cycle_id, source_id),
      )
    }

    Publish(output:) -> {
      route_output(output, state)
      state
    }

    // Inbound request handling is wired in Phase 2 once cognitive accepts
    // the source_id-carrying variants. Until then these paths are inert;
    // the legacy WS → cognitive direct dispatch remains in place.
    InboundUserMessage(source_id: _, text: _) -> state
    InboundUserAnswer(source_id: _, question_id: _, text: _) -> state
    InboundScheduler(
      source_id: _,
      job_name: _,
      query: _,
      kind: _,
      for_: _,
      title: _,
      body: _,
      tags: _,
    ) -> state
  }
}

// ---------------------------------------------------------------------------
// Output routing
// ---------------------------------------------------------------------------

fn route_output(output: CognitiveOutput, state: State) -> Nil {
  let cycle_id = case output {
    CognitiveReplyOutput(cycle_id:, ..) -> cycle_id
    HumanQuestionOutput(cycle_id:, ..) -> cycle_id
  }

  case dict.get(state.cycle_owners, cycle_id) {
    Error(_) -> {
      slog.debug(
        "frontdoor",
        "route_output",
        "no owner for cycle " <> cycle_id <> " — dropping",
        Some(cycle_id),
      )
      Nil
    }
    Ok(source_id) -> {
      case dict.get(state.destinations, source_id) {
        Error(_) -> {
          slog.debug(
            "frontdoor",
            "route_output",
            "no destination registered for " <> source_id,
            Some(cycle_id),
          )
          Nil
        }
        Ok(dest) -> deliver(state, dest, output)
      }
    }
  }
}

fn deliver(state: State, dest: Destination, output: CognitiveOutput) -> Nil {
  case output {
    CognitiveReplyOutput(cycle_id:, response:, model:, usage:, tools_fired:) -> {
      process.send(
        dest.sink,
        DeliverReply(cycle_id:, response:, model:, usage:, tools_fired:),
      )
    }
    HumanQuestionOutput(cycle_id:, question_id:, question:, origin:) -> {
      case dest.kind {
        UserSource -> {
          process.send(
            dest.sink,
            DeliverQuestion(cycle_id:, question_id:, question:, origin:),
          )
        }
        SchedulerSource -> deliver_scheduler_question(state, cycle_id, question)
      }
    }
  }
}

/// SchedulerSource cannot field a human question — there is no human
/// at the destination. Log the drop and synthesise an answer back to
/// cognitive so the paused react loop resumes without a broadcast.
fn deliver_scheduler_question(
  state: State,
  cycle_id: String,
  question: String,
) -> Nil {
  slog.info(
    "frontdoor",
    "deliver",
    "autonomous cycle "
      <> cycle_id
      <> " raised a human question — synthesising 'no human available' reply",
    Some(cycle_id),
  )
  let canned =
    "[Frontdoor: no human is attached to this autonomous cycle. "
    <> "Answer your own question based on your best current estimate, "
    <> "or return what you already have. Your question was: "
    <> question
    <> "]"
  case state.cognitive_inbox {
    Some(inbox) -> process.send(inbox, InjectUserAnswer(text: canned))
    None ->
      slog.warn(
        "frontdoor",
        "deliver",
        "no cognitive inbox wired — scheduler cycle "
          <> cycle_id
          <> " will hang until watchdog fires",
        Some(cycle_id),
      )
  }
}
