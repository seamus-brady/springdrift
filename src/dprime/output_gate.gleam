//// D' output gate — quality evaluation for finished reports/outputs.
////
//// Evaluates completed text against output-specific quality features
//// (e.g. unsourced claims, causal overreach, stale data, certainty overstatement).
//// Uses the same D' scoring infrastructure but with output-focused prompts.

import cycle_log
import dprime/deterministic.{type DeterministicConfig, Blocked, Escalated, Pass}
import dprime/engine
import dprime/scorer
import dprime/types.{
  type DprimeState, type Feature, type Forecast, type GateResult, Accept,
  Deliberative, GateResult, Modify, Reactive, Reject,
}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider}
import slog

/// Evaluate a completed report/output against output quality features.
/// Returns a GateResult with Accept/Modify/Reject decision.
pub fn evaluate(
  report_text: String,
  original_query: String,
  state: DprimeState,
  provider: Provider,
  model: String,
  cycle_id: String,
  verbose: Bool,
  redact: Bool,
) -> GateResult {
  evaluate_with_deterministic(
    report_text,
    original_query,
    state,
    provider,
    model,
    cycle_id,
    verbose,
    redact,
    None,
  )
}

/// Evaluate with an optional deterministic pre-filter for output.
pub fn evaluate_with_deterministic(
  report_text: String,
  original_query: String,
  state: DprimeState,
  provider: Provider,
  model: String,
  cycle_id: String,
  verbose: Bool,
  redact: Bool,
  det_config: Option(DeterministicConfig),
) -> GateResult {
  // Deterministic pre-filter for output
  let det_blocked = case det_config {
    Some(dc) -> {
      let det_result = deterministic.check_output(report_text, dc)
      case det_result {
        Blocked(rule_id, _reason) -> {
          slog.warn(
            "dprime/output_gate",
            "evaluate",
            "Deterministic block: rule " <> rule_id,
            Some(cycle_id),
          )
          cycle_log.log_dprime_layer(
            cycle_id,
            "deterministic_output",
            "reject",
            1.0,
            "Deterministic block: banned output pattern detected",
          )
          True
        }
        Escalated(_rule_id, _det_context) -> {
          slog.info(
            "dprime/output_gate",
            "evaluate",
            "Deterministic escalation on output, continuing with LLM gate",
            Some(cycle_id),
          )
          False
        }
        Pass -> False
      }
    }
    None -> False
  }

  case det_blocked {
    True ->
      GateResult(
        decision: Reject,
        dprime_score: 1.0,
        forecasts: [],
        explanation: "Deterministic block: banned output pattern detected",
        layer: Reactive,
        canary_result: None,
      )
    False ->
      evaluate_llm(
        report_text,
        original_query,
        state,
        provider,
        model,
        cycle_id,
        verbose,
        redact,
      )
  }
}

/// Run the LLM-based output quality evaluation.
fn evaluate_llm(
  report_text: String,
  original_query: String,
  state: DprimeState,
  provider: Provider,
  model: String,
  cycle_id: String,
  verbose: Bool,
  redact: Bool,
) -> GateResult {
  slog.info(
    "dprime/output_gate",
    "evaluate",
    "Evaluating output quality ("
      <> int.to_string(list.length(state.config.features))
      <> " features)",
    Some(cycle_id),
  )

  let prompt =
    build_output_scoring_prompt(
      report_text,
      original_query,
      state.config.features,
    )
  let forecasts =
    score_output(
      prompt,
      state.config.features,
      provider,
      model,
      cycle_id,
      verbose,
      redact,
    )

  let score =
    engine.compute_dprime(forecasts, state.config.features, state.config.tiers)
  let decision =
    engine.gate_decision(
      score,
      state.current_modify_threshold,
      state.current_reject_threshold,
    )

  let explanation = case decision {
    Accept -> "Output quality acceptable"
    Modify -> build_modification_explanation(forecasts, state.config.features)
    Reject -> build_rejection_explanation(forecasts, state.config.features)
  }

  cycle_log.log_dprime_layer(
    cycle_id,
    "output_gate",
    decision_to_string(decision),
    score,
    explanation,
  )

  slog.info(
    "dprime/output_gate",
    "evaluate",
    "Output gate decision: "
      <> decision_to_string(decision)
      <> " (D' = "
      <> float.to_string(score)
      <> ")",
    Some(cycle_id),
  )

  GateResult(
    decision:,
    dprime_score: score,
    forecasts:,
    explanation:,
    layer: Deliberative,
    canary_result: option.None,
  )
}

// ---------------------------------------------------------------------------
// Output-specific scoring prompt
// ---------------------------------------------------------------------------

fn build_output_scoring_prompt(
  report_text: String,
  original_query: String,
  features: List(Feature),
) -> String {
  let features_text =
    list.map(features, fn(f) { "- " <> f.name <> ": " <> f.description })
    |> string.join("\n")

  "You are a report quality evaluator. You will be given a completed report and the original query that produced it.\n"
  <> "For each quality standard, rate the magnitude of any quality issue on this scale:\n"
  <> "  0 = No issue. The report fully meets this standard.\n"
  <> "  1 = Minor issue. Small quality gap that could be improved.\n"
  <> "  2 = Moderate issue. Meaningful quality gap that should be addressed.\n"
  <> "  3 = Severe issue. The report fundamentally fails this standard.\n"
  <> "\n"
  <> "IMPORTANT RULES:\n"
  <> "- Evaluate each standard independently.\n"
  <> "- Focus on what is actually present in the report text, not hypotheticals.\n"
  <> "- A score of 0 means genuinely no concern.\n"
  <> "- A score of 3 means a clear, significant quality failure.\n"
  <> "- Respond with ONLY a JSON array of objects with \"feature\", \"magnitude\", and \"rationale\" fields.\n"
  <> "\n"
  <> "ORIGINAL QUERY: "
  <> original_query
  <> "\n\n"
  <> "COMPLETED REPORT:\n"
  <> report_text
  <> "\n\n"
  <> "QUALITY STANDARDS TO EVALUATE:\n"
  <> features_text
  <> "\n\n"
  <> "NOW EVALUATE the report against each standard:"
}

fn score_output(
  prompt: String,
  features: List(Feature),
  provider: Provider,
  model: String,
  cycle_id: String,
  verbose: Bool,
  _redact: Bool,
) -> List(Forecast) {
  // Use the same XStructor-based scoring as the input/tool gates.
  // The prompt contains the report text and quality standards.
  scorer.score_features(
    prompt,
    "",
    features,
    provider,
    model,
    cycle_id,
    verbose,
  )
}

// ---------------------------------------------------------------------------
// Explanation builders
// ---------------------------------------------------------------------------

fn build_modification_explanation(
  forecasts: List(Forecast),
  features: List(Feature),
) -> String {
  let concerns = flagged_concerns(forecasts, features)
  case concerns {
    [] -> "Minor quality concerns detected"
    _ -> "Quality issues: " <> string.join(concerns, "; ")
  }
}

fn build_rejection_explanation(
  forecasts: List(Forecast),
  features: List(Feature),
) -> String {
  let concerns = flagged_concerns(forecasts, features)
  case concerns {
    [] -> "Severe quality issues detected"
    _ -> "Report rejected — " <> string.join(concerns, "; ")
  }
}

fn flagged_concerns(
  forecasts: List(Forecast),
  features: List(Feature),
) -> List(String) {
  list.filter_map(forecasts, fn(f) {
    case f.magnitude >= 2 {
      True ->
        case list.find(features, fn(feat) { feat.name == f.feature_name }) {
          Ok(feat) -> Ok(feat.name <> ": " <> f.rationale)
          Error(_) -> Ok(f.feature_name <> ": " <> f.rationale)
        }
      False -> Error(Nil)
    }
  })
}

fn decision_to_string(decision: types.GateDecision) -> String {
  case decision {
    Accept -> "accept"
    Modify -> "modify"
    Reject -> "reject"
  }
}
