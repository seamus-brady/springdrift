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

import deputy/briefing
import deputy/types.{
  type Deputy, type DeputyBriefing, type DeputyMessage, Briefing, Complete,
  Deputy, Failed, GenerateBriefing, Kill, Killed, Shutdown,
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
// Actor loop
// ---------------------------------------------------------------------------

fn loop(self: Subject(DeputyMessage), deputy: Deputy, spec: DeputySpec) -> Nil {
  case process.receive(self, 60_000) {
    Error(_) -> {
      slog.warn(
        "deputy/framework",
        "loop",
        "Deputy "
          <> deputy.id
          <> " timed out waiting for instruction; shutting down",
        option.Some(deputy.cycle_id),
      )
      Nil
    }
    Ok(msg) ->
      case msg {
        GenerateBriefing(reply_to:) -> {
          case
            briefing.generate(
              deputy.id,
              spec.root_agent,
              spec.instruction,
              spec.provider,
              spec.model,
              spec.max_tokens,
              spec.librarian,
            )
          {
            Ok(b) -> {
              briefing.log_briefing_summary(b, deputy.cycle_id)
              let _ = Deputy(..deputy, status: Complete)
              process.send(reply_to, Ok(b))
            }
            Error(e) -> {
              slog.warn(
                "deputy/framework",
                "briefing",
                "Deputy "
                  <> deputy.id
                  <> " briefing failed: "
                  <> string.slice(e, 0, 200),
                option.Some(deputy.cycle_id),
              )
              let _ = Deputy(..deputy, status: Failed(string.slice(e, 0, 200)))
              process.send(reply_to, Error(e))
            }
          }
          Nil
        }
        Kill(reason:) -> {
          slog.info(
            "deputy/framework",
            "kill",
            "Deputy "
              <> deputy.id
              <> " killed by cog: "
              <> string.slice(reason, 0, 200),
            option.Some(deputy.cycle_id),
          )
          let _ = Deputy(..deputy, status: Killed(reason))
          Nil
        }
        Shutdown -> Nil
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
