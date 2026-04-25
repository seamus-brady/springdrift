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
import gleam/list
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
    /// Replies and questions whose target source_id has no currently
    /// registered destination. Held until a Subscribe arrives for the
    /// same source_id, then flushed in chronological order.
    ///
    /// The natural workflow that fills this queue: operator opens a
    /// long-running query; their websocket disconnects mid-cycle (idle
    /// proxy timeout, sleep, blip); the cycle completes and tries to
    /// route to a source_id with no destination. Without this buffer
    /// the reply was dropped silently. With it, the operator's next
    /// reconnect drains it.
    pending: Dict(SourceId, List(Delivery)),
  )
}

fn initial_state() -> State {
  State(
    destinations: dict.new(),
    cycle_owners: dict.new(),
    cognitive_inbox: None,
    pending: dict.new(),
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
      let with_dest =
        State(
          ..state,
          destinations: dict.insert(
            state.destinations,
            source_id,
            Destination(kind:, sink:),
          ),
        )
      // Flush any pending deliveries that arrived while no destination
      // was registered. Order preserved (we prepend on buffer-write so
      // we reverse here for chronological delivery). After flushing,
      // remove the per-source_id pending bucket so the routing table
      // reflects "all delivered".
      case dict.get(with_dest.pending, source_id) {
        Error(_) -> with_dest
        Ok(deliveries) -> {
          slog.debug(
            "frontdoor",
            "subscribe",
            "flushing pending deliveries for " <> source_id,
            None,
          )
          deliveries
          |> list.reverse
          |> list.each(fn(d) { process.send(sink, d) })
          State(..with_dest, pending: dict.delete(with_dest.pending, source_id))
        }
      }
    }

    Unsubscribe(source_id:, sink:) -> {
      slog.debug("frontdoor", "unsubscribe", source_id, None)
      case dict.get(state.destinations, source_id) {
        Ok(dest) ->
          case dest.sink == sink {
            True -> {
              // Real close from the currently-registered subscriber.
              process.send(dest.sink, DeliverClosed)
              State(
                ..state,
                destinations: dict.delete(state.destinations, source_id),
              )
            }
            False -> {
              // Stale unsubscribe from a previous sink that's already
              // been replaced by a reconnect. Ignoring it is critical
              // — deleting here would silently disconnect the new
              // websocket. Logged at debug for traceability.
              slog.debug(
                "frontdoor",
                "unsubscribe",
                "ignoring stale unsubscribe (sink mismatch) for " <> source_id,
                None,
              )
              state
            }
          }
        Error(_) -> state
      }
    }

    ClaimCycle(cycle_id:, source_id:) -> {
      State(
        ..state,
        cycle_owners: dict.insert(state.cycle_owners, cycle_id, source_id),
      )
    }

    Publish(output:) -> route_output(output, state)

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

fn route_output(output: CognitiveOutput, state: State) -> State {
  let cycle_id = case output {
    CognitiveReplyOutput(cycle_id:, ..) -> cycle_id
    HumanQuestionOutput(cycle_id:, ..) -> cycle_id
  }

  case dict.get(state.cycle_owners, cycle_id) {
    Error(_) -> {
      // No source ever claimed this cycle. Genuinely orphaned —
      // nothing useful to do; logging is the only signal.
      slog.debug(
        "frontdoor",
        "route_output",
        "no owner for cycle " <> cycle_id <> " — dropping",
        Some(cycle_id),
      )
      state
    }
    Ok(source_id) -> {
      case dict.get(state.destinations, source_id) {
        Ok(dest) -> {
          deliver(state, dest, output)
          state
        }
        Error(_) -> {
          // The source is known (cycle was claimed) but the
          // destination isn't currently registered — typically the
          // websocket disconnected mid-cycle. Buffer the delivery so
          // the operator gets it when they reconnect under the same
          // source_id. With stable client_ids, "same source_id"
          // means "same browser conversation."
          let delivery = output_to_delivery(output)
          let existing = dict.get(state.pending, source_id) |> result_or_empty
          slog.debug(
            "frontdoor",
            "route_output",
            "no destination for " <> source_id <> " — buffering",
            Some(cycle_id),
          )
          State(
            ..state,
            pending: dict.insert(state.pending, source_id, [
              delivery,
              ..existing
            ]),
          )
        }
      }
    }
  }
}

fn result_or_empty(r: Result(List(Delivery), Nil)) -> List(Delivery) {
  case r {
    Ok(v) -> v
    Error(_) -> []
  }
}

/// Convert a CognitiveOutput into the Delivery shape the sinks expect.
/// Same shape `deliver` constructs and sends, but as a value we can
/// hold in the pending buffer until a sink registers.
fn output_to_delivery(output: CognitiveOutput) -> Delivery {
  case output {
    CognitiveReplyOutput(cycle_id:, response:, model:, usage:, tools_fired:) ->
      DeliverReply(cycle_id:, response:, model:, usage:, tools_fired:)
    HumanQuestionOutput(cycle_id:, question_id:, question:, origin:) ->
      DeliverQuestion(cycle_id:, question_id:, question:, origin:)
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
