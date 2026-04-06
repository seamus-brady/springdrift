//// Layer 3b observer — evaluates meta-level patterns after each cycle.
////
//// Pure function (no OTP actor needed). Called from the cognitive loop
//// after each cycle completes. Takes current MetaState + observation,
//// runs detectors, determines intervention, updates state.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import meta/detectors
import meta/types.{
  type MetaIntervention, type MetaObservation, type MetaSignal, type MetaState,
  CumulativeRiskSignal, EscalateToUser, ForceCooldown, HighFalsePositiveSignal,
  InjectCaution, Layer3aPersistenceSignal, NoIntervention, RateLimitSignal,
  RepeatedRejectionSignal, TightenAllGates, VirtueDriftSignal,
}

/// Evaluate a new observation against the meta state.
/// Returns updated state with any pending intervention set.
pub fn observe(state: MetaState, obs: MetaObservation) -> MetaState {
  // Record the observation
  let state = types.record_observation(state, obs)

  // Update streaks
  let has_rejection = types.has_rejection(obs)
  let max_score = types.max_score(obs)
  let is_elevated = max_score >=. state.config.elevated_score_threshold

  let state =
    types.MetaState(
      ..state,
      rejection_streak: case has_rejection {
        True -> state.rejection_streak + 1
        False -> 0
      },
      elevated_score_streak: case is_elevated {
        True -> state.elevated_score_streak + 1
        False -> 0
      },
    )

  // Run all detectors
  let signals = detectors.run_all(state)

  // Determine intervention from signals (highest severity wins)
  let intervention = determine_intervention(signals, state)

  types.MetaState(
    ..state,
    last_signals: signals,
    pending_intervention: intervention,
  )
}

/// Map signals to the most appropriate intervention.
/// Priority: EscalateToUser > ForceCooldown > TightenAllGates > InjectCaution > NoIntervention
fn determine_intervention(
  signals: List(MetaSignal),
  state: MetaState,
) -> MetaIntervention {
  case list.length(signals) {
    0 -> NoIntervention
    _ -> {
      // Check for the most severe signals first
      let has_rate_limit =
        list.any(signals, fn(s) {
          case s {
            RateLimitSignal(..) -> True
            _ -> False
          }
        })
      let has_repeated_rejection =
        list.any(signals, fn(s) {
          case s {
            RepeatedRejectionSignal(..) -> True
            _ -> False
          }
        })
      let has_cumulative =
        list.any(signals, fn(s) {
          case s {
            CumulativeRiskSignal(..) -> True
            _ -> False
          }
        })
      let has_layer3a =
        list.any(signals, fn(s) {
          case s {
            Layer3aPersistenceSignal(..) -> True
            _ -> False
          }
        })
      let has_high_fp =
        list.any(signals, fn(s) {
          case s {
            HighFalsePositiveSignal(..) -> True
            _ -> False
          }
        })

      let has_virtue_drift =
        list.any(signals, fn(s) {
          case s {
            VirtueDriftSignal(..) -> True
            _ -> False
          }
        })

      // Priority: virtue drift / high FP > rate+rejection > rejection > cumulative/3a > rate > none
      case has_virtue_drift {
        True -> {
          let desc =
            list.find_map(signals, fn(s) {
              case s {
                VirtueDriftSignal(_, d) -> Ok(d)
                _ -> Error(Nil)
              }
            })
          let body = case desc {
            Ok(d) -> d
            Error(_) -> "Normative calculus drift detected"
          }
          EscalateToUser(
            title: "Normative calculus: virtue drift",
            body: body <> " — review character.json or D' thresholds.",
          )
        }
        False ->
          case has_high_fp {
            True ->
              EscalateToUser(
                title: "Meta observer: high false positive rate",
                body: "Multiple D' rejections have been flagged as false positives. Current thresholds may be too aggressive — consider reviewing dprime.json.",
              )
            False ->
              case has_rate_limit && has_repeated_rejection {
                True ->
                  EscalateToUser(
                    title: "Meta observer: safety concern",
                    body: "High cycle rate combined with repeated D' rejections. The agent may be stuck in a blocked loop.",
                  )
                False ->
                  case has_repeated_rejection {
                    True ->
                      ForceCooldown(delay_ms: state.config.cooldown_delay_ms)
                    False ->
                      case has_cumulative || has_layer3a {
                        True ->
                          TightenAllGates(factor: state.config.tighten_factor)
                        False ->
                          case has_rate_limit {
                            True ->
                              InjectCaution(
                                message: "Meta observer: high cycle rate detected. Consider whether current approach is productive.",
                              )
                            False -> NoIntervention
                          }
                      }
                  }
              }
          }
      }
    }
  }
}
