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
  )
}

// ---------------------------------------------------------------------------
// Forecast — LLM-scored magnitude per feature
// ---------------------------------------------------------------------------

pub type Forecast {
  Forecast(feature_name: String, magnitude: Int, rationale: String)
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
// Configuration
// ---------------------------------------------------------------------------

pub type DprimeConfig {
  DprimeConfig(
    features: List(Feature),
    tiers: Int,
    modify_threshold: Float,
    reject_threshold: Float,
    max_history: Int,
    stall_window: Int,
    stall_threshold: Float,
    canary_enabled: Bool,
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
  )
}
