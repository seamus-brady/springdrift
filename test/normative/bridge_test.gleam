// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/types as dprime_types
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import normative/bridge
import normative/character
import normative/types

pub fn main() -> Nil {
  gleeunit.main()
}

fn forecast(name: String, magnitude: Int) -> dprime_types.Forecast {
  dprime_types.Forecast(feature_name: name, magnitude:, rationale: "test")
}

fn feature(name: String, critical: Bool) -> dprime_types.Feature {
  dprime_types.Feature(
    name:,
    importance: dprime_types.Medium,
    description: name <> " description",
    critical:,
    feature_set: None,
    feature_set_importance: None,
    group: None,
    group_importance: None,
  )
}

// ---------------------------------------------------------------------------
// feature_to_level
// ---------------------------------------------------------------------------

pub fn feature_to_level_harmful_content_test() {
  bridge.feature_to_level("harmful_content")
  |> should.equal(types.EthicalMoral)
}

pub fn feature_to_level_accuracy_test() {
  bridge.feature_to_level("accuracy")
  |> should.equal(types.IntellectualHonesty)
}

pub fn feature_to_level_privacy_test() {
  bridge.feature_to_level("privacy_leak")
  |> should.equal(types.PrivacyData)
}

pub fn feature_to_level_unknown_test() {
  bridge.feature_to_level("unknown_feature")
  |> should.equal(types.Operational)
}

pub fn feature_to_level_legal_test() {
  bridge.feature_to_level("legal_risk")
  |> should.equal(types.Legal)
}

// ---------------------------------------------------------------------------
// magnitude_to_operator
// ---------------------------------------------------------------------------

pub fn magnitude_0_indifferent_test() {
  bridge.magnitude_to_operator(0) |> should.equal(types.Indifferent)
}

pub fn magnitude_1_indifferent_test() {
  bridge.magnitude_to_operator(1) |> should.equal(types.Indifferent)
}

pub fn magnitude_2_ought_test() {
  bridge.magnitude_to_operator(2) |> should.equal(types.Ought)
}

pub fn magnitude_3_required_test() {
  bridge.magnitude_to_operator(3) |> should.equal(types.Required)
}

// ---------------------------------------------------------------------------
// forecasts_to_propositions
// ---------------------------------------------------------------------------

pub fn forecasts_to_propositions_filters_zero_test() {
  let forecasts = [forecast("accuracy", 0), forecast("privacy_leak", 2)]
  let features = [feature("accuracy", False), feature("privacy_leak", False)]
  let nps = bridge.forecasts_to_propositions(forecasts, features)
  list.length(nps) |> should.equal(1)
  let assert [np] = nps
  np.level |> should.equal(types.PrivacyData)
  np.operator |> should.equal(types.Ought)
}

pub fn forecasts_to_propositions_all_zero_test() {
  let forecasts = [forecast("accuracy", 0)]
  let features = [feature("accuracy", False)]
  bridge.forecasts_to_propositions(forecasts, features)
  |> should.equal([])
}

pub fn forecasts_to_propositions_multiple_test() {
  let forecasts = [
    forecast("harmful_content", 3),
    forecast("accuracy", 2),
    forecast("privacy_leak", 1),
  ]
  let features = [
    feature("harmful_content", True),
    feature("accuracy", False),
    feature("privacy_leak", False),
  ]
  let nps = bridge.forecasts_to_propositions(forecasts, features)
  list.length(nps) |> should.equal(3)
}

// ---------------------------------------------------------------------------
// build_harm_context
// ---------------------------------------------------------------------------

pub fn harm_context_no_forecasts_test() {
  let hc = bridge.build_harm_context([], [])
  hc.impact_score |> should.equal(0.0)
  hc.catastrophic |> should.be_false()
}

pub fn harm_context_catastrophic_test() {
  let forecasts = [forecast("harmful_content", 3)]
  let features = [feature("harmful_content", True)]
  let hc = bridge.build_harm_context(forecasts, features)
  hc.catastrophic |> should.be_true()
}

pub fn harm_context_not_catastrophic_non_critical_test() {
  let forecasts = [forecast("accuracy", 3)]
  let features = [feature("accuracy", False)]
  let hc = bridge.build_harm_context(forecasts, features)
  hc.catastrophic |> should.be_false()
}

pub fn harm_context_not_catastrophic_low_magnitude_test() {
  let forecasts = [forecast("harmful_content", 2)]
  let features = [feature("harmful_content", True)]
  let hc = bridge.build_harm_context(forecasts, features)
  hc.catastrophic |> should.be_false()
}

// ---------------------------------------------------------------------------
// evaluate — full flow
// ---------------------------------------------------------------------------

pub fn evaluate_clean_output_flourishing_test() {
  let forecasts = [forecast("accuracy", 0), forecast("privacy_leak", 0)]
  let features = [feature("accuracy", False), feature("privacy_leak", False)]
  let spec = character.default_character()
  let j = bridge.evaluate(0.0, forecasts, features, spec, 0.4, 0.7)
  j.verdict |> should.equal(types.Flourishing)
}

pub fn evaluate_high_dprime_prohibited_test() {
  let forecasts = [forecast("accuracy", 0)]
  let features = [feature("accuracy", False)]
  let spec = character.default_character()
  let j = bridge.evaluate(0.8, forecasts, features, spec, 0.4, 0.7)
  j.verdict |> should.equal(types.Prohibited)
  j.floor_rule |> should.equal("floor_3_dprime_reject")
}

pub fn evaluate_moderate_dprime_constrained_test() {
  let forecasts = [forecast("accuracy", 0)]
  let features = [feature("accuracy", False)]
  let spec = character.default_character()
  let j = bridge.evaluate(0.5, forecasts, features, spec, 0.4, 0.7)
  j.verdict |> should.equal(types.Constrained)
  j.floor_rule |> should.equal("floor_6_dprime_modify")
}

pub fn evaluate_harmful_content_max_prohibited_test() {
  // harmful_content at magnitude 3 → EthicalMoral + Required user NP
  // Against EthicalMoral + Required system NP → Absolute → floor 1
  let forecasts = [forecast("harmful_content", 3)]
  let features = [feature("harmful_content", True)]
  let spec = character.default_character()
  let j = bridge.evaluate(0.0, forecasts, features, spec, 0.4, 0.7)
  j.verdict |> should.equal(types.Prohibited)
  j.floor_rule |> should.equal("floor_1_absolute_prohibition")
}

// ---------------------------------------------------------------------------
// verdict_to_gate_decision
// ---------------------------------------------------------------------------

pub fn verdict_flourishing_accept_test() {
  bridge.verdict_to_gate_decision(types.Flourishing)
  |> should.equal(dprime_types.Accept)
}

pub fn verdict_constrained_modify_test() {
  bridge.verdict_to_gate_decision(types.Constrained)
  |> should.equal(dprime_types.Modify)
}

pub fn verdict_prohibited_reject_test() {
  bridge.verdict_to_gate_decision(types.Prohibited)
  |> should.equal(dprime_types.Reject)
}

// ---------------------------------------------------------------------------
// format_judgement
// ---------------------------------------------------------------------------

pub fn format_judgement_flourishing_test() {
  let j =
    types.NormativeJudgement(
      verdict: types.Flourishing,
      floor_rule: "floor_8_flourishing",
      conflicts: [],
      axiom_trail: [],
    )
  let s = bridge.format_judgement(j)
  should.be_true(string.contains(s, "flourishing"))
  should.be_true(string.contains(s, "floor_8"))
}

pub fn format_judgement_with_trail_test() {
  let j =
    types.NormativeJudgement(
      verdict: types.Prohibited,
      floor_rule: "floor_1_absolute_prohibition",
      conflicts: [],
      axiom_trail: ["axiom_6.2_absolute_prohibition"],
    )
  let s = bridge.format_judgement(j)
  should.be_true(string.contains(s, "axiom_6.2"))
}

import gleam/string
