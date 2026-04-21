//// Artifacts store — ETS cache over `artifacts-YYYY-MM-DD.jsonl` files.
////
//// Keeps only `ArtifactMeta` (metadata) in ETS; large content bodies stay on
//// disk. Two tables: `artifacts` (set, by id) and `artifacts_by_cycle`
//// (bag, keyed by cycle_id). Consumed by the researcher agent's
//// `store_result` / `retrieve_result` tools.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import artifacts/log as artifacts_log
import artifacts/types as artifacts_types
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/order
import gleam/string
import simplifile
import slog

pub type Table

@external(erlang, "store_ffi", "new_unique_table")
pub fn new_table(name: String, table_type: String) -> Table

@external(erlang, "store_ffi", "delete_table")
pub fn delete_table(table: Table) -> Nil

@external(erlang, "store_ffi", "insert")
pub fn insert(
  table: Table,
  key: String,
  value: artifacts_types.ArtifactMeta,
) -> Nil

@external(erlang, "store_ffi", "lookup")
pub fn lookup_one(
  table: Table,
  key: String,
) -> Result(artifacts_types.ArtifactMeta, Nil)

@external(erlang, "store_ffi", "lookup_bag")
pub fn lookup_bag(
  table: Table,
  key: String,
) -> List(artifacts_types.ArtifactMeta)

@external(erlang, "store_ffi", "all_values")
pub fn all_values(table: Table) -> List(artifacts_types.ArtifactMeta)

@external(erlang, "store_ffi", "delete_key")
pub fn delete_key(table: Table, key: String) -> Nil

// ---------------------------------------------------------------------------
// Indexing
// ---------------------------------------------------------------------------

/// Insert an artifact's metadata into both ETS tables. Idempotent.
pub fn index_meta(
  artifacts: Table,
  artifacts_by_cycle: Table,
  meta: artifacts_types.ArtifactMeta,
) -> Nil {
  insert(artifacts, meta.artifact_id, meta)
  insert(artifacts_by_cycle, meta.cycle_id, meta)
}

// ---------------------------------------------------------------------------
// Startup replay
// ---------------------------------------------------------------------------

/// Scan `artifacts_dir` for `artifacts-YYYY-MM-DD.jsonl` files and index
/// every metadata entry. `max_files` caps how many date files are replayed.
pub fn replay_from_disk(
  artifacts: Table,
  artifacts_by_cycle: Table,
  artifacts_dir: String,
  max_files: Int,
) -> Nil {
  case simplifile.read_directory(artifacts_dir) {
    Error(_) -> Nil
    Ok(files) -> {
      let artifact_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.sort(string.compare)

      let limited = limit_files(artifact_files, max_files)

      list.each(limited, fn(f) {
        // File format: artifacts-YYYY-MM-DD.jsonl
        let date =
          f
          |> string.drop_start(10)
          |> string.drop_end(6)
        let metas = artifacts_log.load_date_meta(artifacts_dir, date)
        list.each(metas, fn(m) { index_meta(artifacts, artifacts_by_cycle, m) })
      })
    }
  }
}

// ---------------------------------------------------------------------------
// Reconciliation — ETS vs disk gap repair
// ---------------------------------------------------------------------------

/// Compare today's JSONL line count against ETS, replay any missing metas.
pub fn reconcile(
  artifacts: Table,
  artifacts_by_cycle: Table,
  artifacts_dir: String,
  date: String,
  count_lines: fn(String) -> Int,
) -> Nil {
  let disk_path = artifacts_dir <> "/artifacts-" <> date <> ".jsonl"
  let disk_count = count_lines(disk_path)

  case disk_count {
    0 -> Nil
    _ -> {
      let disk_metas = artifacts_log.load_date_meta(artifacts_dir, date)
      let missing =
        list.filter(disk_metas, fn(m) {
          case lookup_one(artifacts, m.artifact_id) {
            Ok(_) -> False
            Error(_) -> True
          }
        })

      case list.length(missing) {
        0 -> Nil
        n -> {
          slog.info(
            "librarian",
            "reconcile",
            "Artifacts: "
              <> int.to_string(n)
              <> " missing artifacts for "
              <> date
              <> " — replaying",
            None,
          )
          list.each(missing, fn(m) {
            index_meta(artifacts, artifacts_by_cycle, m)
          })
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Trim window
// ---------------------------------------------------------------------------

/// Drop artifacts whose `stored_at` date is strictly before `cutoff_date`.
/// Returns the number of entries deleted. `artifacts_by_cycle` bag entries
/// are orphaned but harmless — the set is the authoritative index.
pub fn trim(artifacts: Table, cutoff_date: String) -> Int {
  let all = all_values(artifacts)
  let old_metas =
    list.filter(all, fn(meta) {
      string.compare(string.slice(meta.stored_at, 0, 10), cutoff_date)
      == order.Lt
    })
  let count = list.length(old_metas)
  list.each(old_metas, fn(meta) { delete_key(artifacts, meta.artifact_id) })
  count
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
