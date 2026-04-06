// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import affect/compute.{AffectSignals, compute_snapshot}
import affect/types.{AffectSnapshot, Rising, Stable}
import gleam/option.{None, Some}
import gleeunit/should

fn clean_signals() {
  AffectSignals(
    tool_calls_total: 5,
    tool_calls_failed: 0,
    same_tool_retries: 0,
    gate_rejections: 0,
    gate_modifications: 0,
    delegations_total: 1,
    delegations_failed: 0,
    recent_success_rate: 0.8,
    cbr_hit_rate: 0.6,
    budget_pressure: 0.0,
    consecutive_failure_cycles: 0,
    output_gate_rejections: 0,
  )
}

fn failing_signals() {
  AffectSignals(
    tool_calls_total: 5,
    tool_calls_failed: 3,
    same_tool_retries: 2,
    gate_rejections: 1,
    gate_modifications: 1,
    delegations_total: 2,
    delegations_failed: 1,
    recent_success_rate: 0.3,
    cbr_hit_rate: 0.2,
    budget_pressure: 0.5,
    consecutive_failure_cycles: 3,
    output_gate_rejections: 0,
  )
}

// ---------------------------------------------------------------------------
// Clean cycle — low pressure
// ---------------------------------------------------------------------------

pub fn clean_cycle_low_desperation_test() {
  let s = compute_snapshot(clean_signals(), None, "c1", "2026-04-04T10:00:00")
  // No failures, no retries, no rejections → desperation should be very low
  should.be_true(s.desperation <. 10.0)
}

pub fn clean_cycle_reasonable_confidence_test() {
  let s = compute_snapshot(clean_signals(), None, "c1", "2026-04-04T10:00:00")
  // Good success rate + CBR hits → confidence should be decent
  should.be_true(s.confidence >. 50.0)
}

pub fn clean_cycle_low_frustration_test() {
  let s = compute_snapshot(clean_signals(), None, "c1", "2026-04-04T10:00:00")
  should.be_true(s.frustration <. 15.0)
}

pub fn clean_cycle_low_pressure_test() {
  let s = compute_snapshot(clean_signals(), None, "c1", "2026-04-04T10:00:00")
  should.be_true(s.pressure <. 25.0)
}

// ---------------------------------------------------------------------------
// Failing cycle — high pressure
// ---------------------------------------------------------------------------

pub fn failing_cycle_high_desperation_test() {
  let s = compute_snapshot(failing_signals(), None, "c2", "2026-04-04T10:00:00")
  // Retries + rejections + consecutive failures → desperation should be elevated
  should.be_true(s.desperation >. 40.0)
}

pub fn failing_cycle_low_confidence_test() {
  let s = compute_snapshot(failing_signals(), None, "c2", "2026-04-04T10:00:00")
  // Low success rate + low CBR hits → confidence should be low
  should.be_true(s.confidence <. 40.0)
}

pub fn failing_cycle_high_pressure_test() {
  let s = compute_snapshot(failing_signals(), None, "c2", "2026-04-04T10:00:00")
  should.be_true(s.pressure >. 30.0)
}

// ---------------------------------------------------------------------------
// Calm inertia
// ---------------------------------------------------------------------------

pub fn calm_inertia_test() {
  // Start with high calm baseline
  let prev = AffectSnapshot(..types.baseline(), calm: 80.0, pressure: 10.0)
  // One bad cycle shouldn't crash calm
  let s =
    compute_snapshot(failing_signals(), Some(prev), "c3", "2026-04-04T10:00:00")
  // Calm should drop but not catastrophically (EMA alpha=0.15)
  should.be_true(s.calm >. 50.0)
  should.be_true(s.calm <. 80.0)
}

pub fn calm_recovery_slow_test() {
  // Start with depleted calm
  let prev = AffectSnapshot(..types.baseline(), calm: 30.0, pressure: 60.0)
  // One clean cycle shouldn't fully restore calm
  let s =
    compute_snapshot(clean_signals(), Some(prev), "c4", "2026-04-04T10:00:00")
  should.be_true(s.calm >. 30.0)
  should.be_true(s.calm <. 60.0)
}

// ---------------------------------------------------------------------------
// Trend
// ---------------------------------------------------------------------------

pub fn trend_rising_test() {
  let prev = AffectSnapshot(..types.baseline(), pressure: 20.0)
  let s =
    compute_snapshot(failing_signals(), Some(prev), "c5", "2026-04-04T10:00:00")
  // Pressure should rise significantly → Rising trend
  should.equal(s.trend, Rising)
}

pub fn trend_stable_on_consecutive_clean_test() {
  // Two clean cycles in a row → trend should stabilise
  let first =
    compute_snapshot(clean_signals(), None, "c6a", "2026-04-04T10:00:00")
  let second =
    compute_snapshot(clean_signals(), Some(first), "c6b", "2026-04-04T10:01:00")
  // Second clean cycle with same signals as first → Stable
  should.equal(second.trend, Stable)
}

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

pub fn zero_tools_test() {
  let signals =
    AffectSignals(
      tool_calls_total: 0,
      tool_calls_failed: 0,
      same_tool_retries: 0,
      gate_rejections: 0,
      gate_modifications: 0,
      delegations_total: 0,
      delegations_failed: 0,
      recent_success_rate: 0.5,
      cbr_hit_rate: 0.5,
      budget_pressure: 0.0,
      consecutive_failure_cycles: 0,
      output_gate_rejections: 0,
    )
  let s = compute_snapshot(signals, None, "c7", "2026-04-04T10:00:00")
  // Should not crash, should produce reasonable defaults
  should.be_true(s.desperation >=. 0.0)
  should.be_true(s.calm >. 0.0)
  should.be_true(s.pressure >=. 0.0)
}

pub fn all_dimensions_clamped_test() {
  let extreme =
    AffectSignals(
      tool_calls_total: 10,
      tool_calls_failed: 10,
      same_tool_retries: 8,
      gate_rejections: 5,
      gate_modifications: 5,
      delegations_total: 5,
      delegations_failed: 5,
      recent_success_rate: 0.0,
      cbr_hit_rate: 0.0,
      budget_pressure: 1.0,
      consecutive_failure_cycles: 10,
      output_gate_rejections: 5,
    )
  let s = compute_snapshot(extreme, None, "c8", "2026-04-04T10:00:00")
  // All dimensions should be within [0, 100]
  should.be_true(s.desperation >=. 0.0 && s.desperation <=. 100.0)
  should.be_true(s.calm >=. 0.0 && s.calm <=. 100.0)
  should.be_true(s.confidence >=. 0.0 && s.confidence <=. 100.0)
  should.be_true(s.frustration >=. 0.0 && s.frustration <=. 100.0)
  should.be_true(s.pressure >=. 0.0 && s.pressure <=. 100.0)
}
