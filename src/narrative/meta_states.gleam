//// Meta-states — epistemic signals derived from session counters.
////
//// Three signals: uncertainty, prediction_error, and novelty.
//// All are pure computations over session counters or keyword sets.
//// No LLM calls needed.

import gleam/float
import gleam/int
import gleam/list
import gleam/set
import gleam/string

/// Compute uncertainty: proportion of recent cycles with no CBR hits.
/// Returns 0.0 when session_cycles == 0.
/// Result clamped to [0.0, 1.0].
pub fn compute_uncertainty(session_cycles: Int, session_cbr_hits: Int) -> Float {
  case session_cycles > 0 {
    False -> 0.0
    True -> {
      let hits = int.to_float(session_cbr_hits)
      let total = int.to_float(session_cycles)
      clamp(1.0 -. { hits /. total })
    }
  }
}

/// Compute prediction error: ratio of failures + D' interventions to total tool calls.
/// Returns 0.0 when session_tool_calls == 0.
/// Result clamped to [0.0, 1.0].
pub fn compute_prediction_error(
  session_tool_calls: Int,
  session_tool_failures: Int,
  session_dprime_modifications: Int,
  session_dprime_rejections: Int,
) -> Float {
  case session_tool_calls > 0 {
    False -> 0.0
    True -> {
      let errors =
        int.to_float(
          session_tool_failures
          + session_dprime_modifications
          + session_dprime_rejections,
        )
      let total = int.to_float(session_tool_calls)
      clamp(errors /. total)
    }
  }
}

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
