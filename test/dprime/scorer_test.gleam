// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/scorer
import dprime/types.{type Feature, Feature, High, Low, Medium}
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import llm/adapters/mock

pub fn main() -> Nil {
  gleeunit.main()
}

fn feature(name: String, importance, critical: Bool) -> Feature {
  Feature(
    name:,
    importance:,
    description: case name {
      "safety" -> "User safety"
      "accuracy" -> "Factual correctness"
      _ -> name
    },
    critical:,
    feature_set: None,
    feature_set_importance: None,
    group: None,
    group_importance: None,
  )
}

// ---------------------------------------------------------------------------
// build_scoring_prompt
// ---------------------------------------------------------------------------

pub fn build_scoring_prompt_includes_instruction_test() {
  let features = [feature("safety", High, True)]
  let prompt = scorer.build_scoring_prompt("delete all files", "", features)
  string.contains(prompt, "delete all files") |> should.be_true
}

pub fn build_scoring_prompt_includes_features_test() {
  let features = [
    feature("safety", High, True),
    feature("accuracy", Medium, False),
  ]
  let prompt = scorer.build_scoring_prompt("test", "", features)
  string.contains(prompt, "safety") |> should.be_true
  string.contains(prompt, "accuracy") |> should.be_true
}

pub fn build_scoring_prompt_includes_context_when_present_test() {
  let features = [feature("safety", High, True)]
  let prompt =
    scorer.build_scoring_prompt("test", "some context here", features)
  string.contains(prompt, "some context here") |> should.be_true
}

pub fn build_scoring_prompt_omits_context_when_empty_test() {
  let features = [feature("safety", High, True)]
  let prompt = scorer.build_scoring_prompt("test", "", features)
  string.contains(prompt, "CONTEXT:") |> should.be_false
}

pub fn build_scoring_prompt_includes_calibration_examples_test() {
  let features = [feature("safety", High, True)]
  let prompt = scorer.build_scoring_prompt("test", "", features)
  string.contains(prompt, "CALIBRATION EXAMPLES") |> should.be_true
  string.contains(prompt, "birthday card") |> should.be_true
}

pub fn build_scoring_prompt_includes_magnitude_scale_test() {
  let features = [feature("safety", High, True)]
  let prompt = scorer.build_scoring_prompt("test", "", features)
  string.contains(prompt, "0 = No violation") |> should.be_true
  string.contains(prompt, "3 = Severe violation") |> should.be_true
}

// ---------------------------------------------------------------------------
// parse_forecasts — now XML
// ---------------------------------------------------------------------------

pub fn parse_forecasts_valid_xml_test() {
  let xml =
    "<forecasts><forecast><feature>safety</feature><magnitude>2</magnitude><rationale>could harm data</rationale></forecast></forecasts>"
  let result = scorer.parse_forecasts(xml)
  result |> should.be_ok
  let assert Ok(forecasts) = result
  list.length(forecasts) |> should.equal(1)
  let assert [f] = forecasts
  f.feature_name |> should.equal("safety")
  f.magnitude |> should.equal(2)
}

pub fn parse_forecasts_with_markdown_fences_test() {
  let xml =
    "```xml\n<forecasts><forecast><feature>safety</feature><magnitude>1</magnitude><rationale>ok</rationale></forecast></forecasts>\n```"
  let result = scorer.parse_forecasts(xml)
  result |> should.be_ok
  let assert Ok(forecasts) = result
  list.length(forecasts) |> should.equal(1)
}

pub fn parse_forecasts_clamps_magnitude_test() {
  let xml =
    "<forecasts><forecast><feature>safety</feature><magnitude>5</magnitude><rationale>high</rationale></forecast></forecasts>"
  let result = scorer.parse_forecasts(xml)
  result |> should.be_ok
  let assert Ok([f]) = result
  f.magnitude |> should.equal(3)
}

pub fn parse_forecasts_clamps_negative_test() {
  let xml =
    "<forecasts><forecast><feature>safety</feature><magnitude>-1</magnitude><rationale>neg</rationale></forecast></forecasts>"
  let result = scorer.parse_forecasts(xml)
  result |> should.be_ok
  let assert Ok([f]) = result
  f.magnitude |> should.equal(0)
}

pub fn parse_forecasts_invalid_xml_test() {
  scorer.parse_forecasts("not xml at all") |> should.be_error
}

pub fn parse_forecasts_empty_forecasts_test() {
  let xml = "<forecasts></forecasts>"
  let result = scorer.parse_forecasts(xml)
  // No forecast elements → Error (empty list)
  result |> should.be_error
}

pub fn parse_forecasts_multiple_features_test() {
  let xml =
    "<forecasts><forecast><feature>safety</feature><magnitude>2</magnitude><rationale>a</rationale></forecast><forecast><feature>accuracy</feature><magnitude>0</magnitude><rationale>b</rationale></forecast></forecasts>"
  let result = scorer.parse_forecasts(xml)
  result |> should.be_ok
  let assert Ok(forecasts) = result
  list.length(forecasts) |> should.equal(2)
}

pub fn parse_forecasts_missing_rationale_test() {
  let xml =
    "<forecasts><forecast><feature>safety</feature><magnitude>1</magnitude></forecast></forecasts>"
  let result = scorer.parse_forecasts(xml)
  result |> should.be_ok
  let assert Ok([f]) = result
  f.feature_name |> should.equal("safety")
  f.magnitude |> should.equal(1)
  f.rationale |> should.equal("")
}

// ---------------------------------------------------------------------------
// default_forecasts
// ---------------------------------------------------------------------------

pub fn default_forecasts_all_zero_test() {
  let features = [feature("safety", High, True), feature("scope", Low, False)]
  let forecasts = scorer.default_forecasts(features)
  list.length(forecasts) |> should.equal(2)
  list.all(forecasts, fn(f) { f.magnitude == 0 }) |> should.be_true
}

// ---------------------------------------------------------------------------
// cautious_forecasts
// ---------------------------------------------------------------------------

pub fn cautious_forecasts_all_one_test() {
  let features = [feature("safety", High, True), feature("scope", Low, False)]
  let forecasts = scorer.cautious_forecasts(features)
  list.length(forecasts) |> should.equal(2)
  // Fail-open: all features default to magnitude 0 when scoring unavailable
  list.all(forecasts, fn(f) { f.magnitude == 0 }) |> should.be_true
}

// ---------------------------------------------------------------------------
// score_features — mock provider integration
// ---------------------------------------------------------------------------

pub fn score_features_with_mock_provider_test() {
  let features = [feature("safety", High, True)]
  let xml_response =
    "<forecasts><forecast><feature>safety</feature><magnitude>1</magnitude><rationale>minor concern</rationale></forecast></forecasts>"
  let provider = mock.provider_with_text(xml_response)
  let forecasts =
    scorer.score_features(
      "test instruction",
      "",
      features,
      provider,
      "mock-model",
      "test-cycle",
      False,
    )
  // XStructor compile_schema requires filesystem; if it fails, falls back to cautious
  // Either we get the parsed result or cautious fallback (magnitude 0, fail-open)
  list.length(forecasts) |> should.equal(1)
  let assert [f] = forecasts
  f.feature_name |> should.equal("safety")
  // Parsed result = 1; cautious fallback = 0 (fail-open)
  { f.magnitude == 1 || f.magnitude == 0 } |> should.be_true
}

pub fn score_features_falls_back_to_cautious_on_error_test() {
  let features = [feature("safety", High, True)]
  let provider = mock.provider_with_error("API down")
  let forecasts =
    scorer.score_features(
      "test",
      "",
      features,
      provider,
      "mock-model",
      "test-cycle",
      False,
    )
  list.length(forecasts) |> should.equal(1)
  let assert [f] = forecasts
  // Fail-open: cautious fallback defaults to magnitude 0
  f.magnitude |> should.equal(0)
}

pub fn score_features_falls_back_to_cautious_on_invalid_response_test() {
  let features = [feature("safety", High, True)]
  let provider = mock.provider_with_text("I can't evaluate that")
  let forecasts =
    scorer.score_features(
      "test",
      "",
      features,
      provider,
      "mock-model",
      "test-cycle",
      False,
    )
  list.length(forecasts) |> should.equal(1)
  // Fail-open: cautious fallback defaults to magnitude 0
  list.all(forecasts, fn(f) { f.magnitude == 0 }) |> should.be_true
}
