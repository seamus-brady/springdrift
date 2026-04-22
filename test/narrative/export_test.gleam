//// Pure tests for the narrative markdown renderer.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import narrative/export as narrative_export
import narrative/types.{
  type DelegationStep, type NarrativeEntry, type Outcome, type Thread,
  DataReport, DelegationStep, Entities, Failure, Intent, Metrics, Narrative,
  NarrativeEntry, Outcome, Success, Thread,
}

fn make_entry(
  cycle_id: String,
  timestamp: String,
  summary: String,
  status: types.OutcomeStatus,
  assessment: String,
  keywords: List(String),
  delegations: List(String),
  thread: option.Option(Thread),
) -> NarrativeEntry {
  NarrativeEntry(
    schema_version: 1,
    cycle_id: cycle_id,
    parent_cycle_id: None,
    timestamp: timestamp,
    entry_type: Narrative,
    summary: summary,
    intent: Intent(
      classification: DataReport,
      description: "test intent",
      domain: "test",
    ),
    outcome: Outcome(status: status, confidence: 0.9, assessment: assessment),
    delegation_chain: delegations
      |> delegations_from_names,
    decisions: [],
    keywords: keywords,
    topics: [],
    entities: Entities(
      locations: [],
      organisations: [],
      data_points: [],
      temporal_references: [],
    ),
    sources: [],
    thread: thread,
    metrics: Metrics(
      total_duration_ms: 0,
      input_tokens: 0,
      output_tokens: 0,
      thinking_tokens: 0,
      tool_calls: 0,
      agent_delegations: 0,
      dprime_evaluations: 0,
      model_used: "mock",
    ),
    observations: [],
    redacted: False,
    strategy_used: None,
  )
}

fn delegations_from_names(names: List(String)) -> List(DelegationStep) {
  case names {
    [] -> []
    [n, ..rest] -> [
      DelegationStep(
        agent: n,
        agent_id: "id",
        agent_human_name: n,
        agent_cycle_id: "cyc",
        instruction: "",
        outcome: "",
        contribution: "",
        tools_used: [],
        sources_accessed: 0,
        input_tokens: 0,
        output_tokens: 0,
        duration_ms: 0,
      ),
      ..delegations_from_names(rest)
    ]
  }
}

// ---------------------------------------------------------------------------
// render_thread
// ---------------------------------------------------------------------------

pub fn render_thread_empty_test() {
  let out = narrative_export.render_thread("Nothing yet", [])
  string.contains(out, "# Nothing yet") |> should.equal(True)
  string.contains(out, "No narrative entries recorded") |> should.equal(True)
}

pub fn render_thread_single_entry_contains_summary_and_outcome_test() {
  let entry =
    make_entry(
      "abcd1234",
      "2026-04-22T09:00:00Z",
      "Ran the demo",
      Success,
      "worked",
      ["demo", "test"],
      [],
      None,
    )
  let out = narrative_export.render_thread("Demo Thread", [entry])
  string.contains(out, "# Demo Thread") |> should.equal(True)
  string.contains(out, "Ran the demo") |> should.equal(True)
  string.contains(out, "Success") |> should.equal(True)
  string.contains(out, "worked") |> should.equal(True)
  string.contains(out, "demo, test") |> should.equal(True)
}

pub fn render_thread_multiple_entries_separated_test() {
  let e1 =
    make_entry(
      "aaaa1111",
      "2026-04-22T09:00:00Z",
      "First",
      Success,
      "ok",
      [],
      [],
      None,
    )
  let e2 =
    make_entry(
      "bbbb2222",
      "2026-04-22T10:00:00Z",
      "Second",
      Failure,
      "broke",
      [],
      [],
      None,
    )
  let out = narrative_export.render_thread("Two cycles", [e1, e2])
  string.contains(out, "First") |> should.equal(True)
  string.contains(out, "Second") |> should.equal(True)
  string.contains(out, "Failure") |> should.equal(True)
  // Separator between entries
  string.contains(out, "\n---\n") |> should.equal(True)
  // Meta block reports cycle count
  string.contains(out, "**Cycles:** 2") |> should.equal(True)
}

pub fn render_thread_includes_thread_name_when_present_test() {
  let thread =
    Thread(
      thread_id: "thr_1",
      thread_name: "Debugging cycle",
      position: 1,
      previous_cycle_id: None,
      continuity_note: "",
    )
  let entry =
    make_entry(
      "aaaa1111",
      "2026-04-22T09:00:00Z",
      "Debug",
      Success,
      "ok",
      [],
      [],
      Some(thread),
    )
  let out = narrative_export.render_thread("X", [entry])
  string.contains(out, "**Thread:** Debugging cycle") |> should.equal(True)
}

pub fn render_entry_lists_delegations_test() {
  let entry =
    make_entry(
      "cccc3333",
      "2026-04-22T09:00:00Z",
      "With helpers",
      Success,
      "",
      [],
      ["researcher", "coder"],
      None,
    )
  let out = narrative_export.render_entry(entry)
  string.contains(out, "**Delegations:**") |> should.equal(True)
  string.contains(out, "researcher") |> should.equal(True)
  string.contains(out, "coder") |> should.equal(True)
}
