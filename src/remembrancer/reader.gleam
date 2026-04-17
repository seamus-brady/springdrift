//// Remembrancer reader — direct JSONL file access bypassing ETS.
//// Reads the full archive from disk for deep historical queries.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/log as cbr_log
import cbr/types as cbr_types
import facts/log as facts_log
import facts/types as facts_types
import gleam/list
import gleam/order
import gleam/string
import narrative/log as narrative_log
import narrative/types as narrative_types
import simplifile

/// Read all narrative entries from JSONL files in a date range.
pub fn read_narrative_entries(
  narrative_dir: String,
  from_date: String,
  to_date: String,
) -> List(narrative_types.NarrativeEntry) {
  narrative_log.load_entries(narrative_dir, from_date, to_date)
}

/// Read all CBR cases from the cases.jsonl file.
pub fn read_all_cases(cbr_dir: String) -> List(cbr_types.CbrCase) {
  cbr_log.load_all(cbr_dir)
}

/// Read all facts from daily-rotated JSONL files within a date range.
pub fn read_facts(
  facts_dir: String,
  from_date: String,
  to_date: String,
) -> List(facts_types.MemoryFact) {
  facts_log.load_all(facts_dir)
  |> list.filter(fn(f) {
    let date = case string.length(f.timestamp) >= 10 {
      True -> string.slice(f.timestamp, 0, 10)
      False -> f.timestamp
    }
    in_range(date, from_date, to_date)
  })
}

/// Count total narrative entries across all files in a date range.
pub fn count_entries(
  narrative_dir: String,
  from_date: String,
  to_date: String,
) -> Int {
  list.length(read_narrative_entries(narrative_dir, from_date, to_date))
}

/// Find the oldest entry date in the narrative directory.
pub fn oldest_entry_date(narrative_dir: String) -> String {
  let files = list_jsonl_files(narrative_dir)
  case list.sort(files, string.compare) {
    [first, ..] -> extract_date(first)
    [] -> ""
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn in_range(date: String, from: String, to: String) -> Bool {
  case string.compare(date, from), string.compare(date, to) {
    order.Lt, _ -> False
    _, order.Gt -> False
    _, _ -> True
  }
}

fn list_jsonl_files(dir: String) -> List(String) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) ->
      files
      |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
      |> list.sort(string.compare)
  }
}

fn extract_date(filename: String) -> String {
  let without_ext = string.replace(filename, ".jsonl", "")
  case string.length(without_ext) >= 10 {
    True -> string.slice(without_ext, 0, 10)
    False -> without_ext
  }
}
