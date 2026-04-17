// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/types as cbr_types
import facts/types as facts_types
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import narrative/types.{
  type NarrativeEntry, type Thread, DataQuery, Entities, Intent, Metrics,
  Narrative, NarrativeEntry, Outcome, Success, Thread,
}
import remembrancer/query as rquery

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

fn make_entry(
  cycle_id: String,
  timestamp: String,
  summary: String,
  domain: String,
  keywords: List(String),
  thread: option.Option(Thread),
) -> NarrativeEntry {
  NarrativeEntry(
    schema_version: 1,
    cycle_id:,
    parent_cycle_id: None,
    timestamp:,
    entry_type: Narrative,
    summary:,
    intent: Intent(classification: DataQuery, description: "", domain:),
    outcome: Outcome(status: Success, confidence: 0.9, assessment: "ok"),
    delegation_chain: [],
    decisions: [],
    keywords:,
    topics: [],
    entities: Entities(
      locations: [],
      organisations: [],
      data_points: [],
      temporal_references: [],
    ),
    sources: [],
    thread:,
    metrics: Metrics(
      total_duration_ms: 0,
      input_tokens: 0,
      output_tokens: 0,
      thinking_tokens: 0,
      tool_calls: 0,
      agent_delegations: 0,
      dprime_evaluations: 0,
      model_used: "test",
    ),
    observations: [],
    redacted: False,
  )
}

fn make_fact(
  key: String,
  value: String,
  confidence: Float,
  timestamp: String,
) -> facts_types.MemoryFact {
  facts_types.MemoryFact(
    schema_version: 1,
    fact_id: "fact-" <> key <> "-" <> timestamp,
    timestamp:,
    cycle_id: "cycle-test",
    agent_id: None,
    key:,
    value:,
    scope: facts_types.Persistent,
    operation: facts_types.Write,
    supersedes: None,
    confidence:,
    source: "test",
    provenance: None,
  )
}

fn make_case(
  case_id: String,
  intent: String,
  domain: String,
  keywords: List(String),
  confidence: Float,
) -> cbr_types.CbrCase {
  cbr_types.CbrCase(
    case_id:,
    timestamp: "2026-03-01T12:00:00Z",
    schema_version: 1,
    problem: cbr_types.CbrProblem(
      user_input: "test",
      intent:,
      domain:,
      entities: [],
      keywords:,
      query_complexity: "simple",
    ),
    solution: cbr_types.CbrSolution(
      approach: "test",
      agents_used: [],
      tools_used: [],
      steps: [],
    ),
    outcome: cbr_types.CbrOutcome(
      status: "success",
      confidence:,
      assessment: "ok",
      pitfalls: [],
    ),
    source_narrative_id: "",
    profile: None,
    redacted: False,
    category: None,
    usage_stats: None,
  )
}

// ---------------------------------------------------------------------------
// search_entries
// ---------------------------------------------------------------------------

pub fn search_entries_matches_summary_test() {
  let entries = [
    make_entry(
      "c1",
      "2026-03-01T10:00:00Z",
      "Investigating Dublin housing market",
      "housing",
      ["dublin"],
      None,
    ),
    make_entry(
      "c2",
      "2026-03-02T10:00:00Z",
      "Weather forecast review",
      "weather",
      ["forecast"],
      None,
    ),
  ]
  let matches = rquery.search_entries(entries, "housing market")
  list.length(matches) |> should.equal(1)
}

pub fn search_entries_matches_keyword_test() {
  let entries = [
    make_entry(
      "c1",
      "2026-03-01T10:00:00Z",
      "Generic summary",
      "test",
      ["insurance", "underwriting"],
      None,
    ),
  ]
  rquery.search_entries(entries, "underwriting")
  |> list.length
  |> should.equal(1)
}

pub fn search_entries_drops_short_terms_test() {
  let entries = [
    make_entry("c1", "2026-03-01T10:00:00Z", "no match here", "test", [], None),
  ]
  // "a" and "of" get filtered; "cat" is too short-ish but over 2 chars
  rquery.search_entries(entries, "a of") |> list.length |> should.equal(0)
}

// ---------------------------------------------------------------------------
// trace_fact_key / find_related_facts
// ---------------------------------------------------------------------------

pub fn trace_fact_key_finds_versions_test() {
  let facts = [
    make_fact("dublin_price", "100k", 0.9, "2026-01-01T10:00:00Z"),
    make_fact("dublin_price", "110k", 0.8, "2026-02-01T10:00:00Z"),
    make_fact("cork_price", "80k", 0.9, "2026-01-01T10:00:00Z"),
  ]
  rquery.trace_fact_key(facts, "dublin_price")
  |> list.length
  |> should.equal(2)
}

pub fn trace_fact_key_case_insensitive_test() {
  let facts = [
    make_fact("Dublin_Price", "100k", 0.9, "2026-01-01T10:00:00Z"),
  ]
  rquery.trace_fact_key(facts, "dublin_price")
  |> list.length
  |> should.equal(1)
}

pub fn find_related_facts_uses_tokens_test() {
  let facts = [
    make_fact("dublin_price", "100k", 0.9, "2026-01-01T10:00:00Z"),
    make_fact("dublin_size", "120m2", 0.9, "2026-01-01T10:00:00Z"),
    make_fact("cork_temperature", "10C", 0.9, "2026-01-01T10:00:00Z"),
  ]
  let related = rquery.find_related_facts(facts, "dublin_price")
  // excludes exact match; finds dublin_size via "dublin" token
  list.length(related) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// cluster_cases
// ---------------------------------------------------------------------------

pub fn cluster_cases_groups_by_keyword_test() {
  let cases = [
    make_case("c1", "i1", "housing", ["dublin", "rental"], 0.9),
    make_case("c2", "i2", "housing", ["dublin", "sales"], 0.8),
    make_case("c3", "i3", "housing", ["dublin", "survey"], 0.85),
    make_case("c4", "i4", "weather", ["temperature"], 0.9),
  ]
  let clusters = rquery.cluster_cases(cases, 3)
  // three cases share "dublin" in housing domain
  clusters
  |> list.filter(fn(cl) { cl.domain == "housing" })
  |> list.length
  |> should.equal(1)
}

pub fn cluster_cases_respects_min_size_test() {
  let cases = [
    make_case("c1", "i1", "housing", ["dublin"], 0.9),
    make_case("c2", "i2", "housing", ["dublin"], 0.9),
  ]
  // min_cluster_size = 3, only 2 cases share keyword
  rquery.cluster_cases(cases, 3) |> list.length |> should.equal(0)
}

// ---------------------------------------------------------------------------
// find_dormant_threads
// ---------------------------------------------------------------------------

pub fn find_dormant_threads_excludes_unthreaded_test() {
  let entries = [
    make_entry("c1", "2026-01-01T10:00:00Z", "no thread here", "x", [], None),
  ]
  rquery.find_dormant_threads(entries, "2026-03-01")
  |> list.length
  |> should.equal(0)
}

pub fn find_dormant_threads_detects_old_threads_test() {
  let thread =
    Some(Thread(
      thread_id: "t1",
      thread_name: "Old investigation",
      position: 1,
      previous_cycle_id: None,
      continuity_note: "",
    ))
  let entries = [
    make_entry("c1", "2026-01-01T10:00:00Z", "historical", "x", ["old"], thread),
  ]
  let dormant = rquery.find_dormant_threads(entries, "2026-03-01")
  list.length(dormant) |> should.equal(1)
  case dormant {
    [d, ..] -> d.thread_name |> should.equal("Old investigation")
    [] -> should.fail()
  }
}

pub fn find_dormant_threads_ignores_recent_test() {
  let thread =
    Some(Thread(
      thread_id: "t1",
      thread_name: "Active investigation",
      position: 1,
      previous_cycle_id: None,
      continuity_note: "",
    ))
  let entries = [
    make_entry("c1", "2026-04-10T10:00:00Z", "recent", "x", [], thread),
  ]
  rquery.find_dormant_threads(entries, "2026-03-01")
  |> list.length
  |> should.equal(0)
}

// ---------------------------------------------------------------------------
// cross_reference
// ---------------------------------------------------------------------------

pub fn cross_reference_counts_across_stores_test() {
  let entries = [
    make_entry(
      "c1",
      "2026-01-01T10:00:00Z",
      "report on housing market",
      "housing",
      ["housing"],
      None,
    ),
  ]
  let cases = [make_case("cs1", "housing query", "housing", ["market"], 0.9)]
  let facts = [make_fact("housing_price", "100k", 0.9, "2026-01-01T10:00:00Z")]
  let xref = rquery.cross_reference("housing", entries, cases, facts)
  xref.narrative_hits |> should.equal(1)
  xref.case_hits |> should.equal(1)
  xref.fact_hits |> should.equal(1)
}
