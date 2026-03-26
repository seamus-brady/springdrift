//// Normative bridge — translates D' forecasts into normative propositions
//// and evaluates them against the character spec's highest endeavour.
////
//// No new LLM calls — operates purely on existing D' scorer output.
//// This is the integration point between the D' safety system and the
//// normative calculus.

import gleam/int
import gleam/list
import gleam/string
import normative/calculus
import normative/judgement
import normative/types.{
  type CharacterSpec, type FlourishingVerdict, type HarmContext,
  type NormativeJudgement, type NormativeLevel, type NormativeOperator,
  type NormativeProposition, Constrained, Flourishing, HarmContext, Indifferent,
  NormativeProposition, Ought, Possible, Prohibited, Required,
}

import dprime/types as dprime_types

/// Map a D' feature name to a normative level.
pub fn feature_to_level(name: String) -> NormativeLevel {
  case name {
    "harmful_content" -> types.EthicalMoral
    "harmful" -> types.EthicalMoral
    "accuracy" -> types.IntellectualHonesty
    "unsourced_claim" -> types.IntellectualHonesty
    "unsourced_claims" -> types.IntellectualHonesty
    "privacy_leak" -> types.PrivacyData
    "privacy" -> types.PrivacyData
    "certainty_overstatement" -> types.Transparency
    "causal_overreach" -> types.IntellectualHonesty
    "stale_data" -> types.IntellectualHonesty
    "manipulation" -> types.EthicalMoral
    "legal_risk" -> types.Legal
    "safety" -> types.SafetyPhysical
    _ -> types.Operational
  }
}

/// Map a D' forecast magnitude (0-3) to a normative operator.
pub fn magnitude_to_operator(magnitude: Int) -> NormativeOperator {
  case magnitude {
    0 | 1 -> Indifferent
    2 -> Ought
    _ -> Required
  }
}

/// Convert D' forecasts into user-side normative propositions.
pub fn forecasts_to_propositions(
  forecasts: List(dprime_types.Forecast),
  features: List(dprime_types.Feature),
) -> List(NormativeProposition) {
  list.filter_map(forecasts, fn(forecast) {
    // Only create NPs for non-zero magnitudes
    case forecast.magnitude > 0 {
      True -> {
        let level = feature_to_level(forecast.feature_name)
        let operator = magnitude_to_operator(forecast.magnitude)
        let description = case
          list.find(features, fn(f) { f.name == forecast.feature_name })
        {
          Ok(f) -> f.description
          Error(_) -> forecast.feature_name
        }
        Ok(NormativeProposition(
          level:,
          operator:,
          modality: Possible,
          description:,
        ))
      }
      False -> Error(Nil)
    }
  })
}

/// Build harm context from D' forecasts.
pub fn build_harm_context(
  forecasts: List(dprime_types.Forecast),
  features: List(dprime_types.Feature),
) -> HarmContext {
  let total_magnitude =
    list.fold(forecasts, 0, fn(acc, f) { acc + f.magnitude })
  let max_possible = list.length(forecasts) * 3
  let impact_score = case max_possible {
    0 -> 0.0
    _ -> int.to_float(total_magnitude) /. int.to_float(max_possible)
  }

  // Catastrophic when any critical feature has maximum magnitude
  let catastrophic =
    list.any(forecasts, fn(forecast) {
      forecast.magnitude >= 3
      && list.any(features, fn(f) {
        f.name == forecast.feature_name && f.critical
      })
    })

  HarmContext(impact_score:, catastrophic:)
}

/// Main entry point — evaluate output using the normative calculus.
///
/// Converts D' forecasts to user-side NPs, loads system-side NPs from
/// the character spec, resolves conflicts, and produces a judgement.
pub fn evaluate(
  dprime_score: Float,
  forecasts: List(dprime_types.Forecast),
  features: List(dprime_types.Feature),
  character_spec: CharacterSpec,
  modify_threshold: Float,
  reject_threshold: Float,
) -> NormativeJudgement {
  let user_nps = forecasts_to_propositions(forecasts, features)
  let system_nps = character_spec.highest_endeavour
  let conflicts = calculus.resolve_all(user_nps, system_nps)
  let harm_context = build_harm_context(forecasts, features)
  judgement.judge(
    conflicts,
    harm_context,
    dprime_score,
    modify_threshold,
    reject_threshold,
  )
}

/// Map a FlourishingVerdict to a D' GateDecision.
pub fn verdict_to_gate_decision(
  verdict: FlourishingVerdict,
) -> dprime_types.GateDecision {
  case verdict {
    Flourishing -> dprime_types.Accept
    Constrained -> dprime_types.Modify
    Prohibited -> dprime_types.Reject
  }
}

/// Format a normative judgement as a human-readable explanation string.
pub fn format_judgement(j: NormativeJudgement) -> String {
  let verdict_str = judgement.verdict_to_string(j.verdict)
  let trail_str = case j.axiom_trail {
    [] -> ""
    trail -> " [axioms: " <> string.join(trail, ", ") <> "]"
  }
  let conflict_count = list.length(j.conflicts)
  let non_trivial =
    list.count(j.conflicts, fn(c) { c.severity != types.NoConflict })

  "Normative verdict: "
  <> verdict_str
  <> " (rule: "
  <> j.floor_rule
  <> ", conflicts: "
  <> int.to_string(non_trivial)
  <> "/"
  <> int.to_string(conflict_count)
  <> ")"
  <> trail_str
}
