//// Eval: Meta-state usefulness — epistemic signals for session awareness.
////
//// Verifies that uncertainty, prediction_error, and novelty produce
//// meaningful values for different simulated session states, and that
//// they are coherent across scenarios.
//// All tests are pure computation with synthetic data — no LLM calls.

import gleam/float
import gleeunit/should
import narrative/meta_states

// ---------------------------------------------------------------------------
// Uncertainty
// ---------------------------------------------------------------------------

pub fn uncertainty_high_when_no_cbr_hits_test() {
  // 10 cycles, 0 CBR hits → uncertainty 1.0
  let u = meta_states.compute_uncertainty(10, 0)
  should.be_true(u >=. 0.99)
}

pub fn uncertainty_low_when_all_cbr_hits_test() {
  // 10 cycles, 10 CBR hits → uncertainty 0.0
  let u = meta_states.compute_uncertainty(10, 10)
  should.be_true(u <. 0.01)
}

pub fn uncertainty_mixed_test() {
  // 10 cycles, 3 CBR hits → uncertainty = 1 - 3/10 = 0.7
  let u = meta_states.compute_uncertainty(10, 3)
  let diff = float.absolute_value(u -. 0.7)
  should.be_true(diff <. 0.01)
}

pub fn uncertainty_zero_cycles_is_zero_test() {
  // No cycles → no uncertainty (no data to be uncertain about)
  let u = meta_states.compute_uncertainty(0, 0)
  should.be_true(u <. 0.01)
}

pub fn uncertainty_clamped_when_hits_exceed_cycles_test() {
  // More hits than cycles (edge case) → clamp at 0.0
  let u = meta_states.compute_uncertainty(5, 10)
  should.be_true(u >=. 0.0)
  should.be_true(u <. 0.01)
}

// ---------------------------------------------------------------------------
// Prediction error
// ---------------------------------------------------------------------------

pub fn prediction_error_zero_when_no_failures_test() {
  // 20 tool calls, 0 failures, 0 D' modifications, 0 rejections
  let pe = meta_states.compute_prediction_error(20, 0, 0, 0)
  should.be_true(pe <. 0.01)
}

pub fn prediction_error_high_when_many_failures_test() {
  // 20 tool calls, 10 failures, 3 modifications, 2 rejections = 15/20 = 0.75
  let pe = meta_states.compute_prediction_error(20, 10, 3, 2)
  should.be_true(pe >=. 0.74)
  should.be_true(pe <=. 0.76)
}

pub fn prediction_error_zero_when_no_tool_calls_test() {
  // 0 tool calls → 0.0 (no tools = no prediction errors)
  let pe = meta_states.compute_prediction_error(0, 0, 0, 0)
  should.be_true(pe <. 0.01)
}

pub fn prediction_error_clamped_at_one_test() {
  // More errors than calls → clamp at 1.0
  let pe = meta_states.compute_prediction_error(5, 5, 3, 2)
  should.equal(pe, 1.0)
}

pub fn prediction_error_only_modifications_test() {
  // 10 calls, 3 D' modifications → 0.3
  let pe = meta_states.compute_prediction_error(10, 0, 3, 0)
  let diff = float.absolute_value(pe -. 0.3)
  should.be_true(diff <. 0.01)
}

// ---------------------------------------------------------------------------
// Novelty
// ---------------------------------------------------------------------------

pub fn novelty_high_for_unrelated_input_test() {
  // Input about "quantum physics" with recent entries about "Dublin rent"
  let recent_keywords = [["dublin", "rent", "apartment", "market"]]
  let n =
    meta_states.compute_novelty(
      "quantum physics experiment results",
      recent_keywords,
    )
  should.be_true(n >=. 0.9)
}

pub fn novelty_low_for_related_input_test() {
  // Input about "Dublin rent" with recent entries about "Dublin rent"
  // Tokenized input: {what, is, the, current, dublin, rent, market} (7 tokens)
  // Recent keywords: {dublin, rent, apartment, market} (4 tokens)
  // Jaccard = |{dublin, rent, market}| / |{what, is, the, current, dublin, rent, market, apartment}| = 3/8 = 0.375
  // Novelty = 1 - 0.375 = 0.625
  let recent_keywords = [["dublin", "rent", "apartment", "market"]]
  let n =
    meta_states.compute_novelty(
      "what is the current dublin rent market",
      recent_keywords,
    )
  // Novelty is moderate — stopwords dilute the match
  should.be_true(n <. 0.7)
  should.be_true(n >. 0.5)
}

pub fn novelty_one_when_no_history_test() {
  // No recent entries → everything is novel
  let n = meta_states.compute_novelty("anything at all", [])
  should.be_true(n >=. 0.99)
}

pub fn novelty_uses_best_match_across_entries_test() {
  // Multiple entries: one related, one unrelated — uses best match
  let recent_keywords = [
    ["quantum", "physics", "particle"],
    ["dublin", "rent", "market"],
  ]
  let n =
    meta_states.compute_novelty("dublin rent prices market", recent_keywords)
  // Should have low novelty due to second entry match
  should.be_true(n <. 0.4)
}

// ---------------------------------------------------------------------------
// Scenario: fresh session
// ---------------------------------------------------------------------------

pub fn new_session_meta_states_test() {
  // Fresh session: 0 cycles, no CBR, no tools
  let uncertainty = meta_states.compute_uncertainty(0, 0)
  let prediction_error = meta_states.compute_prediction_error(0, 0, 0, 0)
  let novelty = meta_states.compute_novelty("any question", [])

  // Uncertainty: 0.0 (no data to be uncertain about — function returns 0 for 0 cycles)
  should.be_true(uncertainty <. 0.01)
  // Prediction error: 0.0 (no tool calls)
  should.be_true(prediction_error <. 0.01)
  // Novelty: 1.0 (no history → everything novel)
  should.be_true(novelty >=. 0.99)
}

// ---------------------------------------------------------------------------
// Scenario: experienced session
// ---------------------------------------------------------------------------

pub fn experienced_session_meta_states_test() {
  // 50 cycles, 40 CBR hits
  let uncertainty = meta_states.compute_uncertainty(50, 40)
  // uncertainty = 1 - 40/50 = 0.2
  let diff_u = float.absolute_value(uncertainty -. 0.2)
  should.be_true(diff_u <. 0.01)

  // 200 tool calls, 10 failures, 5 D' mods, 2 rejects → 17/200 = 0.085
  let prediction_error = meta_states.compute_prediction_error(200, 10, 5, 2)
  let diff_pe = float.absolute_value(prediction_error -. 0.085)
  should.be_true(diff_pe <. 0.01)

  // Novelty depends on input — related input should be low
  let novelty =
    meta_states.compute_novelty("dublin rent market analysis", [
      ["dublin", "rent", "market"],
      ["property", "prices", "analysis"],
    ])
  should.be_true(novelty <. 0.5)
}

// ---------------------------------------------------------------------------
// Scenario: struggling session
// ---------------------------------------------------------------------------

pub fn struggling_session_meta_states_test() {
  // 10 cycles, 1 CBR hit → uncertainty = 1 - 1/10 = 0.9
  let uncertainty = meta_states.compute_uncertainty(10, 1)
  let diff_u = float.absolute_value(uncertainty -. 0.9)
  should.be_true(diff_u <. 0.01)

  // 30 tool calls, 15 failures, 8 D' mods, 3 rejects → 26/30 ≈ 0.867
  let prediction_error = meta_states.compute_prediction_error(30, 15, 8, 3)
  let diff_pe = float.absolute_value(prediction_error -. 0.8667)
  should.be_true(diff_pe <. 0.01)

  // Novel input with sparse history → high novelty
  let novelty =
    meta_states.compute_novelty("completely new topic about quantum computing", [
      ["dublin", "rent"],
    ])
  should.be_true(novelty >=. 0.9)
}

// ---------------------------------------------------------------------------
// Cross-signal coherence
// ---------------------------------------------------------------------------

pub fn signals_independent_of_each_other_test() {
  // Uncertainty and prediction_error use different inputs —
  // verify they can have opposite values
  // High uncertainty (no CBR hits) but low prediction error (no tool failures)
  let uncertainty = meta_states.compute_uncertainty(10, 0)
  let prediction_error = meta_states.compute_prediction_error(100, 0, 0, 0)

  should.be_true(uncertainty >=. 0.99)
  should.be_true(prediction_error <. 0.01)
}

pub fn all_signals_high_indicates_distress_test() {
  // When all signals are high, the session is struggling
  let uncertainty = meta_states.compute_uncertainty(5, 0)
  let prediction_error = meta_states.compute_prediction_error(10, 8, 1, 1)
  let novelty =
    meta_states.compute_novelty("alien topic", [["unrelated", "keywords"]])

  should.be_true(uncertainty >=. 0.9)
  should.be_true(prediction_error >=. 0.9)
  should.be_true(novelty >=. 0.9)
}

pub fn all_signals_low_indicates_confidence_test() {
  // When all signals are low, the session is running smoothly
  let uncertainty = meta_states.compute_uncertainty(50, 45)
  let prediction_error = meta_states.compute_prediction_error(200, 5, 1, 0)
  let novelty =
    meta_states.compute_novelty("dublin rent prices", [
      ["dublin", "rent", "prices", "market"],
    ])

  should.be_true(uncertainty <. 0.15)
  should.be_true(prediction_error <. 0.05)
  should.be_true(novelty <. 0.3)
}
