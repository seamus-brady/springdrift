//// Eval: CBR self-improvement — utility-weighted retrieval scoring.
////
//// Verifies that cases with better track records score higher in retrieval,
//// and that the housekeeping system identifies harmful cases for deprecation.
//// All tests are pure computation with synthetic data — no LLM calls.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/bridge
import cbr/types.{
  type CbrCase, CbrCase, CbrOutcome, CbrProblem, CbrQuery, CbrSolution,
  CbrUsageStats,
}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import narrative/housekeeping

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_case_with_stats(
  case_id: String,
  timestamp: String,
  retrieval_count: Int,
  retrieval_success_count: Int,
  helpful_count: Int,
  harmful_count: Int,
) -> CbrCase {
  CbrCase(
    case_id:,
    timestamp:,
    schema_version: 1,
    problem: CbrProblem(
      user_input: "test query",
      intent: "research",
      domain: "property",
      entities: ["dublin"],
      keywords: ["rent", "market"],
      query_complexity: "simple",
    ),
    solution: CbrSolution(
      approach: "web search and extract",
      agents_used: ["researcher"],
      tools_used: ["web_search", "fetch_url"],
      steps: ["search", "extract"],
    ),
    outcome: CbrOutcome(
      status: "success",
      confidence: 0.8,
      assessment: "found relevant data",
      pitfalls: [],
    ),
    source_narrative_id: "cycle-001",
    profile: None,
    redacted: False,
    category: None,
    usage_stats: Some(CbrUsageStats(
      retrieval_count:,
      retrieval_success_count:,
      helpful_count:,
      harmful_count:,
    )),
  )
}

fn make_case_no_stats(case_id: String, timestamp: String) -> CbrCase {
  CbrCase(
    case_id:,
    timestamp:,
    schema_version: 1,
    problem: CbrProblem(
      user_input: "test query",
      intent: "research",
      domain: "property",
      entities: ["dublin"],
      keywords: ["rent", "market"],
      query_complexity: "simple",
    ),
    solution: CbrSolution(
      approach: "web search and extract",
      agents_used: ["researcher"],
      tools_used: ["web_search", "fetch_url"],
      steps: ["search", "extract"],
    ),
    outcome: CbrOutcome(
      status: "success",
      confidence: 0.8,
      assessment: "found relevant data",
      pitfalls: [],
    ),
    source_narrative_id: "cycle-001",
    profile: None,
    redacted: False,
    category: None,
    usage_stats: None,
  )
}

// ---------------------------------------------------------------------------
// Utility score ranking
// ---------------------------------------------------------------------------

pub fn utility_score_ranking_test() {
  // Cases with better track records should score higher
  let high_success =
    Some(CbrUsageStats(
      retrieval_count: 10,
      retrieval_success_count: 8,
      helpful_count: 8,
      harmful_count: 0,
    ))
  let low_success =
    Some(CbrUsageStats(
      retrieval_count: 10,
      retrieval_success_count: 2,
      helpful_count: 2,
      harmful_count: 5,
    ))
  let no_data = None

  let score_high = types.utility_score(high_success)
  let score_low = types.utility_score(low_success)
  let score_neutral = types.utility_score(no_data)

  // High success (9/12 = 0.75) > neutral (0.5) > low success (3/12 = 0.25)
  should.be_true(score_high >. score_neutral)
  should.be_true(score_neutral >. score_low)
}

pub fn utility_ranking_d_a_c_b_test() {
  // Case A: retrieved 10 times, succeeded 8 times → (8+1)/(10+2) = 9/12 = 0.75
  let score_a =
    types.utility_score(
      Some(CbrUsageStats(
        retrieval_count: 10,
        retrieval_success_count: 8,
        helpful_count: 8,
        harmful_count: 0,
      )),
    )
  // Case B: retrieved 10 times, succeeded 2 times → (2+1)/(10+2) = 3/12 = 0.25
  let score_b =
    types.utility_score(
      Some(CbrUsageStats(
        retrieval_count: 10,
        retrieval_success_count: 2,
        helpful_count: 2,
        harmful_count: 5,
      )),
    )
  // Case C: never retrieved → 0.5 (Laplace neutral)
  let score_c = types.utility_score(None)
  // Case D: retrieved 5 times, succeeded 5 times → (5+1)/(5+2) = 6/7 ≈ 0.857
  let score_d =
    types.utility_score(
      Some(CbrUsageStats(
        retrieval_count: 5,
        retrieval_success_count: 5,
        helpful_count: 5,
        harmful_count: 0,
      )),
    )

  // Ranking: D > A > C > B
  should.be_true(score_d >. score_a)
  should.be_true(score_a >. score_c)
  should.be_true(score_c >. score_b)
}

// ---------------------------------------------------------------------------
// Utility improves with accumulating successes
// ---------------------------------------------------------------------------

pub fn utility_improves_with_success_test() {
  // Simulate accumulating successes and verify score increases
  let stats_after_1 =
    CbrUsageStats(
      retrieval_count: 1,
      retrieval_success_count: 1,
      helpful_count: 1,
      harmful_count: 0,
    )
  let stats_after_5 =
    CbrUsageStats(
      retrieval_count: 5,
      retrieval_success_count: 4,
      helpful_count: 4,
      harmful_count: 0,
    )
  let stats_after_10 =
    CbrUsageStats(
      retrieval_count: 10,
      retrieval_success_count: 8,
      helpful_count: 8,
      harmful_count: 0,
    )

  let score_1 = types.utility_score(Some(stats_after_1))
  let score_5 = types.utility_score(Some(stats_after_5))
  let score_10 = types.utility_score(Some(stats_after_10))

  // With consistent high success rate, more data → higher confidence
  // score_1 = 2/3 ≈ 0.667, score_5 = 5/7 ≈ 0.714, score_10 = 9/12 = 0.75
  should.be_true(score_5 >. score_1)
  should.be_true(score_10 >. score_1)
  should.be_true(score_10 >. score_5)
}

// ---------------------------------------------------------------------------
// Harmful cases score lower
// ---------------------------------------------------------------------------

pub fn harmful_cases_score_lower_test() {
  // Note: utility_score uses retrieval_success_count, not helpful/harmful counts
  let helpful =
    CbrUsageStats(
      retrieval_count: 10,
      retrieval_success_count: 8,
      helpful_count: 10,
      harmful_count: 0,
    )
  let mixed =
    CbrUsageStats(
      retrieval_count: 10,
      retrieval_success_count: 5,
      helpful_count: 5,
      harmful_count: 5,
    )
  let harmful =
    CbrUsageStats(
      retrieval_count: 10,
      retrieval_success_count: 2,
      helpful_count: 2,
      harmful_count: 8,
    )

  // 9/12 > 6/12 > 3/12
  should.be_true(
    types.utility_score(Some(helpful)) >. types.utility_score(Some(mixed)),
  )
  should.be_true(
    types.utility_score(Some(mixed)) >. types.utility_score(Some(harmful)),
  )
}

// ---------------------------------------------------------------------------
// Utility signal affects retrieval ranking end-to-end
// ---------------------------------------------------------------------------

pub fn utility_signal_ranks_good_cases_higher_test() {
  // Build two identical cases differing only in usage stats
  let good =
    make_case_with_stats("case-good", "2026-03-26T10:00:00", 10, 9, 9, 0)
  let bad = make_case_with_stats("case-bad", "2026-03-26T10:00:00", 10, 1, 0, 8)
  let neutral = make_case_no_stats("case-neutral", "2026-03-26T10:00:00")

  let base =
    bridge.new()
    |> bridge.retain_case(good)
    |> bridge.retain_case(bad)
    |> bridge.retain_case(neutral)

  let metadata =
    dict.from_list([
      #("case-good", good),
      #("case-bad", bad),
      #("case-neutral", neutral),
    ])

  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["rent", "market"],
      entities: ["dublin"],
      max_results: 10,
      query_complexity: None,
    )

  // Use utility-heavy weights to isolate the utility signal
  let weights =
    bridge.RetrievalWeights(
      field_weight: 0.0,
      index_weight: 0.0,
      recency_weight: 0.0,
      domain_weight: 0.0,
      embedding_weight: 0.0,
      utility_weight: 1.0,
    )

  let results = bridge.retrieve_cases(base, query, metadata, weights, 0.0)
  should.be_true(list.length(results) == 3)
  let assert [top, middle, bottom] = results
  top.cbr_case.case_id |> should.equal("case-good")
  // Neutral (0.5) should be above bad (2/12 ≈ 0.167)
  should.be_true(middle.score >. bottom.score)
}

// ---------------------------------------------------------------------------
// Utility converges as data accumulates
// ---------------------------------------------------------------------------

pub fn utility_converges_toward_true_rate_test() {
  // With 80% true success rate, utility score should approach 0.8 as N grows
  let score_n5 =
    types.utility_score(
      Some(CbrUsageStats(
        retrieval_count: 5,
        retrieval_success_count: 4,
        helpful_count: 4,
        harmful_count: 0,
      )),
    )
  let score_n50 =
    types.utility_score(
      Some(CbrUsageStats(
        retrieval_count: 50,
        retrieval_success_count: 40,
        helpful_count: 40,
        harmful_count: 0,
      )),
    )
  let score_n500 =
    types.utility_score(
      Some(CbrUsageStats(
        retrieval_count: 500,
        retrieval_success_count: 400,
        helpful_count: 400,
        harmful_count: 0,
      )),
    )

  // All should be close to 0.8, getting closer as N grows
  let target = 0.8
  let diff_5 = abs_float(score_n5 -. target)
  let diff_50 = abs_float(score_n50 -. target)
  let diff_500 = abs_float(score_n500 -. target)

  should.be_true(diff_50 <. diff_5)
  should.be_true(diff_500 <. diff_50)
  // With N=500, should be very close to 0.8
  should.be_true(diff_500 <. 0.005)
}

fn abs_float(x: Float) -> Float {
  case x <. 0.0 {
    True -> 0.0 -. x
    False -> x
  }
}

// ---------------------------------------------------------------------------
// Housekeeping: harmful case detection
// ---------------------------------------------------------------------------

pub fn housekeeping_identifies_harmful_cases_test() {
  // Cases with harmful_count > helpful_count * 2 and retrieval_count > 5
  // should be flagged for deprecation
  let cases = [
    // Clearly harmful: 8 harmful > 1*2 helpful, retrieval_count 10 > 5
    make_case_with_stats("harmful-1", "2026-03-26T10:00:00", 10, 3, 1, 8),
    // Harmful edge: 7 harmful > 3*2=6, retrieval_count 10 > 5
    make_case_with_stats("harmful-2", "2026-03-26T10:00:00", 10, 4, 3, 7),
    // Not harmful: balanced
    make_case_with_stats("balanced", "2026-03-26T10:00:00", 10, 5, 4, 4),
    // Not harmful: helpful dominant
    make_case_with_stats("helpful", "2026-03-26T10:00:00", 10, 8, 8, 1),
    // Not enough data (retrieval_count <= 5)
    make_case_with_stats("low-data", "2026-03-26T10:00:00", 3, 0, 0, 3),
    // No stats at all
    make_case_no_stats("no-stats", "2026-03-26T10:00:00"),
  ]

  let results = housekeeping.find_harmful_cases(cases)
  let result_ids = list.map(results, fn(r) { r.case_id })

  // Should flag both harmful cases
  should.be_true(list.contains(result_ids, "harmful-1"))
  should.be_true(list.contains(result_ids, "harmful-2"))
  // Should not flag balanced, helpful, low-data, or no-stats
  should.be_false(list.contains(result_ids, "balanced"))
  should.be_false(list.contains(result_ids, "helpful"))
  should.be_false(list.contains(result_ids, "low-data"))
  should.be_false(list.contains(result_ids, "no-stats"))
}

pub fn housekeeping_boundary_harmful_count_test() {
  // Edge case: harmful_count == helpful_count * 2 (not strictly greater)
  let cases = [
    make_case_with_stats("boundary", "2026-03-26T10:00:00", 10, 3, 3, 6),
  ]
  let results = housekeeping.find_harmful_cases(cases)
  // 6 is NOT > 3*2=6, so should not be flagged
  list.length(results) |> should.equal(0)
}

pub fn housekeeping_boundary_retrieval_count_test() {
  // Edge case: retrieval_count == 5 (not strictly greater)
  let cases = [
    make_case_with_stats("boundary", "2026-03-26T10:00:00", 5, 0, 0, 5),
  ]
  let results = housekeeping.find_harmful_cases(cases)
  // 5 is NOT > 5, so should not be flagged
  list.length(results) |> should.equal(0)
}
