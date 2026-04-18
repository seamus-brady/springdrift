// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/types as cbr_types
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import skills/pattern

// ---------------------------------------------------------------------------
// Fixture builder
// ---------------------------------------------------------------------------

fn case_with(
  case_id: String,
  domain: String,
  category: cbr_types.CbrCategory,
  tools: List(String),
  agents: List(String),
  keywords: List(String),
  confidence: Float,
) -> cbr_types.CbrCase {
  // Default to a retrieved-and-helpful case so the utility floor is met.
  // The Laplace-smoothed utility is (successes+1)/(retrievals+2) → with
  // 5 retrievals all success that's 6/7 = 0.857. Combined with a 0.95
  // confidence: 0.81, which clears the 0.70 floor.
  case_with_usage(
    case_id,
    domain,
    category,
    tools,
    agents,
    keywords,
    confidence,
    5,
    5,
  )
}

fn case_with_usage(
  case_id: String,
  domain: String,
  category: cbr_types.CbrCategory,
  tools: List(String),
  agents: List(String),
  keywords: List(String),
  confidence: Float,
  retrievals: Int,
  successes: Int,
) -> cbr_types.CbrCase {
  cbr_types.CbrCase(
    case_id: case_id,
    timestamp: "2026-04-18T10:00:00Z",
    schema_version: 1,
    problem: cbr_types.CbrProblem(
      user_input: "",
      intent: "",
      domain: domain,
      entities: [],
      keywords: keywords,
      query_complexity: "",
    ),
    solution: cbr_types.CbrSolution(
      approach: "",
      agents_used: agents,
      tools_used: tools,
      steps: [],
    ),
    outcome: cbr_types.CbrOutcome(
      status: "success",
      confidence: confidence,
      assessment: "",
      pitfalls: [],
    ),
    source_narrative_id: "",
    profile: None,
    redacted: False,
    category: Some(category),
    usage_stats: Some(cbr_types.CbrUsageStats(
      retrieval_count: retrievals,
      retrieval_success_count: successes,
      helpful_count: 0,
      harmful_count: 0,
    )),
  )
}

// ---------------------------------------------------------------------------
// Cluster qualification
// ---------------------------------------------------------------------------

pub fn empty_input_returns_no_clusters_test() {
  pattern.find_clusters([], pattern.default_config())
  |> list.length
  |> should.equal(0)
}

pub fn below_min_cases_returns_no_cluster_test() {
  // Only 4 cases — default min_cases is 5.
  let cases =
    do_range(1, 4)
    |> list.map(fn(i) {
      case_with(
        "c" <> int_to_string(i),
        "research",
        cbr_types.Strategy,
        ["brave_answer"],
        ["researcher"],
        ["search", "factual"],
        0.95,
      )
    })
  pattern.find_clusters(cases, pattern.default_config())
  |> list.length
  |> should.equal(0)
}

pub fn five_consistent_cases_qualify_test() {
  let cases =
    do_range(1, 5)
    |> list.map(fn(i) {
      case_with(
        "c" <> int_to_string(i),
        "research",
        cbr_types.Strategy,
        ["brave_answer", "fetch_url"],
        ["researcher"],
        ["search", "factual"],
        0.95,
      )
    })
  let clusters = pattern.find_clusters(cases, pattern.default_config())
  list.length(clusters) |> should.equal(1)
}

pub fn diverging_tools_fail_overlap_test() {
  // Five cases in same category+domain but each uses entirely different
  // tools — Jaccard overlap is 0.0, far below the 0.50 threshold.
  let tools_per_case = [
    ["a", "b"],
    ["c", "d"],
    ["e", "f"],
    ["g", "h"],
    ["i", "j"],
  ]
  let cases =
    list.index_map(tools_per_case, fn(tools, i) {
      case_with(
        "c" <> int_to_string(i),
        "research",
        cbr_types.Strategy,
        tools,
        ["researcher"],
        ["k1", "k2"],
        0.95,
      )
    })
  pattern.find_clusters(cases, pattern.default_config())
  |> list.length
  |> should.equal(0)
}

pub fn low_utility_fails_floor_test() {
  // Five consistent cases but confidence 0.20 → mean utility ~0.10 well
  // below the 0.70 floor.
  let cases =
    do_range(1, 5)
    |> list.map(fn(i) {
      case_with(
        "c" <> int_to_string(i),
        "research",
        cbr_types.Strategy,
        ["brave_answer"],
        ["researcher"],
        ["search"],
        0.2,
      )
    })
  pattern.find_clusters(cases, pattern.default_config())
  |> list.length
  |> should.equal(0)
}

pub fn different_categories_dont_merge_test() {
  // Strategy and Pitfall in same domain — should not group together.
  let strategy_cases =
    do_range(1, 3)
    |> list.map(fn(i) {
      case_with(
        "s" <> int_to_string(i),
        "research",
        cbr_types.Strategy,
        ["brave_answer"],
        ["researcher"],
        ["search"],
        0.95,
      )
    })
  let pitfall_cases =
    do_range(1, 3)
    |> list.map(fn(i) {
      case_with(
        "p" <> int_to_string(i),
        "research",
        cbr_types.Pitfall,
        ["brave_answer"],
        ["researcher"],
        ["search"],
        0.95,
      )
    })
  // Six cases total, but split into two 3-case groups — neither group
  // hits min_cases on its own.
  let all = list.append(strategy_cases, pitfall_cases)
  pattern.find_clusters(all, pattern.default_config())
  |> list.length
  |> should.equal(0)
}

// ---------------------------------------------------------------------------
// Proposal generation
// ---------------------------------------------------------------------------

pub fn cluster_produces_proposal_with_source_cases_test() {
  let cases =
    do_range(1, 5)
    |> list.map(fn(i) {
      case_with(
        "case-" <> int_to_string(i),
        "research",
        cbr_types.Strategy,
        ["brave_answer"],
        ["researcher"],
        ["search"],
        0.95,
      )
    })
  let clusters = pattern.find_clusters(cases, pattern.default_config())
  let proposals =
    pattern.clusters_to_proposals(
      clusters,
      [],
      "2026-04-18T10:00:00Z",
      "remembrancer",
    )
  list.length(proposals) |> should.equal(1)
  case proposals {
    [p] -> {
      list.length(p.source_cases) |> should.equal(5)
      p.proposed_by |> should.equal("remembrancer")
      list.contains(p.agents, "researcher") |> should.be_true
      list.contains(p.contexts, "research") |> should.be_true
    }
    _ -> True |> should.be_false
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

import gleam/int

fn int_to_string(i: Int) -> String {
  int.to_string(i)
}

/// Inclusive range — gleam_stdlib's list.range is deprecated and int.range
/// has a different signature, so we build it manually for tests.
fn do_range(start: Int, finish: Int) -> List(Int) {
  case start > finish {
    True -> []
    False -> [start, ..do_range(start + 1, finish)]
  }
}
