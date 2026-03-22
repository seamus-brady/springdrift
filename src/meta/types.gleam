//// Layer 3b types — session-level meta observer for cross-cycle pattern detection.
////
//// The meta observer runs after each cognitive cycle completes, analyzing
//// accumulated D' history for patterns that per-cycle gates can't detect:
//// rate limiting, cumulative risk, rejection patterns, and persona drift.

// ---------------------------------------------------------------------------
// Observations — input to the meta observer from the cognitive loop
// ---------------------------------------------------------------------------

/// Post-cycle observation sent to the meta observer after each cycle completes.
pub type MetaObservation {
  MetaObservation(
    cycle_id: String,
    timestamp: String,
    /// Gate decisions from this cycle (gate_name, decision, score)
    gate_decisions: List(GateDecisionSummary),
    /// Total tokens consumed this cycle (input + output)
    tokens_used: Int,
    /// Number of tool calls in this cycle
    tool_call_count: Int,
    /// Whether any agent delegations occurred
    had_delegations: Bool,
  )
}

pub type GateDecisionSummary {
  GateDecisionSummary(gate: String, decision: String, score: Float)
}

// ---------------------------------------------------------------------------
// Signals — detected patterns from individual detectors
// ---------------------------------------------------------------------------

/// A signal detected by one of the meta observer's detectors.
pub type MetaSignal {
  /// Too many cycles in a short window
  RateLimitSignal(cycles_in_window: Int, window_ms: Int)
  /// Cumulative D' score trending upward over recent cycles
  CumulativeRiskSignal(avg_score: Float, trend: String)
  /// Repeated rejections suggest the agent is stuck on a blocked path
  RepeatedRejectionSignal(rejection_count: Int, window_cycles: Int)
  /// Layer 3a (intra-gate meta) has been firing frequently
  Layer3aPersistenceSignal(tightening_count: Int, window_cycles: Int)
  /// Persona drift detected (bounded LLM check)
  PersonaDriftSignal(drift_description: String, confidence: Float)
}

// ---------------------------------------------------------------------------
// Interventions — actions applied at the start of the next cycle
// ---------------------------------------------------------------------------

/// An intervention to be applied by the cognitive loop at the start of the next cycle.
pub type MetaIntervention {
  /// No action needed
  NoIntervention
  /// Inject a caution message into the system prompt
  InjectCaution(message: String)
  /// Temporarily tighten D' thresholds across all gates
  TightenAllGates(factor: Float)
  /// Force a cooldown — delay the next cycle by N ms
  ForceCooldown(delay_ms: Int)
  /// Escalate to the user via sensory event
  EscalateToUser(title: String, body: String)
}

// ---------------------------------------------------------------------------
// Meta state — persisted between cycles
// ---------------------------------------------------------------------------

/// Persistent meta observer state, updated after each cycle.
pub type MetaState {
  MetaState(
    /// Recent observations (ring buffer, max_history entries)
    observations: List(MetaObservation),
    /// Signals detected in the last evaluation
    last_signals: List(MetaSignal),
    /// Current intervention (applied at next cycle start)
    pending_intervention: MetaIntervention,
    /// Count of consecutive cycles with elevated D' scores
    elevated_score_streak: Int,
    /// Count of consecutive rejections
    rejection_streak: Int,
    /// Total cycles observed this session
    total_cycles: Int,
    /// Configuration
    config: MetaConfig,
  )
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Configuration for the meta observer.
pub type MetaConfig {
  MetaConfig(
    /// Enable the meta observer (default: True when D' is enabled)
    enabled: Bool,
    /// Max observations to retain in the ring buffer
    max_history: Int,
    /// Rate limit: max cycles per window
    rate_limit_max_cycles: Int,
    /// Rate limit: window size in ms
    rate_limit_window_ms: Int,
    /// Cumulative risk: score threshold for elevated status
    elevated_score_threshold: Float,
    /// Cumulative risk: number of elevated cycles before signal
    elevated_streak_threshold: Int,
    /// Repeated rejection: count before signal
    rejection_count_threshold: Int,
    /// Repeated rejection: window in cycles
    rejection_window_cycles: Int,
    /// Layer 3a persistence: tightening count before signal
    layer3a_tightening_threshold: Int,
    /// Layer 3a persistence: window in cycles
    layer3a_window_cycles: Int,
    /// Persona drift: enable LLM-based drift check
    drift_check_enabled: Bool,
    /// Persona drift: check every N cycles
    drift_check_interval: Int,
    /// Cooldown delay in ms when ForceCooldown fires
    cooldown_delay_ms: Int,
    /// Threshold tightening factor (e.g. 0.85 = tighten by 15%)
    tighten_factor: Float,
  )
}

/// Default meta observer configuration.
pub fn default_config() -> MetaConfig {
  MetaConfig(
    enabled: True,
    max_history: 50,
    rate_limit_max_cycles: 30,
    rate_limit_window_ms: 60_000,
    elevated_score_threshold: 0.2,
    elevated_streak_threshold: 5,
    rejection_count_threshold: 3,
    rejection_window_cycles: 10,
    layer3a_tightening_threshold: 3,
    layer3a_window_cycles: 10,
    drift_check_enabled: False,
    drift_check_interval: 20,
    cooldown_delay_ms: 5000,
    tighten_factor: 0.85,
  )
}

/// Create initial meta state from config.
pub fn initial_state(config: MetaConfig) -> MetaState {
  MetaState(
    observations: [],
    last_signals: [],
    pending_intervention: NoIntervention,
    elevated_score_streak: 0,
    rejection_streak: 0,
    total_cycles: 0,
    config:,
  )
}

/// Record an observation, maintaining the ring buffer.
pub fn record_observation(state: MetaState, obs: MetaObservation) -> MetaState {
  let history = [obs, ..state.observations]
  let trimmed = case list.length(history) > state.config.max_history {
    True -> list.take(history, state.config.max_history)
    False -> history
  }
  MetaState(
    ..state,
    observations: trimmed,
    total_cycles: state.total_cycles + 1,
  )
}

import gleam/list

/// Check if any gate decision in an observation was a rejection.
pub fn has_rejection(obs: MetaObservation) -> Bool {
  list.any(obs.gate_decisions, fn(g) { g.decision == "reject" })
}

/// Get the max D' score from an observation's gate decisions.
pub fn max_score(obs: MetaObservation) -> Float {
  obs.gate_decisions
  |> list.fold(0.0, fn(acc, g) {
    case g.score >. acc {
      True -> g.score
      False -> acc
    }
  })
}

/// Consume the pending intervention (returns it and resets to NoIntervention).
pub fn consume_intervention(state: MetaState) -> #(MetaIntervention, MetaState) {
  #(
    state.pending_intervention,
    MetaState(..state, pending_intervention: NoIntervention),
  )
}
