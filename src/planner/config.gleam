//// Planner feature configuration — configurable feature sets for the Forecaster.
////
//// Mirrors the D' config pattern: operator sets defaults in a JSON file,
//// agent adjusts per-endeavour via tools. Falls back to hardcoded defaults
//// if the JSON file is missing or malformed.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/types as dprime_types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import planner/features
import planner/types as planner_types
import simplifile
import slog

/// Forecaster feature configuration — features + replan threshold.
pub type ForecasterFeatureConfig {
  ForecasterFeatureConfig(
    features: List(dprime_types.Feature),
    replan_threshold: Float,
  )
}

/// Default config using hardcoded features.
pub fn default_config() -> ForecasterFeatureConfig {
  ForecasterFeatureConfig(
    features: features.plan_health_features(),
    replan_threshold: features.default_replan_threshold,
  )
}

/// Load config from a JSON file. Falls back to defaults on any error.
pub fn load(path: String) -> ForecasterFeatureConfig {
  case simplifile.read(path) {
    Error(_) -> {
      slog.debug(
        "planner/config",
        "load",
        "No planner features file at " <> path <> ", using defaults",
        None,
      )
      default_config()
    }
    Ok(content) ->
      case json.parse(content, config_decoder()) {
        Ok(config) -> {
          slog.info(
            "planner/config",
            "load",
            "Loaded "
              <> string.inspect(list.length(config.features))
              <> " planner features from "
              <> path,
            None,
          )
          config
        }
        Error(_) -> {
          slog.warn(
            "planner/config",
            "load",
            "Failed to parse planner features at " <> path <> ", using defaults",
            None,
          )
          default_config()
        }
      }
  }
}

/// Save config to a JSON file (for agent tool use).
pub fn save(
  path: String,
  config: ForecasterFeatureConfig,
) -> Result(Nil, String) {
  let json_str = json.to_string(encode_config(config))
  case simplifile.write(path, json_str) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error("Failed to write: " <> simplifile.describe_error(e))
  }
}

// ---------------------------------------------------------------------------
// JSON encoding
// ---------------------------------------------------------------------------

pub fn encode_config(config: ForecasterFeatureConfig) -> json.Json {
  json.object([
    #("features", json.array(config.features, encode_feature)),
    #("replan_threshold", json.float(config.replan_threshold)),
  ])
}

pub fn encode_feature(f: dprime_types.Feature) -> json.Json {
  json.object([
    #("name", json.string(f.name)),
    #("importance", json.string(encode_importance(f.importance))),
    #("description", json.string(f.description)),
    #("critical", json.bool(f.critical)),
  ])
}

fn encode_importance(i: dprime_types.Importance) -> String {
  case i {
    dprime_types.High -> "high"
    dprime_types.Medium -> "medium"
    dprime_types.Low -> "low"
  }
}

// ---------------------------------------------------------------------------
// JSON decoding
// ---------------------------------------------------------------------------

fn config_decoder() -> decode.Decoder(ForecasterFeatureConfig) {
  use features <- decode.field("features", decode.list(feature_decoder()))
  use replan_threshold <- decode.optional_field(
    "replan_threshold",
    features.default_replan_threshold,
    decode.float,
  )
  decode.success(ForecasterFeatureConfig(features:, replan_threshold:))
}

pub fn feature_decoder() -> decode.Decoder(dprime_types.Feature) {
  use name <- decode.field("name", decode.string)
  use importance <- decode.optional_field(
    "importance",
    dprime_types.Medium,
    importance_decoder(),
  )
  use description <- decode.optional_field("description", "", decode.string)
  use critical <- decode.optional_field("critical", False, decode.bool)
  decode.success(dprime_types.Feature(
    name:,
    importance:,
    description:,
    critical:,
    feature_set: None,
    feature_set_importance: None,
    group: None,
    group_importance: None,
  ))
}

fn importance_decoder() -> decode.Decoder(dprime_types.Importance) {
  use s <- decode.then(decode.string)
  case s {
    "high" -> decode.success(dprime_types.High)
    "medium" -> decode.success(dprime_types.Medium)
    "low" -> decode.success(dprime_types.Low)
    _ -> decode.success(dprime_types.Medium)
  }
}

/// Encode a list of features as JSON (for storing per-endeavour overrides).
pub fn encode_features(fs: List(dprime_types.Feature)) -> json.Json {
  json.array(fs, encode_feature)
}

/// Decode a list of features (for loading per-endeavour overrides).
pub fn features_decoder() -> decode.Decoder(List(dprime_types.Feature)) {
  decode.list(feature_decoder())
}

// ---------------------------------------------------------------------------
// Feature resolution — per-endeavour overrides over base config
// ---------------------------------------------------------------------------

/// Resolve effective features and threshold for a specific endeavour.
/// Per-endeavour overrides take precedence over the base config.
pub fn effective_features(
  base: ForecasterFeatureConfig,
  endeavour: Option(planner_types.Endeavour),
) -> #(List(dprime_types.Feature), Float) {
  case endeavour {
    None -> #(base.features, base.replan_threshold)
    Some(e) -> {
      let features = case e.feature_overrides {
        Some(overrides) -> overrides
        None -> base.features
      }
      let threshold = case e.threshold_override {
        Some(t) -> t
        None -> base.replan_threshold
      }
      #(features, threshold)
    }
  }
}
