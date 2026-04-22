//// Narrative export — render a list of NarrativeEntry values as
//// operator-readable markdown.
////
//// Use case: handing a thread or a date range off to someone outside
//// the agent (or reading it yourself without the web GUI). The
//// renderer is pure — no I/O — so callers fetch the entries from
//// `narrative/log` and pipe them here.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import narrative/types.{type NarrativeEntry}

/// Render a full thread (list of entries, ordered by timestamp) as
/// markdown. Includes the thread name if available, a one-line
/// header per cycle, and the summary + notable intent/outcome data.
/// Entries are rendered in the order given — callers should sort
/// before calling if ordering matters.
pub fn render_thread(title: String, entries: List(NarrativeEntry)) -> String {
  let header = "# " <> title <> "\n\n"
  let meta = render_meta(entries)
  let body = case entries {
    [] -> "_No narrative entries recorded._\n"
    _ ->
      entries
      |> list.map(render_entry)
      |> string.join("\n---\n\n")
  }
  header <> meta <> body
}

/// Render a single entry as a markdown block. Used by render_thread
/// but also exposed for callers that want to include one cycle in a
/// larger document.
pub fn render_entry(entry: NarrativeEntry) -> String {
  let header =
    "## Cycle "
    <> string.slice(entry.cycle_id, 0, 8)
    <> " — "
    <> entry.timestamp
    <> "\n\n"
  let summary = "**Summary:** " <> entry.summary <> "\n\n"
  let intent = "**Intent:** " <> entry.intent.description <> "\n\n"
  let outcome_line =
    "**Outcome:** "
    <> outcome_tag(entry.outcome)
    <> case entry.outcome.assessment {
      "" -> ""
      s -> " — " <> s
    }
    <> "\n\n"
  let keywords = case entry.keywords {
    [] -> ""
    ks -> "**Keywords:** " <> string.join(ks, ", ") <> "\n\n"
  }
  let delegations = case entry.delegation_chain {
    [] -> ""
    steps ->
      "**Delegations:**\n"
      <> { steps |> list.map(fn(s) { "  - " <> s.agent }) |> string.join("\n") }
      <> "\n\n"
  }
  header <> summary <> intent <> outcome_line <> keywords <> delegations
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn render_meta(entries: List(NarrativeEntry)) -> String {
  case entries {
    [] -> ""
    _ -> {
      let count = list.length(entries)
      let first = case list.first(entries) {
        Ok(e) -> e.timestamp
        Error(_) -> "?"
      }
      let last = case list.last(entries) {
        Ok(e) -> e.timestamp
        Error(_) -> "?"
      }
      let thread_line = case entries {
        [first_entry, ..] ->
          case first_entry.thread {
            Some(t) -> "**Thread:** " <> t.thread_name <> "\n"
            None -> ""
          }
        [] -> ""
      }
      thread_line
      <> "**Cycles:** "
      <> int_to_string(count)
      <> "\n**From:** "
      <> first
      <> "\n**To:** "
      <> last
      <> "\n\n---\n\n"
    }
  }
}

fn outcome_tag(outcome: types.Outcome) -> String {
  case outcome.status {
    types.Success -> "Success"
    types.Partial -> "Partial"
    types.Failure -> "Failure"
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String
