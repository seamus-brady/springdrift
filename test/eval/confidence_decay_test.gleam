//// Eval: Confidence decay — half-life decay at various ages.
////
//// Verifies that decay_confidence produces correct values at standard ages,
//// that ordering is monotonically decreasing with age, and that edge cases
//// (zero half-life, competing facts) behave correctly.
//// All tests are pure computation with synthetic data — no LLM calls.

import dprime/decay
import gleam/float
import gleam/list
import gleeunit/should

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn approx_equal(actual: Float, expected: Float, tolerance: Float) -> Nil {
  let diff = float.absolute_value(actual -. expected)
  should.be_true(diff <. tolerance)
}

// ---------------------------------------------------------------------------
// Correct values at standard ages
// ---------------------------------------------------------------------------

pub fn decay_produces_correct_values_at_standard_ages_test() {
  // half_life = 30 days, original confidence = 0.90
  let half_life = 30

  // Day 0: no decay
  decay.decay_confidence(0.9, 0, half_life)
  |> should.equal(0.9)

  // Day 15: 0.90 * 2^(-0.5) ≈ 0.90 * 0.7071 ≈ 0.6364
  let day_15 = decay.decay_confidence(0.9, 15, half_life)
  approx_equal(day_15, 0.6364, 0.001)

  // Day 30: 0.90 * 2^(-1) = 0.90 * 0.5 = 0.45
  let day_30 = decay.decay_confidence(0.9, 30, half_life)
  approx_equal(day_30, 0.45, 0.001)

  // Day 60: 0.90 * 2^(-2) = 0.90 * 0.25 = 0.225
  let day_60 = decay.decay_confidence(0.9, 60, half_life)
  approx_equal(day_60, 0.225, 0.001)

  // Day 90: 0.90 * 2^(-3) = 0.90 * 0.125 = 0.1125
  let day_90 = decay.decay_confidence(0.9, 90, half_life)
  approx_equal(day_90, 0.1125, 0.001)

  // Day 365: 0.90 * 2^(-365/30) ≈ 0.90 * 2^(-12.17) ≈ effectively zero
  let day_365 = decay.decay_confidence(0.9, 365, half_life)
  should.be_true(day_365 <. 0.001)
  should.be_true(day_365 >=. 0.0)
}

// ---------------------------------------------------------------------------
// Comparison table: different half-lives
// ---------------------------------------------------------------------------

pub fn decay_comparison_aggressive_half_life_7_test() {
  // Half-life 7 days (aggressive)
  let hl = 7

  // Day 7: 50%
  let day_7 = decay.decay_confidence(1.0, 7, hl)
  approx_equal(day_7, 0.5, 0.001)

  // Day 14: 25%
  let day_14 = decay.decay_confidence(1.0, 14, hl)
  approx_equal(day_14, 0.25, 0.001)

  // Day 30: 2^(-30/7) ≈ 2^(-4.286) ≈ 0.051
  let day_30 = decay.decay_confidence(1.0, 30, hl)
  approx_equal(day_30, 0.051, 0.005)
}

pub fn decay_comparison_default_half_life_30_test() {
  // Half-life 30 days (default for facts)
  let hl = 30

  let day_30 = decay.decay_confidence(1.0, 30, hl)
  approx_equal(day_30, 0.5, 0.001)

  let day_60 = decay.decay_confidence(1.0, 60, hl)
  approx_equal(day_60, 0.25, 0.001)

  let day_90 = decay.decay_confidence(1.0, 90, hl)
  approx_equal(day_90, 0.125, 0.001)
}

pub fn decay_comparison_cbr_half_life_60_test() {
  // Half-life 60 days (default for CBR)
  let hl = 60

  let day_60 = decay.decay_confidence(1.0, 60, hl)
  approx_equal(day_60, 0.5, 0.001)

  let day_120 = decay.decay_confidence(1.0, 120, hl)
  approx_equal(day_120, 0.25, 0.001)

  let day_180 = decay.decay_confidence(1.0, 180, hl)
  approx_equal(day_180, 0.125, 0.001)
}

pub fn decay_comparison_conservative_half_life_365_test() {
  // Half-life 365 days (conservative)
  let hl = 365

  let day_365 = decay.decay_confidence(1.0, 365, hl)
  approx_equal(day_365, 0.5, 0.001)

  let day_730 = decay.decay_confidence(1.0, 730, hl)
  approx_equal(day_730, 0.25, 0.001)
}

// ---------------------------------------------------------------------------
// Monotonic decrease: fresh facts always higher than old
// ---------------------------------------------------------------------------

pub fn fresh_facts_always_higher_than_old_test() {
  let original = 0.85
  let half_life = 30
  let day_1 = decay.decay_confidence(original, 1, half_life)
  let day_7 = decay.decay_confidence(original, 7, half_life)
  let day_30 = decay.decay_confidence(original, 30, half_life)
  let day_90 = decay.decay_confidence(original, 90, half_life)

  should.be_true(day_1 >. day_7)
  should.be_true(day_7 >. day_30)
  should.be_true(day_30 >. day_90)
}

pub fn monotonic_across_all_ages_test() {
  // Test a wider range of ages for strict monotonic decrease
  let original = 0.95
  let half_life = 30
  let ages = [0, 1, 3, 7, 14, 21, 30, 45, 60, 90, 120, 180, 365]
  let scores =
    list.map(ages, fn(age) { decay.decay_confidence(original, age, half_life) })

  // Each score should be >= the next (strictly decreasing or equal for age 0)
  check_monotonic_decreasing(scores)
}

fn check_monotonic_decreasing(scores: List(Float)) -> Nil {
  case scores {
    [] -> Nil
    [_] -> Nil
    [a, b, ..rest] -> {
      should.be_true(a >=. b)
      check_monotonic_decreasing([b, ..rest])
    }
  }
}

// ---------------------------------------------------------------------------
// Old high-confidence vs new low-confidence
// ---------------------------------------------------------------------------

pub fn high_confidence_old_fact_vs_low_confidence_new_fact_test() {
  // A high-confidence fact from 60 days ago: 0.95 * 2^(-2) = 0.2375
  let old_high = decay.decay_confidence(0.95, 60, 30)
  // A low-confidence fact from today: 0.30 * 2^0 = 0.30
  let new_low = decay.decay_confidence(0.3, 0, 30)
  // The new fact should win despite lower original confidence
  should.be_true(new_low >. old_high)
}

pub fn moderate_confidence_beats_old_high_confidence_test() {
  // Even a moderate 0.50 confidence from today beats 0.99 from 90 days ago
  let old = decay.decay_confidence(0.99, 90, 30)
  // 0.99 * 2^(-3) = 0.99 * 0.125 ≈ 0.124
  let new_moderate = decay.decay_confidence(0.5, 0, 30)
  should.be_true(new_moderate >. old)
}

// ---------------------------------------------------------------------------
// Zero half-life disables decay
// ---------------------------------------------------------------------------

pub fn zero_half_life_disables_decay_test() {
  let original = 0.9
  let result = decay.decay_confidence(original, 365, 0)
  // half_life 0 means no decay — returns original
  should.equal(result, original)
}

pub fn negative_half_life_disables_decay_test() {
  let original = 0.75
  let result = decay.decay_confidence(original, 100, -10)
  should.equal(result, original)
}

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

pub fn zero_confidence_stays_zero_test() {
  // 0.0 * anything = 0.0
  let result = decay.decay_confidence(0.0, 30, 30)
  should.equal(result, 0.0)
}

pub fn very_small_half_life_rapid_decay_test() {
  // half_life = 1 day: after 10 days, 2^(-10) ≈ 0.001
  let result = decay.decay_confidence(1.0, 10, 1)
  should.be_true(result <. 0.002)
  should.be_true(result >. 0.0)
}

pub fn large_age_does_not_go_negative_test() {
  // Even after 10000 days, result should be >= 0.0
  let result = decay.decay_confidence(1.0, 10_000, 30)
  should.be_true(result >=. 0.0)
  should.be_true(result <=. 1.0)
}
