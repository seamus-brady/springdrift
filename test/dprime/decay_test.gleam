// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/decay
import gleam/float
import gleeunit/should

// ---------------------------------------------------------------------------
// decay_confidence tests
// ---------------------------------------------------------------------------

pub fn decay_confidence_age_zero_returns_original_test() {
  decay.decay_confidence(0.8, 0, 30)
  |> should.equal(0.8)
}

pub fn decay_confidence_at_half_life_returns_half_test() {
  let result = decay.decay_confidence(1.0, 30, 30)
  // At exactly one half-life, result should be ~0.5
  let diff = float.absolute_value(result -. 0.5)
  should.be_true(diff <. 0.001)
}

pub fn decay_confidence_at_two_half_lives_returns_quarter_test() {
  let result = decay.decay_confidence(1.0, 60, 30)
  // At two half-lives, result should be ~0.25
  let diff = float.absolute_value(result -. 0.25)
  should.be_true(diff <. 0.001)
}

pub fn decay_confidence_half_life_zero_returns_original_test() {
  decay.decay_confidence(0.9, 10, 0)
  |> should.equal(0.9)
}

pub fn decay_confidence_negative_age_returns_original_test() {
  decay.decay_confidence(0.7, -5, 30)
  |> should.equal(0.7)
}

pub fn decay_confidence_clamped_to_unit_interval_test() {
  // Original confidence already at 1.0, decay should keep it <= 1.0
  let result = decay.decay_confidence(1.0, 1, 30)
  should.be_true(result >=. 0.0)
  should.be_true(result <=. 1.0)
}

pub fn decay_confidence_with_fractional_original_test() {
  let result = decay.decay_confidence(0.8, 30, 30)
  // 0.8 * 0.5 = 0.4
  let diff = float.absolute_value(result -. 0.4)
  should.be_true(diff <. 0.001)
}

pub fn decay_confidence_very_old_approaches_zero_test() {
  let result = decay.decay_confidence(1.0, 300, 30)
  // 10 half-lives: 1.0 * 2^-10 ≈ 0.000977
  should.be_true(result <. 0.01)
  should.be_true(result >=. 0.0)
}

// ---------------------------------------------------------------------------
// decay_fact_confidence tests
// ---------------------------------------------------------------------------

pub fn decay_fact_confidence_same_day_returns_original_test() {
  decay.decay_fact_confidence(0.9, "2026-03-25", "2026-03-25", 30)
  |> should.equal(0.9)
}

pub fn decay_fact_confidence_30_days_ago_half_life_30_test() {
  let result = decay.decay_fact_confidence(1.0, "2026-02-23", "2026-03-25", 30)
  // 30 days ago with half_life 30 → ~0.5
  let diff = float.absolute_value(result -. 0.5)
  should.be_true(diff <. 0.001)
}
