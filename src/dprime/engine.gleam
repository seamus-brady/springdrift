//// Pure D' computation engine — no LLM calls, no I/O, fully unit-testable.
////
//// D' = sum(importance_i * magnitude_i) / scaling_unit
////
//// The scaling unit normalizes the score to [0, 1] for the maximum possible
//// discrepancy given the configured number of tiers.

import dprime/types.{
  type DprimeConfig, type Feature, type Forecast, type GateDecision, Accept,
  High, Low, Medium, Modify, Reject,
}
import gleam/int
import gleam/list

/// Map importance level to numeric weight.
pub fn importance_weight(importance: types.Importance) -> Int {
  case importance {
    Low -> 1
    Medium -> 2
    High -> 3
  }
}

/// Scaling unit: 3^(tiers+1).
/// For 1 tier: 9, 2 tiers: 27, 3 tiers: 81.
pub fn scaling_unit(tiers: Int) -> Int {
  pow3(tiers + 1)
}

/// Compute D' score from forecasts, features, and tier count.
///
/// D' = sum(importance_weight(feature_i) * magnitude_i) / scaling_unit(tiers)
///
/// Features not found in forecasts are treated as magnitude 0.
/// Magnitudes are clamped to [0, tiers].
pub fn compute_dprime(
  forecasts: List(Forecast),
  features: List(Feature),
  tiers: Int,
) -> Float {
  let unit = scaling_unit(tiers)
  let sum =
    list.fold(features, 0, fn(acc, feature) {
      let magnitude = find_magnitude(forecasts, feature.name, tiers)
      acc + importance_weight(feature.importance) * magnitude
    })
  int.to_float(sum) /. int.to_float(unit)
}

/// Determine gate decision from D' score and thresholds.
pub fn gate_decision(
  score: Float,
  modify_threshold: Float,
  reject_threshold: Float,
) -> GateDecision {
  case score >=. reject_threshold {
    True -> Reject
    False ->
      case score >=. modify_threshold {
        True -> Modify
        False -> Accept
      }
  }
}

/// Filter features to only critical ones.
pub fn critical_features(features: List(Feature)) -> List(Feature) {
  list.filter(features, fn(f) { f.critical })
}

/// Check if all forecasts have magnitude 0.
pub fn all_zero(forecasts: List(Forecast)) -> Bool {
  list.all(forecasts, fn(f) { f.magnitude == 0 })
}

/// Quick D' check using only a subset of features (for reactive layer).
pub fn compute_dprime_for_features(
  forecasts: List(Forecast),
  features: List(Feature),
  config: DprimeConfig,
) -> Float {
  compute_dprime(forecasts, features, config.tiers)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn find_magnitude(
  forecasts: List(Forecast),
  feature_name: String,
  _tiers: Int,
) -> Int {
  case list.find(forecasts, fn(f) { f.feature_name == feature_name }) {
    Ok(forecast) -> clamp(forecast.magnitude, 0, 3)
    Error(_) -> 0
  }
}

fn clamp(value: Int, min: Int, max: Int) -> Int {
  int.min(max, int.max(min, value))
}

fn pow3(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 3 * pow3(n - 1)
  }
}
