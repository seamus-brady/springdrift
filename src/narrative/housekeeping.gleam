//// Housekeeping — periodic maintenance for CBR cases and facts.
////
//// Pure functions that identify cases for deduplication, pruning, and
//// conflict resolution. The Curator calls these and then applies the
//// results via the Librarian.
////
//// Operations:
////   1. CBR deduplication: cosine similarity > 0.92 → merge (supersede older)
////   2. CBR pruning: failure + confidence < 0.3 + age > 60 days + no pitfalls → remove
////   3. Fact conflict resolution: same key, different values → supersede lower confidence

import cbr/types as cbr_types
import facts/types as facts_types
import gleam/float
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string

// ---------------------------------------------------------------------------
// CBR deduplication — cosine similarity > threshold
// ---------------------------------------------------------------------------

/// A dedup decision: the newer case supersedes the older one.
pub type DedupResult {
  DedupResult(keep_id: String, supersede_id: String, similarity: Float)
}

/// Find pairs of CBR cases with cosine similarity > threshold on their
/// embeddings. Returns a list of DedupResult where the older (by timestamp)
/// case should be superseded.
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
    case case_a.embedding, case_b.embedding {
      [], _ -> Error(Nil)
      _, [] -> Error(Nil)
      emb_a, emb_b -> {
        let sim = cosine_similarity(emb_a, emb_b)
        case sim >. threshold {
          True -> {
            // Keep the newer one (later timestamp), supersede the older
            let #(keep, supersede) = case
              string.compare(case_a.timestamp, case_b.timestamp)
            {
              order.Lt -> #(case_b.case_id, case_a.case_id)
              _ -> #(case_a.case_id, case_b.case_id)
            }
            Ok(DedupResult(
              keep_id: keep,
              supersede_id: supersede,
              similarity: sim,
            ))
          }
          False -> Error(Nil)
        }
      }
    }
  })
}

/// Cosine similarity between two float vectors.
pub fn cosine_similarity(a: List(Float), b: List(Float)) -> Float {
  let #(dot, mag_a, mag_b) = dot_and_magnitudes(a, b, 0.0, 0.0, 0.0)
  let denominator = float_sqrt(mag_a) *. float_sqrt(mag_b)
  case denominator >. 0.0 {
    True -> dot /. denominator
    False -> 0.0
  }
}

fn dot_and_magnitudes(
  a: List(Float),
  b: List(Float),
  dot: Float,
  mag_a: Float,
  mag_b: Float,
) -> #(Float, Float, Float) {
  case a, b {
    [], _ -> #(dot, mag_a, mag_b)
    _, [] -> #(dot, mag_a, mag_b)
    [x, ..rest_a], [y, ..rest_b] ->
      dot_and_magnitudes(
        rest_a,
        rest_b,
        dot +. { x *. y },
        mag_a +. { x *. x },
        mag_b +. { y *. y },
      )
  }
}

@external(erlang, "math", "sqrt")
fn float_sqrt(x: Float) -> Float

// ---------------------------------------------------------------------------
// CBR pruning — old failures without pitfalls
// ---------------------------------------------------------------------------

/// A pruning decision: the case should be removed.
pub type PruneResult {
  PruneResult(case_id: String, reason: String)
}

/// Find CBR cases eligible for pruning:
/// - outcome.status == "failure"
/// - confidence < 0.3
/// - timestamp older than cutoff_date (YYYY-MM-DD string comparison)
/// - empty pitfalls list
pub fn find_prunable_cases(
  cases: List(cbr_types.CbrCase),
  cutoff_date: String,
) -> List(PruneResult) {
  list.filter_map(cases, fn(c) {
    let is_failure = c.outcome.status == "failure"
    let is_low_confidence = c.outcome.confidence <. 0.3
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
// Housekeeping report
// ---------------------------------------------------------------------------

/// Summary of a housekeeping pass.
pub type HousekeepingReport {
  HousekeepingReport(
    cases_deduplicated: Int,
    cases_pruned: Int,
    facts_resolved: Int,
  )
}

/// Create an empty report (nothing done).
pub fn empty_report() -> HousekeepingReport {
  HousekeepingReport(cases_deduplicated: 0, cases_pruned: 0, facts_resolved: 0)
}

/// Format a report for logging.
pub fn format_report(report: HousekeepingReport) -> String {
  "Housekeeping: "
  <> string.inspect(report.cases_deduplicated)
  <> " cases deduplicated, "
  <> string.inspect(report.cases_pruned)
  <> " cases pruned, "
  <> string.inspect(report.facts_resolved)
  <> " fact conflicts resolved"
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
