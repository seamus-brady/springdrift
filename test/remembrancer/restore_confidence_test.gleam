// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import facts/log as facts_log
import facts/types as facts_types
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import llm/types as llm_types
import simplifile
import tools/remembrancer as tools_remembrancer

fn temp_dir(suffix: String) -> String {
  let dir = "/tmp/remembrancer_restore_confidence_" <> suffix
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

fn context(facts_dir: String) -> tools_remembrancer.RemembrancerContext {
  tools_remembrancer.RemembrancerContext(
    narrative_dir: facts_dir,
    cbr_dir: facts_dir,
    facts_dir:,
    knowledge_consolidation_dir: facts_dir,
    consolidation_log_dir: facts_dir,
    cycle_id: "test-cycle",
    agent_id: "test-agent",
    librarian: None,
    review_confidence_threshold: 0.3,
    dormant_thread_days: 7,
    min_pattern_cases: 3,
  )
}

fn seed_fact(
  dir: String,
  fact_id: String,
  key: String,
  confidence: Float,
) -> Nil {
  facts_log.append(
    dir,
    facts_types.MemoryFact(
      schema_version: 1,
      fact_id:,
      timestamp: "2026-01-01T10:00:00",
      cycle_id: "seed",
      agent_id: None,
      key:,
      value: "original value",
      scope: facts_types.Persistent,
      operation: facts_types.Write,
      supersedes: None,
      confidence:,
      source: "test",
      provenance: None,
    ),
  )
}

// ---------------------------------------------------------------------------
// Supersedes chain
// ---------------------------------------------------------------------------

pub fn restore_confidence_links_prior_fact_test() {
  let dir = temp_dir("links_prior")
  seed_fact(dir, "fact-original-001", "dublin_rent", 0.25)

  let call =
    llm_types.ToolCall(
      id: "t1",
      name: "restore_confidence",
      input_json: "{\"key\":\"dublin_rent\",\"value\":\"2400\","
        <> "\"new_confidence\":0.9,\"reason\":\"re-checked CSO source\"}",
    )
  let result = tools_remembrancer.execute(call, context(dir))
  case result {
    llm_types.ToolSuccess(_, _) -> Nil
    llm_types.ToolFailure(_, e) -> {
      panic as { "expected success, got failure: " <> e }
    }
  }

  let all = facts_log.load_all(dir)
  // Two facts total: seeded + restored
  list.length(all) |> should.equal(2)

  let restored = list.find(all, fn(f) { f.fact_id != "fact-original-001" })
  case restored {
    Ok(f) -> {
      f.supersedes |> should.equal(Some("fact-original-001"))
      f.confidence |> should.equal(0.9)
      f.value |> should.equal("2400")
      f.source |> should.equal("remembrancer:restore_confidence")
    }
    Error(_) -> should.fail()
  }
}

pub fn restore_confidence_no_prior_has_none_supersedes_test() {
  let dir = temp_dir("no_prior")
  // Deliberately NO seed fact for this key

  let call =
    llm_types.ToolCall(
      id: "t1",
      name: "restore_confidence",
      input_json: "{\"key\":\"novel_key\",\"value\":\"newly_verified\","
        <> "\"new_confidence\":0.75,\"reason\":\"first time verified\"}",
    )
  let result = tools_remembrancer.execute(call, context(dir))
  case result {
    llm_types.ToolSuccess(_, _) -> Nil
    llm_types.ToolFailure(_, e) -> {
      panic as { "expected success, got failure: " <> e }
    }
  }

  let all = facts_log.load_all(dir)
  list.length(all) |> should.equal(1)
  case all {
    [f] -> {
      f.supersedes |> should.equal(None)
      f.key |> should.equal("novel_key")
    }
    _ -> should.fail()
  }
}

pub fn restore_confidence_confidence_clamped_test() {
  let dir = temp_dir("clamped")
  let call =
    llm_types.ToolCall(
      id: "t1",
      name: "restore_confidence",
      input_json: "{\"key\":\"some_key\",\"value\":\"v\","
        <> "\"new_confidence\":1.5,\"reason\":\"over-bound\"}",
    )
  let _ = tools_remembrancer.execute(call, context(dir))
  case facts_log.load_all(dir) {
    [f] -> f.confidence |> should.equal(1.0)
    _ -> should.fail()
  }
}

pub fn restore_confidence_empty_key_rejected_test() {
  let dir = temp_dir("empty_key")
  let call =
    llm_types.ToolCall(
      id: "t1",
      name: "restore_confidence",
      input_json: "{\"key\":\"   \",\"value\":\"v\","
        <> "\"new_confidence\":0.5,\"reason\":\"blank\"}",
    )
  let result = tools_remembrancer.execute(call, context(dir))
  case result {
    llm_types.ToolFailure(_, _) -> Nil
    llm_types.ToolSuccess(_, _) -> should.fail()
  }
  // No fact written
  facts_log.load_all(dir) |> list.length |> should.equal(0)
}
