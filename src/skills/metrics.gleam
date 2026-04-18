//// Per-skill usage metrics — append-only events written to
//// `<skill_dir>/skill.metrics.jsonl`.
////
//// The skills manager owns this file. Operators never edit it directly.
//// Each event line is a JSON object:
////
//// ```jsonl
//// {"timestamp":"2026-04-18T10:30:42Z","cycle_id":"abc","event":"read","agent":"researcher"}
//// {"timestamp":"2026-04-18T10:31:00Z","cycle_id":"abc","event":"inject","agent":"researcher"}
//// {"timestamp":"2026-04-18T10:31:15Z","cycle_id":"abc","event":"outcome","outcome":"success"}
//// ```
////
//// Three event kinds:
//// - `read` — `read_skill` tool was called for this skill (intentional read).
//// - `inject` — the skill was placed into a system prompt this cycle.
//// - `outcome` — the cycle's outcome (success/partial/failure) — correlated
////   later with the cycle's read/inject events.
////
//// Reads are the primary signal: an agent that called `read_skill` did so
//// intentionally. Injects are reported as context (no honest counterfactual
//// available). See `docs/roadmap/planned/skills-management.md` §Usage
//// Tracking for the rationale.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type SkillEventKind {
  Read
  Inject
  Outcome(outcome: String)
}

pub type SkillEvent {
  SkillEvent(
    timestamp: String,
    cycle_id: String,
    agent: String,
    kind: SkillEventKind,
  )
}

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

/// Record an explicit `read_skill` tool call for the skill at `skill_dir`.
/// The skill_dir should be the directory containing SKILL.md (not the path
/// to SKILL.md itself).
pub fn append_read(skill_dir: String, cycle_id: String, agent: String) -> Nil {
  append_event(skill_dir, cycle_id, agent, Read)
}

/// Record that the skill was placed into a system prompt this cycle.
/// Intended to be called once per cycle per skill — the Curator emits these
/// when assembling the prompt. Inject events are reported alongside reads
/// in the audit view but should not be confused with intentional reads.
pub fn append_inject(skill_dir: String, cycle_id: String, agent: String) -> Nil {
  append_event(skill_dir, cycle_id, agent, Inject)
}

/// Record the cycle's final outcome against the skill so the audit view can
/// surface the (correlation-not-causation) success rate when the skill was
/// active. Outcome string is free-form ("success" | "partial" | "failure").
pub fn append_outcome(
  skill_dir: String,
  cycle_id: String,
  agent: String,
  outcome: String,
) -> Nil {
  append_event(skill_dir, cycle_id, agent, Outcome(outcome:))
}

fn append_event(
  skill_dir: String,
  cycle_id: String,
  agent: String,
  kind: SkillEventKind,
) -> Nil {
  let path = skill_dir <> "/skill.metrics.jsonl"
  let event =
    SkillEvent(
      timestamp: get_datetime(),
      cycle_id: cycle_id,
      agent: agent,
      kind: kind,
    )
  let line = json.to_string(encode_event(event)) <> "\n"
  let _ = simplifile.create_directory_all(skill_dir)
  case simplifile.append(path, line) {
    Ok(_) -> Nil
    Error(e) ->
      slog.log_error(
        "skills/metrics",
        "append",
        "Failed to append "
          <> kind_to_string(kind)
          <> " for skill at "
          <> skill_dir
          <> ": "
          <> simplifile.describe_error(e),
        Some(cycle_id),
      )
  }
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

/// Load every event recorded for a skill, in append order.
/// Returns an empty list when the metrics file is missing or empty.
pub fn load_all(skill_dir: String) -> List(SkillEvent) {
  let path = skill_dir <> "/skill.metrics.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_jsonl(content)
  }
}

/// Total count of `read` events — the honest "how often did an agent
/// intentionally read this skill" signal.
pub fn usage_count(skill_dir: String) -> Int {
  load_all(skill_dir)
  |> list.filter(fn(e) {
    case e.kind {
      Read -> True
      _ -> False
    }
  })
  |> list.length
}

/// Count of `inject` events — how often the skill was placed in a system
/// prompt. Reported as context, not as effectiveness measurement.
pub fn inject_count(skill_dir: String) -> Int {
  load_all(skill_dir)
  |> list.filter(fn(e) {
    case e.kind {
      Inject -> True
      _ -> False
    }
  })
  |> list.length
}

/// Timestamp of the most recent event of any kind. Used for dead-skill
/// detection by the decay recommender. Returns None when no events exist.
pub fn last_used(skill_dir: String) -> Option(String) {
  case load_all(skill_dir) {
    [] -> None
    events ->
      list.last(events)
      |> result_to_option
      |> option.map(fn(e: SkillEvent) { e.timestamp })
  }
}

fn result_to_option(r: Result(a, b)) -> Option(a) {
  case r {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

// ---------------------------------------------------------------------------
// JSON encode/decode
// ---------------------------------------------------------------------------

fn kind_to_string(kind: SkillEventKind) -> String {
  case kind {
    Read -> "read"
    Inject -> "inject"
    Outcome(_) -> "outcome"
  }
}

fn encode_event(event: SkillEvent) -> json.Json {
  let base = [
    #("timestamp", json.string(event.timestamp)),
    #("cycle_id", json.string(event.cycle_id)),
    #("event", json.string(kind_to_string(event.kind))),
    #("agent", json.string(event.agent)),
  ]
  let with_outcome = case event.kind {
    Outcome(outcome:) -> list.append(base, [#("outcome", json.string(outcome))])
    _ -> base
  }
  json.object(with_outcome)
}

fn parse_jsonl(content: String) -> List(SkillEvent) {
  string.split(content, "\n")
  |> list.filter_map(fn(line) {
    case string.trim(line) {
      "" -> Error(Nil)
      trimmed ->
        case json.parse(trimmed, event_decoder()) {
          Ok(e) -> Ok(e)
          Error(_) -> Error(Nil)
        }
    }
  })
}

fn event_decoder() -> decode.Decoder(SkillEvent) {
  use timestamp <- decode.field("timestamp", decode.string)
  use cycle_id <- decode.field("cycle_id", decode.string)
  use event_str <- decode.field("event", decode.string)
  use agent <- decode.optional_field("agent", "", decode.string)
  use outcome <- decode.optional_field("outcome", "", decode.string)
  let kind = case event_str {
    "read" -> Read
    "inject" -> Inject
    "outcome" -> Outcome(outcome:)
    _ -> Read
  }
  decode.success(SkillEvent(
    timestamp: timestamp,
    cycle_id: cycle_id,
    agent: agent,
    kind: kind,
  ))
}

// ---------------------------------------------------------------------------
// Summary helpers
// ---------------------------------------------------------------------------

/// Human-readable single-line summary used in audit reports.
pub fn summarise(skill_dir: String) -> String {
  let events = load_all(skill_dir)
  let reads = list.count(events, fn(e) { e.kind == Read })
  let injects = list.count(events, fn(e) { e.kind == Inject })
  let last = case events {
    [] -> "never"
    _ ->
      list.last(events)
      |> result_to_option
      |> option.map(fn(e: SkillEvent) { e.timestamp })
      |> option.unwrap("unknown")
  }
  int.to_string(reads)
  <> " reads, "
  <> int.to_string(injects)
  <> " injects, last "
  <> last
}
