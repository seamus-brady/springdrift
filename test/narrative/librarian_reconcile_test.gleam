// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/log as cbr_log
import cbr/types as cbr_types
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import narrative/librarian
import narrative/log as narrative_log
import narrative/types.{
  Conversation, Entities, Intent, Metrics, Narrative, NarrativeEntry, Outcome,
  Success,
}
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/librarian_reconcile_test_" <> suffix
  let _ = simplifile.create_directory_all(dir)
  let _ = simplifile.create_directory_all(dir <> "/cbr")
  let _ = simplifile.create_directory_all(dir <> "/facts")
  let _ = simplifile.create_directory_all(dir <> "/artifacts")
  let _ = simplifile.create_directory_all(dir <> "/planner")
  // Clean any existing files in all subdirs
  clean_dir(dir)
  clean_dir(dir <> "/cbr")
  clean_dir(dir <> "/facts")
  clean_dir(dir <> "/artifacts")
  clean_dir(dir <> "/planner")
  dir
}

fn clean_dir(dir: String) -> Nil {
  case simplifile.read_directory(dir) {
    Ok(files) ->
      list.each(files, fn(f) {
        let path = dir <> "/" <> f
        case simplifile.is_directory(path) {
          Ok(True) -> Nil
          _ -> {
            let _ = simplifile.delete(path)
            Nil
          }
        }
      })
    Error(_) -> Nil
  }
}

fn make_entry(cycle_id: String, summary: String) -> types.NarrativeEntry {
  NarrativeEntry(
    schema_version: 1,
    cycle_id:,
    parent_cycle_id: None,
    timestamp: "2026-03-08T10:00:00",
    entry_type: Narrative,
    summary:,
    intent: Intent(
      classification: Conversation,
      description: "test",
      domain: "testing",
    ),
    outcome: Outcome(status: Success, confidence: 0.9, assessment: "ok"),
    delegation_chain: [],
    decisions: [],
    keywords: ["test"],
    topics: [],
    entities: Entities(
      locations: [],
      organisations: [],
      data_points: [],
      temporal_references: [],
    ),
    sources: [],
    thread: None,
    metrics: Metrics(
      total_duration_ms: 0,
      input_tokens: 100,
      output_tokens: 50,
      thinking_tokens: 0,
      tool_calls: 0,
      agent_delegations: 0,
      dprime_evaluations: 0,
      model_used: "mock",
    ),
    observations: [],
    redacted: False,
  )
}

fn make_cbr_case(id: String) -> cbr_types.CbrCase {
  cbr_types.CbrCase(
    schema_version: 1,
    case_id: id,
    timestamp: "2026-03-08T10:00:00",
    problem: cbr_types.CbrProblem(
      user_input: "test input",
      intent: "test intent",
      domain: "testing",
      entities: [],
      keywords: ["test"],
      query_complexity: "simple",
    ),
    solution: cbr_types.CbrSolution(
      approach: "test approach",
      agents_used: [],
      tools_used: [],
      steps: [],
    ),
    outcome: cbr_types.CbrOutcome(
      status: "success",
      confidence: 0.9,
      assessment: "ok",
      pitfalls: [],
    ),
    source_narrative_id: "cycle-001",
    profile: None,
    category: None,
    usage_stats: None,
    redacted: False,
  )
}

fn start_lib(dir: String) -> process.Subject(librarian.LibrarianMessage) {
  librarian.start(
    dir,
    dir <> "/cbr",
    dir <> "/facts",
    dir <> "/artifacts",
    dir <> "/planner",
    0,
    librarian.default_cbr_config(),
  )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Write entries to JSONL but do NOT notify the Librarian. After a short wait
/// (to allow the 60s reconciliation timer to fire), the entries should appear.
/// Since we can't wait 60s in a test, we test the mechanism indirectly by
/// writing to disk before starting the Librarian, then adding more entries
/// to disk without notifying, then restarting.
pub fn reconcile_detects_missed_narrative_entry_test() {
  let dir = test_dir("reconcile_narrative")

  // Write two entries to disk
  let entry1 = make_entry("cycle-100", "Entry one")
  let entry2 = make_entry("cycle-200", "Entry two")
  narrative_log.append(dir, entry1)
  narrative_log.append(dir, entry2)

  // Start Librarian — replays both entries from disk
  let lib = start_lib(dir)
  let entries = librarian.load_all(lib)
  list.length(entries) |> should.equal(2)

  // Now write a third entry directly to disk (simulating a missed notification)
  let entry3 = make_entry("cycle-300", "Entry three")
  narrative_log.append(dir, entry3)

  // The entry is NOT in ETS yet because we didn't call notify_new_entry
  let entries2 = librarian.load_all(lib)
  list.length(entries2) |> should.equal(2)

  // Shutdown and restart — the reconciliation at startup replays all
  process.send(lib, librarian.Shutdown)
  process.sleep(50)
  let lib2 = start_lib(dir)
  let entries3 = librarian.load_all(lib2)
  list.length(entries3) |> should.equal(3)
  process.send(lib2, librarian.Shutdown)
}

/// Similar test for CBR cases.
pub fn reconcile_detects_missed_cbr_case_test() {
  let dir = test_dir("reconcile_cbr")

  // Write a CBR case to disk
  let case1 = make_cbr_case("case-100")
  cbr_log.append(dir <> "/cbr", case1)

  // Start Librarian — replays the case
  let lib = start_lib(dir)
  let cases = librarian.load_all_cases(lib)
  list.length(cases) |> should.equal(1)

  // Write another case directly to disk (missed notification)
  let case2 = make_cbr_case("case-200")
  cbr_log.append(dir <> "/cbr", case2)

  // Not in ETS yet
  let cases2 = librarian.load_all_cases(lib)
  list.length(cases2) |> should.equal(1)

  // Restart — replays all
  process.send(lib, librarian.Shutdown)
  process.sleep(50)
  let lib2 = start_lib(dir)
  let cases3 = librarian.load_all_cases(lib2)
  list.length(cases3) |> should.equal(2)
  process.send(lib2, librarian.Shutdown)
}

/// Verify that when disk and ETS are in sync, no re-indexing happens
/// (the Librarian starts cleanly with correct counts).
pub fn reconcile_no_op_when_in_sync_test() {
  let dir = test_dir("reconcile_noop")

  let entry1 = make_entry("cycle-400", "Synced entry")
  narrative_log.append(dir, entry1)

  let lib = start_lib(dir)

  // Notify the Librarian (simulating normal operation)
  librarian.notify_new_entry(lib, make_entry("cycle-500", "Notified entry"))
  process.sleep(50)

  // Both entries should be present (1 from replay + 1 from notification)
  // Note: cycle-500 was notified but not written to disk by us, so
  // on restart it would disappear. The point is: during this session
  // both are visible.
  let entries = librarian.load_all(lib)
  list.length(entries) |> should.equal(2)

  process.send(lib, librarian.Shutdown)
}

/// Test that the count_lines FFI works correctly.
pub fn count_lines_ffi_test() {
  let dir = test_dir("count_lines")
  let path = dir <> "/test.jsonl"

  // Empty/non-existent file
  count_lines(path) |> should.equal(0)

  // Write 3 lines
  let _ = simplifile.write(path, "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n")
  count_lines(path) |> should.equal(3)

  // File with blank lines (should be skipped)
  let _ = simplifile.write(path, "{\"a\":1}\n\n{\"b\":2}\n\n")
  count_lines(path) |> should.equal(2)
}

@external(erlang, "springdrift_ffi", "count_lines")
fn count_lines(path: String) -> Int
