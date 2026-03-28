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
import gleam/option.{None, Some}

/// Map importance level to numeric weight.
pub fn importance_weight(importance: types.Importance) -> Int {
  case importance {
    Low -> 1
    Medium -> 2
    High -> 3
  }
}

/// Compute the effective importance weight for a feature, accounting for
/// multi-tier hierarchies. For tier 1: base importance only. For tier 2:
/// base × feature_set_importance. For tier 3: base × set × group.
pub fn feature_importance(feature: Feature, tiers: Int) -> Int {
  let base = importance_weight(feature.importance)
  case tiers {
    1 -> base
    2 -> {
      let set_weight = case feature.feature_set_importance {
        Some(imp) -> importance_weight(imp)
        None -> 1
      }
      base * set_weight
    }
    _ -> {
      let set_weight = case feature.feature_set_importance {
        Some(imp) -> importance_weight(imp)
        None -> 1
      }
      let group_weight = case feature.group_importance {
        Some(imp) -> importance_weight(imp)
        None -> 1
      }
      base * set_weight * group_weight
    }
  }
}

/// Maximum possible D' score for a feature set.
/// sum(feature_importance_i * max_magnitude) where max_magnitude = 3.
/// This normalizes D' to true [0, 1] space.
pub fn max_possible_score(features: List(Feature), tiers: Int) -> Int {
  list.fold(features, 0, fn(acc, f) { acc + feature_importance(f, tiers) * 3 })
}

/// DEPRECATED: Legacy scaling unit — mathematically incorrect for non-symmetric
/// feature trees. Kept only for backward compatibility with existing tests.
/// Use max_possible_score() for correct normalization.
pub fn scaling_unit(tiers: Int) -> Int {
  pow3(tiers + 1)
}

/// Reactive scaling unit for critical features only:
/// num_critical × max_importance × max_magnitude.
pub fn reactive_scaling_unit(critical_features: List(Feature)) -> Int {
  let count = list.length(critical_features)
  count * 3 * 3
}

/// Compute D' score from forecasts, features, and tier count.
///
/// D' = sum(feature_importance(feature_i, tiers) * magnitude_i) / scaling_unit(tiers)
///
/// Features not found in forecasts are treated as magnitude 0.
/// Magnitudes are clamped to [0, 3].
pub fn compute_dprime(
  forecasts: List(Forecast),
  features: List(Feature),
  tiers: Int,
) -> Float {
  let max = max_possible_score(features, tiers)
  case max {
    0 -> 0.0
    _ -> {
      let sum =
        list.fold(features, 0, fn(acc, feature) {
          let magnitude = find_magnitude(forecasts, feature.name)
          acc + feature_importance(feature, tiers) * magnitude
        })
      int.to_float(sum) /. int.to_float(max)
    }
  }
}

/// Compute D' for reactive layer using critical features and reactive scaling.
pub fn compute_reactive_dprime(
  forecasts: List(Forecast),
  critical: List(Feature),
) -> Float {
  let unit = reactive_scaling_unit(critical)
  case unit {
    0 -> 0.0
    _ -> {
      let sum =
        list.fold(critical, 0, fn(acc, feature) {
          let magnitude = find_magnitude(forecasts, feature.name)
          acc + importance_weight(feature.importance) * magnitude
        })
      int.to_float(sum) /. int.to_float(unit)
    }
  }
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

fn find_magnitude(forecasts: List(Forecast), feature_name: String) -> Int {
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
