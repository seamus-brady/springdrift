// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/engine
import dprime/types.{type Feature, Feature, Forecast, High, Medium}
import gleam/option.{None}
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Output features — mirrors output gate in .springdrift_example/dprime.json
// ---------------------------------------------------------------------------

fn output_features() -> List(Feature) {
  [
    Feature(
      name: "unsourced_claim",
      importance: High,
      description: "Factual assertion without supporting evidence",
      critical: True,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    Feature(
      name: "accuracy",
      importance: High,
      description: "False, misleading, or unverifiable information",
      critical: True,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    Feature(
      name: "certainty_overstatement",
      importance: Medium,
      description: "Presenting uncertain data as definitive",
      critical: False,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    Feature(
      name: "harmful_content",
      importance: High,
      description: "Dangerous instructions or harmful material",
      critical: True,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    Feature(
      name: "privacy_leak",
      importance: Medium,
      description: "Exposing private or sensitive information",
      critical: False,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
  ]
}

// ---------------------------------------------------------------------------
// Clean response: all magnitudes 0 -> score near 0
// ---------------------------------------------------------------------------

pub fn clean_response_low_score_test() {
  let features = output_features()
  let clean_forecasts =
    features
    |> list.map(fn(f) {
      Forecast(feature_name: f.name, magnitude: 0, rationale: "clean")
    })
  let score = engine.compute_dprime(clean_forecasts, features, 1)
  should.be_true(score <. 0.01)
}

// ---------------------------------------------------------------------------
// All-zero forecasts produce exactly 0.0
// ---------------------------------------------------------------------------

pub fn all_zero_forecasts_exact_zero_test() {
  let features = output_features()
  let forecasts =
    features
    |> list.map(fn(f) {
      Forecast(feature_name: f.name, magnitude: 0, rationale: "none")
    })
  let score = engine.compute_dprime(forecasts, features, 1)
  score |> should.equal(0.0)
}

// ---------------------------------------------------------------------------
// Problematic response: high magnitudes on key features -> high score
// ---------------------------------------------------------------------------

pub fn problematic_response_high_score_test() {
  let features = output_features()
  let problematic_forecasts = [
    Forecast(
      feature_name: "unsourced_claim",
      magnitude: 3,
      rationale: "no sources cited",
    ),
    Forecast(
      feature_name: "accuracy",
      magnitude: 2,
      rationale: "unverifiable claims",
    ),
    Forecast(
      feature_name: "certainty_overstatement",
      magnitude: 2,
      rationale: "definitive language",
    ),
    Forecast(feature_name: "harmful_content", magnitude: 0, rationale: "safe"),
    Forecast(feature_name: "privacy_leak", magnitude: 0, rationale: "no PII"),
  ]
  let score = engine.compute_dprime(problematic_forecasts, features, 1)
  // Should be above the output gate modify threshold (0.40)
  should.be_true(score >. 0.4)
}

// ---------------------------------------------------------------------------
// Gate decision logic with output thresholds
// ---------------------------------------------------------------------------

pub fn clean_score_accepts_test() {
  // Output gate thresholds: modify=0.40, reject=0.75
  let decision = engine.gate_decision(0.05, 0.4, 0.75)
  decision |> should.equal(types.Accept)
}

pub fn moderate_score_modifies_test() {
  let decision = engine.gate_decision(0.5, 0.4, 0.75)
  decision |> should.equal(types.Modify)
}

pub fn high_score_rejects_test() {
  let decision = engine.gate_decision(0.8, 0.4, 0.75)
  decision |> should.equal(types.Reject)
}

// ---------------------------------------------------------------------------
// Single high-importance feature drives score up
// ---------------------------------------------------------------------------

pub fn single_critical_feature_high_magnitude_test() {
  let features = output_features()
  // Only harmful_content at max magnitude, everything else 0
  let forecasts = [
    Forecast(
      feature_name: "harmful_content",
      magnitude: 3,
      rationale: "dangerous",
    ),
  ]
  let score = engine.compute_dprime(forecasts, features, 1)
  // harmful_content is High importance (weight 3), magnitude 3
  // Max possible = 3*3 + 3*3 + 2*3 + 3*3 + 2*3 = 9+9+6+9+6 = 39
  // Score = 3*3 / 39 = 9/39 ~ 0.23
  should.be_true(score >. 0.2)
}

// ---------------------------------------------------------------------------
// Missing forecasts treated as magnitude 0
// ---------------------------------------------------------------------------

pub fn missing_forecasts_treated_as_zero_test() {
  let features = output_features()
  // Empty forecast list — all features default to magnitude 0
  let score = engine.compute_dprime([], features, 1)
  score |> should.equal(0.0)
}

// ---------------------------------------------------------------------------
// Magnitude clamping: values above 3 clamped to 3
// ---------------------------------------------------------------------------

pub fn magnitude_clamped_to_three_test() {
  let features = output_features()
  let forecasts = [
    Forecast(
      feature_name: "unsourced_claim",
      magnitude: 10,
      rationale: "extreme",
    ),
  ]
  let score_clamped = engine.compute_dprime(forecasts, features, 1)

  let forecasts_max = [
    Forecast(feature_name: "unsourced_claim", magnitude: 3, rationale: "max"),
  ]
  let score_max = engine.compute_dprime(forecasts_max, features, 1)

  // Clamped at 3, so both should produce the same score
  score_clamped |> should.equal(score_max)
}

// ---------------------------------------------------------------------------
// All features at maximum -> score = 1.0
// ---------------------------------------------------------------------------

pub fn all_max_magnitudes_score_one_test() {
  let features = output_features()
  let forecasts =
    features
    |> list.map(fn(f) {
      Forecast(feature_name: f.name, magnitude: 3, rationale: "max")
    })
  let score = engine.compute_dprime(forecasts, features, 1)
  score |> should.equal(1.0)
}

import gleam/list
