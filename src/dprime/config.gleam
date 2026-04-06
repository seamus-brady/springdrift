//// D' configuration — default features, JSON loading, state initialization.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/deterministic.{
  type DeterministicConfig, type DeterministicRule, type RuleAction, BlockAction,
  DeterministicConfig, DeterministicRule, EscalateAction,
}
import dprime/types.{
  type DprimeConfig, type DprimeState, DprimeConfig, DprimeState, Feature, High,
  Low, Medium,
}
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import meta/types as meta_types
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
    modify_threshold: 0.35,
    reject_threshold: 0.55,
    reactive_reject_threshold: 0.65,
    min_modify_threshold: 0.2,
    min_reject_threshold: 0.4,
    allow_adaptation: False,
    max_history: 100,
    stall_window: 5,
    stall_threshold: 0.25,
    canary_enabled: True,
    max_iterations: 3,
    max_candidates: 3,
    max_output_modifications: 2,
  )
}

// ---------------------------------------------------------------------------
// Unified config — covers all gates, agent overrides, and meta observer
// ---------------------------------------------------------------------------

/// Unified D' configuration covering all gates, agent overrides, and meta observer.
pub type UnifiedDprimeConfig {
  UnifiedDprimeConfig(
    input_gate: DprimeConfig,
    tool_gate: DprimeConfig,
    output_gate: Option(DprimeConfig),
    post_exec_gate: Option(DprimeConfig),
    agent_overrides: List(AgentDprimeOverride),
    meta: Option(meta_types.MetaConfig),
    deterministic: DeterministicConfig,
  )
}

pub type AgentDprimeOverride {
  AgentDprimeOverride(agent_name: String, tool_gate: Option(DprimeConfig))
}

/// Default unified config — all gates use default(), no overrides, no meta override.
pub fn default_unified() -> UnifiedDprimeConfig {
  UnifiedDprimeConfig(
    input_gate: default(),
    tool_gate: default(),
    output_gate: None,
    post_exec_gate: None,
    agent_overrides: [],
    meta: None,
    deterministic: deterministic.default_config(),
  )
}

/// Look up the tool gate config for a specific agent, falling back to the
/// unified tool_gate when no override exists.
pub fn get_agent_tool_config(
  unified: UnifiedDprimeConfig,
  agent_name: String,
) -> DprimeConfig {
  case
    list.find(unified.agent_overrides, fn(o) { o.agent_name == agent_name })
  {
    Ok(override) ->
      case override.tool_gate {
        Some(cfg) -> cfg
        None -> unified.tool_gate
      }
    Error(_) -> unified.tool_gate
  }
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

/// Load dual-gate D' config from a JSON file.
/// Returns #(tool_gate_config, output_gate_config_or_none).
/// If the JSON has "tool_gate" and "output_gate" sections, parses both.
/// Otherwise treats the entire JSON as a single (tool gate) config.
pub fn load_dual(path: String) -> #(DprimeConfig, Option(DprimeConfig)) {
  slog.debug(
    "dprime/config",
    "load_dual",
    "Loading dual-gate D' config from " <> path,
    None,
  )
  case simplifile.read(path) {
    Error(_) -> {
      slog.info(
        "dprime/config",
        "load_dual",
        "Config file not found, using defaults (no output gate)",
        None,
      )
      #(default(), None)
    }
    Ok(contents) -> {
      // Try dual-gate format first
      case json.parse(contents, dual_gate_decoder()) {
        Ok(#(tool_cfg, output_cfg)) -> {
          slog.info(
            "dprime/config",
            "load_dual",
            "Loaded dual-gate config: tool_gate ("
              <> int.to_string(list.length(tool_cfg.features))
              <> " features), output_gate ("
              <> int.to_string(list.length(output_cfg.features))
              <> " features)",
            None,
          )
          #(tool_cfg, Some(output_cfg))
        }
        Error(_) ->
          // Fall back to single-gate format
          case json.parse(contents, config_decoder()) {
            Ok(cfg) -> {
              slog.info(
                "dprime/config",
                "load_dual",
                "Loaded single-gate config with "
                  <> int.to_string(list.length(cfg.features))
                  <> " features",
                None,
              )
              #(cfg, None)
            }
            Error(_) -> {
              slog.warn(
                "dprime/config",
                "load_dual",
                "Config parse failed, using defaults",
                None,
              )
              #(default(), None)
            }
          }
      }
    }
  }
}

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

/// Load unified D' config from a JSON file.
/// Tries the new unified format first (has "gates" key), falls back to the
/// old dual-gate format (has "tool_gate" key), then to defaults.
pub fn load_unified(path: String) -> UnifiedDprimeConfig {
  slog.debug(
    "dprime/config",
    "load_unified",
    "Loading unified D' config from " <> path,
    None,
  )
  case simplifile.read(path) {
    Error(_) -> {
      slog.info(
        "dprime/config",
        "load_unified",
        "Config file not found, using defaults",
        None,
      )
      default_unified()
    }
    Ok(contents) -> {
      // Try unified format first (has "gates" key)
      case json.parse(contents, unified_decoder()) {
        Ok(unified) -> {
          slog.info(
            "dprime/config",
            "load_unified",
            "Loaded unified config: input_gate ("
              <> int.to_string(list.length(unified.input_gate.features))
              <> " features), tool_gate ("
              <> int.to_string(list.length(unified.tool_gate.features))
              <> " features), "
              <> int.to_string(list.length(unified.agent_overrides))
              <> " agent overrides",
            None,
          )
          unified
        }
        Error(_) ->
          // Fall back to dual-gate format
          case json.parse(contents, dual_gate_decoder()) {
            Ok(#(tool_cfg, output_cfg)) -> {
              slog.info(
                "dprime/config",
                "load_unified",
                "Loaded dual-gate config as unified (tool_gate as input+tool)",
                None,
              )
              UnifiedDprimeConfig(
                input_gate: tool_cfg,
                tool_gate: tool_cfg,
                output_gate: Some(output_cfg),
                post_exec_gate: None,
                agent_overrides: [],
                meta: None,
                deterministic: deterministic.default_config(),
              )
            }
            Error(_) ->
              // Fall back to single-gate format
              case json.parse(contents, config_decoder()) {
                Ok(cfg) -> {
                  slog.info(
                    "dprime/config",
                    "load_unified",
                    "Loaded single-gate config as unified",
                    None,
                  )
                  UnifiedDprimeConfig(
                    input_gate: cfg,
                    tool_gate: cfg,
                    output_gate: None,
                    post_exec_gate: None,
                    agent_overrides: [],
                    meta: None,
                    deterministic: deterministic.default_config(),
                  )
                }
                Error(_) -> {
                  slog.warn(
                    "dprime/config",
                    "load_unified",
                    "Config parse failed, using defaults",
                    None,
                  )
                  default_unified()
                }
              }
          }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Unified format decoder
// ---------------------------------------------------------------------------

fn unified_decoder() -> decode.Decoder(UnifiedDprimeConfig) {
  use gates <- decode.field("gates", gates_decoder())
  // agent_overrides can be either:
  // - object keyed by agent name: {"coder": {"tool": {...}}}  (current format)
  // - list with agent_name field: [{"agent_name": "coder", "tool": {...}}]  (legacy)
  use agent_overrides <- decode.optional_field(
    "agent_overrides",
    [],
    decode.one_of(
      // Try object/dict format first (current)
      decode.map(
        decode.dict(decode.string, agent_override_value_decoder()),
        fn(d) {
          dict.to_list(d)
          |> list.map(fn(pair) {
            let #(name, tool_gate) = pair
            AgentDprimeOverride(agent_name: name, tool_gate: tool_gate)
          })
        },
      ),
      [
        // Fall back to list format (legacy)
        decode.list(agent_override_list_decoder()),
      ],
    ),
  )
  use meta <- decode.optional_field(
    "meta",
    None,
    decode.optional(meta_decoder()),
  )
  use shared <- decode.optional_field(
    "shared",
    None,
    decode.optional(shared_decoder()),
  )
  use det <- decode.optional_field(
    "deterministic",
    deterministic.default_config(),
    deterministic_config_decoder(),
  )

  // Apply shared fields to all gates that don't explicitly override them
  let input_gate = apply_shared(gates.0, shared)
  let tool_gate = apply_shared(gates.1, shared)
  let output_gate = option.map(gates.2, apply_shared(_, shared))
  let post_exec_gate = option.map(gates.3, apply_shared(_, shared))

  decode.success(UnifiedDprimeConfig(
    input_gate:,
    tool_gate:,
    output_gate:,
    post_exec_gate:,
    agent_overrides:,
    meta:,
    deterministic: det,
  ))
}

fn gates_decoder() -> decode.Decoder(
  #(DprimeConfig, DprimeConfig, Option(DprimeConfig), Option(DprimeConfig)),
) {
  use input <- decode.field("input", config_decoder())
  use tool <- decode.field("tool", config_decoder())
  use output <- decode.optional_field(
    "output",
    None,
    decode.optional(config_decoder()),
  )
  use post_exec <- decode.optional_field(
    "post_exec",
    None,
    decode.optional(config_decoder()),
  )
  decode.success(#(input, tool, output, post_exec))
}

/// Decode the value side of an agent override entry (dict format): {"tool": {...}}
fn agent_override_value_decoder() -> decode.Decoder(Option(DprimeConfig)) {
  use tool_gate <- decode.optional_field(
    "tool",
    None,
    decode.optional(config_decoder()),
  )
  decode.success(tool_gate)
}

/// Decode a single agent override from list format (legacy): {"agent_name": "coder", "tool": {...}}
fn agent_override_list_decoder() -> decode.Decoder(AgentDprimeOverride) {
  use agent_name <- decode.field("agent_name", decode.string)
  use tool_gate <- decode.optional_field(
    "tool",
    None,
    decode.optional(config_decoder()),
  )
  decode.success(AgentDprimeOverride(agent_name:, tool_gate:))
}

fn meta_decoder() -> decode.Decoder(meta_types.MetaConfig) {
  let defaults = meta_types.default_config()
  use enabled <- decode.optional_field("enabled", defaults.enabled, decode.bool)
  use max_history <- decode.optional_field(
    "max_history",
    defaults.max_history,
    decode.int,
  )
  use rate_limit_max_cycles <- decode.optional_field(
    "rate_limit_max_cycles",
    defaults.rate_limit_max_cycles,
    decode.int,
  )
  use rate_limit_window_ms <- decode.optional_field(
    "rate_limit_window_ms",
    defaults.rate_limit_window_ms,
    decode.int,
  )
  use elevated_score_threshold <- decode.optional_field(
    "elevated_score_threshold",
    defaults.elevated_score_threshold,
    decode.float,
  )
  use elevated_streak_threshold <- decode.optional_field(
    "elevated_streak_threshold",
    defaults.elevated_streak_threshold,
    decode.int,
  )
  use rejection_count_threshold <- decode.optional_field(
    "rejection_count_threshold",
    defaults.rejection_count_threshold,
    decode.int,
  )
  use rejection_window_cycles <- decode.optional_field(
    "rejection_window_cycles",
    defaults.rejection_window_cycles,
    decode.int,
  )
  use layer3a_tightening_threshold <- decode.optional_field(
    "layer3a_tightening_threshold",
    defaults.layer3a_tightening_threshold,
    decode.int,
  )
  use layer3a_window_cycles <- decode.optional_field(
    "layer3a_window_cycles",
    defaults.layer3a_window_cycles,
    decode.int,
  )
  use drift_check_enabled <- decode.optional_field(
    "drift_check_enabled",
    defaults.drift_check_enabled,
    decode.bool,
  )
  use drift_check_interval <- decode.optional_field(
    "drift_check_interval",
    defaults.drift_check_interval,
    decode.int,
  )
  use cooldown_delay_ms <- decode.optional_field(
    "cooldown_delay_ms",
    defaults.cooldown_delay_ms,
    decode.int,
  )
  use tighten_factor <- decode.optional_field(
    "tighten_factor",
    defaults.tighten_factor,
    decode.float,
  )
  use decay_days <- decode.optional_field(
    "decay_days",
    defaults.decay_days,
    decode.int,
  )
  decode.success(meta_types.MetaConfig(
    enabled:,
    max_history:,
    rate_limit_max_cycles:,
    rate_limit_window_ms:,
    elevated_score_threshold:,
    elevated_streak_threshold:,
    rejection_count_threshold:,
    rejection_window_cycles:,
    layer3a_tightening_threshold:,
    layer3a_window_cycles:,
    drift_check_enabled:,
    drift_check_interval:,
    cooldown_delay_ms:,
    tighten_factor:,
    decay_days:,
  ))
}

/// Shared fields that can be applied to all gates.
pub type SharedConfig {
  SharedConfig(
    tiers: Option(Int),
    max_history: Option(Int),
    stall_window: Option(Int),
    max_iterations: Option(Int),
  )
}

fn shared_decoder() -> decode.Decoder(SharedConfig) {
  use tiers <- decode.optional_field("tiers", None, decode.optional(decode.int))
  use max_history <- decode.optional_field(
    "max_history",
    None,
    decode.optional(decode.int),
  )
  use stall_window <- decode.optional_field(
    "stall_window",
    None,
    decode.optional(decode.int),
  )
  use max_iterations <- decode.optional_field(
    "max_iterations",
    None,
    decode.optional(decode.int),
  )
  decode.success(SharedConfig(
    tiers:,
    max_history:,
    stall_window:,
    max_iterations:,
  ))
}

/// Apply shared config fields to a gate config. The gate's own values take
/// precedence — shared fields only fill in when the gate used its defaults.
fn apply_shared(cfg: DprimeConfig, shared: Option(SharedConfig)) -> DprimeConfig {
  let defaults = default()
  case shared {
    None -> cfg
    Some(s) -> {
      // Only apply shared value if the gate still has the default value
      // (i.e. it didn't explicitly set its own)
      let tiers = case s.tiers {
        Some(v) if cfg.tiers == defaults.tiers -> v
        _ -> cfg.tiers
      }
      let max_history = case s.max_history {
        Some(v) if cfg.max_history == defaults.max_history -> v
        _ -> cfg.max_history
      }
      let stall_window = case s.stall_window {
        Some(v) if cfg.stall_window == defaults.stall_window -> v
        _ -> cfg.stall_window
      }
      let max_iterations = case s.max_iterations {
        Some(v) if cfg.max_iterations == defaults.max_iterations -> v
        _ -> cfg.max_iterations
      }
      DprimeConfig(..cfg, tiers:, max_history:, stall_window:, max_iterations:)
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
  use max_output_modifications <- decode.optional_field(
    "max_output_modifications",
    defaults.max_output_modifications,
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
    max_output_modifications:,
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

fn dual_gate_decoder() -> decode.Decoder(#(DprimeConfig, DprimeConfig)) {
  use tool_gate <- decode.field("tool_gate", config_decoder())
  use output_gate <- decode.field("output_gate", config_decoder())
  decode.success(#(tool_gate, output_gate))
}

// ---------------------------------------------------------------------------
// Deterministic config decoder
// ---------------------------------------------------------------------------

fn deterministic_config_decoder() -> decode.Decoder(DeterministicConfig) {
  let defaults = deterministic.default_config()
  use enabled <- decode.optional_field("enabled", defaults.enabled, decode.bool)
  use input_rules <- decode.optional_field(
    "input_rules",
    [],
    decode.list(deterministic_rule_decoder()),
  )
  use tool_rules <- decode.optional_field(
    "tool_rules",
    [],
    decode.list(deterministic_rule_decoder()),
  )
  use output_rules <- decode.optional_field(
    "output_rules",
    [],
    decode.list(deterministic_rule_decoder()),
  )
  use path_allowlist <- decode.optional_field(
    "path_allowlist",
    [],
    decode.list(decode.string),
  )
  use domain_allowlist <- decode.optional_field(
    "domain_allowlist",
    [],
    decode.list(decode.string),
  )
  decode.success(DeterministicConfig(
    enabled:,
    input_rules:,
    tool_rules:,
    output_rules:,
    path_allowlist:,
    domain_allowlist:,
  ))
}

fn deterministic_rule_decoder() -> decode.Decoder(DeterministicRule) {
  use id <- decode.field("id", decode.string)
  use pattern <- decode.field("pattern", decode.string)
  use action_str <- decode.field("action", decode.string)
  let action = parse_rule_action(action_str)
  decode.success(DeterministicRule(id:, pattern:, action:))
}

fn parse_rule_action(s: String) -> RuleAction {
  case s {
    "block" -> BlockAction
    "escalate" -> EscalateAction
    _ -> EscalateAction
  }
}
