//// Meta-states — epistemic signals for ambient self-awareness.
////
//// Novelty measures how different the current input is from recent work.
//// Pure computation over keyword sets — no LLM calls needed.
////
//// Note: uncertainty and prediction_error were removed in favour of
//// history-backed PerformanceSummary signals (success_rate, cbr_hit_rate)
//// computed from narrative entries in curator.gleam. Those signals span
//// sessions and don't suffer from small-sample noise.

import gleam/float
import gleam/int
import gleam/list
import gleam/set
import gleam/string

/// Compute novelty: 1.0 minus max Jaccard similarity between input keywords
/// and each recent entry's keywords.
/// Returns 1.0 when recent_keywords_lists is empty.
/// Result clamped to [0.0, 1.0].
pub fn compute_novelty(
  input_text: String,
  recent_keywords_lists: List(List(String)),
) -> Float {
  let input_words = tokenize(input_text)
  case set.size(input_words) == 0 {
    True -> 1.0
    False -> {
      case recent_keywords_lists {
        [] -> 1.0
        entries -> {
          let max_sim =
            list.fold(entries, 0.0, fn(best, entry_keywords) {
              let entry_set =
                set.from_list(list.map(entry_keywords, string.lowercase))
              let sim = jaccard(input_words, entry_set)
              float.max(best, sim)
            })
          clamp(1.0 -. max_sim)
        }
      }
    }
  }
}

/// Jaccard similarity between two sets.
pub fn jaccard(a: set.Set(String), b: set.Set(String)) -> Float {
  let intersection_size = set.size(set.intersection(a, b))
  let union_size = set.size(set.union(a, b))
  case union_size > 0 {
    False -> 0.0
    True -> int.to_float(intersection_size) /. int.to_float(union_size)
  }
}

/// Tokenize text into a set of lowercase words (simple whitespace split).
pub fn tokenize(text: String) -> set.Set(String) {
  text
  |> string.lowercase
  |> string.split(" ")
  |> list.filter(fn(w) { w != "" })
  |> set.from_list
}

/// Format a float to 2 decimal places as a string.
pub fn format_2dp(value: Float) -> String {
  // Truncate to 2 decimal places: floor(value * 100) / 100
  let scaled = float.floor(value *. 100.0) /. 100.0
  float.to_string(scaled)
}

fn clamp(value: Float) -> Float {
  float.max(0.0, float.min(1.0, value))
}
