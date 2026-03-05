import dprime/engine
import dprime/types.{
  Accept, Feature, Forecast, High, Low, Medium, Modify, Reject,
}
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// importance_weight
// ---------------------------------------------------------------------------

pub fn importance_weight_low_test() {
  engine.importance_weight(Low) |> should.equal(1)
}

pub fn importance_weight_medium_test() {
  engine.importance_weight(Medium) |> should.equal(2)
}

pub fn importance_weight_high_test() {
  engine.importance_weight(High) |> should.equal(3)
}

// ---------------------------------------------------------------------------
// scaling_unit
// ---------------------------------------------------------------------------

pub fn scaling_unit_1_tier_test() {
  engine.scaling_unit(1) |> should.equal(9)
}

pub fn scaling_unit_2_tier_test() {
  engine.scaling_unit(2) |> should.equal(27)
}

pub fn scaling_unit_3_tier_test() {
  engine.scaling_unit(3) |> should.equal(81)
}

// ---------------------------------------------------------------------------
// compute_dprime
// ---------------------------------------------------------------------------

pub fn dprime_all_zero_test() {
  let features = [
    Feature(name: "safety", importance: High, description: "", critical: True),
    Feature(
      name: "accuracy",
      importance: Medium,
      description: "",
      critical: False,
    ),
  ]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 0, rationale: ""),
    Forecast(feature_name: "accuracy", magnitude: 0, rationale: ""),
  ]
  engine.compute_dprime(forecasts, features, 1)
  |> should.equal(0.0)
}

pub fn dprime_single_high_at_max_test() {
  // Single High feature at magnitude 3 with 1 tier:
  // D' = (3 * 3) / 9 = 1.0
  let features = [
    Feature(name: "safety", importance: High, description: "", critical: True),
  ]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 3, rationale: ""),
  ]
  engine.compute_dprime(forecasts, features, 1)
  |> should.equal(1.0)
}

pub fn dprime_mixed_features_test() {
  // High (weight=3) at magnitude 2, Medium (weight=2) at magnitude 1
  // D' = (3*2 + 2*1) / 9 = 8/9 ≈ 0.889
  let features = [
    Feature(name: "safety", importance: High, description: "", critical: True),
    Feature(
      name: "accuracy",
      importance: Medium,
      description: "",
      critical: False,
    ),
  ]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 2, rationale: ""),
    Forecast(feature_name: "accuracy", magnitude: 1, rationale: ""),
  ]
  let score = engine.compute_dprime(forecasts, features, 1)
  // 8/9 ≈ 0.8889
  let diff = case score -. 0.8889 {
    d if d <. 0.0 -> 0.0 -. d
    d -> d
  }
  let assert True = diff <. 0.001
}

pub fn dprime_missing_forecast_treated_as_zero_test() {
  let features = [
    Feature(name: "safety", importance: High, description: "", critical: True),
    Feature(
      name: "accuracy",
      importance: Medium,
      description: "",
      critical: False,
    ),
  ]
  // Only safety forecast provided; accuracy defaults to 0
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 1, rationale: ""),
  ]
  // D' = (3*1 + 2*0) / 9 = 3/9 = 1/3 ≈ 0.333
  let score = engine.compute_dprime(forecasts, features, 1)
  // 3/9 ≈ 0.3333
  let diff = case score -. 0.3333 {
    d if d <. 0.0 -> 0.0 -. d
    d -> d
  }
  let assert True = diff <. 0.001
}

pub fn dprime_magnitude_clamped_to_max_test() {
  // Magnitude 5 should be clamped to max of 3
  let features = [
    Feature(name: "safety", importance: High, description: "", critical: True),
  ]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 5, rationale: ""),
  ]
  // D' = (3 * 3) / 9 = 1.0 (clamped from 5 to 3)
  let score = engine.compute_dprime(forecasts, features, 1)
  score |> should.equal(1.0)
}

pub fn dprime_2_tier_scaling_test() {
  // 2 tiers: scaling_unit = 27, magnitudes clamped to [0,3]
  let features = [
    Feature(name: "safety", importance: High, description: "", critical: True),
  ]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 2, rationale: ""),
  ]
  // D' = (3 * 2) / 27 = 6/27 ≈ 0.222
  let score = engine.compute_dprime(forecasts, features, 2)
  let diff = case score -. 0.2222 {
    d if d <. 0.0 -> 0.0 -. d
    d -> d
  }
  let assert True = diff <. 0.001
}

// ---------------------------------------------------------------------------
// gate_decision
// ---------------------------------------------------------------------------

pub fn gate_decision_accept_below_modify_test() {
  engine.gate_decision(0.1, 0.3, 0.7) |> should.equal(Accept)
}

pub fn gate_decision_modify_between_thresholds_test() {
  engine.gate_decision(0.5, 0.3, 0.7) |> should.equal(Modify)
}

pub fn gate_decision_reject_at_threshold_test() {
  engine.gate_decision(0.7, 0.3, 0.7) |> should.equal(Reject)
}

pub fn gate_decision_reject_above_threshold_test() {
  engine.gate_decision(0.9, 0.3, 0.7) |> should.equal(Reject)
}

pub fn gate_decision_accept_at_zero_test() {
  engine.gate_decision(0.0, 0.3, 0.7) |> should.equal(Accept)
}

pub fn gate_decision_modify_at_modify_threshold_test() {
  engine.gate_decision(0.3, 0.3, 0.7) |> should.equal(Modify)
}

// ---------------------------------------------------------------------------
// critical_features
// ---------------------------------------------------------------------------

pub fn critical_features_filters_correctly_test() {
  let features = [
    Feature(name: "safety", importance: High, description: "", critical: True),
    Feature(
      name: "accuracy",
      importance: Medium,
      description: "",
      critical: False,
    ),
    Feature(name: "privacy", importance: High, description: "", critical: True),
  ]
  let critical = engine.critical_features(features)
  critical
  |> should.equal([
    Feature(name: "safety", importance: High, description: "", critical: True),
    Feature(name: "privacy", importance: High, description: "", critical: True),
  ])
}

pub fn critical_features_empty_when_none_critical_test() {
  let features = [
    Feature(
      name: "accuracy",
      importance: Medium,
      description: "",
      critical: False,
    ),
  ]
  engine.critical_features(features) |> should.equal([])
}

// ---------------------------------------------------------------------------
// all_zero
// ---------------------------------------------------------------------------

pub fn all_zero_true_test() {
  let forecasts = [
    Forecast(feature_name: "a", magnitude: 0, rationale: ""),
    Forecast(feature_name: "b", magnitude: 0, rationale: ""),
  ]
  engine.all_zero(forecasts) |> should.be_true
}

pub fn all_zero_false_test() {
  let forecasts = [
    Forecast(feature_name: "a", magnitude: 0, rationale: ""),
    Forecast(feature_name: "b", magnitude: 1, rationale: ""),
  ]
  engine.all_zero(forecasts) |> should.be_false
}

pub fn all_zero_empty_list_test() {
  engine.all_zero([]) |> should.be_true
}
