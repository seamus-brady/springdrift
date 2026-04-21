//// Tests for Phase 3a synthesis-provenance strictness.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import facts/provenance_check.{Commentary, Evidence}
import facts/types as facts_types
import gleam/option.{None, Some}
import gleeunit/should

fn synthesis_fact(confidence: Float) -> facts_types.MemoryFact {
  facts_types.MemoryFact(
    schema_version: 1,
    fact_id: "f-1",
    timestamp: "2026-04-21T10:00:00",
    cycle_id: "c-1",
    agent_id: Some("cognitive"),
    key: "affect_corr_confidence_success",
    value: "Pearson r = -0.3",
    scope: facts_types.Persistent,
    operation: facts_types.Write,
    supersedes: None,
    confidence: confidence,
    source: "memory_write",
    provenance: Some(facts_types.FactProvenance(
      source_cycle_id: "c-1",
      source_tool: "memory_write",
      source_agent: "cognitive",
      derivation: facts_types.Synthesis,
    )),
  )
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

pub fn default_config_has_expected_evidence_tools_test() {
  let cfg = provenance_check.default_config()
  // A representative sample — the list is long and operator-configurable.
  provenance_check.grade(cfg, "analyze_affect_performance")
  |> should.equal(Evidence)
  provenance_check.grade(cfg, "memory_read") |> should.equal(Evidence)
  provenance_check.grade(cfg, "kagi_search") |> should.equal(Evidence)
  provenance_check.grade(cfg, "run_code") |> should.equal(Evidence)
  provenance_check.grade(cfg, "audit_fabrication") |> should.equal(Evidence)
}

pub fn commentary_grade_tools_are_flagged_test() {
  let cfg = provenance_check.default_config()
  // These are in the April 20 transcript — called instead of the
  // actual analysis, and must NOT anchor a synthesis claim.
  provenance_check.grade(cfg, "reflect") |> should.equal(Commentary)
  provenance_check.grade(cfg, "memory_write") |> should.equal(Commentary)
  provenance_check.grade(cfg, "introspect") |> should.equal(Commentary)
}

pub fn unknown_tools_default_to_commentary_test() {
  let cfg = provenance_check.default_config()
  // New tools without classification are safe defaults — can't anchor
  // synthesis until operator explicitly adds them.
  provenance_check.grade(cfg, "some_new_tool") |> should.equal(Commentary)
  provenance_check.grade(cfg, "") |> should.equal(Commentary)
}

pub fn has_evidence_grade_true_when_any_present_test() {
  let cfg = provenance_check.default_config()
  provenance_check.has_evidence_grade(cfg, [
    "reflect",
    "analyze_affect_performance",
  ])
  |> should.be_true
}

pub fn has_evidence_grade_false_when_only_commentary_test() {
  let cfg = provenance_check.default_config()
  // The April 20 cycle exactly — lots of tool calls, none of them the
  // required analysis tool.
  provenance_check.has_evidence_grade(cfg, ["reflect", "list_affect_history"])
  |> should.be_false
}

pub fn has_evidence_grade_false_on_empty_test() {
  let cfg = provenance_check.default_config()
  provenance_check.has_evidence_grade(cfg, []) |> should.be_false
}

// ---------------------------------------------------------------------------
// apply_check — the write-path guard
// ---------------------------------------------------------------------------

pub fn synthesis_with_evidence_passes_unchanged_test() {
  let cfg = provenance_check.default_config()
  let fact = synthesis_fact(0.9)
  let checked =
    provenance_check.apply_check(
      fact,
      ["analyze_affect_performance", "memory_write"],
      cfg,
    )
  // Unchanged — evidence-grade tool fired.
  checked.confidence |> should.equal(0.9)
  let assert Some(p) = checked.provenance
  p.derivation |> should.equal(facts_types.Synthesis)
}

pub fn synthesis_without_evidence_is_downgraded_test() {
  let cfg = provenance_check.default_config()
  let fact = synthesis_fact(0.9)
  let checked =
    provenance_check.apply_check(
      fact,
      // April 20: reflect fired but the actual analysis tool didn't.
      ["reflect", "list_affect_history"],
      cfg,
    )
  // Downgraded.
  let assert Some(p) = checked.provenance
  p.derivation |> should.equal(facts_types.Unknown)
  // Confidence capped.
  checked.confidence |> should.equal(cfg.downgrade_confidence_cap)
}

pub fn synthesis_below_cap_keeps_original_confidence_test() {
  let cfg = provenance_check.default_config()
  // 0.3 is already below the 0.5 cap — should not be changed upward.
  let fact = synthesis_fact(0.3)
  let checked = provenance_check.apply_check(fact, ["reflect"], cfg)
  checked.confidence |> should.equal(0.3)
}

pub fn non_synthesis_facts_are_not_touched_test() {
  let cfg = provenance_check.default_config()
  let fact =
    facts_types.MemoryFact(
      ..synthesis_fact(0.9),
      provenance: Some(facts_types.FactProvenance(
        source_cycle_id: "c-1",
        source_tool: "kagi_search",
        source_agent: "researcher",
        derivation: facts_types.DirectObservation,
      )),
    )
  let checked = provenance_check.apply_check(fact, [], cfg)
  // DirectObservation facts never get downgraded by this check.
  let assert Some(p) = checked.provenance
  p.derivation |> should.equal(facts_types.DirectObservation)
  checked.confidence |> should.equal(0.9)
}

pub fn facts_without_provenance_are_not_touched_test() {
  let cfg = provenance_check.default_config()
  let fact = facts_types.MemoryFact(..synthesis_fact(0.9), provenance: None)
  let checked = provenance_check.apply_check(fact, ["reflect"], cfg)
  checked.provenance |> should.equal(None)
  checked.confidence |> should.equal(0.9)
}
