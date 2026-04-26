//// Coder session → CbrCase ingestion (Phase 4).
////
//// When the coder agent calls coder_end_session, the manager passes
//// the accumulated conversation here. We:
////   1. Map (prompt, response) pairs into a CbrCase
////   2. Append it to the day's CBR log so future delegations can
////      retrieve patterns from past coding sessions
////   3. Archive the raw conversation as JSON to
////      .springdrift/memory/coder/sessions/<session_id>.json so a
////      future ingest pass can re-derive richer cases without
////      replaying the original API calls
////
//// Phase 4 minimum: structural mapping only — no LLM-based
//// abstraction, no tool-call-trajectory parsing. Phase 4.x adds:
////   - Parsing parts (tool_use / tool_result) for richer Solution.steps
////   - Outcome derivation from host-side run_tests/run_build results
////     (currently outcome is "completed" with neutral confidence)
////   - Compaction handling — if OpenCode collapsed older messages,
////     mark the case as compacted: true so retrieval can down-weight

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/log as cbr_log
import cbr/types.{
  type CbrCase, type CbrCategory, type CbrOutcome, type CbrProblem,
  type CbrSolution, CbrCase, CbrOutcome, CbrProblem, CbrSolution, CodePattern,
}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import slog

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Persist a finished coder session as both a CbrCase (for retrieval)
/// and an archived JSON dump (for forensics). Best-effort — failures
/// log warnings but do not propagate, since end_session must complete
/// regardless.
///
/// `conversation` is the manager's most-recent-first log of
/// (prompt, response) pairs. We reverse it to chronological order
/// here, deriving the initial brief from the FIRST entry.
///
/// `tool_titles` is the distinct list of OpenCode tool names the
/// in-container model invoked during the session (e.g. ["Read", "Edit",
/// "Bash"]) in first-seen order. Feeds Solution.tools_used so CBR
/// retrieval can cluster sessions by what they actually did.
pub fn ingest_session(
  cbr_dir: String,
  sessions_dir: String,
  session_id: String,
  conversation: List(#(String, String)),
  tool_titles: List(String),
  model_id: String,
  duration_ms: Int,
) -> Nil {
  case list.is_empty(conversation) {
    True -> {
      // No prompts sent — agent acquired then ended without any work.
      // Don't pollute CBR with an empty case.
      slog.debug(
        "coder/ingest",
        "ingest_session",
        "Skipping ingest for empty session " <> session_id,
        Some(session_id),
      )
      Nil
    }
    False -> {
      let chronological = list.reverse(conversation)
      let cbr_case =
        build_case(
          session_id,
          chronological,
          tool_titles,
          model_id,
          duration_ms,
        )
      cbr_log.append(cbr_dir, cbr_case)
      archive_session_json(
        sessions_dir,
        session_id,
        chronological,
        tool_titles,
        model_id,
        duration_ms,
      )
      slog.info(
        "coder/ingest",
        "ingest_session",
        "Ingested coder session "
          <> session_id
          <> " ("
          <> int.to_string(list.length(chronological))
          <> " turns, "
          <> int.to_string(list.length(tool_titles))
          <> " distinct tools)",
        Some(session_id),
      )
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// CbrCase construction (pure)
// ---------------------------------------------------------------------------

/// Build a CbrCase from a chronological conversation. Pure — testable
/// without filesystem or any actor.
pub fn build_case(
  session_id: String,
  chronological: List(#(String, String)),
  tool_titles: List(String),
  model_id: String,
  duration_ms: Int,
) -> CbrCase {
  let initial_brief = case chronological {
    [#(brief, _), ..] -> brief
    [] -> ""
  }

  let problem = build_problem(initial_brief)
  let solution = build_solution(chronological, tool_titles, model_id)
  let outcome = build_outcome(chronological, tool_titles, duration_ms)

  CbrCase(
    case_id: "coder-" <> session_id,
    timestamp: get_timestamp(),
    schema_version: 1,
    problem: problem,
    solution: solution,
    outcome: outcome,
    source_narrative_id: session_id,
    profile: None,
    redacted: False,
    category: Some(coder_category()),
    usage_stats: None,
    strategy_id: None,
  )
}

fn coder_category() -> CbrCategory {
  // Coder sessions produce reusable code patterns (the prompts that
  // worked) or troubleshooting traces. CodePattern is the better
  // catch-all — matches how the existing CBR taxonomy treats coding
  // sessions vs strategy/troubleshooting/pitfall.
  CodePattern
}

fn build_problem(brief: String) -> CbrProblem {
  CbrProblem(
    user_input: truncate(brief, 2000),
    intent: "code",
    domain: "code",
    entities: [],
    keywords: extract_keywords(brief),
    query_complexity: "Complex",
  )
}

fn build_solution(
  chronological: List(#(String, String)),
  tool_titles: List(String),
  model_id: String,
) -> CbrSolution {
  let steps =
    chronological
    |> list.index_map(fn(pair, i) {
      let #(prompt, response) = pair
      "turn "
      <> int.to_string(i + 1)
      <> ": "
      <> truncate(string.trim(prompt), 200)
      <> " → "
      <> truncate(string.trim(response), 200)
    })

  // Use the actual tools the OpenCode session invoked when we have
  // them (post-R7). Empty list falls back to a single sentinel so CBR
  // retrieval has something to match on for sessions that ran without
  // tool calls (rare — usually pure chat).
  let tools_used = case tool_titles {
    [] -> ["coder_dispatch"]
    titles -> titles
  }

  CbrSolution(
    approach: "OpenCode coder driven via " <> model_id,
    agents_used: ["coder"],
    tools_used: tools_used,
    steps: steps,
  )
}

fn build_outcome(
  chronological: List(#(String, String)),
  tool_titles: List(String),
  duration_ms: Int,
) -> CbrOutcome {
  // Outcome is structural — turn count, duration, and the distinct
  // tool count. Phase 4.x can layer host-side test verdicts on top.
  let n = list.length(chronological)
  let tools_part = case list.length(tool_titles) {
    0 -> ""
    k -> ", " <> int.to_string(k) <> " distinct tool(s) invoked"
  }
  CbrOutcome(
    status: "completed",
    confidence: 0.5,
    assessment: "Coder session completed: "
      <> int.to_string(n)
      <> " turn(s) over "
      <> int.to_string(duration_ms / 1000)
      <> "s"
      <> tools_part
      <> ".",
    pitfalls: [],
  )
}

// ---------------------------------------------------------------------------
// Archive raw session JSON (impure)
// ---------------------------------------------------------------------------

fn archive_session_json(
  sessions_dir: String,
  session_id: String,
  chronological: List(#(String, String)),
  tool_titles: List(String),
  model_id: String,
  duration_ms: Int,
) -> Nil {
  let _ = simplifile.create_directory_all(sessions_dir)
  let path = sessions_dir <> "/" <> session_id <> ".json"

  let turns_json =
    list.map(chronological, fn(pair) {
      let #(prompt, response) = pair
      json.object([
        #("prompt", json.string(prompt)),
        #("response", json.string(response)),
      ])
    })

  let body =
    json.object([
      #("session_id", json.string(session_id)),
      #("model_id", json.string(model_id)),
      #("duration_ms", json.int(duration_ms)),
      #("turn_count", json.int(list.length(chronological))),
      #("turns", json.array(turns_json, of: fn(j) { j })),
      #("tool_titles", json.array(tool_titles, of: json.string)),
    ])
    |> json.to_string

  case simplifile.write(path, body) {
    Ok(_) -> Nil
    Error(e) ->
      slog.warn(
        "coder/ingest",
        "archive_session_json",
        "Failed to archive coder session "
          <> session_id
          <> ": "
          <> simplifile.describe_error(e),
        Some(session_id),
      )
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn truncate(s: String, n: Int) -> String {
  case string.length(s) > n {
    True -> string.slice(s, 0, n) <> "..."
    False -> s
  }
}

/// Cheap keyword extraction — pull tokens longer than 4 chars from the
/// first 500 chars of the brief. Phase 4 minimum; Phase 4.x can
/// upgrade to LLM-based intent + entity extraction if retrieval
/// quality demands it.
fn extract_keywords(brief: String) -> List(String) {
  brief
  |> string.slice(0, 500)
  |> string.lowercase
  |> string.split(" ")
  |> list.filter(fn(w) { string.length(w) > 4 })
  |> list.take(20)
}

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_timestamp() -> String
