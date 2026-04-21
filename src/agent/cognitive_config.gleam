// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive/escalation.{type EscalationConfig}
import agent/registry.{type Registry}
import agent/team
import agent/types.{type Notification}
import agentlair/types as agentlair_types
import dprime/deterministic.{type DeterministicConfig}
import dprime/types as dprime_types
import facts/provenance_check
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None}
import gleam/string
import llm/provider.{type Provider}
import llm/retry
import llm/types as llm_types
import meta/types as meta_types
import narrative/curator.{type CuratorMessage}
import narrative/librarian.{type LibrarianMessage}
import narrative/threading
import normative/types as normative_types
import simplifile
import tools/memory

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

/// Configuration record for starting the cognitive loop.
/// Replaces the 19-parameter `cognitive.start()` signature.
pub type CognitiveConfig {
  CognitiveConfig(
    provider: Provider,
    system: String,
    max_tokens: Int,
    max_context_messages: Option(Int),
    agent_tools: List(llm_types.Tool),
    initial_messages: List(llm_types.Message),
    registry: Registry,
    verbose: Bool,
    notify: Subject(Notification),
    task_model: String,
    reasoning_model: String,
    input_dprime_state: Option(dprime_types.DprimeState),
    tool_dprime_state: Option(dprime_types.DprimeState),
    output_dprime_state: Option(dprime_types.DprimeState),
    meta_config: Option(meta_types.MetaConfig),
    narrative_dir: String,
    cbr_dir: String,
    thinking_budget_tokens: Option(Int),
    archivist_model: String,
    archivist_max_tokens: Int,
    appraiser_model: String,
    appraiser_max_tokens: Int,
    appraisal_min_complexity: String,
    appraisal_min_steps: Int,
    librarian: Option(Subject(LibrarianMessage)),
    write_anywhere: Bool,
    curator: Option(Subject(CuratorMessage)),
    agent_uuid: String,
    agent_name: String,
    session_since: String,
    retry_config: retry.RetryConfig,
    classify_timeout_ms: Int,
    threading_config: threading.ThreadingConfig,
    memory_limits: memory.MemoryLimits,
    input_queue_cap: Int,
    how_to_content: Option(String),
    redact_secrets: Bool,
    planner_dir: String,
    max_delegation_depth: Int,
    sandbox_enabled: Bool,
    deterministic_config: Option(DeterministicConfig),
    fact_decay_half_life_days: Int,
    escalation_config: EscalationConfig,
    gate_timeout_ms: Int,
    normative_calculus_enabled: Bool,
    character_spec: Option(normative_types.CharacterSpec),
    team_specs: List(team.TeamSpec),
    team_guards: team.TeamGuards,
    agentlair_config: Option(agentlair_types.AgentLairConfig),
    /// Meta-learning Phase A — when False, the Archivist drops
    /// strategy_used emissions and skips StrategyUsed/StrategyOutcome
    /// event logging. Default True.
    strategy_registry_enabled: Bool,
    /// Phase 3a synthesis-provenance classification. Threaded through
    /// so memory_write can downgrade unsupported synthesis facts at
    /// write time. Default: provenance_check.default_config().
    evidence_config: provenance_check.EvidenceConfig,
  )
}

/// Create a CognitiveConfig with sensible defaults for testing.
/// Uses isolated temp directories so tests never pollute the live memory store.
pub fn default_test_config(
  provider: Provider,
  notify: Subject(Notification),
) -> CognitiveConfig {
  let id = string.slice(generate_uuid(), 0, 8)
  let base = "/tmp/springdrift_test/" <> id
  let narrative_dir = base <> "/narrative"
  let cbr_dir = base <> "/cbr"
  let _ = simplifile.create_directory_all(narrative_dir)
  let _ = simplifile.create_directory_all(cbr_dir)
  CognitiveConfig(
    provider:,
    system: "You are a test assistant.",
    max_tokens: 256,
    max_context_messages: None,
    agent_tools: [],
    initial_messages: [],
    registry: registry.new(),
    verbose: False,
    notify:,
    task_model: "mock-model",
    reasoning_model: "mock-reasoning",
    input_dprime_state: None,
    tool_dprime_state: None,
    output_dprime_state: None,
    meta_config: None,
    narrative_dir:,
    cbr_dir:,
    thinking_budget_tokens: None,
    archivist_model: "mock-model",
    archivist_max_tokens: 8192,
    appraiser_model: "mock-model",
    appraiser_max_tokens: 4096,
    appraisal_min_complexity: "medium",
    appraisal_min_steps: 3,
    librarian: None,
    write_anywhere: False,
    curator: None,
    agent_uuid: "",
    agent_name: "test-agent",
    session_since: "",
    retry_config: retry.default_retry_config(),
    classify_timeout_ms: 10_000,
    threading_config: threading.default_config(),
    memory_limits: memory.default_limits(),
    input_queue_cap: 10,
    how_to_content: None,
    redact_secrets: False,
    planner_dir: base <> "/planner",
    max_delegation_depth: 3,
    sandbox_enabled: False,
    deterministic_config: None,
    fact_decay_half_life_days: 30,
    escalation_config: escalation.default_config(),
    gate_timeout_ms: 60_000,
    normative_calculus_enabled: False,
    character_spec: None,
    team_specs: [],
    team_guards: team.default_guards(),
    agentlair_config: None,
    strategy_registry_enabled: True,
    evidence_config: provenance_check.default_config(),
  )
}
