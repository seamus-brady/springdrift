//// D' configuration — default features, JSON loading, state initialization.

import dprime/types.{
  type DprimeConfig, type DprimeState, DprimeConfig, DprimeState, Feature, High,
  Low, Medium,
}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import simplifile
import slog

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

/// Sensible default D' configuration with five standard features.
pub fn default() -> DprimeConfig {
  DprimeConfig(
    features: [
      Feature(
        name: "user_safety",
        importance: High,
        description: "Actions that could harm the user or their data",
        critical: True,
      ),
      Feature(
        name: "accuracy",
        importance: Medium,
        description: "Factual correctness and reliability of information",
        critical: False,
      ),
      Feature(
        name: "privacy",
        importance: High,
        description: "Protection of sensitive or personal information",
        critical: True,
      ),
      Feature(
        name: "scope",
        importance: Medium,
        description: "Whether the action stays within the user's intended scope",
        critical: False,
      ),
      Feature(
        name: "reversibility",
        importance: Low,
        description: "Whether the action can be undone if it goes wrong",
        critical: False,
      ),
    ],
    tiers: 1,
    modify_threshold: 0.3,
    reject_threshold: 0.7,
    max_history: 100,
    stall_window: 5,
    stall_threshold: 0.25,
    canary_enabled: True,
  )
}

// ---------------------------------------------------------------------------
// State initialization
// ---------------------------------------------------------------------------

/// Create initial D' state from config.
pub fn initial_state(config: DprimeConfig) -> DprimeState {
  DprimeState(
    config:,
    history: [],
    current_modify_threshold: config.modify_threshold,
    current_reject_threshold: config.reject_threshold,
  )
}

// ---------------------------------------------------------------------------
// JSON loading
// ---------------------------------------------------------------------------

/// Load D' config from a JSON file. Falls back to default() on any error.
pub fn load(path: String) -> DprimeConfig {
  slog.debug("dprime/config", "load", "Loading D' config from " <> path, None)
  case simplifile.read(path) {
    Error(_) -> {
      slog.info(
        "dprime/config",
        "load",
        "Config file not found, using defaults",
        None,
      )
      default()
    }
    Ok(contents) ->
      case json.parse(contents, config_decoder()) {
        Ok(cfg) -> {
          slog.info(
            "dprime/config",
            "load",
            "Loaded D' config with "
              <> int.to_string(list.length(cfg.features))
              <> " features",
            None,
          )
          cfg
        }
        Error(_) -> {
          slog.warn(
            "dprime/config",
            "load",
            "Config parse failed, using defaults",
            None,
          )
          default()
        }
      }
  }
}

fn config_decoder() -> decode.Decoder(DprimeConfig) {
  use features <- decode.field("features", decode.list(feature_decoder()))
  use tiers <- decode.optional_field("tiers", 1, decode.int)
  use modify_threshold <- decode.optional_field(
    "modify_threshold",
    0.3,
    decode.float,
  )
  use reject_threshold <- decode.optional_field(
    "reject_threshold",
    0.7,
    decode.float,
  )
  use max_history <- decode.optional_field("max_history", 100, decode.int)
  use stall_window <- decode.optional_field("stall_window", 5, decode.int)
  use stall_threshold <- decode.optional_field(
    "stall_threshold",
    0.25,
    decode.float,
  )
  use canary_enabled <- decode.optional_field(
    "canary_enabled",
    True,
    decode.bool,
  )
  decode.success(DprimeConfig(
    features:,
    tiers:,
    modify_threshold:,
    reject_threshold:,
    max_history:,
    stall_window:,
    stall_threshold:,
    canary_enabled:,
  ))
}

fn feature_decoder() -> decode.Decoder(types.Feature) {
  use name <- decode.field("name", decode.string)
  use importance_str <- decode.field("importance", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use critical <- decode.optional_field("critical", False, decode.bool)
  let importance = parse_importance(importance_str)
  decode.success(Feature(name:, importance:, description:, critical:))
}

fn parse_importance(s: String) -> types.Importance {
  case s {
    "high" -> High
    "medium" -> Medium
    "low" -> Low
    _ -> Medium
  }
}
