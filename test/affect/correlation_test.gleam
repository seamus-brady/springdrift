// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import affect/correlation
import affect/types as affect_types
import gleam/list
import gleam/option.{None}
import gleeunit/should
import narrative/types as narrative_types

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn snap(cycle_id: String, pressure: Float) -> affect_types.AffectSnapshot {
  affect_types.AffectSnapshot(
    cycle_id: cycle_id,
    timestamp: "2026-04-18T10:00:00Z",
    desperation: 0.0,
    calm: 75.0,
    confidence: 60.0,
    frustration: 0.0,
    pressure: pressure,
    trend: affect_types.Stable,
  )
}

fn entry(
  cycle_id: String,
  domain: String,
  status: narrative_types.OutcomeStatus,
) -> narrative_types.NarrativeEntry {
  narrative_types.NarrativeEntry(
    schema_version: 1,
    cycle_id: cycle_id,
    parent_cycle_id: None,
    timestamp: "2026-04-18T10:00:00Z",
    entry_type: narrative_types.Narrative,
    summary: "test",
    intent: narrative_types.Intent(
      classification: narrative_types.Conversation,
      description: "",
      domain: domain,
    ),
    outcome: narrative_types.Outcome(
      status: status,
      confidence: 0.9,
      assessment: "",
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
// Pearson — pure math
// ---------------------------------------------------------------------------

pub fn pearson_perfect_positive_test() {
  // y = 2x — perfect positive correlation, r = 1.0
  let xs = [1.0, 2.0, 3.0, 4.0, 5.0]
  let ys = [2.0, 4.0, 6.0, 8.0, 10.0]
  let #(r, inconclusive) = correlation.pearson(xs, ys)
  inconclusive |> should.equal(False)
  // Allow tiny float wobble
  let diff = r -. 1.0
  let abs_diff = case diff <. 0.0 {
    True -> -1.0 *. diff
    False -> diff
  }
  case abs_diff <. 0.0001 {
    True -> Nil
    False -> should.fail()
  }
}

pub fn pearson_perfect_negative_test() {
  let xs = [1.0, 2.0, 3.0, 4.0, 5.0]
  let ys = [10.0, 8.0, 6.0, 4.0, 2.0]
  let #(r, inconclusive) = correlation.pearson(xs, ys)
  inconclusive |> should.equal(False)
  let diff = r -. -1.0
  let abs_diff = case diff <. 0.0 {
    True -> -1.0 *. diff
    False -> diff
  }
  case abs_diff <. 0.0001 {
    True -> Nil
    False -> should.fail()
  }
}

pub fn pearson_zero_variance_inconclusive_test() {
  // All xs identical → no variance → inconclusive
  let xs = [5.0, 5.0, 5.0, 5.0]
  let ys = [1.0, 2.0, 3.0, 4.0]
  let #(_, inconclusive) = correlation.pearson(xs, ys)
  inconclusive |> should.equal(True)
}

pub fn pearson_singleton_inconclusive_test() {
  let #(_, inconclusive) = correlation.pearson([1.0], [2.0])
  inconclusive |> should.equal(True)
}

pub fn pearson_empty_inconclusive_test() {
  let #(_, inconclusive) = correlation.pearson([], [])
  inconclusive |> should.equal(True)
}

// ---------------------------------------------------------------------------
// compute_correlations — joins by cycle_id, groups by domain
// ---------------------------------------------------------------------------

pub fn compute_correlations_pressure_predicts_failure_test() {
  // Pressure goes up → failures cluster. Negative correlation expected.
  let snapshots = [
    snap("c1", 10.0),
    snap("c2", 20.0),
    snap("c3", 30.0),
    snap("c4", 80.0),
    snap("c5", 90.0),
    snap("c6", 100.0),
  ]
  let entries = [
    entry("c1", "research", narrative_types.Success),
    entry("c2", "research", narrative_types.Success),
    entry("c3", "research", narrative_types.Success),
    entry("c4", "research", narrative_types.Failure),
    entry("c5", "research", narrative_types.Failure),
    entry("c6", "research", narrative_types.Failure),
  ]
  let results = correlation.compute_correlations(snapshots, entries, 3)
  let pressure_research =
    list.find(results, fn(c) {
      c.dimension == correlation.Pressure && c.domain == "research"
    })
  case pressure_research {
    Ok(c) -> {
      c.inconclusive |> should.equal(False)
      // Strong negative correlation
      should.be_true(c.correlation <. -0.8)
      c.sample_size |> should.equal(6)
    }
    Error(_) -> should.fail()
  }
}

pub fn compute_correlations_below_min_sample_dropped_test() {
  let snapshots = [snap("c1", 10.0), snap("c2", 20.0)]
  let entries = [
    entry("c1", "research", narrative_types.Success),
    entry("c2", "research", narrative_types.Failure),
  ]
  // min_sample = 5; only 2 pairs available → no results returned
  let results = correlation.compute_correlations(snapshots, entries, 5)
  list.length(results) |> should.equal(0)
}

pub fn compute_correlations_unmatched_cycles_skipped_test() {
  // entries reference cycles that have no affect snapshot → join drops them
  let snapshots = [snap("c1", 50.0)]
  let entries = [
    entry("c1", "research", narrative_types.Success),
    entry("c2", "research", narrative_types.Failure),
    entry("c3", "research", narrative_types.Success),
  ]
  let results = correlation.compute_correlations(snapshots, entries, 1)
  // Each result aggregates only matched cycles — only c1 matched
  case
    list.find(results, fn(c) {
      c.dimension == correlation.Pressure && c.domain == "research"
    })
  {
    Ok(c) -> c.sample_size |> should.equal(1)
    Error(_) -> should.fail()
  }
}

pub fn compute_correlations_empty_domain_normalised_test() {
  let snapshots = [snap("c1", 50.0), snap("c2", 60.0)]
  let entries = [
    entry("c1", "", narrative_types.Success),
    entry("c2", "", narrative_types.Failure),
  ]
  let results = correlation.compute_correlations(snapshots, entries, 1)
  list.any(results, fn(c) { c.domain == "unknown" })
  |> should.equal(True)
}

// ---------------------------------------------------------------------------
// Fact key encoding round-trip
// ---------------------------------------------------------------------------

pub fn fact_value_round_trip_test() {
  let c =
    correlation.AffectCorrelation(
      dimension: correlation.Pressure,
      domain: "research",
      correlation: -0.65,
      sample_size: 12,
      inconclusive: False,
    )
  let encoded = correlation.fact_value(c)
  case correlation.parse_fact_value(encoded) {
    Ok(#(r, n, inconclusive)) -> {
      let diff = r -. -0.65
      let abs_diff = case diff <. 0.0 {
        True -> -1.0 *. diff
        False -> diff
      }
      case abs_diff <. 0.0001 {
        True -> Nil
        False -> should.fail()
      }
      n |> should.equal(12)
      inconclusive |> should.equal(False)
    }
    Error(_) -> should.fail()
  }
}

pub fn fact_value_malformed_returns_error_test() {
  case correlation.parse_fact_value("not|a|valid|format") {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }
}

pub fn fact_key_normalises_whitespace_test() {
  let c =
    correlation.AffectCorrelation(
      dimension: correlation.Calm,
      domain: "code review",
      correlation: 0.5,
      sample_size: 10,
      inconclusive: False,
    )
  correlation.fact_key(c)
  |> should.equal("affect_corr_calm_code-review")
}
