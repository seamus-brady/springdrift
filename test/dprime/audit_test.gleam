// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/audit as dprime_audit
import dprime/config as dprime_config
import dprime/types.{type GateResult, Accept, Deliberative, GateResult}
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

fn test_gate_result() -> GateResult {
  GateResult(
    decision: Accept,
    dprime_score: 0.3,
    forecasts: [
      types.Forecast(
        feature_name: "user_safety",
        magnitude: 1,
        rationale: "minor",
      ),
    ],
    explanation: "test explanation",
    layer: Deliberative,
    canary_result: Some(types.ProbeResult(
      hijack_detected: False,
      leakage_detected: False,
      probe_failed: False,
      details: "ok",
    )),
  )
}

// ---------------------------------------------------------------------------
// build_record
// ---------------------------------------------------------------------------

pub fn build_record_has_prompt_hash_test() {
  let result = test_gate_result()
  let features = dprime_config.default().features
  let record =
    dprime_audit.build_record(
      "req-123",
      "test prompt text",
      result,
      features,
      Some(0.1),
      None,
    )
  // Hash should be non-empty and not the raw prompt
  let assert True = record.prompt_hash != ""
  let assert True = record.prompt_hash != "test prompt text"
}

pub fn build_record_has_correct_fields_test() {
  let result = test_gate_result()
  let features = dprime_config.default().features
  let record =
    dprime_audit.build_record(
      "req-456",
      "some prompt",
      result,
      features,
      Some(0.2),
      None,
    )
  record.request_id |> should.equal("req-456")
  record.decision |> should.equal(Accept)
  record.source |> should.equal("deliberative")
  record.reactive_dprime |> should.equal(Some(0.2))
  record.deliberative_dprime |> should.equal(Some(0.3))
}

pub fn build_record_canary_fields_test() {
  let result = test_gate_result()
  let features = dprime_config.default().features
  let record =
    dprime_audit.build_record("req-789", "prompt", result, features, None, None)
  record.canary_hijack |> should.equal(Some(False))
  record.canary_leakage |> should.equal(Some(False))
}

pub fn build_record_no_canary_test() {
  let result = GateResult(..test_gate_result(), canary_result: None)
  let features = dprime_config.default().features
  let record =
    dprime_audit.build_record("req-abc", "prompt", result, features, None, None)
  record.canary_hijack |> should.equal(None)
  record.canary_leakage |> should.equal(None)
}

pub fn build_record_per_feature_populated_test() {
  let result = test_gate_result()
  let features = dprime_config.default().features
  let record =
    dprime_audit.build_record("req-def", "prompt", result, features, None, None)
  // Should have a score entry for each feature
  list.length(record.per_feature) |> should.equal(7)
}

pub fn build_record_reactive_source_test() {
  let result = GateResult(..test_gate_result(), layer: types.Reactive)
  let features = dprime_config.default().features
  let record =
    dprime_audit.build_record("req-xyz", "prompt", result, features, None, None)
  record.source |> should.equal("reactive")
  record.deliberative_dprime |> should.equal(None)
}
