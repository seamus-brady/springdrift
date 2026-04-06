//// CBR (Case-Based Reasoning) types — procedural memory.
////
//// CbrCase records are derived from NarrativeEntry by the Archivist,
//// optimised for similarity retrieval. They capture the problem/solution/outcome
//// structure that enables "how have I handled this before?" queries.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/int
import gleam/option.{type Option}

// ---------------------------------------------------------------------------
// Case category — what kind of knowledge this case captures
// ---------------------------------------------------------------------------

pub type CbrCategory {
  /// High-level approach that worked
  Strategy
  /// Reusable code snippet or template
  CodePattern
  /// How to diagnose/fix a specific problem
  Troubleshooting
  /// What NOT to do — learned from failure
  Pitfall
  /// Factual knowledge about a domain
  DomainKnowledge
}

// ---------------------------------------------------------------------------
// Core case
// ---------------------------------------------------------------------------

pub type CbrCase {
  CbrCase(
    case_id: String,
    timestamp: String,
    schema_version: Int,
    problem: CbrProblem,
    solution: CbrSolution,
    outcome: CbrOutcome,
    source_narrative_id: String,
    profile: Option(String),
    redacted: Bool,
    category: Option(CbrCategory),
    usage_stats: Option(CbrUsageStats),
  )
}

// ---------------------------------------------------------------------------
// Usage tracking — retrieval feedback loop
// ---------------------------------------------------------------------------

pub type CbrUsageStats {
  CbrUsageStats(
    retrieval_count: Int,
    retrieval_success_count: Int,
    helpful_count: Int,
    harmful_count: Int,
  )
}

/// Create empty usage stats (all counters at zero).
pub fn empty_usage_stats() -> CbrUsageStats {
  CbrUsageStats(
    retrieval_count: 0,
    retrieval_success_count: 0,
    helpful_count: 0,
    harmful_count: 0,
  )
}

/// Compute utility score with Laplace smoothing.
/// Returns a value in (0, 1). With no data, returns 0.5 (neutral).
pub fn utility_score(stats: Option(CbrUsageStats)) -> Float {
  case stats {
    option.None -> 0.5
    option.Some(s) -> {
      let num = int.to_float(s.retrieval_success_count + 1)
      let denom = int.to_float(s.retrieval_count + 2)
      num /. denom
    }
  }
}

// ---------------------------------------------------------------------------
// Problem descriptor
// ---------------------------------------------------------------------------

pub type CbrProblem {
  CbrProblem(
    user_input: String,
    intent: String,
    domain: String,
    entities: List(String),
    keywords: List(String),
    query_complexity: String,
  )
}

// ---------------------------------------------------------------------------
// Solution descriptor
// ---------------------------------------------------------------------------

pub type CbrSolution {
  CbrSolution(
    approach: String,
    agents_used: List(String),
    tools_used: List(String),
    steps: List(String),
  )
}

// ---------------------------------------------------------------------------
// Outcome descriptor
// ---------------------------------------------------------------------------

pub type CbrOutcome {
  CbrOutcome(
    status: String,
    confidence: Float,
    assessment: String,
    pitfalls: List(String),
  )
}

// ---------------------------------------------------------------------------
// Query and scored result (for retrieval)
// ---------------------------------------------------------------------------

pub type CbrQuery {
  CbrQuery(
    intent: String,
    domain: String,
    keywords: List(String),
    entities: List(String),
    max_results: Int,
    query_complexity: Option(String),
  )
}

pub type ScoredCase {
  ScoredCase(score: Float, cbr_case: CbrCase)
}
