//// Mid-cycle model escalation criteria.
////
//// When the cheap model (task_model) encounters difficulties during a cycle
//// — tool failures, elevated D' scores — automatically escalate to the
//// powerful model (reasoning_model) for the remainder of the cycle.
////
//// This is distinct from initial query classification (Simple→haiku,
//// Complex→opus). Escalation fires mid-cycle when things go wrong.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type EscalationTrigger {
  ToolFailureEscalation(failure_count: Int, threshold: Int)
  SafetyEscalation(avg_score: Float, threshold: Float)
  TurnExhaustionEscalation(agent: String, turns_used: Int, max_turns: Int)
  StagnationEscalation(stall_count: Int)
}

pub type EscalationConfig {
  EscalationConfig(
    enabled: Bool,
    tool_failure_threshold: Int,
    safety_score_threshold: Float,
  )
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

pub fn default_config() -> EscalationConfig {
  EscalationConfig(
    enabled: True,
    tool_failure_threshold: 2,
    safety_score_threshold: 0.4,
  )
}

// ---------------------------------------------------------------------------
// Core check
// ---------------------------------------------------------------------------

/// Check if any escalation criteria are met.
/// Returns Some(trigger) if escalation should happen, None otherwise.
///
/// Checks in priority order:
/// 1. Tool failure count >= threshold → ToolFailureEscalation
/// 2. Average D' score >= threshold (needs >= 2 scores) → SafetyEscalation
pub fn check_escalation(
  tool_failure_count: Int,
  dprime_scores: List(Float),
  config: EscalationConfig,
) -> Option(EscalationTrigger) {
  case config.enabled {
    False -> None
    True -> {
      // Check tool failures first (highest priority)
      case tool_failure_count >= config.tool_failure_threshold {
        True ->
          Some(ToolFailureEscalation(
            failure_count: tool_failure_count,
            threshold: config.tool_failure_threshold,
          ))
        False -> check_safety_escalation(dprime_scores, config)
      }
    }
  }
}

fn check_safety_escalation(
  dprime_scores: List(Float),
  config: EscalationConfig,
) -> Option(EscalationTrigger) {
  // Need at least 2 D' scores for a meaningful average
  case list.length(dprime_scores) >= 2 {
    False -> None
    True -> {
      let sum = list.fold(dprime_scores, 0.0, fn(acc, s) { acc +. s })
      let count = int.to_float(list.length(dprime_scores))
      let avg = sum /. count
      case avg >=. config.safety_score_threshold {
        True ->
          Some(SafetyEscalation(
            avg_score: avg,
            threshold: config.safety_score_threshold,
          ))
        False -> None
      }
    }
  }
}

/// Format an escalation trigger as a human-readable reason string.
pub fn trigger_reason(trigger: EscalationTrigger) -> String {
  case trigger {
    ToolFailureEscalation(failure_count:, threshold:) ->
      "tool failures ("
      <> int.to_string(failure_count)
      <> " >= threshold "
      <> int.to_string(threshold)
      <> ")"
    SafetyEscalation(avg_score: _, threshold: _) -> "elevated D' safety scores"
    TurnExhaustionEscalation(agent:, turns_used:, max_turns:) ->
      "agent "
      <> agent
      <> " turn exhaustion ("
      <> int.to_string(turns_used)
      <> "/"
      <> int.to_string(max_turns)
      <> ")"
    StagnationEscalation(stall_count:) ->
      "stagnation (" <> int.to_string(stall_count) <> " stalls)"
  }
}
