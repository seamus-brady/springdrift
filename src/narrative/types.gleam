//// Prime Narrative types — NarrativeEntry and all supporting structures.
////
//// Uses agent_id/agent_human_name strings (no enum) so custom agents
//// from profiles work without code changes.

import gleam/option.{type Option}

// ---------------------------------------------------------------------------
// Core entry
// ---------------------------------------------------------------------------

pub type NarrativeEntry {
  NarrativeEntry(
    schema_version: Int,
    cycle_id: String,
    parent_cycle_id: Option(String),
    timestamp: String,
    entry_type: EntryType,
    summary: String,
    intent: Intent,
    outcome: Outcome,
    delegation_chain: List(DelegationStep),
    decisions: List(Decision),
    keywords: List(String),
    topics: List(String),
    entities: Entities,
    sources: List(Source),
    thread: Option(Thread),
    metrics: Metrics,
    observations: List(Observation),
  )
}

pub type EntryType {
  Narrative
  Amendment
  Summary
  ObservationEntry
}

// ---------------------------------------------------------------------------
// Intent
// ---------------------------------------------------------------------------

pub type IntentClassification {
  DataReport
  DataQuery
  Comparison
  TrendAnalysis
  MonitoringCheck
  Exploration
  Clarification
  SystemCommand
  Conversation
}

pub type Intent {
  Intent(
    classification: IntentClassification,
    description: String,
    domain: String,
  )
}

// ---------------------------------------------------------------------------
// Outcome
// ---------------------------------------------------------------------------

pub type OutcomeStatus {
  Success
  Partial
  Failure
}

pub type Outcome {
  Outcome(status: OutcomeStatus, confidence: Float, assessment: String)
}

// ---------------------------------------------------------------------------
// Delegation chain
// ---------------------------------------------------------------------------

pub type DelegationStep {
  DelegationStep(
    agent: String,
    agent_id: String,
    agent_human_name: String,
    agent_cycle_id: String,
    instruction: String,
    outcome: String,
    contribution: String,
    tools_used: List(String),
    sources_accessed: Int,
    input_tokens: Int,
    output_tokens: Int,
    duration_ms: Int,
  )
}

// ---------------------------------------------------------------------------
// Decisions
// ---------------------------------------------------------------------------

pub type Decision {
  Decision(
    point: String,
    choice: String,
    rationale: String,
    score: Option(Float),
  )
}

// ---------------------------------------------------------------------------
// Entities
// ---------------------------------------------------------------------------

pub type DataPoint {
  DataPoint(
    label: String,
    value: String,
    unit: String,
    period: String,
    source: String,
  )
}

pub type Entities {
  Entities(
    locations: List(String),
    organisations: List(String),
    data_points: List(DataPoint),
    temporal_references: List(String),
  )
}

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------

pub type Source {
  Source(
    source_type: String,
    url: Option(String),
    path: Option(String),
    name: String,
    accessed_at: Option(String),
    data_date: Option(String),
  )
}

// ---------------------------------------------------------------------------
// Threading
// ---------------------------------------------------------------------------

pub type Thread {
  Thread(
    thread_id: String,
    thread_name: String,
    position: Int,
    previous_cycle_id: Option(String),
    continuity_note: String,
  )
}

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

pub type Metrics {
  Metrics(
    total_duration_ms: Int,
    input_tokens: Int,
    output_tokens: Int,
    thinking_tokens: Int,
    tool_calls: Int,
    agent_delegations: Int,
    dprime_evaluations: Int,
    model_used: String,
  )
}

// ---------------------------------------------------------------------------
// Observations
// ---------------------------------------------------------------------------

pub type ObservationSeverity {
  Info
  Warning
  ErrorSeverity
}

pub type Observation {
  Observation(
    observation_type: String,
    severity: ObservationSeverity,
    detail: String,
  )
}

// ---------------------------------------------------------------------------
// Thread index (persisted to thread_index.json)
// ---------------------------------------------------------------------------

pub type ThreadState {
  ThreadState(
    thread_id: String,
    thread_name: String,
    created_at: String,
    last_cycle_id: String,
    last_cycle_at: String,
    cycle_count: Int,
    locations: List(String),
    domains: List(String),
    keywords: List(String),
    topics: List(String),
    last_data_points: List(DataPoint),
  )
}

pub type ThreadIndex {
  ThreadIndex(threads: List(ThreadState))
}
