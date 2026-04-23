//// Deputy framework — spawn, lifecycle, and kill control.
////
//// A deputy is an OTP process that produces one briefing and shuts down.
//// Ephemeral by design. During its brief lifetime (typically 1-3 seconds
//// for an LLM call), cog can kill it to interrupt the briefing if
//// needed. Phase 2 extends the framework to long-lived deputies that
//// handle ask_deputy and emit escalations.
////
//// Lifecycle:
////   spawn(...)  → Subject(DeputyMessage)
////   await_briefing(subj, timeout) → Result(DeputyBriefing, String)
////   kill(subj, reason)           → Nil
////
//// Cycle logging:
////   On spawn, a DeputyCycleStarted event is logged.
////   On briefing completion, DeputyCycleCompleted with the briefing
////   summary.
////   On failure / kill, DeputyCycleFailed / DeputyCycleKilled.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import deputy/ask
import deputy/briefing
import deputy/types.{
  type Deputy, type DeputyBriefing, type DeputyMessage, AskQuestion, Briefing,
  Complete, Deputy, DeputySnapshot, Failed, GenerateBriefing, Kill, Killed,
  Recall, Shutdown, render_briefing,
}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option}
import gleam/string
import llm/provider.{type Provider}
import narrative/librarian.{type LibrarianMessage}
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

// ---------------------------------------------------------------------------
// Metadata for the registry — what cog and operators can see
// ---------------------------------------------------------------------------

pub type DeputyMeta {
  DeputyMeta(
    id: String,
    cycle_id: String,
    hierarchy_cycle_id: String,
    root_agent: String,
    spawned_at: String,
    subject: Subject(DeputyMessage),
  )
}

// ---------------------------------------------------------------------------
// Context passed to the spawned actor
// ---------------------------------------------------------------------------

pub type DeputySpec {
  DeputySpec(
    root_agent: String,
    instruction: String,
    hierarchy_cycle_id: String,
    provider: Provider,
    model: String,
    max_tokens: Int,
    librarian: Option(Subject(LibrarianMessage)),
    /// Cognitive subject — used to emit sensory events (Tier 1
    /// escalation). None during tests or early boot; when None the
    /// deputy silently skips emission.
    cognitive: Option(Subject(agent_types.CognitiveMessage)),
  )
}

// ---------------------------------------------------------------------------
// Public API — spawn
// ---------------------------------------------------------------------------

/// Spawn a deputy. Returns a Meta record the caller can use to await
/// the briefing, kill the deputy, or register it with the Librarian.
///
/// Spawns unlinked — the caller is not affected by deputy crashes.
pub fn spawn(spec: DeputySpec) -> DeputyMeta {
  let deputy_id = make_deputy_id()
  let cycle_id = make_cycle_id()
  let spawned_at = get_datetime()

  slog.info(
    "deputy/framework",
    "spawn",
    "Deputy "
      <> deputy_id
      <> " spawned for root_agent="
      <> spec.root_agent
      <> " hierarchy="
      <> spec.hierarchy_cycle_id,
    option.Some(cycle_id),
  )

  let setup: Subject(Subject(DeputyMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(DeputyMessage) = process.new_subject()
    process.send(setup, self)
    let deputy =
      Deputy(
        id: deputy_id,
        cycle_id: cycle_id,
        hierarchy_cycle_id: spec.hierarchy_cycle_id,
        root_agent: spec.root_agent,
        instruction: spec.instruction,
        spawned_at: spawned_at,
        status: Briefing,
      )
    loop(self, deputy, spec)
  })

  let subj = case process.receive(setup, 5000) {
    Ok(s) -> s
    Error(_) -> {
      slog.log_error(
        "deputy/framework",
        "spawn",
        "Deputy process failed to signal setup within 5s",
        option.Some(cycle_id),
      )
      // Fallback: an orphan subject — caller will time out on await_briefing
      // and proceed without a briefing.
      process.new_subject()
    }
  }

  DeputyMeta(
    id: deputy_id,
    cycle_id: cycle_id,
    hierarchy_cycle_id: spec.hierarchy_cycle_id,
    root_agent: spec.root_agent,
    spawned_at: spawned_at,
    subject: subj,
  )
}

/// Request the briefing and block until it arrives or the timeout
/// expires. If the deputy was killed or crashed, returns Error.
pub fn await_briefing(
  meta: DeputyMeta,
  timeout_ms: Int,
) -> Result(DeputyBriefing, String) {
  let reply: Subject(Result(DeputyBriefing, String)) = process.new_subject()
  process.send(meta.subject, GenerateBriefing(reply_to: reply))
  case process.receive(reply, timeout_ms) {
    Ok(result) -> result
    Error(_) -> {
      let _ =
        kill(
          meta,
          "await_briefing timeout after " <> int.to_string(timeout_ms) <> "ms",
        )
      Error("briefing timeout")
    }
  }
}

/// Kill an active deputy with a reason. Fire-and-forget from the caller's
/// perspective; the deputy logs its termination and shuts down.
pub fn kill(meta: DeputyMeta, reason: String) -> Nil {
  process.send(meta.subject, Kill(reason))
}

// ---------------------------------------------------------------------------
// Actor loop — long-lived deputy (Phase 2)
// ---------------------------------------------------------------------------

/// Internal actor state that accumulates between messages. Held in the
/// loop function's tail recursion; not exposed publicly.
type DeputyState {
  DeputyState(
    deputy: Deputy,
    /// Serialized briefing XML once produced — used as context for
    /// AskQuestion answers.
    briefing_context: String,
    last_signal: String,
    briefing_complete: Bool,
    questions_answered: Int,
    escalations_emitted: Int,
  )
}

fn loop(self: Subject(DeputyMessage), deputy: Deputy, spec: DeputySpec) -> Nil {
  loop_with_state(
    self,
    DeputyState(
      deputy: deputy,
      briefing_context: "",
      last_signal: "silent",
      briefing_complete: False,
      questions_answered: 0,
      escalations_emitted: 0,
    ),
    spec,
  )
}

fn loop_with_state(
  self: Subject(DeputyMessage),
  state: DeputyState,
  spec: DeputySpec,
) -> Nil {
  // Deputies live as long as their hierarchy; wait a long time between
  // messages. If nothing arrives in an hour, the hierarchy has almost
  // certainly died elsewhere — shut down defensively.
  case process.receive(self, 3_600_000) {
    Error(_) -> {
      slog.warn(
        "deputy/framework",
        "loop",
        "Deputy "
          <> state.deputy.id
          <> " idle timeout (1h) — shutting down defensively",
        option.Some(state.deputy.cycle_id),
      )
      Nil
    }
    Ok(msg) ->
      case msg {
        GenerateBriefing(reply_to:) -> {
          case
            briefing.generate(
              state.deputy.id,
              spec.root_agent,
              spec.instruction,
              spec.provider,
              spec.model,
              spec.max_tokens,
              spec.librarian,
            )
          {
            Ok(b) -> {
              briefing.log_briefing_summary(b, state.deputy.cycle_id)
              let rendered = render_briefing(b)
              let new_state =
                DeputyState(
                  ..state,
                  deputy: Deputy(..state.deputy, status: Complete),
                  briefing_context: rendered,
                  last_signal: b.signal,
                  briefing_complete: True,
                )
              process.send(reply_to, Ok(b))
              loop_with_state(self, new_state, spec)
            }
            Error(e) -> {
              slog.warn(
                "deputy/framework",
                "briefing",
                "Deputy "
                  <> state.deputy.id
                  <> " briefing failed: "
                  <> string.slice(e, 0, 200),
                option.Some(state.deputy.cycle_id),
              )
              let new_state =
                DeputyState(
                  ..state,
                  deputy: Deputy(
                    ..state.deputy,
                    status: Failed(string.slice(e, 0, 200)),
                  ),
                )
              process.send(reply_to, Error(e))
              // Stay alive — agent may still call ask_deputy; we'll
              // serve without briefing context.
              loop_with_state(self, new_state, spec)
            }
          }
        }
        AskQuestion(question:, context:, reply_to:) -> {
          case
            ask.answer(
              question,
              context,
              spec.root_agent,
              state.briefing_context,
              spec.provider,
              spec.model,
              spec.max_tokens,
              spec.librarian,
            )
          {
            ask.Answered(text) -> {
              process.send(reply_to, Ok(text))
              loop_with_state(
                self,
                DeputyState(
                  ..state,
                  questions_answered: state.questions_answered + 1,
                ),
                spec,
              )
            }
            ask.Unanswered(reason) -> {
              slog.info(
                "deputy/framework",
                "ask",
                "Deputy "
                  <> state.deputy.id
                  <> " unanswered: "
                  <> string.slice(reason, 0, 120),
                option.Some(state.deputy.cycle_id),
              )
              // Phase 3 — Tier 1 escalation. Emit a sensory event so cog
              // sees the deputy couldn't help on the next cycle.
              emit_unanswered_event(spec, state, reason)
              process.send(reply_to, Error(reason))
              loop_with_state(
                self,
                DeputyState(
                  ..state,
                  questions_answered: state.questions_answered + 1,
                  escalations_emitted: state.escalations_emitted + 1,
                  last_signal: "unanswered",
                ),
                spec,
              )
            }
          }
        }
        Recall(reply_to:) -> {
          let snapshot =
            DeputySnapshot(
              id: state.deputy.id,
              cycle_id: state.deputy.cycle_id,
              root_agent: state.deputy.root_agent,
              spawned_at: state.deputy.spawned_at,
              last_signal: state.last_signal,
              briefing_complete: state.briefing_complete,
              questions_answered: state.questions_answered,
              escalations_emitted: state.escalations_emitted,
            )
          process.send(reply_to, snapshot)
          loop_with_state(self, state, spec)
        }
        Kill(reason:) -> {
          slog.info(
            "deputy/framework",
            "kill",
            "Deputy "
              <> state.deputy.id
              <> " killed by cog: "
              <> string.slice(reason, 0, 200),
            option.Some(state.deputy.cycle_id),
          )
          let _ = Deputy(..state.deputy, status: Killed(reason))
          Nil
        }
        Shutdown -> {
          slog.debug(
            "deputy/framework",
            "shutdown",
            "Deputy "
              <> state.deputy.id
              <> " shutting down after hierarchy completion",
            option.Some(state.deputy.cycle_id),
          )
          Nil
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_deputy_id() -> String {
  "dep-" <> string.slice(generate_uuid(), 0, 8)
}

fn make_cycle_id() -> String {
  generate_uuid()
}

// ---------------------------------------------------------------------------
// Escalation — Phase 3 Tier 1 sensory events
// ---------------------------------------------------------------------------

fn emit_unanswered_event(
  spec: DeputySpec,
  state: DeputyState,
  reason: String,
) -> Nil {
  case spec.cognitive {
    option.None -> Nil
    option.Some(cog) -> {
      let event =
        agent_types.SensoryEvent(
          name: "deputy_unanswered",
          title: "Deputy couldn't answer",
          body: "Deputy "
            <> state.deputy.id
            <> " (agent="
            <> state.deputy.root_agent
            <> ") was asked a question but couldn't answer. Reason: "
            <> string.slice(reason, 0, 200),
          fired_at: get_datetime(),
        )
      process.send(cog, agent_types.QueuedSensoryEvent(event: event))
      Nil
    }
  }
}
