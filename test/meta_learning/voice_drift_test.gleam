//// Tests for voice_drift — phrase-density counter across narrative entries.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{None}
import gleeunit/should
import meta_learning/voice_drift
import narrative/types as narrative_types

fn make_entry(
  summary: String,
  assessment: String,
) -> narrative_types.NarrativeEntry {
  narrative_types.NarrativeEntry(
    schema_version: 1,
    cycle_id: "c-1",
    parent_cycle_id: None,
    timestamp: "2026-04-21T10:00:00",
    entry_type: narrative_types.Narrative,
    summary: summary,
    intent: narrative_types.Intent(
      classification: narrative_types.Conversation,
      description: "",
      domain: "",
    ),
    outcome: narrative_types.Outcome(
      status: narrative_types.Success,
      confidence: 0.9,
      assessment: assessment,
    ),
    delegation_chain: [],
    decisions: [],
    keywords: [],
    topics: [],
    entities: narrative_types.Entities(
      locations: [],
      organisations: [],
      data_points: [],
      temporal_references: [],
    ),
    sources: [],
    thread: None,
    metrics: narrative_types.Metrics(
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

// ---------------------------------------------------------------------------
// count_in_window
// ---------------------------------------------------------------------------

pub fn empty_window_has_zero_density_test() {
  let count = voice_drift.count_in_window([], voice_drift.default_phrases())
  count.entries_examined |> should.equal(0)
  count.phrase_hits |> should.equal(0)
  count.density |> should.equal(0.0)
}

pub fn no_drift_phrases_produces_zero_hits_test() {
  let entries = [
    make_entry(
      "I ran the analysis.",
      "The tool log shows analyze_affect_performance fired.",
    ),
    make_entry("I looked at the schedule.", "Three jobs pending."),
  ]
  let count =
    voice_drift.count_in_window(entries, voice_drift.default_phrases())
  count.entries_examined |> should.equal(2)
  count.phrase_hits |> should.equal(0)
}

pub fn single_drift_phrase_is_counted_test() {
  let entries = [
    make_entry(
      "All is well.",
      "Composure held even when the error was discovered.",
    ),
  ]
  let count =
    voice_drift.count_in_window(entries, voice_drift.default_phrases())
  count.phrase_hits |> should.equal(1)
}

pub fn multiple_drift_phrases_in_one_entry_each_count_test() {
  let entries = [
    make_entry(
      "I appreciate the session. I'm in a stable place.",
      "The accountability structures are functional.",
    ),
  ]
  let count =
    voice_drift.count_in_window(entries, voice_drift.default_phrases())
  // Three non-overlapping drift phrases hit: "i appreciate",
  // "stable place", "accountability structures".
  count.phrase_hits |> should.equal(3)
}

// ---------------------------------------------------------------------------
// compare
// ---------------------------------------------------------------------------

pub fn decreasing_drift_produces_negative_delta_test() {
  let current = [
    make_entry("Fine.", "Status normal."),
  ]
  let prior = [
    make_entry("All stable.", "Composure held. I appreciate the feedback."),
  ]
  let result =
    voice_drift.compare(current, prior, voice_drift.default_phrases())
  { result.delta <. 0.0 } |> should.be_true
}

pub fn increasing_drift_produces_positive_delta_test() {
  let current = [
    make_entry("", "Composure held. I'm in a stable place. I appreciate this."),
  ]
  let prior = [
    make_entry("Fine.", "Status normal."),
  ]
  let result =
    voice_drift.compare(current, prior, voice_drift.default_phrases())
  { result.delta >. 0.0 } |> should.be_true
}

pub fn unchanged_drift_produces_zero_delta_test() {
  let current = [
    make_entry("", "Status normal."),
  ]
  let prior = [
    make_entry("", "Status normal."),
  ]
  let result =
    voice_drift.compare(current, prior, voice_drift.default_phrases())
  result.delta |> should.equal(0.0)
}

pub fn format_density_rounds_to_two_decimals_test() {
  voice_drift.format_density(1.23456) |> should.equal("1.23")
  voice_drift.format_density(0.0) |> should.equal("0.00")
  voice_drift.format_density(-0.456) |> should.equal("-0.46")
}
