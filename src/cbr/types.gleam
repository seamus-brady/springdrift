//// CBR (Case-Based Reasoning) types — procedural memory.
////
//// CbrCase records are derived from NarrativeEntry by the Archivist,
//// optimised for similarity retrieval. They capture the problem/solution/outcome
//// structure that enables "how have I handled this before?" queries.

import gleam/option.{type Option}

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
  )
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
