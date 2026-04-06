//// Eval: Meta-state usefulness — novelty signal for session awareness.
////
//// Verifies that novelty produces meaningful values for different simulated
//// session states. Uncertainty and prediction_error were removed in favour
//// of history-backed PerformanceSummary signals (success_rate, cbr_hit_rate).
//// All tests are pure computation with synthetic data — no LLM calls.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleeunit/should
import narrative/meta_states

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
  let recent_keywords = [["dublin", "rent", "apartment", "market"]]
  let n =
    meta_states.compute_novelty(
      "what is the current dublin rent market",
      recent_keywords,
    )
  should.be_true(n <. 0.7)
  should.be_true(n >. 0.5)
}

pub fn novelty_one_when_no_history_test() {
  let n = meta_states.compute_novelty("anything at all", [])
  should.be_true(n >=. 0.99)
}

pub fn novelty_uses_best_match_across_entries_test() {
  let recent_keywords = [
    ["quantum", "physics", "particle"],
    ["dublin", "rent", "market"],
  ]
  let n =
    meta_states.compute_novelty("dublin rent prices market", recent_keywords)
  should.be_true(n <. 0.4)
}
