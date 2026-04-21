//// Narrative store — Prime Narrative entries + five ETS indexes.
////
//// Tables:
////   - entries     (set)          — cycle_id  → NarrativeEntry
////   - by_thread   (bag)          — thread_id → NarrativeEntry
////   - by_date     (bag)          — YYYY-MM-DD → NarrativeEntry
////   - by_keyword  (bag)          — keyword (lowercased) → NarrativeEntry
////   - by_recency  (ordered_set)  — timestamp → NarrativeEntry
////
//// `entries` is the authoritative primary table. The bag tables are
//// populated on index and queries tolerate their duplication.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import narrative/log as narrative_log
import narrative/types.{type NarrativeEntry}
import simplifile
import slog

pub type Table

@external(erlang, "store_ffi", "new_unique_table")
pub fn new_table(name: String, table_type: String) -> Table

@external(erlang, "store_ffi", "insert")
pub fn insert(table: Table, key: String, value: NarrativeEntry) -> Nil

@external(erlang, "store_ffi", "lookup")
pub fn lookup(table: Table, key: String) -> Result(NarrativeEntry, Nil)

@external(erlang, "store_ffi", "lookup_bag")
pub fn lookup_bag(table: Table, key: String) -> List(NarrativeEntry)

@external(erlang, "store_ffi", "all_values")
pub fn all_values(table: Table) -> List(NarrativeEntry)

@external(erlang, "store_ffi", "last_n")
pub fn last_n(table: Table, n: Int) -> List(NarrativeEntry)

@external(erlang, "store_ffi", "delete_table")
pub fn delete_table(table: Table) -> Nil

@external(erlang, "store_ffi", "table_size")
pub fn table_size(table: Table) -> Int

@external(erlang, "store_ffi", "delete_key")
pub fn delete_key(table: Table, key: String) -> Nil

@external(erlang, "store_ffi", "delete_object")
pub fn delete_object(table: Table, object: #(String, NarrativeEntry)) -> Nil

// ---------------------------------------------------------------------------
// Indexing
// ---------------------------------------------------------------------------

/// Index a single entry across all five tables. The primary set uses
/// cycle_id; bag tables fan out to thread, date, keyword, and recency.
pub fn index_entry(
  entries: Table,
  by_thread: Table,
  by_date: Table,
  by_keyword: Table,
  by_recency: Table,
  entry: NarrativeEntry,
) -> Nil {
  insert(entries, entry.cycle_id, entry)

  case entry.thread {
    Some(t) -> insert(by_thread, t.thread_id, entry)
    None -> Nil
  }

  let date = extract_date(entry.timestamp)
  insert(by_date, date, entry)

  list.each(entry.keywords, fn(kw) {
    insert(by_keyword, string.lowercase(kw), entry)
  })

  list.each(entry.topics, fn(topic) {
    let lower_topic = string.lowercase(topic)
    insert(by_keyword, lower_topic, entry)
    string.split(lower_topic, " ")
    |> list.filter(fn(w) { string.length(w) > 2 })
    |> list.each(fn(word) { insert(by_keyword, word, entry) })
  })

  insert(by_recency, entry.timestamp, entry)
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/// Extract the `YYYY-MM-DD` prefix from an ISO timestamp, or return the
/// timestamp unchanged if there's no 'T' separator.
pub fn extract_date(timestamp: String) -> String {
  case string.split(timestamp, "T") {
    [date, ..] -> date
    _ -> timestamp
  }
}

/// Date-range query via the by_date bag index — avoids full scans.
/// `date_range_fn` produces "YYYY-MM-DD" strings from `from` to `to`
/// inclusive (owner supplies the date arithmetic — see
/// `springdrift_ffi:days_between/add_days`).
pub fn query_date_range(
  by_date: Table,
  from: String,
  to: String,
  date_range_fn: fn(String, String) -> List(String),
) -> List(NarrativeEntry) {
  let dates = date_range_fn(from, to)
  list.flat_map(dates, fn(date) { lookup_bag(by_date, date) })
  |> list.sort(fn(a, b) { string.compare(a.timestamp, b.timestamp) })
}

/// Keyword search — combines by_keyword bag lookup (structured index)
/// with a full-scan substring match over summaries/topics, deduplicated
/// by cycle_id.
pub fn search(
  entries: Table,
  by_keyword: Table,
  keyword: String,
) -> List(NarrativeEntry) {
  let lower = string.lowercase(keyword)
  let by_kw = lookup_bag(by_keyword, lower)
  let all = all_values(entries)
  let by_text =
    list.filter(all, fn(entry) {
      string.contains(string.lowercase(entry.summary), lower)
      || list.any(entry.topics, fn(t) {
        string.contains(string.lowercase(t), lower)
      })
    })
  merge_unique_entries(by_kw, by_text)
}

fn merge_unique_entries(
  a: List(NarrativeEntry),
  b: List(NarrativeEntry),
) -> List(NarrativeEntry) {
  let id_set =
    list.fold(a, dict.new(), fn(d, e) { dict.insert(d, e.cycle_id, Nil) })
  let unique_b = list.filter(b, fn(e) { !dict.has_key(id_set, e.cycle_id) })
  list.append(a, unique_b)
}

// ---------------------------------------------------------------------------
// Startup replay
// ---------------------------------------------------------------------------

/// Scan `narrative_dir` for daily JSONL files and index every entry.
/// `max_files` caps how many date files are replayed (0 = all).
pub fn replay_from_disk(
  entries: Table,
  by_thread: Table,
  by_date: Table,
  by_keyword: Table,
  by_recency: Table,
  narrative_dir: String,
  max_files: Int,
) -> Nil {
  case simplifile.read_directory(narrative_dir) {
    Error(_) -> Nil
    Ok(files) -> {
      let jsonl_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.sort(string.compare)

      let limited = limit_files(jsonl_files, max_files)

      list.each(limited, fn(f) {
        let date = string.drop_end(f, 6)
        let entries_list = narrative_log.load_date(narrative_dir, date)
        list.each(entries_list, fn(entry) {
          index_entry(
            entries,
            by_thread,
            by_date,
            by_keyword,
            by_recency,
            entry,
          )
        })
      })
    }
  }
}

// ---------------------------------------------------------------------------
// Reconciliation — ETS vs disk gap repair
// ---------------------------------------------------------------------------

/// Compare by_date bag count vs JSONL line count for `date`. If disk has
/// more entries, replay the full day — `index_entry` uses set semantics
/// on the primary table so duplicates are harmless, and bag tables may
/// get duplicates but queries deduplicate by cycle_id.
pub fn reconcile(
  entries: Table,
  by_thread: Table,
  by_date: Table,
  by_keyword: Table,
  by_recency: Table,
  narrative_dir: String,
  date: String,
  count_lines: fn(String) -> Int,
) -> Nil {
  let ets_count = list.length(lookup_bag(by_date, date))
  let disk_path = narrative_dir <> "/" <> date <> ".jsonl"
  let disk_count = count_lines(disk_path)

  case disk_count > ets_count {
    False -> Nil
    True -> {
      let diff = disk_count - ets_count
      slog.info(
        "librarian",
        "reconcile",
        "Narrative: "
          <> int.to_string(diff)
          <> " missing entries for "
          <> date
          <> " — replaying from disk",
        None,
      )
      let entries_list = narrative_log.load_date(narrative_dir, date)
      list.each(entries_list, fn(entry) {
        index_entry(entries, by_thread, by_date, by_keyword, by_recency, entry)
      })
    }
  }
}

// ---------------------------------------------------------------------------
// Trim window — evict old entries across all five tables
// ---------------------------------------------------------------------------

/// Drop entries older than `cutoff_date`. Primary set + by_recency are
/// key-deleted; bag tables need per-object deletion. Returns the count of
/// entries removed from the primary set.
pub fn trim(
  entries: Table,
  by_thread: Table,
  by_date: Table,
  by_keyword: Table,
  by_recency: Table,
  cutoff_date: String,
) -> Int {
  let all = all_values(entries)
  let old_entries =
    list.filter(all, fn(entry) {
      string.compare(extract_date(entry.timestamp), cutoff_date) == order.Lt
    })
  let count = list.length(old_entries)

  list.each(old_entries, fn(entry) {
    delete_key(entries, entry.cycle_id)
    delete_key(by_recency, entry.timestamp)
  })

  list.each(old_entries, fn(entry) {
    let date = extract_date(entry.timestamp)
    delete_object(by_date, #(date, entry))
    case entry.thread {
      Some(t) -> delete_object(by_thread, #(t.thread_id, entry))
      None -> Nil
    }
    list.each(entry.keywords, fn(kw) {
      delete_object(by_keyword, #(string.lowercase(kw), entry))
    })
    list.each(entry.topics, fn(topic) {
      let lower_topic = string.lowercase(topic)
      delete_object(by_keyword, #(lower_topic, entry))
      string.split(lower_topic, " ")
      |> list.filter(fn(w) { string.length(w) > 2 })
      |> list.each(fn(word) { delete_object(by_keyword, #(word, entry)) })
    })
  })
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
