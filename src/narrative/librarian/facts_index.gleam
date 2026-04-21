//// Facts store — key-value memory with scopes, confidence, supersession.
////
//// Two ETS tables:
////   - facts_by_key    (set)  — key → MemoryFact (current value)
////   - facts_by_cycle  (bag)  — cycle_id → MemoryFact (per-cycle provenance)
////
//// Write/Clear/Superseded operations feed through `index_fact` to keep
//// the ETS caches in sync with the daily-rotated JSONL log.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import facts/log as facts_log
import facts/types as facts_types
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import slog

pub type Table

@external(erlang, "store_ffi", "new_unique_table")
pub fn new_table(name: String, table_type: String) -> Table

@external(erlang, "store_ffi", "delete_table")
pub fn delete_table(table: Table) -> Nil

@external(erlang, "store_ffi", "table_size")
pub fn table_size(table: Table) -> Int

@external(erlang, "store_ffi", "insert")
pub fn insert(table: Table, key: String, value: facts_types.MemoryFact) -> Nil

@external(erlang, "store_ffi", "lookup")
pub fn lookup(table: Table, key: String) -> Result(facts_types.MemoryFact, Nil)

@external(erlang, "store_ffi", "lookup_bag")
pub fn lookup_bag(table: Table, key: String) -> List(facts_types.MemoryFact)

@external(erlang, "store_ffi", "all_values")
pub fn all_values(table: Table) -> List(facts_types.MemoryFact)

@external(erlang, "store_ffi", "delete_key")
pub fn delete_key(table: Table, key: String) -> Nil

// ---------------------------------------------------------------------------
// Indexing
// ---------------------------------------------------------------------------

/// Apply a single fact op to both ETS tables, honouring its operation.
/// Write: update facts_by_key, index by cycle. Clear: delete from by_key,
/// still index by_cycle for provenance. Superseded: index by_cycle only
/// (the new Write that caused the supersession already updated by_key).
pub fn index_fact(
  facts_by_key: Table,
  facts_by_cycle: Table,
  fact: facts_types.MemoryFact,
) -> Nil {
  case fact.operation {
    facts_types.Write -> {
      insert(facts_by_key, fact.key, fact)
      insert(facts_by_cycle, fact.cycle_id, fact)
    }
    facts_types.Clear -> {
      delete_key(facts_by_key, fact.key)
      insert(facts_by_cycle, fact.cycle_id, fact)
    }
    facts_types.Superseded -> {
      insert(facts_by_cycle, fact.cycle_id, fact)
    }
  }
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/// Case-insensitive substring search over current (non-superseded) facts.
/// Matches on both key and value.
pub fn search(
  facts_by_key: Table,
  keyword: String,
) -> List(facts_types.MemoryFact) {
  let lower = string.lowercase(keyword)
  let all = all_values(facts_by_key)
  list.filter(all, fn(f) {
    string.contains(string.lowercase(f.key), lower)
    || string.contains(string.lowercase(f.value), lower)
  })
}

// ---------------------------------------------------------------------------
// Startup replay
// ---------------------------------------------------------------------------

/// Facts always load ALL files — no max_files windowing. Full history is
/// needed for `memory_trace_fact`, `inspect_cycle`, and correct
/// supersession resolution across the entire fact timeline.
pub fn replay_from_disk(
  facts_by_key: Table,
  facts_by_cycle: Table,
  facts_dir: String,
) -> Nil {
  let facts = facts_log.load_all(facts_dir)
  list.each(facts, fn(f) { index_fact(facts_by_key, facts_by_cycle, f) })
}

// ---------------------------------------------------------------------------
// Reconciliation — ETS vs disk gap repair
// ---------------------------------------------------------------------------

/// Replay any facts from today's JSONL that aren't already indexed in
/// the by_cycle bag. Skipped entirely if no file for today.
pub fn reconcile(
  facts_by_key: Table,
  facts_by_cycle: Table,
  facts_dir: String,
  date: String,
  count_lines: fn(String) -> Int,
) -> Nil {
  let disk_path = facts_dir <> "/" <> date <> "-facts.jsonl"
  let disk_count = count_lines(disk_path)

  case disk_count {
    0 -> Nil
    _ -> {
      let disk_facts = facts_log.load_date(facts_dir, date)
      let missing =
        list.filter(disk_facts, fn(f) {
          let cycle_facts = lookup_bag(facts_by_cycle, f.cycle_id)
          let found = list.any(cycle_facts, fn(cf) { cf.fact_id == f.fact_id })
          !found
        })

      case list.length(missing) {
        0 -> Nil
        n -> {
          slog.info(
            "librarian",
            "reconcile",
            "Facts: "
              <> int.to_string(n)
              <> " missing facts for "
              <> date
              <> " — replaying",
            None,
          )
          list.each(missing, fn(f) {
            index_fact(facts_by_key, facts_by_cycle, f)
          })
        }
      }
    }
  }
}
