//// D' gate orchestrator — three-layer evaluation (reactive → deliberative → meta).
////
//// Single entry point `evaluate` runs the H-CogAff layers sequentially:
//// 1. Canary probes (if enabled) — hijack/leakage → immediate REJECT
//// 2. Reactive — critical features only; all-zero → fast ACCEPT
//// 3. Deliberative — full feature set; compute D' and gate
//// 4. Meta-management — stall detection may escalate MODIFY → REJECT

import cycle_log
import dprime/canary
import dprime/engine
import dprime/meta
import dprime/scorer
import dprime/types.{
  type DprimeState, type GateResult, Accept, Deliberative, GateResult,
  MetaManagement, Modify, Reactive, Reject,
}
import gleam/float
import gleam/list
import gleam/option.{type Option, None, Some}
import llm/provider.{type Provider}
import slog

/// Evaluate an instruction through all three H-CogAff layers.
/// Returns a GateResult with the final decision, score, and layer info.
pub fn evaluate(
  instruction: String,
  context: String,
  state: DprimeState,
  provider: Provider,
  model: String,
  cycle_id: String,
  verbose: Bool,
) -> GateResult {
  slog.info(
    "dprime/gate",
    "evaluate",
    "Starting D' safety evaluation",
    Some(cycle_id),
  )
  // Layer 0: Canary probes (if enabled)
  case state.config.canary_enabled {
    True -> {
      slog.debug(
        "dprime/gate",
        "evaluate",
        "Running canary probes",
        Some(cycle_id),
      )
      let probe_result =
        canary.run_probes(instruction, provider, model, cycle_id, verbose)
      cycle_log.log_dprime_canary(
        cycle_id,
        probe_result.hijack_detected,
        probe_result.leakage_detected,
        probe_result.details,
      )
      case probe_result.hijack_detected || probe_result.leakage_detected {
        True -> {
          slog.warn(
            "dprime/gate",
            "evaluate",
            "Canary probe FAILED: " <> probe_result.details,
            Some(cycle_id),
          )
          cycle_log.log_dprime_layer(
            cycle_id,
            "reactive",
            "reject",
            1.0,
            "Canary probe failed: " <> probe_result.details,
          )
          GateResult(
            decision: Reject,
            dprime_score: 1.0,
            forecasts: [],
            explanation: "Canary probe failed: " <> probe_result.details,
            layer: Reactive,
            canary_result: Some(probe_result),
          )
        }
        False ->
          evaluate_reactive(
            instruction,
            context,
            state,
            provider,
            model,
            Some(probe_result),
            cycle_id,
            verbose,
          )
      }
    }
    False ->
      evaluate_reactive(
        instruction,
        context,
        state,
        provider,
        model,
        None,
        cycle_id,
        verbose,
      )
  }
}

// ---------------------------------------------------------------------------
// Layer 1: Reactive — critical features only
// ---------------------------------------------------------------------------

fn evaluate_reactive(
  instruction: String,
  context: String,
  state: DprimeState,
  provider: Provider,
  model: String,
  canary_result: Option(types.ProbeResult),
  cycle_id: String,
  verbose: Bool,
) -> GateResult {
  slog.debug(
    "dprime/gate",
    "evaluate_reactive",
    "Layer 1: reactive evaluation",
    Some(cycle_id),
  )
  let critical = engine.critical_features(state.config.features)
  case critical {
    // No critical features → skip to deliberative
    [] ->
      evaluate_deliberative(
        instruction,
        context,
        state,
        provider,
        model,
        canary_result,
        cycle_id,
        verbose,
      )
    _ -> {
      let forecasts =
        scorer.score_features(
          instruction,
          context,
          critical,
          provider,
          model,
          cycle_id,
          verbose,
        )
      case engine.all_zero(forecasts) {
        // Fast accept — no critical concerns
        True -> {
          slog.info(
            "dprime/gate",
            "evaluate_reactive",
            "Fast ACCEPT: no critical discrepancies",
            Some(cycle_id),
          )
          cycle_log.log_dprime_layer(
            cycle_id,
            "reactive",
            "accept",
            0.0,
            "Fast accept: no critical feature discrepancies",
          )
          GateResult(
            decision: Accept,
            dprime_score: 0.0,
            forecasts:,
            explanation: "Fast accept: no critical feature discrepancies",
            layer: Reactive,
            canary_result:,
          )
        }
        False -> {
          let score =
            engine.compute_dprime(forecasts, critical, state.config.tiers)
          case score >=. state.current_reject_threshold {
            True -> {
              cycle_log.log_dprime_layer(
                cycle_id,
                "reactive",
                "reject",
                score,
                "Reactive reject: critical feature score exceeds threshold",
              )
              GateResult(
                decision: Reject,
                dprime_score: score,
                forecasts:,
                explanation: "Reactive reject: critical feature score exceeds threshold",
                layer: Reactive,
                canary_result:,
              )
            }
            False ->
              // Critical features flagged but not rejected → full deliberative
              evaluate_deliberative(
                instruction,
                context,
                state,
                provider,
                model,
                canary_result,
                cycle_id,
                verbose,
              )
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Layer 2: Deliberative — all features
// ---------------------------------------------------------------------------

fn evaluate_deliberative(
  instruction: String,
  context: String,
  state: DprimeState,
  provider: Provider,
  model: String,
  canary_result: Option(types.ProbeResult),
  cycle_id: String,
  verbose: Bool,
) -> GateResult {
  slog.debug(
    "dprime/gate",
    "evaluate_deliberative",
    "Layer 2: deliberative evaluation",
    Some(cycle_id),
  )
  let forecasts =
    scorer.score_features(
      instruction,
      context,
      state.config.features,
      provider,
      model,
      cycle_id,
      verbose,
    )
  let score =
    engine.compute_dprime(forecasts, state.config.features, state.config.tiers)
  slog.info(
    "dprime/gate",
    "evaluate_deliberative",
    "D' score: " <> float.to_string(score),
    Some(cycle_id),
  )
  let decision =
    engine.gate_decision(
      score,
      state.current_modify_threshold,
      state.current_reject_threshold,
    )

  // Layer 3: Meta-management — may escalate MODIFY → REJECT
  let final_decision = case decision {
    Modify -> {
      slog.debug(
        "dprime/gate",
        "evaluate_deliberative",
        "Checking meta-management for MODIFY escalation",
        Some(cycle_id),
      )
      let escalated = meta.maybe_escalate(state, decision)
      escalated
    }
    other -> other
  }

  let layer = case final_decision == decision {
    True -> Deliberative
    False -> MetaManagement
  }

  let explanation = case final_decision {
    Accept -> "Deliberative accept: D' score below modify threshold"
    Modify -> "Deliberative modify: D' score between thresholds"
    Reject ->
      case layer {
        MetaManagement ->
          "Meta-management escalation: stall detected, MODIFY escalated to REJECT"
        _ -> "Deliberative reject: D' score exceeds reject threshold"
      }
  }

  // Log meta-management check when decision was Modify
  case decision {
    Modify -> {
      let stall_detected = final_decision != decision
      let original_str = decision_to_string(decision)
      let final_str = decision_to_string(final_decision)
      cycle_log.log_dprime_meta_stall(
        cycle_id,
        stall_detected,
        list.length(state.history),
        original_str,
        final_str,
      )
    }
    _ -> Nil
  }

  // Log the layer decision
  let layer_str = case layer {
    Deliberative -> "deliberative"
    MetaManagement -> "meta_management"
    Reactive -> "reactive"
  }
  cycle_log.log_dprime_layer(
    cycle_id,
    layer_str,
    decision_to_string(final_decision),
    score,
    explanation,
  )

  slog.info(
    "dprime/gate",
    "evaluate_deliberative",
    "Final decision: "
      <> decision_to_string(final_decision)
      <> " (layer: "
      <> layer_str
      <> ", score: "
      <> float.to_string(score)
      <> ")",
    Some(cycle_id),
  )

  GateResult(
    decision: final_decision,
    dprime_score: score,
    forecasts:,
    explanation:,
    layer:,
    canary_result:,
  )
}

fn decision_to_string(decision: types.GateDecision) -> String {
  case decision {
    Accept -> "accept"
    Modify -> "modify"
    Reject -> "reject"
  }
}
