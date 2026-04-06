//// D' output gate — quality evaluation for finished reports/outputs.
////
//// Evaluates completed text against output-specific quality features
//// (e.g. unsourced claims, causal overreach, stale data, certainty overstatement).
//// Uses the same D' scoring infrastructure but with output-focused prompts.
////
//// When normative calculus is enabled, the gate applies virtue-based evaluation
//// after D' scoring — mapping forecasts to normative propositions and resolving
//// conflicts against the character spec's highest endeavour.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

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
import normative/bridge as normative_bridge
import normative/judgement as normative_judgement
import normative/types as normative_types
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
    None,
    False,
  )
}

/// Evaluate with an optional deterministic pre-filter for output.
/// When `normative_enabled` is True and `character_spec` is Some, applies
/// virtue-based normative evaluation after D' scoring.
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
  character_spec: Option(normative_types.CharacterSpec),
  normative_enabled: Bool,
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
        character_spec,
        normative_enabled,
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
  character_spec: Option(normative_types.CharacterSpec),
  normative_enabled: Bool,
) -> GateResult {
  slog.info(
    "dprime/output_gate",
    "evaluate",
    "Evaluating output quality ("
      <> int.to_string(list.length(state.config.features))
      <> " features"
      <> case normative_enabled {
      True -> ", normative calculus enabled"
      False -> ""
    }
      <> ")",
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

  // Branch: normative calculus or plain D' threshold comparison
  case normative_enabled, character_spec {
    True, Some(spec) ->
      evaluate_normative(
        forecasts,
        state.config.features,
        score,
        state.current_modify_threshold,
        state.current_reject_threshold,
        spec,
        cycle_id,
      )
    _, _ ->
      evaluate_threshold(
        forecasts,
        state.config.features,
        score,
        state.current_modify_threshold,
        state.current_reject_threshold,
        cycle_id,
      )
  }
}

/// Threshold-based evaluation (existing behaviour, unchanged).
fn evaluate_threshold(
  forecasts: List(Forecast),
  features: List(Feature),
  score: Float,
  modify_threshold: Float,
  reject_threshold: Float,
  cycle_id: String,
) -> GateResult {
  let decision = engine.gate_decision(score, modify_threshold, reject_threshold)

  let explanation = case decision {
    Accept -> "Output quality acceptable"
    Modify -> build_modification_explanation(forecasts, features)
    Reject -> build_rejection_explanation(forecasts, features)
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

/// Normative calculus evaluation — maps D' forecasts to normative propositions,
/// resolves conflicts against the character spec, and produces a verdict with
/// axiom trail.
fn evaluate_normative(
  forecasts: List(Forecast),
  features: List(Feature),
  score: Float,
  modify_threshold: Float,
  reject_threshold: Float,
  character_spec: normative_types.CharacterSpec,
  cycle_id: String,
) -> GateResult {
  let judgement =
    normative_bridge.evaluate(
      score,
      forecasts,
      features,
      character_spec,
      modify_threshold,
      reject_threshold,
    )

  let decision = normative_bridge.verdict_to_gate_decision(judgement.verdict)
  let normative_explanation = normative_bridge.format_judgement(judgement)

  // Combine normative explanation with concern details when not flourishing
  let explanation = case decision {
    Accept -> normative_explanation
    Modify -> {
      let concerns = build_modification_explanation(forecasts, features)
      normative_explanation <> " — " <> concerns
    }
    Reject -> {
      let concerns = build_rejection_explanation(forecasts, features)
      normative_explanation <> " — " <> concerns
    }
  }

  cycle_log.log_dprime_layer(
    cycle_id,
    "output_gate_normative",
    decision_to_string(decision),
    score,
    explanation,
  )

  slog.info(
    "dprime/output_gate",
    "evaluate",
    "Normative output gate: "
      <> normative_judgement.verdict_to_string(judgement.verdict)
      <> " (D' = "
      <> float.to_string(score)
      <> ", rule: "
      <> judgement.floor_rule
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

  "Evaluate this completed report against quality standards.\n"
  <> "For each standard, rate the magnitude of any quality issue on this scale:\n"
  <> "  0 = No issue. The report fully meets this standard.\n"
  <> "  1 = Minor issue. Small quality gap that could be improved.\n"
  <> "  2 = Moderate issue. Meaningful quality gap that should be addressed.\n"
  <> "  3 = Severe issue. The report fundamentally fails this standard.\n"
  <> "\n"
  <> "IMPORTANT RULES:\n"
  <> "- Default to 0 unless there is a clear, specific problem.\n"
  <> "- A standard that does not apply to this response scores 0.\n"
  <> "- Short or conversational responses (greetings, acknowledgments, status updates) score 0 on all standards — they are not reports.\n"
  <> "- Research output that names sources, cites URLs, or attributes claims to specific publications is sourced. You cannot verify URLs exist, but named attribution counts as sourced.\n"
  <> "- Research gathered by the agent's researcher tool and synthesised into a response is sourced work, even without inline URLs.\n"
  <> "- Only score unsourced_claim when a factual assertion has NO attribution whatsoever.\n"
  <> "- Only score accuracy when content is internally contradictory or logically impossible.\n"
  <> "- A score of 3 means a clear, unambiguous quality failure — not a gap or omission.\n"
  <> "\n"
  <> "ORIGINAL QUERY: "
  <> original_query
  <> "\n\n"
  <> "QUALITY STANDARDS TO EVALUATE:\n"
  <> features_text
  <> "\n\n"
  <> "COMPLETED REPORT (evaluate this):\n"
  <> string.slice(report_text, 0, 6000)
  <> case string.length(report_text) > 6000 {
    True ->
      "\n[... report truncated for scoring — "
      <> int.to_string(string.length(report_text))
      <> " chars total]"
    False -> ""
  }
  <> "\n\n"
  <> "NOW EVALUATE each standard:"
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
  // Use score_with_custom_prompt to avoid double-wrapping the output prompt.
  // The output gate builds its own domain-specific prompt with the full report
  // text — passing it through score_features would embed it twice in a generic
  // scoring wrapper, inflating the token count and confusing the LLM.
  scorer.score_with_custom_prompt(
    prompt,
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
