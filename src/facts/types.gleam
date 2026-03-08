//// MemoryFact — semantic memory types.
////
//// A discrete, keyed assertion about the world. Every write is permanent —
//// the JSONL is append-only, and supersessions are recorded as new entries
//// rather than mutations.

import gleam/option.{type Option}

// ---------------------------------------------------------------------------
// Core type
// ---------------------------------------------------------------------------

pub type MemoryFact {
  MemoryFact(
    schema_version: Int,
    fact_id: String,
    timestamp: String,
    cycle_id: String,
    agent_id: Option(String),
    key: String,
    value: String,
    scope: FactScope,
    operation: FactOp,
    supersedes: Option(String),
    confidence: Float,
    source: String,
  )
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Fact scope — how long the fact persists.
pub type FactScope {
  /// Survives session restarts, reloaded from facts.jsonl.
  Persistent
  /// Lives only for the current session (not reloaded on restart).
  Session
  /// Very short-lived, cleared at end of cycle.
  Ephemeral
}

/// Fact operation — what this record represents.
pub type FactOp {
  /// A new assertion or update.
  Write
  /// Explicitly removed by user or agent.
  Clear
  /// Replaced by a newer fact (carries the newer fact_id in supersedes).
  Superseded
}
