//// D' (D-Prime) discrepancy-gated safety system types.
////
//// Based on Beach's Theory of Narrative Thought and Sloman's H-CogAff
//// three-layer architecture. D' scores how far an anticipated action
//// deviates from the agent's standards, gating tool dispatch.

import gleam/option.{type Option}

// ---------------------------------------------------------------------------
// Feature importance + definition
// ---------------------------------------------------------------------------

pub type Importance {
  Low
  Medium
  High
}

pub type Feature {
  Feature(
    name: String,
    importance: Importance,
    description: String,
    critical: Bool,
    feature_set: Option(String),
    feature_set_importance: Option(Importance),
    group: Option(String),
    group_importance: Option(Importance),
  )
}

// ---------------------------------------------------------------------------
// Forecast — LLM-scored magnitude per feature
// ---------------------------------------------------------------------------

pub type Forecast {
  Forecast(feature_name: String, magnitude: Int, rationale: String)
}

// ---------------------------------------------------------------------------
// Candidate — deliberative layer candidate action
// ---------------------------------------------------------------------------

pub type Candidate {
  Candidate(description: String, projected_outcome: String)
}

// ---------------------------------------------------------------------------
// Gate decision + layer
// ---------------------------------------------------------------------------

pub type GateDecision {
  Accept
  Modify
  Reject
}

pub type GateLayer {
  Reactive
  Deliberative
  MetaManagement
}

// ---------------------------------------------------------------------------
// Intervention (meta-management)
// ---------------------------------------------------------------------------

pub type Intervention {
  NoIntervention
  Stalled
  AbortMaxIterations
}

// ---------------------------------------------------------------------------
// Probe result (canary)
// ---------------------------------------------------------------------------

pub type ProbeResult {
  ProbeResult(hijack_detected: Bool, leakage_detected: Bool, details: String)
}

// ---------------------------------------------------------------------------
// Gate result — full evaluation outcome
// ---------------------------------------------------------------------------

pub type GateResult {
  GateResult(
    decision: GateDecision,
    dprime_score: Float,
    forecasts: List(Forecast),
    explanation: String,
    layer: GateLayer,
    canary_result: Option(ProbeResult),
  )
}

// ---------------------------------------------------------------------------
// Audit record — self-contained evaluation record
// ---------------------------------------------------------------------------

pub type FeatureScore {
  FeatureScore(name: String, importance: Int, magnitude: Int, score: Int)
}

pub type AuditRecord {
  AuditRecord(
    request_id: String,
    prompt_hash: String,
    canary_hijack: Option(Bool),
    canary_leakage: Option(Bool),
    reactive_dprime: Option(Float),
    deliberative_dprime: Option(Float),
    magnitudes: List(Forecast),
    per_feature: List(FeatureScore),
    decision: GateDecision,
    source: String,
    meta_intervention: Option(Intervention),
  )
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub type DprimeConfig {
  DprimeConfig(
    agent_id: String,
    features: List(Feature),
    tiers: Int,
    modify_threshold: Float,
    reject_threshold: Float,
    reactive_reject_threshold: Float,
    min_modify_threshold: Float,
    min_reject_threshold: Float,
    allow_adaptation: Bool,
    max_history: Int,
    stall_window: Int,
    stall_threshold: Float,
    canary_enabled: Bool,
    max_iterations: Int,
    max_candidates: Int,
  )
}

// ---------------------------------------------------------------------------
// History + state
// ---------------------------------------------------------------------------

pub type DprimeHistoryEntry {
  DprimeHistoryEntry(
    cycle_id: String,
    score: Float,
    decision: GateDecision,
    timestamp: String,
  )
}

pub type DprimeState {
  DprimeState(
    config: DprimeConfig,
    history: List(DprimeHistoryEntry),
    current_modify_threshold: Float,
    current_reject_threshold: Float,
    iteration_count: Int,
  )
}
