//// D' gate orchestrator — three-layer evaluation (reactive → deliberative → meta).
////
//// Single entry point `evaluate` runs the H-CogAff layers sequentially:
//// 1. Canary probes (if enabled) — hijack/leakage → immediate REJECT
//// 2. Reactive — critical features only; all-zero → fast ACCEPT
//// 3. Deliberative — full feature set; compute D' and gate
//// 4. Meta-management — stall detection may escalate MODIFY → REJECT

import dprime/canary
import dprime/engine
import dprime/meta
import dprime/scorer
import dprime/types.{
  type DprimeState, type GateResult, Accept, Deliberative, GateResult,
  MetaManagement, Modify, Reactive, Reject,
}
import gleam/option.{type Option, None, Some}
import llm/provider.{type Provider}

/// Evaluate an instruction through all three H-CogAff layers.
/// Returns a GateResult with the final decision, score, and layer info.
pub fn evaluate(
  instruction: String,
  context: String,
  state: DprimeState,
  provider: Provider,
  model: String,
) -> GateResult {
  // Layer 0: Canary probes (if enabled)
  case state.config.canary_enabled {
    True -> {
      let probe_result = canary.run_probes(instruction, provider, model)
      case probe_result.hijack_detected || probe_result.leakage_detected {
        True ->
          GateResult(
            decision: Reject,
            dprime_score: 1.0,
            forecasts: [],
            explanation: "Canary probe failed: " <> probe_result.details,
            layer: Reactive,
            canary_result: Some(probe_result),
          )
        False ->
          evaluate_reactive(
            instruction,
            context,
            state,
            provider,
            model,
            Some(probe_result),
          )
      }
    }
    False ->
      evaluate_reactive(instruction, context, state, provider, model, None)
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
) -> GateResult {
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
      )
    _ -> {
      let forecasts =
        scorer.score_features(instruction, context, critical, provider, model)
      case engine.all_zero(forecasts) {
        // Fast accept — no critical concerns
        True ->
          GateResult(
            decision: Accept,
            dprime_score: 0.0,
            forecasts:,
            explanation: "Fast accept: no critical feature discrepancies",
            layer: Reactive,
            canary_result:,
          )
        False -> {
          let score =
            engine.compute_dprime(forecasts, critical, state.config.tiers)
          case score >=. state.current_reject_threshold {
            True ->
              GateResult(
                decision: Reject,
                dprime_score: score,
                forecasts:,
                explanation: "Reactive reject: critical feature score exceeds threshold",
                layer: Reactive,
                canary_result:,
              )
            False ->
              // Critical features flagged but not rejected → full deliberative
              evaluate_deliberative(
                instruction,
                context,
                state,
                provider,
                model,
                canary_result,
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
) -> GateResult {
  let forecasts =
    scorer.score_features(
      instruction,
      context,
      state.config.features,
      provider,
      model,
    )
  let score =
    engine.compute_dprime(forecasts, state.config.features, state.config.tiers)
  let decision =
    engine.gate_decision(
      score,
      state.current_modify_threshold,
      state.current_reject_threshold,
    )

  // Layer 3: Meta-management — may escalate MODIFY → REJECT
  let final_decision = case decision {
    Modify -> {
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

  GateResult(
    decision: final_decision,
    dprime_score: score,
    forecasts:,
    explanation:,
    layer:,
    canary_result:,
  )
}
