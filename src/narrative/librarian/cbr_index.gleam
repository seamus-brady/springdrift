//// CBR store — problem/solution/outcome cases for case-based reasoning.
////
//// The ETS table (`cbr_cases`, set, keyed by case_id) holds metadata. Retrieval
//// is handled by the `bridge.CaseBase` which owns an inverted index plus
//// optional embeddings — the loop threads the CaseBase through state
//// alongside the ETS cache, and this module provides helpers that return
//// updated CaseBase values for the loop to rebind.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/bridge
import cbr/log as cbr_log
import cbr/types as cbr_types
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import simplifile
import slog

pub type Table

@external(erlang, "store_ffi", "new_unique_table")
pub fn new_table(name: String, table_type: String) -> Table

@external(erlang, "store_ffi", "delete_table")
pub fn delete_table(table: Table) -> Nil

@external(erlang, "store_ffi", "table_size")
pub fn table_size(table: Table) -> Int

@external(erlang, "store_ffi", "insert")
pub fn insert(table: Table, key: String, value: cbr_types.CbrCase) -> Nil

@external(erlang, "store_ffi", "lookup")
pub fn lookup(table: Table, key: String) -> Result(cbr_types.CbrCase, Nil)

@external(erlang, "store_ffi", "all_values")
pub fn all_values(table: Table) -> List(cbr_types.CbrCase)

@external(erlang, "store_ffi", "delete_key")
pub fn delete_key(table: Table, key: String) -> Nil

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/// Build a metadata dict from the cbr_cases ETS table for bridge lookups.
/// Suppressed cases are excluded — retrieval should never surface them.
pub fn build_metadata(cbr_cases: Table) -> dict.Dict(String, cbr_types.CbrCase) {
  let all_cases = all_values(cbr_cases)
  list.fold(all_cases, dict.new(), fn(d, c) {
    case c.outcome.status {
      "suppressed" -> d
      _ -> dict.insert(d, c.case_id, c)
    }
  })
}

// ---------------------------------------------------------------------------
// Startup replay
// ---------------------------------------------------------------------------

/// Load all CBR cases from disk within `max_files`, index metadata in ETS,
/// add each case to the CaseBase, and rebuild the inverted index.
/// Returns the updated CaseBase so the loop can rebind state.
pub fn replay_from_disk(
  cbr_cases: Table,
  case_base: bridge.CaseBase,
  cbr_dir: String,
  max_files: Int,
) -> bridge.CaseBase {
  case simplifile.read_directory(cbr_dir) {
    Error(_) -> case_base
    Ok(files) -> {
      let jsonl_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.sort(string.compare)

      let limited = limit_files(jsonl_files, max_files)

      let all_cases =
        list.flat_map(limited, fn(f) {
          let date = string.drop_end(f, 6)
          cbr_log.load_date(cbr_dir, date)
        })

      list.each(all_cases, fn(c) { insert(cbr_cases, c.case_id, c) })

      let case_base =
        list.fold(all_cases, case_base, fn(base, c) {
          bridge.retain_case(base, c)
        })
      bridge.rebuild_index(case_base, all_cases)
    }
  }
}

// ---------------------------------------------------------------------------
// Reconciliation — ETS vs disk gap repair
// ---------------------------------------------------------------------------

/// Replay any cases missing from ETS for today's JSONL. Returns the updated
/// CaseBase; if nothing is missing, returns the input CaseBase unchanged.
pub fn reconcile(
  cbr_cases: Table,
  case_base: bridge.CaseBase,
  cbr_dir: String,
  date: String,
  count_lines: fn(String) -> Int,
) -> bridge.CaseBase {
  let disk_path = cbr_dir <> "/" <> date <> ".jsonl"
  let disk_count = count_lines(disk_path)

  case disk_count {
    0 -> case_base
    _ -> {
      let disk_cases = cbr_log.load_date(cbr_dir, date)
      let missing =
        list.filter(disk_cases, fn(c) {
          case lookup(cbr_cases, c.case_id) {
            Ok(_) -> False
            Error(_) -> True
          }
        })

      case list.length(missing) {
        0 -> case_base
        n -> {
          slog.info(
            "librarian",
            "reconcile",
            "CBR: "
              <> int.to_string(n)
              <> " missing cases for "
              <> date
              <> " — replaying",
            None,
          )
          list.each(missing, fn(c) { insert(cbr_cases, c.case_id, c) })
          let case_base =
            list.fold(missing, case_base, fn(base, c) {
              bridge.retain_case(base, c)
            })
          bridge.rebuild_index(case_base, all_values(cbr_cases))
        }
      }
    }
  }
}

fn limit_files(files: List(String), max_files: Int) -> List(String) {
  case max_files > 0 {
    True -> {
      let len = list.length(files)
      case len > max_files {
        True -> list.drop(files, len - max_files)
        False -> files
      }
    }
    False -> files
  }
}
