//// Deputy — ephemeral restricted cog loop that holds delegated attention
//// on one delegation hierarchy on cog's behalf.
////
//// A deputy briefs the specialist agent before its react loop starts,
//// reasons read-only over CBR / narrative / facts, and returns a
//// structured briefing that's prepended to the agent's system prompt.
//// In MVP (Phase 1), the deputy is one-shot: spawn, brief, die. Later
//// phases extend to ask-for-help, escalation, and full sensorium
//// integration.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// A deputy record. Ephemeral — created when a hierarchy spawns, discarded
/// when the root delegation completes.
pub type Deputy {
  Deputy(
    id: String,
    cycle_id: String,
    hierarchy_cycle_id: String,
    root_agent: String,
    instruction: String,
    spawned_at: String,
    status: DeputyStatus,
  )
}

/// Lifecycle state of a deputy. MVP uses Briefing / Complete / Failed /
/// Killed; later phases add Watching for long-lived deputies.
pub type DeputyStatus {
  /// Deputy is currently producing its briefing (LLM call in flight).
  Briefing
  /// Briefing returned successfully; deputy has done its work.
  Complete
  /// Briefing failed (LLM error, schema violation, timeout); agent
  /// continues without a briefing. Fire-and-forget failure mode.
  Failed(reason: String)
  /// Deputy was explicitly killed by cog via kill_deputy.
  Killed(reason: String)
}

// ---------------------------------------------------------------------------
// Actor-protocol messages
// ---------------------------------------------------------------------------

/// Messages accepted by a deputy process. Kept in `types` rather than
/// `framework` so the Librarian (and any other module that needs the
/// Subject type) can depend on it without circular imports.
pub type DeputyMessage {
  /// Request the deputy generate its briefing. The reply_to receives
  /// the result. Deputies handle this exactly once and then shut down.
  GenerateBriefing(reply_to: Subject(Result(DeputyBriefing, String)))
  /// Kill the deputy with a reason. Any pending reply gets an Error.
  Kill(reason: String)
  /// Explicit shutdown signal (used on natural completion).
  Shutdown
}

// ---------------------------------------------------------------------------
// Briefing output
// ---------------------------------------------------------------------------

/// The briefing produced by a deputy. Rendered as an XML block prepended
/// to the root agent's system prompt. Fields are optional so a sparse
/// briefing (no relevant cases, no known facts) still renders correctly.
pub type DeputyBriefing {
  DeputyBriefing(
    deputy_id: String,
    relevant_cases: List(BriefingCase),
    relevant_facts: List(BriefingFact),
    known_pitfalls: Option(String),
    signal: String,
    elapsed_ms: Int,
  )
}

pub type BriefingCase {
  BriefingCase(case_id: String, similarity: Float, summary: String)
}

pub type BriefingFact {
  BriefingFact(key: String, value: String)
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Serialise a briefing to the XML block that goes into the agent's
/// system prompt. Pure — no I/O.
pub fn render_briefing(b: DeputyBriefing) -> String {
  let cases_block = case b.relevant_cases {
    [] -> ""
    cases ->
      "  <relevant_cases>\n"
      <> render_list(cases, render_case)
      <> "  </relevant_cases>\n"
  }
  let facts_block = case b.relevant_facts {
    [] -> ""
    facts ->
      "  <relevant_facts>\n"
      <> render_list(facts, render_fact)
      <> "  </relevant_facts>\n"
  }
  let pitfalls_block = case b.known_pitfalls {
    Some(text) ->
      case string.trim(text) {
        "" -> ""
        t ->
          "  <known_pitfalls>\n    "
          <> xml_escape(t)
          <> "\n  </known_pitfalls>\n"
      }
    None -> ""
  }
  "<briefing deputy_id=\""
  <> xml_escape(b.deputy_id)
  <> "\" signal=\""
  <> xml_escape(b.signal)
  <> "\">\n"
  <> cases_block
  <> facts_block
  <> pitfalls_block
  <> "</briefing>"
}

fn render_case(c: BriefingCase) -> String {
  "    <case id=\""
  <> xml_escape(c.case_id)
  <> "\" similarity=\""
  <> format_float(c.similarity)
  <> "\">"
  <> xml_escape(c.summary)
  <> "</case>\n"
}

fn render_fact(f: BriefingFact) -> String {
  "    <fact key=\""
  <> xml_escape(f.key)
  <> "\">"
  <> xml_escape(f.value)
  <> "</fact>\n"
}

fn render_list(items: List(a), render: fn(a) -> String) -> String {
  case items {
    [] -> ""
    [x, ..rest] -> render(x) <> render_list(rest, render)
  }
}

/// Format a float to 2 decimal places for briefing XML rendering.
fn format_float(f: Float) -> String {
  let scaled = float.to_precision(f, 2)
  float.to_string(scaled)
  |> fallback_int_render(scaled)
}

fn fallback_int_render(rendered: String, original: Float) -> String {
  // Gleam's float.to_string can produce "0.0" style output; acceptable
  // for briefing readability. If the rendered form is empty for some
  // reason, fall back to "0.00".
  case rendered {
    "" -> int.to_string(float.truncate(original))
    _ -> rendered
  }
}

/// Minimal XML escape so briefing content renders safely inside the
/// agent's system prompt (which may itself be templated into the LLM
/// request XML payload).
pub fn xml_escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&apos;")
}
