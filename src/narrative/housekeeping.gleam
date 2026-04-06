//// Housekeeping — periodic maintenance for CBR cases, facts, and threads.
////
//// Pure functions that identify items for deduplication, pruning, and
//// conflict resolution. The Curator calls these and then applies the
//// results via the Librarian.
////
//// Operations:
////   1. CBR deduplication: field similarity > 0.92 → merge (supersede older)
////   2. CBR pruning: failure + confidence < 0.3 + age > 60 days + no pitfalls → remove
////   3. Fact conflict resolution: same key, different values → supersede lower confidence
////   4. Thread pruning: single-cycle threads older than cutoff → remove from index

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/bridge
import cbr/types as cbr_types
import facts/types as facts_types
import gleam/float
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import narrative/types as narrative_types

// ---------------------------------------------------------------------------
// CBR deduplication — field similarity > threshold
// ---------------------------------------------------------------------------

/// A dedup decision: the newer case supersedes the older one.
pub type DedupResult {
  DedupResult(keep_id: String, supersede_id: String, similarity: Float)
}

/// Find pairs of CBR cases with field similarity > threshold.
/// Uses deterministic weighted field scoring.
/// Returns a list of DedupResult where the older (by timestamp) case should be superseded.
pub fn find_duplicate_cases(
  cases: List(cbr_types.CbrCase),
  threshold: Float,
) -> List(DedupResult) {
  do_find_duplicates(cases, threshold, [])
}

fn do_find_duplicates(
  cases: List(cbr_types.CbrCase),
  threshold: Float,
  acc: List(DedupResult),
) -> List(DedupResult) {
  case cases {
    [] -> acc
    [first, ..rest] -> {
      let new_results = compare_against_rest(first, rest, threshold)
      do_find_duplicates(rest, threshold, list.append(acc, new_results))
    }
  }
}

fn compare_against_rest(
  case_a: cbr_types.CbrCase,
  others: List(cbr_types.CbrCase),
  threshold: Float,
) -> List(DedupResult) {
  list.filter_map(others, fn(case_b) {
    let sim = bridge.case_similarity(case_a, case_b)
    case sim >=. threshold {
      True -> {
        let #(keep, supersede) = case
          string.compare(case_a.timestamp, case_b.timestamp)
        {
          order.Lt -> #(case_b.case_id, case_a.case_id)
          _ -> #(case_a.case_id, case_b.case_id)
        }
        Ok(DedupResult(keep_id: keep, supersede_id: supersede, similarity: sim))
      }
      False -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// CBR pruning — old failures without pitfalls
// ---------------------------------------------------------------------------

/// A pruning decision: the case should be removed.
pub type PruneResult {
  PruneResult(case_id: String, reason: String)
}

/// Find CBR cases eligible for pruning:
/// - outcome.status == "failure"
/// - confidence < pruning_confidence threshold
/// - timestamp older than cutoff_date (YYYY-MM-DD string comparison)
/// - empty pitfalls list
pub fn find_prunable_cases(
  cases: List(cbr_types.CbrCase),
  cutoff_date: String,
  pruning_confidence: Float,
) -> List(PruneResult) {
  list.filter_map(cases, fn(c) {
    let is_failure = c.outcome.status == "failure"
    let is_low_confidence = c.outcome.confidence <. pruning_confidence
    let is_old =
      string.compare(extract_date(c.timestamp), cutoff_date) == order.Lt
    let has_no_pitfalls = list.is_empty(c.outcome.pitfalls)
    case is_failure && is_low_confidence && is_old && has_no_pitfalls {
      True ->
        Ok(PruneResult(
          case_id: c.case_id,
          reason: "failure, low confidence ("
            <> float.to_string(c.outcome.confidence)
            <> "), old, no pitfalls",
        ))
      False -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// CBR usage-based deprecation — harmful cases
// ---------------------------------------------------------------------------

/// Find CBR cases that usage stats indicate are harmful:
/// - harmful_count > helpful_count * 2
/// - retrieval_count > 5 (enough data to be confident)
/// These are candidates for confidence reduction (deprecation).
pub fn find_harmful_cases(cases: List(cbr_types.CbrCase)) -> List(PruneResult) {
  list.filter_map(cases, fn(c) {
    case c.usage_stats {
      option.None -> Error(Nil)
      option.Some(stats) -> {
        let enough_data = stats.retrieval_count > 5
        let is_harmful = stats.harmful_count > stats.helpful_count * 2
        case enough_data && is_harmful {
          True ->
            Ok(PruneResult(
              case_id: c.case_id,
              reason: "harmful: "
                <> string.inspect(stats.harmful_count)
                <> " harmful vs "
                <> string.inspect(stats.helpful_count)
                <> " helpful over "
                <> string.inspect(stats.retrieval_count)
                <> " retrievals",
            ))
          False -> Error(Nil)
        }
      }
    }
  })
}

// ---------------------------------------------------------------------------
// Fact conflict resolution
// ---------------------------------------------------------------------------

/// A conflict resolution: supersede the lower-confidence fact.
pub type ConflictResult {
  ConflictResult(key: String, keep_fact_id: String, supersede_fact_id: String)
}

/// Find conflicting facts: multiple Write-operation entries for the same key
/// with different values. The lower-confidence one gets superseded.
/// Input should be the full list of current (non-superseded) facts.
pub fn find_fact_conflicts(
  facts: List(facts_types.MemoryFact),
) -> List(ConflictResult) {
  // Group by key — only look at Write operations
  let write_facts =
    list.filter(facts, fn(f) { f.operation == facts_types.Write })
  do_find_conflicts(write_facts, [])
}

fn do_find_conflicts(
  facts: List(facts_types.MemoryFact),
  acc: List(ConflictResult),
) -> List(ConflictResult) {
  case facts {
    [] -> acc
    [first, ..rest] -> {
      // Find any later fact with the same key but different value
      let conflicts =
        list.filter_map(rest, fn(other) {
          case first.key == other.key && first.value != other.value {
            True -> {
              // Keep the higher confidence one
              let #(keep, supersede) = case
                first.confidence >=. other.confidence
              {
                True -> #(first.fact_id, other.fact_id)
                False -> #(other.fact_id, first.fact_id)
              }
              Ok(ConflictResult(
                key: first.key,
                keep_fact_id: keep,
                supersede_fact_id: supersede,
              ))
            }
            False -> Error(Nil)
          }
        })
      do_find_conflicts(rest, list.append(acc, conflicts))
    }
  }
}

// ---------------------------------------------------------------------------
// Thread pruning — single-cycle old threads
// ---------------------------------------------------------------------------

/// A thread pruning decision: the thread should be removed from the index.
pub type ThreadPruneResult {
  ThreadPruneResult(thread_id: String, thread_name: String, reason: String)
}

/// Find threads eligible for pruning:
/// - cycle_count == 1 (never revisited)
/// - last_cycle_at older than cutoff_date
/// - empty keywords, domains, and topics (no useful signal)
///   OR thread_name starts with "Thread " (UUID-pattern fallback name)
pub fn find_prunable_threads(
  threads: List(narrative_types.ThreadState),
  cutoff_date: String,
) -> List(ThreadPruneResult) {
  list.filter_map(threads, fn(ts) {
    let is_single = ts.cycle_count <= 1
    let is_old =
      string.compare(extract_date(ts.last_cycle_at), cutoff_date) == order.Lt
    let is_uuid_name = string.starts_with(ts.thread_name, "Thread ")
    let is_empty_signal =
      list.is_empty(ts.keywords)
      && list.is_empty(ts.domains)
      && list.is_empty(ts.topics)
    case is_single && is_old && { is_uuid_name || is_empty_signal } {
      True ->
        Ok(ThreadPruneResult(
          thread_id: ts.thread_id,
          thread_name: ts.thread_name,
          reason: "single-cycle, old, no signal",
        ))
      False -> Error(Nil)
    }
  })
}

/// Apply thread pruning results to a thread index, returning the cleaned index.
pub fn apply_thread_pruning(
  index: narrative_types.ThreadIndex,
  results: List(ThreadPruneResult),
) -> narrative_types.ThreadIndex {
  let prune_ids = list.map(results, fn(r) { r.thread_id })
  narrative_types.ThreadIndex(
    threads: list.filter(index.threads, fn(ts) {
      !list.contains(prune_ids, ts.thread_id)
    }),
  )
}

// ---------------------------------------------------------------------------
// Housekeeping report
// ---------------------------------------------------------------------------

/// Summary of a housekeeping pass.
pub type HousekeepingReport {
  HousekeepingReport(
    cases_deduplicated: Int,
    cases_pruned: Int,
    facts_resolved: Int,
    threads_pruned: Int,
  )
}

/// Create an empty report (nothing done).
pub fn empty_report() -> HousekeepingReport {
  HousekeepingReport(
    cases_deduplicated: 0,
    cases_pruned: 0,
    facts_resolved: 0,
    threads_pruned: 0,
  )
}

/// Format a report for logging.
pub fn format_report(report: HousekeepingReport) -> String {
  "Housekeeping: "
  <> string.inspect(report.cases_deduplicated)
  <> " cases deduplicated, "
  <> string.inspect(report.cases_pruned)
  <> " cases pruned, "
  <> string.inspect(report.facts_resolved)
  <> " fact conflicts resolved, "
  <> string.inspect(report.threads_pruned)
  <> " threads pruned"
}

// ---------------------------------------------------------------------------
// Superseded record builders
// ---------------------------------------------------------------------------

/// Build a MemoryFact Superseded record for conflict resolution.
pub fn make_superseded_fact(
  original: facts_types.MemoryFact,
  superseded_by_id: String,
  cycle_id: String,
  timestamp: String,
) -> facts_types.MemoryFact {
  facts_types.MemoryFact(
    schema_version: 1,
    fact_id: original.fact_id <> "_superseded",
    timestamp:,
    cycle_id:,
    agent_id: None,
    key: original.key,
    value: original.value,
    scope: original.scope,
    operation: facts_types.Superseded,
    supersedes: Some(superseded_by_id),
    confidence: original.confidence,
    source: "housekeeping",
    provenance: None,
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn extract_date(timestamp: String) -> String {
  case string.split(timestamp, "T") {
    [date, ..] -> date
    _ -> timestamp
  }
}
