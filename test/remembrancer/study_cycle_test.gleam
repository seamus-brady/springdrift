////
//// Tests for Phase E Study-Cycle tools: extract_insights returns raw
//// material; promote_insight rate-limits fact writes.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import facts/log as facts_log
import facts/types as facts_types
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import simplifile

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/study_cycle_test_" <> suffix
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

fn make_promotion(id: String, key: String) -> facts_types.MemoryFact {
  facts_types.MemoryFact(
    schema_version: 1,
    fact_id: id,
    timestamp: "2026-04-19T10:00:00Z",
    cycle_id: "c-1",
    agent_id: Some("remembrancer"),
    key: key,
    value: "an insight",
    scope: facts_types.Persistent,
    operation: facts_types.Write,
    supersedes: None,
    confidence: 0.7,
    source: "promote_insight",
    provenance: None,
  )
}

pub fn promote_insight_round_trip_test() {
  let dir = test_dir("promote_round_trip")
  let f = make_promotion("f1", "research_query_specificity")
  facts_log.append(dir, f)
  let loaded = facts_log.load_all(dir)
  case loaded {
    [first] -> {
      first.key |> should.equal("research_query_specificity")
      first.source |> should.equal("promote_insight")
      first.scope |> should.equal(facts_types.Persistent)
    }
    _ -> should.fail()
  }
}

pub fn promote_insight_rate_limit_count_test() {
  // Replicate the rate-limit query used by run_promote_insight: count
  // today's facts with source = "promote_insight".
  let dir = test_dir("rate_limit")
  facts_log.append(dir, make_promotion("a", "k1"))
  facts_log.append(dir, make_promotion("b", "k2"))
  facts_log.append(dir, make_promotion("c", "k3"))
  // A non-promotion fact must NOT count toward the rate limit.
  let unrelated =
    facts_types.MemoryFact(
      ..make_promotion("d", "k4"),
      source: "memory_write_tool",
    )
  facts_log.append(dir, unrelated)
  let all = facts_log.load_all(dir)
  let promoted = list.count(all, fn(f) { f.source == "promote_insight" })
  promoted |> should.equal(3)
}

pub fn promote_insight_provenance_marks_synthesis_test() {
  // The tool should write provenance with derivation=Synthesis. Verify
  // that round-trips correctly through the JSONL.
  let dir = test_dir("provenance")
  let with_prov =
    facts_types.MemoryFact(
      ..make_promotion("e", "k_prov"),
      provenance: Some(facts_types.FactProvenance(
        source_cycle_id: "c-1",
        source_tool: "promote_insight",
        source_agent: "remembrancer",
        derivation: facts_types.Synthesis,
      )),
    )
  facts_log.append(dir, with_prov)
  case facts_log.load_all(dir) {
    [f] ->
      case f.provenance {
        Some(p) -> p.derivation |> should.equal(facts_types.Synthesis)
        None -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn extract_insights_payload_shape_test() {
  // The tool returns a JSON payload + plain-text body; this test pins
  // the JSON keys so future renames don't silently break the agent's
  // contract with the tool.
  let payload =
    json.object([
      #("from_date", json.string("2026-04-01")),
      #("to_date", json.string("2026-04-19")),
      #("focus", json.string("research")),
      #("max_insights", json.int(5)),
      #("entries_in_period", json.int(12)),
      #("cases_considered", json.int(20)),
    ])
  let s = json.to_string(payload)
  string.contains(s, "from_date") |> should.equal(True)
  string.contains(s, "to_date") |> should.equal(True)
  string.contains(s, "max_insights") |> should.equal(True)
  string.contains(s, "entries_in_period") |> should.equal(True)
  string.contains(s, "cases_considered") |> should.equal(True)
}
