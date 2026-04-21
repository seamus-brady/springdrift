//// Voice drift monitor — counts self-congratulatory and identity-
//// narration phrases in narrative entries.
////
//// Phase 2 of the fluency/grounding separation spec. Produces an
//// integrity signal the agent sees in its own sensorium, prompting
//// learning-goal pressure when the voice starts narrating composure
//// and accountability as identity traits rather than monitoring them
//// as signals.
////
//// The metric is deliberately a trend (7-day delta), not a threshold.
//// A threshold invites regex overfitting; a delta asks "is the density
//// trending down?" which is harder to game and better-aligned with
//// the actual concern (drift, not absolute level).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/float
import gleam/int
import gleam/list
import gleam/string
import narrative/types as narrative_types

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Result of a single-window voice-drift count.
pub type VoiceDriftCount {
  VoiceDriftCount(
    /// Total narrative entries in the window.
    entries_examined: Int,
    /// Total phrase hits across all entries. One entry can contribute
    /// multiple hits if it uses several drift patterns.
    phrase_hits: Int,
    /// Phrase hits per entry. Zero when entries_examined is zero.
    density: Float,
  )
}

/// A two-window comparison. `delta` is `current.density - prior.density` —
/// negative means drift is decreasing, which is the desired direction.
pub type VoiceDriftResult {
  VoiceDriftResult(
    current: VoiceDriftCount,
    prior: VoiceDriftCount,
    delta: Float,
  )
}

// ---------------------------------------------------------------------------
// Default patterns
// ---------------------------------------------------------------------------

/// The baseline self-congratulatory / identity-narration phrase list.
/// Matched as lowercase substrings against the concatenation of summary,
/// assessment, and outcome text in each narrative entry.
///
/// These are the patterns that appeared in the April 20 transcript that
/// exposed the voice-drift issue: the agent reassuring itself about its
/// own stability, composure, and accountability, rather than reporting
/// the signals that produced those descriptions.
pub fn default_phrases() -> List(String) {
  // Deliberately non-overlapping — each pattern should flag a
  // distinct drift move. Overlapping patterns inflate the density
  // without signalling more drift, which biases the regex-is-a-target
  // failure mode the spec calls out.
  [
    "composure held",
    "stable place",
    "accountability structures",
    "accountability system",
    "i appreciate",
    "the cycle is working",
    "working as designed",
  ]
}

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------

/// Count phrase hits and entries in a single window.
pub fn count_in_window(
  entries: List(narrative_types.NarrativeEntry),
  phrases: List(String),
) -> VoiceDriftCount {
  let hits =
    list.fold(entries, 0, fn(total, entry) {
      total + count_entry(entry, phrases)
    })
  let n = list.length(entries)
  let density = case n {
    0 -> 0.0
    _ -> int.to_float(hits) /. int.to_float(n)
  }
  VoiceDriftCount(entries_examined: n, phrase_hits: hits, density: density)
}

/// Compare current to prior window. `current` is the more recent window.
pub fn compare(
  current_entries: List(narrative_types.NarrativeEntry),
  prior_entries: List(narrative_types.NarrativeEntry),
  phrases: List(String),
) -> VoiceDriftResult {
  let current = count_in_window(current_entries, phrases)
  let prior = count_in_window(prior_entries, phrases)
  VoiceDriftResult(
    current: current,
    prior: prior,
    delta: current.density -. prior.density,
  )
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn count_entry(
  entry: narrative_types.NarrativeEntry,
  phrases: List(String),
) -> Int {
  let haystack = entry_text(entry) |> string.lowercase
  list.fold(phrases, 0, fn(acc, phrase) {
    let p = string.lowercase(phrase)
    case string.contains(haystack, p) {
      True -> acc + 1
      False -> acc
    }
  })
}

fn entry_text(entry: narrative_types.NarrativeEntry) -> String {
  entry.summary <> " " <> entry.outcome.assessment
}

// ---------------------------------------------------------------------------
// Rendering helpers
// ---------------------------------------------------------------------------

/// Format density to two decimal places for report output.
pub fn format_density(d: Float) -> String {
  case d <. 0.005 && d >. -0.005 {
    True -> "0.00"
    False -> float.to_string(round_2dp(d))
  }
}

fn round_2dp(f: Float) -> Float {
  int.to_float(float.round(f *. 100.0)) /. 100.0
}
