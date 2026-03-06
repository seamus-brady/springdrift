//// D' configuration — default features, JSON loading, state initialization.

import dprime/types.{
  type DprimeConfig, type DprimeState, DprimeConfig, DprimeState, Feature, High,
  Low, Medium,
}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import simplifile
import slog

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

/// Sensible default D' configuration with seven standard features
/// matching the spec's general-assistant-v1 configuration.
pub fn default() -> DprimeConfig {
  DprimeConfig(
    agent_id: "general-assistant-v1",
    features: [
      Feature(
        name: "user_safety",
        importance: High,
        description: "Could this action cause physical, financial, or psychological harm to the user or others?",
        critical: True,
        feature_set: None,
        feature_set_importance: None,
        group: None,
        group_importance: None,
      ),
      Feature(
        name: "accuracy",
        importance: High,
        description: "Could this action produce false, misleading, or unverifiable information?",
        critical: True,
        feature_set: None,
        feature_set_importance: None,
        group: None,
        group_importance: None,
      ),
      Feature(
        name: "legal_compliance",
        importance: High,
        description: "Could this action violate laws, regulations, or terms of service?",
        critical: True,
        feature_set: None,
        feature_set_importance: None,
        group: None,
        group_importance: None,
      ),
      Feature(
        name: "privacy",
        importance: Medium,
        description: "Could this action expose private information or violate data protection expectations?",
        critical: False,
        feature_set: None,
        feature_set_importance: None,
        group: None,
        group_importance: None,
      ),
      Feature(
        name: "user_autonomy",
        importance: Medium,
        description: "Could this action override, manipulate, or undermine the user's informed decision-making?",
        critical: False,
        feature_set: None,
        feature_set_importance: None,
        group: None,
        group_importance: None,
      ),
      Feature(
        name: "task_completion",
        importance: Low,
        description: "Does this action fail to accomplish what the user actually asked for?",
        critical: False,
        feature_set: None,
        feature_set_importance: None,
        group: None,
        group_importance: None,
      ),
      Feature(
        name: "proportionality",
        importance: Low,
        description: "Is this action disproportionate to what is needed?",
        critical: False,
        feature_set: None,
        feature_set_importance: None,
        group: None,
        group_importance: None,
      ),
    ],
    tiers: 1,
    modify_threshold: 1.2,
    reject_threshold: 2.0,
    reactive_reject_threshold: 0.8,
    min_modify_threshold: 0.8,
    min_reject_threshold: 1.5,
    allow_adaptation: False,
    max_history: 100,
    stall_window: 5,
    stall_threshold: 0.25,
    canary_enabled: True,
    max_iterations: 3,
    max_candidates: 3,
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
    iteration_count: 0,
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
  let defaults = default()
  use agent_id <- decode.optional_field(
    "agent_id",
    defaults.agent_id,
    decode.string,
  )
  use features <- decode.field("features", decode.list(feature_decoder()))
  use tiers <- decode.optional_field("tiers", defaults.tiers, decode.int)
  use modify_threshold <- decode.optional_field(
    "modify_threshold",
    defaults.modify_threshold,
    decode.float,
  )
  use reject_threshold <- decode.optional_field(
    "reject_threshold",
    defaults.reject_threshold,
    decode.float,
  )
  use reactive_reject_threshold <- decode.optional_field(
    "reactive_reject_threshold",
    defaults.reactive_reject_threshold,
    decode.float,
  )
  use min_modify_threshold <- decode.optional_field(
    "min_modify_threshold",
    defaults.min_modify_threshold,
    decode.float,
  )
  use min_reject_threshold <- decode.optional_field(
    "min_reject_threshold",
    defaults.min_reject_threshold,
    decode.float,
  )
  use allow_adaptation <- decode.optional_field(
    "allow_adaptation",
    defaults.allow_adaptation,
    decode.bool,
  )
  use max_history <- decode.optional_field(
    "max_history",
    defaults.max_history,
    decode.int,
  )
  use stall_window <- decode.optional_field(
    "stall_window",
    defaults.stall_window,
    decode.int,
  )
  use stall_threshold <- decode.optional_field(
    "stall_threshold",
    defaults.stall_threshold,
    decode.float,
  )
  use canary_enabled <- decode.optional_field(
    "canary_enabled",
    defaults.canary_enabled,
    decode.bool,
  )
  use max_iterations <- decode.optional_field(
    "max_iterations",
    defaults.max_iterations,
    decode.int,
  )
  use max_candidates <- decode.optional_field(
    "max_candidates",
    defaults.max_candidates,
    decode.int,
  )
  decode.success(DprimeConfig(
    agent_id:,
    features:,
    tiers:,
    modify_threshold:,
    reject_threshold:,
    reactive_reject_threshold:,
    min_modify_threshold:,
    min_reject_threshold:,
    allow_adaptation:,
    max_history:,
    stall_window:,
    stall_threshold:,
    canary_enabled:,
    max_iterations:,
    max_candidates:,
  ))
}

fn feature_decoder() -> decode.Decoder(types.Feature) {
  use name <- decode.field("name", decode.string)
  use importance_str <- decode.field("importance", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use critical <- decode.optional_field("critical", False, decode.bool)
  use feature_set <- decode.optional_field(
    "feature_set",
    None,
    decode.optional(decode.string),
  )
  use feature_set_importance_str <- decode.optional_field(
    "feature_set_importance",
    None,
    decode.optional(decode.string),
  )
  use group <- decode.optional_field(
    "group",
    None,
    decode.optional(decode.string),
  )
  use group_importance_str <- decode.optional_field(
    "group_importance",
    None,
    decode.optional(decode.string),
  )
  let importance = parse_importance(importance_str)
  let feature_set_importance = case feature_set_importance_str {
    Some(s) -> Some(parse_importance(s))
    None -> None
  }
  let group_importance = case group_importance_str {
    Some(s) -> Some(parse_importance(s))
    None -> None
  }
  decode.success(Feature(
    name:,
    importance:,
    description:,
    critical:,
    feature_set:,
    feature_set_importance:,
    group:,
    group_importance:,
  ))
}

fn parse_importance(s: String) -> types.Importance {
  case s {
    "high" -> High
    "medium" -> Medium
    "low" -> Low
    _ -> Medium
  }
}
