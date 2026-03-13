//// Query complexity assessment for model routing.
////
//// Uses a fast task-class LLM call to decide whether a query needs the
//// reasoning model or the standard model. Falls back to heuristic rules
//// if the LLM call fails or returns an unrecognised response.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import llm/provider.{type Provider}
import llm/request
import llm/response
import slog

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
/// `timeout_ms` — how long to wait for the LLM before falling back to heuristic.
pub fn classify(
  query: String,
  p: Provider,
  model: String,
  timeout_ms: Int,
) -> QueryComplexity {
  slog.debug(
    "query_complexity",
    "classify",
    "len=" <> int.to_string(string.length(query)),
    option.None,
  )
  let req =
    request.new(model, 10)
    |> request.with_system(system_prompt)
    |> request.with_user_message(query)

  // Run LLM call in a spawned process with a timeout to prevent hangs
  let reply_subj = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(reply_subj, provider.chat_with(req, p))
  })

  let result = case process.receive(reply_subj, timeout_ms) {
    Error(_) -> {
      slog.warn(
        "query_complexity",
        "classify",
        "LLM timeout — falling back to heuristic",
        option.None,
      )
      heuristic_classify(query)
    }
    Ok(Error(_)) -> heuristic_classify(query)
    Ok(Ok(resp)) ->
      case parse_llm_response(response.text(resp)) {
        LlmSimple -> Simple
        LlmComplex -> Complex
        LlmUnrecognised -> heuristic_classify(query)
      }
  }
  slog.info(
    "query_complexity",
    "classify",
    "result="
      <> case result {
      Simple -> "simple"
      Complex -> "complex"
    },
    option.None,
  )
  result
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
