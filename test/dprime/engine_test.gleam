// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/engine
import dprime/types.{
  type Feature, Accept, Feature, Forecast, High, Low, Medium, Modify, Reject,
}
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

fn feature(name: String, importance, critical: Bool) -> Feature {
  Feature(
    name:,
    importance:,
    description: "",
    critical:,
    feature_set: None,
    feature_set_importance: None,
    group: None,
    group_importance: None,
  )
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
// feature_importance (multi-tier)
// ---------------------------------------------------------------------------

pub fn feature_importance_1_tier_test() {
  let f = feature("safety", High, True)
  engine.feature_importance(f, 1) |> should.equal(3)
}

pub fn feature_importance_2_tier_test() {
  let f =
    Feature(
      ..feature("safety", High, True),
      feature_set: Some("core"),
      feature_set_importance: Some(Medium),
    )
  // High(3) × Medium(2) = 6
  engine.feature_importance(f, 2) |> should.equal(6)
}

pub fn feature_importance_3_tier_test() {
  let f =
    Feature(
      ..feature("safety", High, True),
      feature_set: Some("core"),
      feature_set_importance: Some(Medium),
      group: Some("stakeholder_a"),
      group_importance: Some(Low),
    )
  // High(3) × Medium(2) × Low(1) = 6
  engine.feature_importance(f, 3) |> should.equal(6)
}

pub fn feature_importance_3_tier_all_high_test() {
  let f =
    Feature(
      ..feature("safety", High, True),
      feature_set: Some("core"),
      feature_set_importance: Some(High),
      group: Some("stakeholder_a"),
      group_importance: Some(High),
    )
  // High(3) × High(3) × High(3) = 27
  engine.feature_importance(f, 3) |> should.equal(27)
}

pub fn feature_importance_2_tier_no_set_importance_test() {
  // Missing feature_set_importance defaults to weight 1
  let f = Feature(..feature("safety", Medium, False), feature_set: Some("misc"))
  engine.feature_importance(f, 2) |> should.equal(2)
}

// ---------------------------------------------------------------------------
// reactive_scaling_unit
// ---------------------------------------------------------------------------

pub fn reactive_scaling_unit_test() {
  let critical = [
    feature("safety", High, True),
    feature("privacy", High, True),
  ]
  // 2 features × 3 × 3 = 18
  engine.reactive_scaling_unit(critical) |> should.equal(18)
}

pub fn reactive_scaling_unit_empty_test() {
  engine.reactive_scaling_unit([]) |> should.equal(0)
}

// ---------------------------------------------------------------------------
// compute_dprime
// ---------------------------------------------------------------------------

pub fn dprime_all_zero_test() {
  let features = [
    feature("safety", High, True),
    feature("accuracy", Medium, False),
  ]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 0, rationale: ""),
    Forecast(feature_name: "accuracy", magnitude: 0, rationale: ""),
  ]
  engine.compute_dprime(forecasts, features, 1)
  |> should.equal(0.0)
}

pub fn dprime_single_high_at_max_test() {
  let features = [feature("safety", High, True)]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 3, rationale: ""),
  ]
  engine.compute_dprime(forecasts, features, 1)
  |> should.equal(1.0)
}

pub fn dprime_mixed_features_test() {
  let features = [
    feature("safety", High, True),
    feature("accuracy", Medium, False),
  ]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 2, rationale: ""),
    Forecast(feature_name: "accuracy", magnitude: 1, rationale: ""),
  ]
  let score = engine.compute_dprime(forecasts, features, 1)
  // sum = 3*2 + 2*1 = 8, max = 3*3 + 2*3 = 15, D' = 8/15 = 0.5333
  let diff = case score -. 0.5333 {
    d if d <. 0.0 -> 0.0 -. d
    d -> d
  }
  let assert True = diff <. 0.001
}

pub fn dprime_missing_forecast_treated_as_zero_test() {
  let features = [
    feature("safety", High, True),
    feature("accuracy", Medium, False),
  ]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 1, rationale: ""),
  ]
  let score = engine.compute_dprime(forecasts, features, 1)
  // sum = 3*1 + 2*0 = 3, max = 3*3 + 2*3 = 15, D' = 3/15 = 0.2
  let diff = case score -. 0.2 {
    d if d <. 0.0 -> 0.0 -. d
    d -> d
  }
  let assert True = diff <. 0.001
}

pub fn dprime_magnitude_clamped_to_max_test() {
  let features = [feature("safety", High, True)]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 5, rationale: ""),
  ]
  let score = engine.compute_dprime(forecasts, features, 1)
  score |> should.equal(1.0)
}

pub fn dprime_2_tier_scaling_test() {
  let features = [feature("safety", High, True)]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 2, rationale: ""),
  ]
  let score = engine.compute_dprime(forecasts, features, 2)
  // importance = 3*1 = 3 (no feature_set_importance), sum = 3*2 = 6, max = 3*3 = 9, D' = 6/9 = 0.6667
  let diff = case score -. 0.6667 {
    d if d <. 0.0 -> 0.0 -. d
    d -> d
  }
  let assert True = diff <. 0.001
}

// ---------------------------------------------------------------------------
// compute_reactive_dprime
// ---------------------------------------------------------------------------

pub fn reactive_dprime_test() {
  let critical = [
    feature("safety", High, True),
    feature("privacy", High, True),
  ]
  let forecasts = [
    Forecast(feature_name: "safety", magnitude: 3, rationale: ""),
    Forecast(feature_name: "privacy", magnitude: 0, rationale: ""),
  ]
  // D' = (3*3 + 3*0) / (2*3*3) = 9/18 = 0.5
  let score = engine.compute_reactive_dprime(forecasts, critical)
  score |> should.equal(0.5)
}

pub fn reactive_dprime_empty_test() {
  engine.compute_reactive_dprime([], []) |> should.equal(0.0)
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
    feature("safety", High, True),
    feature("accuracy", Medium, False),
    feature("privacy", High, True),
  ]
  let critical = engine.critical_features(features)
  critical
  |> should.equal([
    feature("safety", High, True),
    feature("privacy", High, True),
  ])
}

pub fn critical_features_empty_when_none_critical_test() {
  let features = [feature("accuracy", Medium, False)]
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
