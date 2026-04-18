// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/bridge
import cbr/log as cbr_log
import cbr/types.{
  type CbrCase, CbrCase, CbrOutcome, CbrProblem, CbrQuery, CbrSolution,
  CbrUsageStats,
}
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import llm/types as llm_types
import narrative/housekeeping
import simplifile
import tools/memory

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_case(case_id: String) -> CbrCase {
  CbrCase(
    case_id:,
    timestamp: "2026-03-26T10:00:00",
    schema_version: 1,
    problem: CbrProblem(
      user_input: "test query",
      intent: "research",
      domain: "property",
      entities: [],
      keywords: ["market"],
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

fn make_case_with_stats(
  case_id: String,
  retrieval_count: Int,
  retrieval_success_count: Int,
  helpful_count: Int,
  harmful_count: Int,
) -> CbrCase {
  CbrCase(
    ..make_case(case_id),
    usage_stats: Some(CbrUsageStats(
      retrieval_count:,
      retrieval_success_count:,
      helpful_count:,
      harmful_count:,
    )),
  )
}

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/cbr_usage_stats_test_" <> suffix
  let _ = simplifile.create_directory_all(dir)
  case simplifile.read_directory(dir) {
    Ok(files) ->
      list.each(files, fn(f) {
        let _ = simplifile.delete(dir <> "/" <> f)
        Nil
      })
    Error(_) -> Nil
  }
  dir
}

// ---------------------------------------------------------------------------
// CbrUsageStats construction
// ---------------------------------------------------------------------------

pub fn empty_usage_stats_test() {
  let stats = types.empty_usage_stats()
  stats.retrieval_count |> should.equal(0)
  stats.retrieval_success_count |> should.equal(0)
  stats.helpful_count |> should.equal(0)
  stats.harmful_count |> should.equal(0)
}

pub fn usage_stats_construction_test() {
  let stats =
    CbrUsageStats(
      retrieval_count: 10,
      retrieval_success_count: 7,
      helpful_count: 5,
      harmful_count: 2,
    )
  stats.retrieval_count |> should.equal(10)
  stats.retrieval_success_count |> should.equal(7)
  stats.helpful_count |> should.equal(5)
  stats.harmful_count |> should.equal(2)
}

// ---------------------------------------------------------------------------
// utility_score calculation
// ---------------------------------------------------------------------------

pub fn utility_score_no_data_returns_half_test() {
  let score = types.utility_score(None)
  should.be_true(score >. 0.49)
  should.be_true(score <. 0.51)
}

pub fn utility_score_empty_stats_returns_half_test() {
  let stats = types.empty_usage_stats()
  let score = types.utility_score(Some(stats))
  // (0 + 1) / (0 + 2) = 0.5
  should.be_true(score >. 0.49)
  should.be_true(score <. 0.51)
}

pub fn utility_score_all_success_test() {
  let stats =
    CbrUsageStats(
      retrieval_count: 10,
      retrieval_success_count: 10,
      helpful_count: 0,
      harmful_count: 0,
    )
  let score = types.utility_score(Some(stats))
  // (10 + 1) / (10 + 2) = 11/12 ≈ 0.917
  should.be_true(score >. 0.9)
  should.be_true(score <. 0.93)
}

pub fn utility_score_no_success_test() {
  let stats =
    CbrUsageStats(
      retrieval_count: 10,
      retrieval_success_count: 0,
      helpful_count: 0,
      harmful_count: 0,
    )
  let score = types.utility_score(Some(stats))
  // (0 + 1) / (10 + 2) = 1/12 ≈ 0.083
  should.be_true(score >. 0.07)
  should.be_true(score <. 0.1)
}

pub fn utility_score_partial_success_test() {
  let stats =
    CbrUsageStats(
      retrieval_count: 8,
      retrieval_success_count: 4,
      helpful_count: 0,
      harmful_count: 0,
    )
  let score = types.utility_score(Some(stats))
  // (4 + 1) / (8 + 2) = 5/10 = 0.5
  should.be_true(score >. 0.49)
  should.be_true(score <. 0.51)
}

// ---------------------------------------------------------------------------
// Encode/decode round-trip
// ---------------------------------------------------------------------------

pub fn usage_stats_encode_decode_roundtrip_test() {
  let c = make_case_with_stats("case-stats", 10, 7, 5, 2)
  let encoded = json.to_string(cbr_log.encode_case(c))
  let assert Ok(decoded) = json.parse(encoded, cbr_log.case_decoder())
  decoded.case_id |> should.equal("case-stats")
  let assert Some(stats) = decoded.usage_stats
  stats.retrieval_count |> should.equal(10)
  stats.retrieval_success_count |> should.equal(7)
  stats.helpful_count |> should.equal(5)
  stats.harmful_count |> should.equal(2)
}

pub fn usage_stats_none_roundtrip_test() {
  let c = make_case("case-no-stats")
  let encoded = json.to_string(cbr_log.encode_case(c))
  let assert Ok(decoded) = json.parse(encoded, cbr_log.case_decoder())
  decoded.usage_stats |> should.equal(None)
}

// ---------------------------------------------------------------------------
// Backward compatibility: decode legacy case without usage_stats
// ---------------------------------------------------------------------------

pub fn backward_compat_no_usage_stats_test() {
  // Minimal JSON without usage_stats field at all
  let legacy_json =
    "{\"case_id\":\"case-legacy\",\"timestamp\":\"2026-03-08T10:00:00\","
    <> "\"schema_version\":1,\"source_narrative_id\":\"cycle-001\",\"profile\":null,"
    <> "\"problem\":{\"user_input\":\"q\",\"intent\":\"research\",\"domain\":\"property\",\"entities\":[],\"keywords\":[],\"query_complexity\":\"simple\"},"
    <> "\"solution\":{\"approach\":\"direct\",\"agents_used\":[],\"tools_used\":[],\"steps\":[]},"
    <> "\"outcome\":{\"status\":\"success\",\"confidence\":0.8,\"assessment\":\"ok\",\"pitfalls\":[]}}"
  let assert Ok(decoded) = json.parse(legacy_json, cbr_log.case_decoder())
  decoded.case_id |> should.equal("case-legacy")
  decoded.usage_stats |> should.equal(None)
}

pub fn backward_compat_null_usage_stats_test() {
  // JSON with usage_stats explicitly set to null
  let json_with_null =
    "{\"case_id\":\"case-null\",\"timestamp\":\"2026-03-08T10:00:00\","
    <> "\"schema_version\":1,\"source_narrative_id\":\"cycle-001\",\"profile\":null,"
    <> "\"usage_stats\":null,"
    <> "\"problem\":{\"user_input\":\"q\",\"intent\":\"research\",\"domain\":\"property\",\"entities\":[],\"keywords\":[],\"query_complexity\":\"simple\"},"
    <> "\"solution\":{\"approach\":\"direct\",\"agents_used\":[],\"tools_used\":[],\"steps\":[]},"
    <> "\"outcome\":{\"status\":\"success\",\"confidence\":0.8,\"assessment\":\"ok\",\"pitfalls\":[]}}"
  let assert Ok(decoded) = json.parse(json_with_null, cbr_log.case_decoder())
  decoded.usage_stats |> should.equal(None)
}

// ---------------------------------------------------------------------------
// JSONL persistence round-trip
// ---------------------------------------------------------------------------

pub fn usage_stats_persist_and_load_test() {
  let dir = test_dir("persist")
  let c = make_case_with_stats("case-persist", 5, 3, 2, 1)
  let json_str = json.to_string(cbr_log.encode_case(c))
  let _ = simplifile.write(dir <> "/2026-03-26.jsonl", json_str <> "\n")

  let cases = cbr_log.load_date(dir, "2026-03-26")
  list.length(cases) |> should.equal(1)
  let assert [loaded] = cases
  let assert Some(stats) = loaded.usage_stats
  stats.retrieval_count |> should.equal(5)
  stats.retrieval_success_count |> should.equal(3)
}

// ---------------------------------------------------------------------------
// Utility signal in retrieval scoring
// ---------------------------------------------------------------------------

pub fn utility_signal_affects_retrieval_ranking_test() {
  let base = bridge.new()
  // c1 has good usage stats, c2 has bad usage stats
  let c1 = make_case_with_stats("case-good", 10, 9, 5, 0)
  let c2 = make_case_with_stats("case-bad", 10, 1, 0, 5)
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)
  let metadata = dict.from_list([#("case-good", c1), #("case-bad", c2)])

  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: [],
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
  should.be_true(list.length(results) == 2)
  let assert [top, ..] = results
  // case-good should rank first due to higher utility score
  top.cbr_case.case_id |> should.equal("case-good")
}

pub fn utility_signal_neutral_without_stats_test() {
  let base = bridge.new()
  let c_with = make_case_with_stats("case-with", 10, 5, 3, 1)
  let c_without = make_case("case-without")
  let base = bridge.retain_case(base, c_with)
  let base = bridge.retain_case(base, c_without)
  let metadata =
    dict.from_list([#("case-with", c_with), #("case-without", c_without)])

  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )

  // With utility weight only, case-without (no stats → 0.5) and
  // case-with (5+1)/(10+2) = 0.5 should be equal
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
  should.be_true(list.length(results) == 2)
  // Both should have the same score (0.5)
  let assert [first, second] = results
  let diff = first.score -. second.score
  should.be_true(diff <. 0.01)
  should.be_true(diff >. -0.01)
}

// ---------------------------------------------------------------------------
// extract_recalled_case_ids
// ---------------------------------------------------------------------------

pub fn extract_case_ids_from_recall_result_test() {
  let calls = [
    llm_types.ToolCall(id: "tool-1", name: "recall_cases", input_json: "{}"),
  ]
  let results = [
    llm_types.ToolResultContent(
      tool_use_id: "tool-1",
      content: "Found 2 matching cases:\n\n[case_id: abc-123] [score: 0.9] research | property\n---\n[case_id: def-456] [score: 0.7] coding | software",
      is_error: False,
    ),
  ]
  let ids = memory.extract_recalled_case_ids(calls, results)
  should.equal(ids, ["abc-123", "def-456"])
}

pub fn extract_case_ids_no_recall_calls_test() {
  let calls = [
    llm_types.ToolCall(id: "tool-1", name: "memory_read", input_json: "{}"),
  ]
  let results = [
    llm_types.ToolResultContent(
      tool_use_id: "tool-1",
      content: "some content",
      is_error: False,
    ),
  ]
  let ids = memory.extract_recalled_case_ids(calls, results)
  should.equal(ids, [])
}

pub fn extract_case_ids_empty_results_test() {
  let calls = [
    llm_types.ToolCall(id: "tool-1", name: "recall_cases", input_json: "{}"),
  ]
  let results = [
    llm_types.ToolResultContent(
      tool_use_id: "tool-1",
      content: "No matching cases found in CBR memory.",
      is_error: False,
    ),
  ]
  let ids = memory.extract_recalled_case_ids(calls, results)
  should.equal(ids, [])
}

// ---------------------------------------------------------------------------
// Housekeeping: harmful case detection
// ---------------------------------------------------------------------------

pub fn find_harmful_cases_test() {
  let cases = [
    // Harmful: 6 harmful > 2 * 1 helpful, retrieval_count > 5
    make_case_with_stats("harmful", 10, 3, 1, 6),
    // Not harmful: balanced
    make_case_with_stats("balanced", 10, 5, 3, 3),
    // Not enough data
    make_case_with_stats("low-data", 3, 1, 0, 3),
    // No stats
    make_case("no-stats"),
  ]
  let results = housekeeping.find_harmful_cases(cases)
  list.length(results) |> should.equal(1)
  let assert [result] = results
  result.case_id |> should.equal("harmful")
}
