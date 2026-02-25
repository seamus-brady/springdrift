//// Heuristic query classifier — zero latency, no LLM call.
////
//// Rules (any one → Complex):
////   - Query length > 200 characters
////   - Contains a complexity keyword (case-insensitive)
////   - More than one question mark
////   - Contains a numbered-list marker ("1." or "1)")

import gleam/list
import gleam/string

pub type QueryComplexity {
  Simple
  Complex
}

/// Classify a query string as Simple or Complex using heuristics.
pub fn classify(query: String) -> QueryComplexity {
  let lower = string.lowercase(query)
  case
    string.length(query) > 200
    || has_complexity_keyword(lower)
    || has_multiple_questions(lower)
    || has_numbered_list(lower)
  {
    True -> Complex
    False -> Simple
  }
}

fn has_complexity_keyword(lower: String) -> Bool {
  list.any(complexity_keywords(), fn(kw) { string.contains(lower, kw) })
}

fn complexity_keywords() -> List(String) {
  [
    "explain", "compare", "analyze", "analyse", "design", "implement",
    "architecture", "trade-off", "trade off", "pros and cons", "step by step",
    "comprehensive", "in-depth", "in depth", "write a", "create a", "build a",
    "derive", "prove", "evaluate", "assess", "refactor", "debug", "optimize",
  ]
}

fn has_multiple_questions(lower: String) -> Bool {
  list.length(string.split(lower, "?")) > 2
}

fn has_numbered_list(lower: String) -> Bool {
  string.contains(lower, "1.") || string.contains(lower, "1)")
}
