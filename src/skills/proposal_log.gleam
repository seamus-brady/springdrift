//// Per-day skills lifecycle log: `.springdrift/memory/skills/YYYY-MM-DD-skills.jsonl`.
////
//// Append-only record of every proposal, promotion, rejection, and
//// archival. The operator's audit surface (consolidation reports, web GUI
//// audit panel) reads from here to show "what changed and why".
////
//// All four `SkillLogEntry` variants are persisted here; supersession is
//// expressed by writing a new event, never editing earlier ones.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import simplifile
import skills/proposal.{
  type SkillLogEntry, type SkillProposal, SkillArchived, SkillCreated,
  SkillProposed, SkillRejected,
}
import slog

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

/// Record a SkillProposed event for `proposal`. The timestamp is the
/// current datetime, not the proposal's `proposed_at` (which may be
/// older when the proposal was generated as part of a batch).
pub fn append_proposed(dir: String, proposal: SkillProposal) -> Nil {
  append(dir, SkillProposed(timestamp: get_datetime(), proposal: proposal))
}

/// Record a SkillCreated event after the gate accepts a proposal.
/// `agents` records the agent scope so the gate's same-scope cooldown
/// check can find recent promotions targeting the same agents without
/// re-walking the skills directory.
pub fn append_created(
  dir: String,
  proposal_id: String,
  skill_id: String,
  skill_path: String,
  agents: List(String),
) -> Nil {
  append(
    dir,
    SkillCreated(
      timestamp: get_datetime(),
      proposal_id: proposal_id,
      skill_id: skill_id,
      skill_path: skill_path,
      agents: agents,
    ),
  )
}

/// Load timestamps of recent SkillCreated events whose agent scope
/// overlaps `agents`. Returns ISO timestamps in append order. Used by
/// the safety gate to enforce min_hours_between_same_scope.
pub fn recent_created_for_scope(
  dir: String,
  date: String,
  agents: List(String),
) -> List(String) {
  load_lines_for_date(dir, date)
  |> list.filter_map(fn(line) {
    case json.parse(line, created_event_decoder()) {
      Ok(#(timestamp, entry_agents)) -> {
        let overlaps =
          list.any(entry_agents, fn(a) { list.contains(agents, a) })
        case overlaps {
          True -> Ok(timestamp)
          False -> Error(Nil)
        }
      }
      Error(_) -> Error(Nil)
    }
  })
}

fn created_event_decoder() -> decode.Decoder(#(String, List(String))) {
  use event <- decode.field("event", decode.string)
  case event {
    "created" -> {
      use timestamp <- decode.field("timestamp", decode.string)
      use agents <- decode.optional_field(
        "agents",
        [],
        decode.list(decode.string),
      )
      decode.success(#(timestamp, agents))
    }
    _ -> decode.failure(#("", []), "not a created event")
  }
}

/// Record a SkillRejected event after the gate rejects a proposal.
pub fn append_rejected(dir: String, proposal_id: String, reason: String) -> Nil {
  append(
    dir,
    SkillRejected(
      timestamp: get_datetime(),
      proposal_id: proposal_id,
      reason: reason,
    ),
  )
}

/// Record a SkillArchived event. `supersedes_id` is set when the
/// archival happened because a newer version was promoted.
pub fn append_archived(
  dir: String,
  skill_id: String,
  reason: String,
  supersedes_id: option.Option(String),
) -> Nil {
  append(
    dir,
    SkillArchived(
      timestamp: get_datetime(),
      skill_id: skill_id,
      reason: reason,
      supersedes_id: supersedes_id,
    ),
  )
}

fn append(dir: String, entry: SkillLogEntry) -> Nil {
  let path = dir <> "/" <> get_date() <> "-skills.jsonl"
  let line = json.to_string(proposal.encode_log_entry(entry)) <> "\n"
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, line) {
    Ok(_) -> Nil
    Error(e) ->
      slog.log_error(
        "skills/proposal_log",
        "append",
        "Failed to append: " <> simplifile.describe_error(e),
        None,
      )
  }
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

/// Load every line of the per-day file as raw JSON strings (callers can
/// decide whether to decode or just count). PR-C only writes proposals;
/// downstream PRs add typed loaders for created/rejected/archived events
/// when the audit surfaces need them.
pub fn load_lines_for_date(dir: String, date: String) -> List(String) {
  let path = dir <> "/" <> date <> "-skills.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) ->
      content
      |> string.split("\n")
      |> list.filter(fn(l) { string.trim(l) != "" })
  }
}
