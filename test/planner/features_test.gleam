//// Tests for plan-health feature definitions used by the Forecaster.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/types as dprime_types
import gleam/list
import gleeunit/should
import planner/features

// ---------------------------------------------------------------------------
// plan_health_features
// ---------------------------------------------------------------------------

pub fn plan_health_features_returns_five_features_test() {
  features.plan_health_features()
  |> list.length()
  |> should.equal(5)
}

pub fn plan_health_features_all_have_non_empty_names_test() {
  features.plan_health_features()
  |> list.each(fn(f) { f.name |> should.not_equal("") })
}

pub fn plan_health_features_two_critical_test() {
  features.plan_health_features()
  |> list.count(fn(f) { f.critical })
  |> should.equal(2)
}

pub fn plan_health_features_critical_names_test() {
  let critical_names =
    features.plan_health_features()
    |> list.filter(fn(f) { f.critical })
    |> list.map(fn(f) { f.name })
  critical_names |> list.contains("step_completion_rate") |> should.equal(True)
  critical_names |> list.contains("dependency_health") |> should.equal(True)
}

pub fn default_replan_threshold_test() {
  features.default_replan_threshold |> should.equal(0.55)
}

pub fn scaling_unit_test() {
  features.scaling_unit |> should.equal(9)
}

pub fn plan_health_features_importances_test() {
  let feats = features.plan_health_features()
  // step_completion_rate and dependency_health are High
  feats
  |> list.filter(fn(f) { f.importance == dprime_types.High })
  |> list.length()
  |> should.equal(2)
  // complexity_drift and risk_materialization are Medium
  feats
  |> list.filter(fn(f) { f.importance == dprime_types.Medium })
  |> list.length()
  |> should.equal(2)
  // scope_creep is Low
  feats
  |> list.filter(fn(f) { f.importance == dprime_types.Low })
  |> list.length()
  |> should.equal(1)
}
