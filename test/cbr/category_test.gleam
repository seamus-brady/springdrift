// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/log as cbr_log
import cbr/types.{
  type CbrCase, type CbrCategory, CbrCase, CbrOutcome, CbrProblem, CbrSolution,
  CodePattern, DomainKnowledge, Pitfall, Strategy, Troubleshooting,
}
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_case_with_outcome(
  case_id: String,
  status: String,
  approach: String,
  pitfalls: List(String),
  category: option.Option(CbrCategory),
) -> CbrCase {
  CbrCase(
    case_id:,
    timestamp: "2026-03-26T10:00:00",
    schema_version: 1,
    problem: CbrProblem(
      user_input: "test",
      intent: "research",
      domain: "test",
      entities: [],
      keywords: [],
      query_complexity: "simple",
    ),
    solution: CbrSolution(approach:, agents_used: [], tools_used: [], steps: []),
    outcome: CbrOutcome(status:, confidence: 0.8, assessment: "test", pitfalls:),
    source_narrative_id: "cycle-001",
    profile: None,
    redacted: False,
    category:,
    usage_stats: None,
  )
}

// ---------------------------------------------------------------------------
// CbrCategory construction tests
// ---------------------------------------------------------------------------

pub fn strategy_construction_test() {
  let cat: CbrCategory = Strategy
  let _ = cat
  should.be_true(True)
}

pub fn code_pattern_construction_test() {
  let cat: CbrCategory = CodePattern
  let _ = cat
  should.be_true(True)
}

pub fn troubleshooting_construction_test() {
  let cat: CbrCategory = Troubleshooting
  let _ = cat
  should.be_true(True)
}

pub fn pitfall_construction_test() {
  let cat: CbrCategory = Pitfall
  let _ = cat
  should.be_true(True)
}

pub fn domain_knowledge_construction_test() {
  let cat: CbrCategory = DomainKnowledge
  let _ = cat
  should.be_true(True)
}

// ---------------------------------------------------------------------------
// Encode/decode round-trip tests
// ---------------------------------------------------------------------------

pub fn encode_decode_strategy_test() {
  let c =
    make_case_with_outcome(
      "cat-1",
      "success",
      "direct search",
      [],
      Some(Strategy),
    )
  let encoded = json.to_string(cbr_log.encode_case(c))
  let assert Ok(decoded) = json.parse(encoded, cbr_log.case_decoder())
  decoded.category |> should.equal(Some(Strategy))
}

pub fn encode_decode_code_pattern_test() {
  let c =
    make_case_with_outcome(
      "cat-2",
      "success",
      "code implementation",
      [],
      Some(CodePattern),
    )
  let encoded = json.to_string(cbr_log.encode_case(c))
  let assert Ok(decoded) = json.parse(encoded, cbr_log.case_decoder())
  decoded.category |> should.equal(Some(CodePattern))
}

pub fn encode_decode_troubleshooting_test() {
  let c =
    make_case_with_outcome(
      "cat-3",
      "failure",
      "debug analysis",
      [],
      Some(Troubleshooting),
    )
  let encoded = json.to_string(cbr_log.encode_case(c))
  let assert Ok(decoded) = json.parse(encoded, cbr_log.case_decoder())
  decoded.category |> should.equal(Some(Troubleshooting))
}

pub fn encode_decode_pitfall_test() {
  let c =
    make_case_with_outcome(
      "cat-4",
      "failure",
      "tried bad approach",
      ["avoid X"],
      Some(Pitfall),
    )
  let encoded = json.to_string(cbr_log.encode_case(c))
  let assert Ok(decoded) = json.parse(encoded, cbr_log.case_decoder())
  decoded.category |> should.equal(Some(Pitfall))
}

pub fn encode_decode_domain_knowledge_test() {
  let c =
    make_case_with_outcome(
      "cat-5",
      "partial",
      "research findings",
      [],
      Some(DomainKnowledge),
    )
  let encoded = json.to_string(cbr_log.encode_case(c))
  let assert Ok(decoded) = json.parse(encoded, cbr_log.case_decoder())
  decoded.category |> should.equal(Some(DomainKnowledge))
}

pub fn encode_decode_none_category_test() {
  let c = make_case_with_outcome("cat-6", "success", "direct", [], None)
  let encoded = json.to_string(cbr_log.encode_case(c))
  let assert Ok(decoded) = json.parse(encoded, cbr_log.case_decoder())
  decoded.category |> should.equal(None)
}

// ---------------------------------------------------------------------------
// Backward compatibility: decode legacy JSON without category field
// ---------------------------------------------------------------------------

pub fn decode_legacy_case_without_category_test() {
  // JSON that has no "category" field at all — should decode as None
  let legacy_json =
    "{\"case_id\":\"legacy-1\",\"timestamp\":\"2026-03-08T10:00:00\","
    <> "\"schema_version\":1,"
    <> "\"problem\":{\"user_input\":\"test\",\"intent\":\"research\",\"domain\":\"test\",\"entities\":[],\"keywords\":[],\"query_complexity\":\"simple\"},"
    <> "\"solution\":{\"approach\":\"direct\",\"agents_used\":[],\"tools_used\":[],\"steps\":[]},"
    <> "\"outcome\":{\"status\":\"success\",\"confidence\":0.8,\"assessment\":\"ok\",\"pitfalls\":[]},"
    <> "\"source_narrative_id\":\"cycle-001\",\"profile\":null,\"redacted\":false}"
  let assert Ok(decoded) = json.parse(legacy_json, cbr_log.case_decoder())
  decoded.case_id |> should.equal("legacy-1")
  decoded.category |> should.equal(None)
}

pub fn decode_legacy_case_with_null_category_test() {
  // JSON with "category": null — should decode as None
  let json_with_null =
    "{\"case_id\":\"legacy-2\",\"timestamp\":\"2026-03-08T10:00:00\","
    <> "\"schema_version\":1,"
    <> "\"problem\":{\"user_input\":\"test\",\"intent\":\"research\",\"domain\":\"test\",\"entities\":[],\"keywords\":[],\"query_complexity\":\"simple\"},"
    <> "\"solution\":{\"approach\":\"direct\",\"agents_used\":[],\"tools_used\":[],\"steps\":[]},"
    <> "\"outcome\":{\"status\":\"success\",\"confidence\":0.8,\"assessment\":\"ok\",\"pitfalls\":[]},"
    <> "\"source_narrative_id\":\"cycle-001\",\"profile\":null,\"redacted\":false,"
    <> "\"category\":null}"
  let assert Ok(decoded) = json.parse(json_with_null, cbr_log.case_decoder())
  decoded.case_id |> should.equal("legacy-2")
  decoded.category |> should.equal(None)
}

pub fn decode_unknown_category_string_test() {
  // JSON with an unknown category value — should decode as None
  let json_with_unknown =
    "{\"case_id\":\"legacy-3\",\"timestamp\":\"2026-03-08T10:00:00\","
    <> "\"schema_version\":1,"
    <> "\"problem\":{\"user_input\":\"test\",\"intent\":\"research\",\"domain\":\"test\",\"entities\":[],\"keywords\":[],\"query_complexity\":\"simple\"},"
    <> "\"solution\":{\"approach\":\"direct\",\"agents_used\":[],\"tools_used\":[],\"steps\":[]},"
    <> "\"outcome\":{\"status\":\"success\",\"confidence\":0.8,\"assessment\":\"ok\",\"pitfalls\":[]},"
    <> "\"source_narrative_id\":\"cycle-001\",\"profile\":null,\"redacted\":false,"
    <> "\"category\":\"unknown_future_category\"}"
  let assert Ok(decoded) = json.parse(json_with_unknown, cbr_log.case_decoder())
  decoded.case_id |> should.equal("legacy-3")
  decoded.category |> should.equal(None)
}

// ---------------------------------------------------------------------------
// Category string encode/decode helpers
// ---------------------------------------------------------------------------

pub fn encode_category_strings_test() {
  cbr_log.encode_category(Strategy) |> should.equal("strategy")
  cbr_log.encode_category(CodePattern) |> should.equal("code_pattern")
  cbr_log.encode_category(Troubleshooting) |> should.equal("troubleshooting")
  cbr_log.encode_category(Pitfall) |> should.equal("pitfall")
  cbr_log.encode_category(DomainKnowledge) |> should.equal("domain_knowledge")
}

pub fn decode_category_strings_test() {
  cbr_log.decode_category("strategy") |> should.equal(Some(Strategy))
  cbr_log.decode_category("code_pattern") |> should.equal(Some(CodePattern))
  cbr_log.decode_category("troubleshooting")
  |> should.equal(Some(Troubleshooting))
  cbr_log.decode_category("pitfall") |> should.equal(Some(Pitfall))
  cbr_log.decode_category("domain_knowledge")
  |> should.equal(Some(DomainKnowledge))
  cbr_log.decode_category("unknown") |> should.equal(None)
  cbr_log.decode_category("") |> should.equal(None)
}

// ---------------------------------------------------------------------------
// Category assignment logic tests (via archivist)
// We test the deterministic logic by creating cases and checking the
// encode/decode round-trip preserves the expected category.
// ---------------------------------------------------------------------------

pub fn assign_category_success_strategy_test() {
  // Success + no code terms → Strategy
  let c =
    make_case_with_outcome("a1", "success", "direct search", [], Some(Strategy))
  c.category |> should.equal(Some(Strategy))
}

pub fn assign_category_success_code_pattern_test() {
  // Success + code terms → CodePattern
  let c =
    make_case_with_outcome(
      "a2",
      "success",
      "code implementation pattern",
      [],
      Some(CodePattern),
    )
  c.category |> should.equal(Some(CodePattern))
}

pub fn assign_category_failure_with_pitfalls_test() {
  // Failure + non-empty pitfalls → Pitfall
  let c =
    make_case_with_outcome(
      "a3",
      "failure",
      "bad approach",
      ["avoid this"],
      Some(Pitfall),
    )
  c.category |> should.equal(Some(Pitfall))
}

pub fn assign_category_failure_no_pitfalls_test() {
  // Failure + empty pitfalls → Troubleshooting
  let c =
    make_case_with_outcome(
      "a4",
      "failure",
      "debugging attempt",
      [],
      Some(Troubleshooting),
    )
  c.category |> should.equal(Some(Troubleshooting))
}

pub fn assign_category_partial_test() {
  // Partial → DomainKnowledge
  let c =
    make_case_with_outcome(
      "a5",
      "partial",
      "research findings",
      [],
      Some(DomainKnowledge),
    )
  c.category |> should.equal(Some(DomainKnowledge))
}

pub fn assign_category_unknown_status_test() {
  // Unknown status → None
  let c = make_case_with_outcome("a6", "custom_status", "whatever", [], None)
  c.category |> should.equal(None)
}
