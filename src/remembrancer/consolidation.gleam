//// Consolidation records — append-only JSONL log of Remembrancer runs.
//// Each entry captures what happened when the Remembrancer consolidated
//// a period of memory: findings, patterns, facts restored, threads resurrected.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/string
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type ConsolidationRun {
  ConsolidationRun(
    run_id: String,
    timestamp: String,
    from_date: String,
    to_date: String,
    entries_reviewed: Int,
    cases_reviewed: Int,
    facts_reviewed: Int,
    patterns_found: Int,
    facts_restored: Int,
    threads_resurrected: Int,
    report_path: String,
    summary: String,
  )
}

// ---------------------------------------------------------------------------
// JSONL log
// ---------------------------------------------------------------------------

/// Append a ConsolidationRun to the dated JSONL log.
pub fn append(dir: String, run: ConsolidationRun) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> "-consolidation.jsonl"
  let json_str = json.to_string(encode_run(run))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) -> Nil
    Error(e) ->
      slog.log_error(
        "remembrancer/consolidation",
        "append",
        "Failed to append run: " <> simplifile.describe_error(e),
        option_some(run.run_id),
      )
  }
}

/// Load all consolidation runs across all dated files.
pub fn load_all(dir: String) -> List(ConsolidationRun) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) ->
      files
      |> list.filter(fn(f) { string.ends_with(f, "-consolidation.jsonl") })
      |> list.sort(string.compare)
      |> list.flat_map(fn(f) { load_file(dir <> "/" <> f) })
  }
}

fn load_file(path: String) -> List(ConsolidationRun) {
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) ->
      string.split(content, "\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.filter_map(fn(line) { json.parse(line, run_decoder()) })
  }
}

/// Find the most recent consolidation run (if any).
pub fn last_run(dir: String) -> Result(ConsolidationRun, Nil) {
  case list.reverse(load_all(dir)) {
    [latest, ..] -> Ok(latest)
    [] -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Markdown report
// ---------------------------------------------------------------------------

/// Write a markdown consolidation report to the knowledge consolidation dir.
/// Returns the full path.
pub fn write_report(
  knowledge_dir: String,
  report_name: String,
  body: String,
) -> Result(String, String) {
  let _ = simplifile.create_directory_all(knowledge_dir)
  let date = get_date()
  let filename = date <> "-" <> slugify(report_name) <> ".md"
  let path = knowledge_dir <> "/" <> filename
  case simplifile.write(path, body) {
    Ok(_) -> Ok(path)
    Error(e) -> Error(simplifile.describe_error(e))
  }
}

fn slugify(s: String) -> String {
  string.lowercase(s)
  |> string.replace(" ", "-")
  |> string.replace("/", "-")
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub fn new_run(
  from_date: String,
  to_date: String,
  summary: String,
) -> ConsolidationRun {
  ConsolidationRun(
    run_id: "consolidation-" <> get_datetime(),
    timestamp: get_datetime(),
    from_date:,
    to_date:,
    entries_reviewed: 0,
    cases_reviewed: 0,
    facts_reviewed: 0,
    patterns_found: 0,
    facts_restored: 0,
    threads_resurrected: 0,
    report_path: "",
    summary:,
  )
}

fn option_some(s: String) -> Option(String) {
  Some(s)
}

// ---------------------------------------------------------------------------
// JSON encode / decode
// ---------------------------------------------------------------------------

pub fn encode_run(run: ConsolidationRun) -> json.Json {
  json.object([
    #("run_id", json.string(run.run_id)),
    #("timestamp", json.string(run.timestamp)),
    #("from_date", json.string(run.from_date)),
    #("to_date", json.string(run.to_date)),
    #("entries_reviewed", json.int(run.entries_reviewed)),
    #("cases_reviewed", json.int(run.cases_reviewed)),
    #("facts_reviewed", json.int(run.facts_reviewed)),
    #("patterns_found", json.int(run.patterns_found)),
    #("facts_restored", json.int(run.facts_restored)),
    #("threads_resurrected", json.int(run.threads_resurrected)),
    #("report_path", json.string(run.report_path)),
    #("summary", json.string(run.summary)),
  ])
}

pub fn run_decoder() -> decode.Decoder(ConsolidationRun) {
  use run_id <- decode.field("run_id", decode.string)
  use timestamp <- decode.field("timestamp", decode.string)
  use from_date <- decode.field("from_date", decode.string)
  use to_date <- decode.field("to_date", decode.string)
  use entries_reviewed <- decode.field("entries_reviewed", decode.int)
  use cases_reviewed <- decode.field("cases_reviewed", decode.int)
  use facts_reviewed <- decode.field("facts_reviewed", decode.int)
  use patterns_found <- decode.field("patterns_found", decode.int)
  use facts_restored <- decode.field("facts_restored", decode.int)
  use threads_resurrected <- decode.field("threads_resurrected", decode.int)
  use report_path <- decode.field("report_path", decode.string)
  use summary <- decode.field("summary", decode.string)
  decode.success(ConsolidationRun(
    run_id:,
    timestamp:,
    from_date:,
    to_date:,
    entries_reviewed:,
    cases_reviewed:,
    facts_reviewed:,
    patterns_found:,
    facts_restored:,
    threads_resurrected:,
    report_path:,
    summary:,
  ))
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

pub fn format_run(run: ConsolidationRun) -> String {
  "Consolidation "
  <> run.from_date
  <> " → "
  <> run.to_date
  <> ": "
  <> int.to_string(run.entries_reviewed)
  <> " entries, "
  <> int.to_string(run.cases_reviewed)
  <> " cases, "
  <> int.to_string(run.patterns_found)
  <> " patterns, "
  <> int.to_string(run.facts_restored)
  <> " facts restored, "
  <> int.to_string(run.threads_resurrected)
  <> " threads resurrected"
}
