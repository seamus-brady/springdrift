// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive/escalation.{
  EscalationConfig, SafetyEscalation, ToolFailureEscalation,
}
import gleam/option.{None, Some}
import gleeunit/should

// ---------------------------------------------------------------------------
// default_config
// ---------------------------------------------------------------------------

pub fn default_config_values_test() {
  let cfg = escalation.default_config()
  should.equal(cfg.enabled, True)
  should.equal(cfg.tool_failure_threshold, 2)
  should.equal(cfg.safety_score_threshold, 0.4)
}

// ---------------------------------------------------------------------------
// check_escalation — disabled
// ---------------------------------------------------------------------------

pub fn check_escalation_disabled_returns_none_test() {
  let cfg = EscalationConfig(..escalation.default_config(), enabled: False)
  let result = escalation.check_escalation(10, [0.9, 0.8], cfg)
  should.equal(result, None)
}

// ---------------------------------------------------------------------------
// check_escalation — tool failures
// ---------------------------------------------------------------------------

pub fn check_escalation_no_failures_returns_none_test() {
  let cfg = escalation.default_config()
  let result = escalation.check_escalation(0, [], cfg)
  should.equal(result, None)
}

pub fn check_escalation_failures_below_threshold_returns_none_test() {
  let cfg = escalation.default_config()
  let result = escalation.check_escalation(1, [], cfg)
  should.equal(result, None)
}

pub fn check_escalation_failures_at_threshold_returns_trigger_test() {
  let cfg = escalation.default_config()
  let result = escalation.check_escalation(2, [], cfg)
  should.equal(
    result,
    Some(ToolFailureEscalation(failure_count: 2, threshold: 2)),
  )
}

pub fn check_escalation_failures_above_threshold_returns_trigger_test() {
  let cfg = escalation.default_config()
  let result = escalation.check_escalation(5, [], cfg)
  should.equal(
    result,
    Some(ToolFailureEscalation(failure_count: 5, threshold: 2)),
  )
}

// ---------------------------------------------------------------------------
// check_escalation — D' safety scores
// ---------------------------------------------------------------------------

pub fn check_escalation_low_dprime_scores_returns_none_test() {
  let cfg = escalation.default_config()
  let result = escalation.check_escalation(0, [0.1, 0.2], cfg)
  should.equal(result, None)
}

pub fn check_escalation_elevated_dprime_scores_returns_trigger_test() {
  let cfg = escalation.default_config()
  let result = escalation.check_escalation(0, [0.5, 0.6], cfg)
  case result {
    Some(SafetyEscalation(avg_score: _, threshold: 0.4)) -> Nil
    _ -> should.fail()
  }
}

pub fn check_escalation_single_dprime_score_returns_none_test() {
  // Need at least 2 scores for safety escalation
  let cfg = escalation.default_config()
  let result = escalation.check_escalation(0, [0.9], cfg)
  should.equal(result, None)
}

pub fn check_escalation_empty_dprime_scores_returns_none_test() {
  let cfg = escalation.default_config()
  let result = escalation.check_escalation(0, [], cfg)
  should.equal(result, None)
}

// ---------------------------------------------------------------------------
// check_escalation — tool failures take priority over D' scores
// ---------------------------------------------------------------------------

pub fn check_escalation_tool_failures_take_priority_test() {
  let cfg = escalation.default_config()
  // Both conditions met — tool failures should win
  let result = escalation.check_escalation(3, [0.9, 0.8], cfg)
  should.equal(
    result,
    Some(ToolFailureEscalation(failure_count: 3, threshold: 2)),
  )
}

// ---------------------------------------------------------------------------
// check_escalation — custom thresholds
// ---------------------------------------------------------------------------

pub fn check_escalation_custom_tool_threshold_test() {
  let cfg =
    EscalationConfig(..escalation.default_config(), tool_failure_threshold: 5)
  // 3 failures — below custom threshold of 5
  let result = escalation.check_escalation(3, [], cfg)
  should.equal(result, None)
  // 5 failures — at custom threshold
  let result2 = escalation.check_escalation(5, [], cfg)
  should.equal(
    result2,
    Some(ToolFailureEscalation(failure_count: 5, threshold: 5)),
  )
}

pub fn check_escalation_custom_safety_threshold_test() {
  let cfg =
    EscalationConfig(..escalation.default_config(), safety_score_threshold: 0.7)
  // Average 0.55 — below custom threshold of 0.7
  let result = escalation.check_escalation(0, [0.5, 0.6], cfg)
  should.equal(result, None)
  // Average 0.75 — above custom threshold of 0.7
  let result2 = escalation.check_escalation(0, [0.7, 0.8], cfg)
  case result2 {
    Some(SafetyEscalation(avg_score: _, threshold: 0.7)) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// trigger_reason
// ---------------------------------------------------------------------------

pub fn trigger_reason_tool_failure_test() {
  let reason =
    escalation.trigger_reason(ToolFailureEscalation(
      failure_count: 3,
      threshold: 2,
    ))
  should.equal(reason, "tool failures (3 >= threshold 2)")
}

pub fn trigger_reason_safety_test() {
  let reason =
    escalation.trigger_reason(SafetyEscalation(avg_score: 0.5, threshold: 0.4))
  should.equal(reason, "elevated D' safety scores")
}
