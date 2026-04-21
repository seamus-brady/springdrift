//// Fabrication audit — deterministic cross-reference of persisted facts
//// against the cycle-log tool-call record.
////
//// Phase 2 of the fluency/grounding separation spec. Runs inside the
//// meta-cognition layer (as a Remembrancer tool invoked on a schedule)
//// rather than as an external operator script. Produces an integrity
//// signal the agent perceives about itself via the sensorium.
////
//// The logic: every Synthesis-derivation fact written in the window is
//// a claim about work the agent did. If the fact's value contains
//// language pattern-matching a specific kind of work (correlation
//// analysis, pattern mining, consolidation), the corresponding tool
//// must appear in the source cycle's tool-call list. When it does not,
//// the fact is suspect — prose laundered as durable memory.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cycle_log
import facts/types as facts_types
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/regexp
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Pattern that associates a prose claim with the tool that should have
/// fired to produce it. When the pattern matches a fact's text but the
/// tool did not appear in the source cycle's tool_successes, the fact
/// is flagged as suspect.
pub type ClaimPattern {
  ClaimPattern(
    /// Short identifier for the pattern (for logging/reporting).
    id: String,
    /// Regex matched against fact key + value.
    pattern: String,
    /// Tool that must be in the source cycle's tool log when the pattern fires.
    expected_tool: String,
    /// Human-readable summary used in the suspect-fact reason.
    description: String,
  )
}

/// A fact that failed the claim-vs-tool-call check, with reasons.
pub type SuspectFact {
  SuspectFact(
    fact_id: String,
    key: String,
    cycle_id: String,
    reasons: List(String),
  )
}

/// Summary of an audit run.
pub type AuditResult {
  AuditResult(
    from_date: String,
    to_date: String,
    facts_examined: Int,
    suspect_facts: List(SuspectFact),
  )
}

// ---------------------------------------------------------------------------
// Default patterns
// ---------------------------------------------------------------------------

/// The baseline set of claim → tool associations. These are the patterns
/// that fire most often in observed fabrications. Operators can extend
/// or replace via config.
pub fn default_patterns() -> List(ClaimPattern) {
  [
    ClaimPattern(
      id: "correlation_analysis",
      pattern: "(?i)\\b(pearson|correlation[s]?)\\b|\\br\\s*[=≈]\\s*-?[0-9]",
      expected_tool: "analyze_affect_performance",
      description: "claims correlation analysis",
    ),
    ClaimPattern(
      id: "affect_performance",
      pattern: "(?i)\\baffect[- ]performance\\b",
      expected_tool: "analyze_affect_performance",
      description: "claims affect-performance analysis",
    ),
    ClaimPattern(
      id: "pattern_mining",
      pattern: "(?i)\\bmined [a-z ]+ patterns?\\b|\\bpattern mining\\b",
      expected_tool: "mine_patterns",
      description: "claims pattern mining",
    ),
    ClaimPattern(
      id: "consolidation_report",
      pattern: "(?i)\\bconsolidat\\w+ report\\b|\\bconsolidation run\\b",
      expected_tool: "write_consolidation_report",
      description: "claims consolidation report",
    ),
    ClaimPattern(
      id: "deep_search",
      pattern: "(?i)\\bdeep search\\b|\\bsearched \\w+ archive\\b",
      expected_tool: "deep_search",
      description: "claims deep-archive search",
    ),
  ]
}

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------

/// Run the audit against a list of facts and cycle-log data. Pure function.
///
/// `facts`: the facts to examine (typically Synthesis writes in the window).
/// `cycles_by_id`: tool-call info keyed by cycle_id. Construct via
/// `build_cycle_index`.
/// `patterns`: claim-tool associations to check. Use `default_patterns()`
/// or an operator-supplied list.
pub fn audit(
  facts: List(facts_types.MemoryFact),
  cycles_by_id: Dict(String, List(#(String, Bool))),
  patterns: List(ClaimPattern),
  from_date: String,
  to_date: String,
) -> AuditResult {
  let synthesis_facts =
    list.filter(facts, fn(f) {
      case f.operation {
        facts_types.Write -> is_synthesis(f)
        _ -> False
      }
    })
  let suspect =
    list.filter_map(synthesis_facts, fn(fact) {
      let reasons = flag_fact(fact, cycles_by_id, patterns)
      case reasons {
        [] -> Error(Nil)
        _ ->
          Ok(SuspectFact(
            fact_id: fact.fact_id,
            key: fact.key,
            cycle_id: fact.cycle_id,
            reasons: reasons,
          ))
      }
    })
  AuditResult(
    from_date: from_date,
    to_date: to_date,
    facts_examined: list.length(synthesis_facts),
    suspect_facts: suspect,
  )
}

/// Build the cycle→tool-calls index by reading cycle logs for the
/// covered date range. Helper so the audit tool can feed `audit/5`
/// without every caller re-implementing the read.
pub fn build_cycle_index(
  dates: List(String),
) -> Dict(String, List(#(String, Bool))) {
  list.fold(dates, dict.new(), fn(acc, date) {
    let cycles = cycle_log.load_cycles_for_date(date)
    list.fold(cycles, acc, fn(acc2, c) {
      dict.insert(acc2, c.cycle_id, c.tool_successes)
    })
  })
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn is_synthesis(fact: facts_types.MemoryFact) -> Bool {
  case fact.provenance {
    Some(p) ->
      case p.derivation {
        facts_types.Synthesis -> True
        _ -> False
      }
    None -> False
  }
}

fn flag_fact(
  fact: facts_types.MemoryFact,
  cycles_by_id: Dict(String, List(#(String, Bool))),
  patterns: List(ClaimPattern),
) -> List(String) {
  let haystack = fact.key <> " " <> fact.value
  let tools_fired = case dict.get(cycles_by_id, fact.cycle_id) {
    Ok(pairs) -> list.map(pairs, fn(p) { p.0 })
    Error(_) -> []
  }
  list.filter_map(patterns, fn(p) {
    case pattern_matches(p.pattern, haystack) {
      False -> Error(Nil)
      True ->
        case list.contains(tools_fired, p.expected_tool) {
          True -> Error(Nil)
          False ->
            Ok(
              p.description
              <> " but "
              <> p.expected_tool
              <> " did not fire in source cycle",
            )
        }
    }
  })
}

fn pattern_matches(pattern: String, text: String) -> Bool {
  case regexp.from_string(pattern) {
    Ok(re) ->
      case regexp.scan(re, text) {
        [] -> False
        _ -> True
      }
    Error(_) -> False
  }
}

/// Extract the distinct YYYY-MM-DD date prefixes from a list of facts.
/// The audit needs to load cycle logs for exactly those dates — no more,
/// no less. Using the timestamps already in the facts sidesteps the
/// date-arithmetic problem of iterating between two bounds.
pub fn dates_from_facts(facts: List(facts_types.MemoryFact)) -> List(String) {
  facts
  |> list.filter_map(fn(f) {
    case string.length(f.timestamp) >= 10 {
      True -> Ok(string.slice(f.timestamp, 0, 10))
      False -> Error(Nil)
    }
  })
  |> list.unique
}
