//// Tests for meta-state computation functions.
////
//// All functions are pure — no actor startup needed.

import gleam/set
import gleeunit/should
import narrative/meta_states

// ---------------------------------------------------------------------------
// compute_novelty
// ---------------------------------------------------------------------------

pub fn novelty_no_entries_returns_one_test() {
  meta_states.compute_novelty("hello world", [])
  |> should.equal(1.0)
}

pub fn novelty_identical_keywords_returns_zero_test() {
  // Input "hello world" vs entry keywords ["hello", "world"]
  let result = meta_states.compute_novelty("hello world", [["hello", "world"]])
  should.be_true(result <. 0.01)
}

pub fn novelty_no_overlap_returns_one_test() {
  let result = meta_states.compute_novelty("alpha beta", [["gamma", "delta"]])
  should.be_true(result >. 0.99)
}

pub fn novelty_partial_overlap_test() {
  // Input "hello world foo" → {hello, world, foo}
  // Entry ["hello", "bar"] → {hello, bar}
  // Jaccard = 1/4 = 0.25 → novelty = 0.75
  let result =
    meta_states.compute_novelty("hello world foo", [["hello", "bar"]])
  should.be_true(result >. 0.74)
  should.be_true(result <. 0.76)
}

pub fn novelty_uses_max_similarity_across_entries_test() {
  // Two entries: one distant, one close
  let result =
    meta_states.compute_novelty("hello world", [
      ["alpha", "beta"],
      ["hello", "world"],
    ])
  // Max similarity is from second entry (identical) → novelty = 0.0
  should.be_true(result <. 0.01)
}

pub fn novelty_empty_input_returns_one_test() {
  meta_states.compute_novelty("", [["hello", "world"]])
  |> should.equal(1.0)
}

// ---------------------------------------------------------------------------
// jaccard
// ---------------------------------------------------------------------------

pub fn jaccard_empty_sets_returns_zero_test() {
  let empty = set.new()
  meta_states.jaccard(empty, empty)
  |> should.equal(0.0)
}

pub fn jaccard_identical_sets_returns_one_test() {
  let s = set.from_list(["a", "b", "c"])
  meta_states.jaccard(s, s)
  |> should.equal(1.0)
}

pub fn jaccard_disjoint_sets_returns_zero_test() {
  let a = set.from_list(["a", "b"])
  let b = set.from_list(["c", "d"])
  meta_states.jaccard(a, b)
  |> should.equal(0.0)
}

pub fn jaccard_partial_overlap_test() {
  let a = set.from_list(["a", "b", "c"])
  let b = set.from_list(["b", "c", "d"])
  // intersection = {b, c} = 2, union = {a, b, c, d} = 4 → 0.5
  let result = meta_states.jaccard(a, b)
  should.be_true(result >. 0.49)
  should.be_true(result <. 0.51)
}

// ---------------------------------------------------------------------------
// tokenize
// ---------------------------------------------------------------------------

pub fn tokenize_simple_test() {
  let result = meta_states.tokenize("Hello World")
  set.size(result) |> should.equal(2)
  set.contains(result, "hello") |> should.be_true
  set.contains(result, "world") |> should.be_true
}

pub fn tokenize_empty_string_test() {
  let result = meta_states.tokenize("")
  set.size(result) |> should.equal(0)
}

pub fn tokenize_lowercases_test() {
  let result = meta_states.tokenize("FOO BAR")
  set.contains(result, "foo") |> should.be_true
  set.contains(result, "bar") |> should.be_true
}

// ---------------------------------------------------------------------------
// format_2dp
// ---------------------------------------------------------------------------

pub fn format_2dp_zero_test() {
  meta_states.format_2dp(0.0)
  |> should.equal("0.0")
}

pub fn format_2dp_one_test() {
  meta_states.format_2dp(1.0)
  |> should.equal("1.0")
}

pub fn format_2dp_truncates_test() {
  // 0.456 → floor(45.6) = 45.0 → 45.0 / 100.0 = 0.45
  let result = meta_states.format_2dp(0.456)
  should.equal(result, "0.45")
}

pub fn format_2dp_rounds_down_test() {
  // 0.999 → floor(99.9) = 99.0 → 99.0 / 100.0 = 0.99
  let result = meta_states.format_2dp(0.999)
  should.equal(result, "0.99")
}
