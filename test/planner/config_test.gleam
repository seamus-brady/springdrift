// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/types as dprime_types
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import planner/config
import planner/types as planner_types
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/planner_config_test_" <> suffix
  let _ = simplifile.create_directory_all(dir)
  dir
}

// ---------------------------------------------------------------------------
// Default config
// ---------------------------------------------------------------------------

pub fn default_config_has_five_features_test() {
  let cfg = config.default_config()
  list.length(cfg.features) |> should.equal(5)
  cfg.replan_threshold |> should.equal(0.55)
}

// ---------------------------------------------------------------------------
// Load from file
// ---------------------------------------------------------------------------

pub fn load_missing_file_returns_defaults_test() {
  let cfg = config.load("/tmp/nonexistent_planner_features.json")
  list.length(cfg.features) |> should.equal(5)
}

pub fn load_valid_file_test() {
  let dir = test_dir("load_valid")
  let path = dir <> "/features.json"
  let content =
    "{\"features\":[{\"name\":\"test_feature\",\"importance\":\"high\",\"description\":\"A test\",\"critical\":true}],\"replan_threshold\":0.42}"
  let _ = simplifile.write(path, content)
  let cfg = config.load(path)
  list.length(cfg.features) |> should.equal(1)
  cfg.replan_threshold |> should.equal(0.42)
  let assert [f] = cfg.features
  f.name |> should.equal("test_feature")
  f.importance |> should.equal(dprime_types.High)
  f.critical |> should.equal(True)
}

pub fn load_malformed_json_returns_defaults_test() {
  let dir = test_dir("load_malformed")
  let path = dir <> "/features.json"
  let _ = simplifile.write(path, "not json")
  let cfg = config.load(path)
  list.length(cfg.features) |> should.equal(5)
}

// ---------------------------------------------------------------------------
// Save and reload roundtrip
// ---------------------------------------------------------------------------

pub fn save_and_reload_roundtrip_test() {
  let dir = test_dir("roundtrip")
  let path = dir <> "/features.json"
  let original = config.default_config()
  let assert Ok(_) = config.save(path, original)
  let loaded = config.load(path)
  list.length(loaded.features) |> should.equal(5)
  loaded.replan_threshold |> should.equal(0.55)
}

// ---------------------------------------------------------------------------
// Effective features resolution
// ---------------------------------------------------------------------------

pub fn effective_features_no_endeavour_uses_base_test() {
  let base = config.default_config()
  let #(features, threshold) = config.effective_features(base, None)
  list.length(features) |> should.equal(5)
  threshold |> should.equal(0.55)
}

pub fn effective_features_with_threshold_override_test() {
  let base = config.default_config()
  let e =
    planner_types.Endeavour(
      ..planner_types.new_endeavour(
        "e1",
        planner_types.SystemEndeavour,
        "T",
        "D",
        "2026-04-01",
      ),
      threshold_override: Some(0.3),
    )
  let #(_features, threshold) = config.effective_features(base, Some(e))
  threshold |> should.equal(0.3)
}

pub fn effective_features_with_feature_overrides_test() {
  let base = config.default_config()
  let custom_features = [
    dprime_types.Feature(
      name: "custom",
      importance: dprime_types.Low,
      description: "Custom",
      critical: False,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
  ]
  let e =
    planner_types.Endeavour(
      ..planner_types.new_endeavour(
        "e2",
        planner_types.SystemEndeavour,
        "T",
        "D",
        "2026-04-01",
      ),
      feature_overrides: Some(custom_features),
    )
  let #(features, _threshold) = config.effective_features(base, Some(e))
  list.length(features) |> should.equal(1)
  let assert [f] = features
  f.name |> should.equal("custom")
}

pub fn effective_features_no_overrides_uses_base_test() {
  let base = config.default_config()
  let e =
    planner_types.new_endeavour(
      "e3",
      planner_types.SystemEndeavour,
      "T",
      "D",
      "2026-04-01",
    )
  let #(features, threshold) = config.effective_features(base, Some(e))
  list.length(features) |> should.equal(5)
  threshold |> should.equal(0.55)
}
