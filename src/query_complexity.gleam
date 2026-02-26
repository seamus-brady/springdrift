//// Query complexity assessment for model routing.
////
//// Uses a fast task-class LLM call to decide whether a query needs the
//// reasoning model or the standard model. Falls back to heuristic rules
//// if the LLM call fails or returns an unrecognised response.

import app_log
import gleam/list
import gleam/string
import llm/provider.{type Provider}
import llm/request
import llm/response

pub type QueryComplexity {
  Simple
  Complex
}

const system_prompt = "Classify the user query as 'simple' or 'complex'.

Simple: direct question, single-step, factual lookup, greeting, arithmetic, yes/no.
Complex: multi-step reasoning, design, comparison, analysis, code generation, debugging, proof.

Reply with exactly one word: simple or complex."

// Internal type representing the parsed LLM classifier response.
type LlmClassification {
  LlmSimple
  LlmComplex
  LlmUnrecognised
}

/// Classify a query using a fast LLM call.
/// Falls back to heuristic classification if the call fails or the
/// response is unrecognised.
pub fn classify(query: String, p: Provider, model: String) -> QueryComplexity {
  let req =
    request.new(model, 10)
    |> request.with_system(system_prompt)
    |> request.with_user_message(query)
  case provider.chat_with(req, p) {
    Error(_) -> {
      app_log.warn("classification_fallback", [#("reason", "llm_error")])
      heuristic_classify(query)
    }
    Ok(resp) ->
      case parse_llm_response(response.text(resp)) {
        LlmSimple -> Simple
        LlmComplex -> Complex
        LlmUnrecognised -> {
          app_log.warn("classification_fallback", [
            #("reason", "unrecognised_response"),
          ])
          heuristic_classify(query)
        }
      }
  }
}

fn parse_llm_response(text: String) -> LlmClassification {
  let lower = string.lowercase(string.trim(text))
  case string.contains(lower, "complex") {
    True -> LlmComplex
    False ->
      case string.contains(lower, "simple") {
        True -> LlmSimple
        False -> LlmUnrecognised
      }
  }
}

// ---------------------------------------------------------------------------
// Heuristic fallback
// ---------------------------------------------------------------------------

fn heuristic_classify(query: String) -> QueryComplexity {
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
