// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/bridge
import cbr/types.{
  type CbrCase, CbrCase, CbrOutcome, CbrProblem, CbrQuery, CbrSolution,
}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_case(
  case_id: String,
  intent: String,
  domain: String,
  keywords: List(String),
  entities: List(String),
) -> CbrCase {
  CbrCase(
    case_id:,
    timestamp: "2026-03-08T10:00:00",
    schema_version: 1,
    problem: CbrProblem(
      user_input: "test query",
      intent:,
      domain:,
      entities:,
      keywords:,
      query_complexity: "simple",
    ),
    solution: CbrSolution(
      approach: "direct search",
      agents_used: ["researcher"],
      tools_used: ["web_search"],
      steps: [],
    ),
    outcome: CbrOutcome(
      status: "success",
      confidence: 0.8,
      assessment: "ok",
      pitfalls: [],
    ),
    source_narrative_id: "cycle-001",
    profile: None,
    redacted: False,
    category: None,
    usage_stats: None,
    strategy_id: None,
  )
}

fn make_case_with_timestamp(
  case_id: String,
  intent: String,
  domain: String,
  keywords: List(String),
  timestamp: String,
) -> CbrCase {
  CbrCase(..make_case(case_id, intent, domain, keywords, []), timestamp:)
}

fn default_weights() -> bridge.RetrievalWeights {
  bridge.default_weights()
}

// ---------------------------------------------------------------------------
// Tests: retain + retrieve round-trip
// ---------------------------------------------------------------------------

pub fn retain_and_retrieve_roundtrip_test() {
  let base = bridge.new()

  let c1 = make_case("case-1", "research", "property", ["market"], ["Dublin"])
  let base = bridge.retain_case(base, c1)

  bridge.case_count(base) |> should.equal(1)

  let metadata = dict.from_list([#("case-1", c1)])
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: ["Dublin"],
      max_results: 10,
      query_complexity: None,
    )
  let results =
    bridge.retrieve_cases(base, query, metadata, default_weights(), 0.0)
  list.length(results) |> should.equal(1)
  let assert [top] = results
  top.cbr_case.case_id |> should.equal("case-1")
}

// ---------------------------------------------------------------------------
// Tests: min_score filtering
// ---------------------------------------------------------------------------

pub fn min_score_filters_low_matches_test() {
  let base = bridge.new()

  let c1 = make_case("case-1", "research", "property", ["market"], ["Dublin"])
  let base = bridge.retain_case(base, c1)

  let metadata = dict.from_list([#("case-1", c1)])

  // Query with completely unrelated terms + high min_score
  let query =
    CbrQuery(
      intent: "coding",
      domain: "software",
      keywords: ["rust", "compiler"],
      entities: ["Mozilla"],
      max_results: 10,
      query_complexity: None,
    )
  // With high min_score, unrelated results should be filtered out
  let results =
    bridge.retrieve_cases(base, query, metadata, default_weights(), 1.0)
  list.length(results) |> should.equal(0)
}

// ---------------------------------------------------------------------------
// Tests: approach tokens in inverted index
// ---------------------------------------------------------------------------

pub fn approach_tokens_in_index_test() {
  let base = bridge.new()

  let c1 =
    CbrCase(
      ..make_case("case-1", "research", "property", ["market"], []),
      solution: CbrSolution(
        approach: "direct web search",
        agents_used: [],
        tools_used: [],
        steps: [],
      ),
    )
  let c2 =
    CbrCase(
      ..make_case("case-2", "research", "property", ["market"], []),
      solution: CbrSolution(
        approach: "deep analysis with experts",
        agents_used: [],
        tools_used: [],
        steps: [],
      ),
    )
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)

  let metadata = dict.from_list([#("case-1", c1), #("case-2", c2)])

  // Query with "search" as keyword — should match c1's approach tokens
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market", "search"],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )
  let results =
    bridge.retrieve_cases(base, query, metadata, default_weights(), 0.0)
  should.be_true(list.length(results) >= 1)
  // c1 should rank higher (has "search" in approach)
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("case-1")
}

// ---------------------------------------------------------------------------
// Tests: recency ranking
// ---------------------------------------------------------------------------

pub fn recency_ranking_test() {
  let base = bridge.new()

  // c1 is older, c2 is newer — both have identical features
  let c1 =
    make_case_with_timestamp(
      "case-old",
      "research",
      "property",
      ["market"],
      "2026-03-01T10:00:00",
    )
  let c2 =
    make_case_with_timestamp(
      "case-new",
      "research",
      "property",
      ["market"],
      "2026-03-15T10:00:00",
    )
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)

  let metadata = dict.from_list([#("case-old", c1), #("case-new", c2)])
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )
  let results =
    bridge.retrieve_cases(base, query, metadata, default_weights(), 0.0)
  should.be_true(list.length(results) == 2)
  // Newer case should rank first due to recency signal
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("case-new")
}

// ---------------------------------------------------------------------------
// Tests: remove_case cleans empty posting lists
// ---------------------------------------------------------------------------

pub fn remove_case_cleans_empty_postings_test() {
  let base = bridge.new()

  // Use a unique keyword only in c1
  let c1 = make_case("case-rm1", "research", "property", ["uniquetoken"], [])
  let c2 = make_case("case-rm2", "research", "property", ["market"], [])
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)

  bridge.case_count(base) |> should.equal(2)

  // Remove c1 — "uniquetoken" posting list should be cleaned up
  let base = bridge.remove_case(base, "case-rm1")
  bridge.case_count(base) |> should.equal(1)

  // Query for the removed unique token — should not match anything via index
  let metadata = dict.from_list([#("case-rm2", c2)])
  let query =
    CbrQuery(
      intent: "",
      domain: "",
      keywords: ["uniquetoken"],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )
  let results =
    bridge.retrieve_cases(base, query, metadata, default_weights(), 0.0)
  // The removed case_id must not appear in results
  let case_ids = list.map(results, fn(r) { r.cbr_case.case_id })
  list.contains(case_ids, "case-rm1") |> should.be_false
}

// ---------------------------------------------------------------------------
// Tests: query_complexity in case_tokens
// ---------------------------------------------------------------------------

pub fn query_complexity_in_tokens_test() {
  let base = bridge.new()

  let c_simple =
    CbrCase(
      ..make_case("case-simple", "research", "property", ["market"], []),
      problem: CbrProblem(
        user_input: "test",
        intent: "research",
        domain: "property",
        entities: [],
        keywords: ["market"],
        query_complexity: "simple",
      ),
    )
  let c_complex =
    CbrCase(
      ..make_case("case-complex", "research", "property", ["market"], []),
      problem: CbrProblem(
        user_input: "test",
        intent: "research",
        domain: "property",
        entities: [],
        keywords: ["market"],
        query_complexity: "complex",
      ),
    )
  let base = bridge.retain_case(base, c_simple)
  let base = bridge.retain_case(base, c_complex)

  let metadata =
    dict.from_list([#("case-simple", c_simple), #("case-complex", c_complex)])

  // Query specifying complex — should favour c_complex
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: [],
      max_results: 10,
      query_complexity: Some("complex"),
    )
  let results =
    bridge.retrieve_cases(base, query, metadata, default_weights(), 0.0)
  should.be_true(list.length(results) == 2)
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("case-complex")
}

// ---------------------------------------------------------------------------
// Tests: weighted field scoring
// ---------------------------------------------------------------------------

pub fn weighted_field_score_exact_match_test() {
  let c =
    make_case("case-1", "research", "property", ["dublin", "price"], ["Dublin"])
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["dublin", "price"],
      entities: ["Dublin"],
      max_results: 10,
      query_complexity: None,
    )
  let score = bridge.weighted_field_score(query, c)
  // intent=0.3 + domain=0.3 + keyword jaccard=1.0*0.2 + entity jaccard=1.0*0.1 + status=0.1 = 1.0
  should.be_true(score >. 0.99)
}

pub fn weighted_field_score_no_match_test() {
  let c =
    make_case("case-1", "coding", "software", ["rust", "compiler"], ["Mozilla"])
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["dublin", "price"],
      entities: ["Dublin"],
      max_results: 10,
      query_complexity: None,
    )
  let score = bridge.weighted_field_score(query, c)
  // intent=0, domain=0, keyword=0, entity=0, status=0.1 (success)
  should.be_true(score <. 0.15)
}

// ---------------------------------------------------------------------------
// Tests: jaccard
// ---------------------------------------------------------------------------

pub fn jaccard_identical_test() {
  bridge.jaccard(["a", "b", "c"], ["a", "b", "c"])
  |> should.equal(1.0)
}

pub fn jaccard_disjoint_test() {
  bridge.jaccard(["a", "b"], ["c", "d"])
  |> should.equal(0.0)
}

pub fn jaccard_empty_test() {
  bridge.jaccard([], ["a", "b"])
  |> should.equal(0.0)
}

// ---------------------------------------------------------------------------
// Tests: cosine_similarity
// ---------------------------------------------------------------------------

pub fn cosine_identical_test() {
  let v = [1.0, 2.0, 3.0]
  let sim = bridge.cosine_similarity(v, v)
  should.be_true(sim >. 0.99)
}

pub fn cosine_orthogonal_test() {
  let sim = bridge.cosine_similarity([1.0, 0.0], [0.0, 1.0])
  should.be_true(sim <. 0.01)
}

pub fn cosine_empty_test() {
  bridge.cosine_similarity([], [])
  |> should.equal(0.0)
}

// ---------------------------------------------------------------------------
// Tests: case_similarity
// ---------------------------------------------------------------------------

pub fn case_similarity_identical_test() {
  let c = make_case("case-1", "research", "property", ["market"], [])
  let sim = bridge.case_similarity(c, c)
  // Same intent(0.3) + domain(0.3) + keywords(0.2) + status(0.1) = 0.9
  should.be_true(sim >. 0.85)
}

pub fn case_similarity_different_test() {
  let c1 = make_case("case-1", "research", "property", ["market"], ["Dublin"])
  let c2 = make_case("case-2", "coding", "software", ["rust"], ["Mozilla"])
  let sim = bridge.case_similarity(c1, c2)
  should.be_true(sim <. 0.15)
}
