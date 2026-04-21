//// Tests for fabrication_audit — pure logic that cross-references
//// synthesis-derivation facts against cycle-log tool calls.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import facts/types as facts_types
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import meta_learning/fabrication_audit

fn synthesis_fact(
  fact_id: String,
  cycle_id: String,
  key: String,
  value: String,
) -> facts_types.MemoryFact {
  facts_types.MemoryFact(
    schema_version: 1,
    fact_id: fact_id,
    timestamp: "2026-04-21T10:00:00",
    cycle_id: cycle_id,
    agent_id: Some("cognitive"),
    key: key,
    value: value,
    scope: facts_types.Persistent,
    operation: facts_types.Write,
    supersedes: None,
    confidence: 0.9,
    source: "memory_write",
    provenance: Some(facts_types.FactProvenance(
      source_cycle_id: cycle_id,
      source_tool: "memory_write",
      source_agent: "cognitive",
      derivation: facts_types.Synthesis,
    )),
  )
}

// ---------------------------------------------------------------------------
// Core audit behaviour
// ---------------------------------------------------------------------------

pub fn empty_inputs_produce_empty_result_test() {
  let result =
    fabrication_audit.audit(
      [],
      dict.new(),
      fabrication_audit.default_patterns(),
      "2026-04-14",
      "2026-04-21",
    )
  result.facts_examined |> should.equal(0)
  result.suspect_facts |> should.equal([])
}

pub fn fact_matching_pattern_without_tool_is_flagged_test() {
  let fact =
    synthesis_fact(
      "f-1",
      "cycle-a",
      "affect_corr_confidence_success",
      "Weak negative correlation observed. Pearson r = -0.3 across the window.",
    )
  // Cycle called adjacent introspection tools but NOT the expected one.
  let cycle_index =
    dict.from_list([#("cycle-a", [#("reflect", True), #("memory_write", True)])])
  let result =
    fabrication_audit.audit(
      [fact],
      cycle_index,
      fabrication_audit.default_patterns(),
      "2026-04-14",
      "2026-04-21",
    )
  result.facts_examined |> should.equal(1)
  let assert [suspect] = result.suspect_facts
  suspect.fact_id |> should.equal("f-1")
  suspect.cycle_id |> should.equal("cycle-a")
  { suspect.reasons != [] } |> should.be_true
}

pub fn fact_matching_pattern_with_expected_tool_is_clean_test() {
  let fact =
    synthesis_fact(
      "f-2",
      "cycle-b",
      "affect_corr_pressure_success",
      "Pearson r = -0.5 across the window.",
    )
  // Cycle actually fired the expected tool — not suspect.
  let cycle_index =
    dict.from_list([#("cycle-b", [#("analyze_affect_performance", True)])])
  let result =
    fabrication_audit.audit(
      [fact],
      cycle_index,
      fabrication_audit.default_patterns(),
      "2026-04-14",
      "2026-04-21",
    )
  result.suspect_facts |> should.equal([])
}

pub fn non_synthesis_facts_are_not_audited_test() {
  // DirectObservation facts are from tools; they're already evidence.
  let direct_fact =
    facts_types.MemoryFact(
      schema_version: 1,
      fact_id: "f-3",
      timestamp: "2026-04-21T10:00:00",
      cycle_id: "cycle-c",
      agent_id: Some("cognitive"),
      key: "affect_corr_calm_success",
      value: "Pearson r = 0.0 (no correlation detected)",
      scope: facts_types.Persistent,
      operation: facts_types.Write,
      supersedes: None,
      confidence: 1.0,
      source: "analyze_affect_performance",
      provenance: Some(facts_types.FactProvenance(
        source_cycle_id: "cycle-c",
        source_tool: "analyze_affect_performance",
        source_agent: "remembrancer",
        derivation: facts_types.DirectObservation,
      )),
    )
  let cycle_index = dict.from_list([#("cycle-c", [#("reflect", True)])])
  let result =
    fabrication_audit.audit(
      [direct_fact],
      cycle_index,
      fabrication_audit.default_patterns(),
      "2026-04-14",
      "2026-04-21",
    )
  // Only synthesis facts are examined; direct observation is out of scope.
  result.facts_examined |> should.equal(0)
  result.suspect_facts |> should.equal([])
}

pub fn missing_cycle_record_flags_pattern_matching_fact_test() {
  // When the source cycle isn't in the index (old cycle, missing log,
  // etc.), any pattern match is flagged — we cannot verify the claim.
  let fact =
    synthesis_fact(
      "f-4",
      "cycle-missing",
      "mined_pattern_scheduler",
      "Mined three scheduler failure patterns across the archive.",
    )
  let result =
    fabrication_audit.audit(
      [fact],
      dict.new(),
      fabrication_audit.default_patterns(),
      "2026-04-14",
      "2026-04-21",
    )
  result.facts_examined |> should.equal(1)
  { result.suspect_facts != [] } |> should.be_true
}

// ---------------------------------------------------------------------------
// dates_from_facts helper
// ---------------------------------------------------------------------------

pub fn dates_from_facts_extracts_unique_date_prefixes_test() {
  let facts = [
    synthesis_fact("f-1", "c-1", "k", "v")
      |> with_ts("2026-04-20T10:00:00"),
    synthesis_fact("f-2", "c-2", "k", "v")
      |> with_ts("2026-04-20T23:59:00"),
    synthesis_fact("f-3", "c-3", "k", "v")
      |> with_ts("2026-04-21T08:00:00"),
  ]
  fabrication_audit.dates_from_facts(facts)
  |> list.sort(string.compare)
  |> should.equal(["2026-04-20", "2026-04-21"])
}

fn with_ts(f: facts_types.MemoryFact, ts: String) -> facts_types.MemoryFact {
  facts_types.MemoryFact(..f, timestamp: ts)
}
