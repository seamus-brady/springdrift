//// Tests for meta_learning/workers — pure config-builder behaviour.
//// Verifies the seven workers are wired with the right invocation
//// mode, tool/instruction, and interval derived from AppConfig.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import config
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import meta_learning/worker.{AgentDelegation, DirectTool}
import meta_learning/workers

fn base_cfg() -> config.AppConfig {
  config.default()
}

fn find_config(
  configs: List(worker.WorkerConfig),
  name: String,
) -> worker.WorkerConfig {
  let assert Ok(c) = list.find(configs, fn(w) { w.name == name })
  c
}

pub fn builds_seven_workers_test() {
  workers.build_configs(base_cfg())
  |> list.length
  |> should.equal(7)
}

pub fn mechanical_audits_use_direct_tool_test() {
  let configs = workers.build_configs(base_cfg())

  let affect = find_config(configs, "affect_correlation")
  case affect.invocation {
    DirectTool(tool_name:) ->
      tool_name |> should.equal("analyze_affect_performance")
    _ -> panic as "affect_correlation should be DirectTool"
  }

  let fab = find_config(configs, "fabrication_audit")
  case fab.invocation {
    DirectTool(tool_name:) -> tool_name |> should.equal("audit_fabrication")
    _ -> panic as "fabrication_audit should be DirectTool"
  }

  let voice = find_config(configs, "voice_drift")
  case voice.invocation {
    DirectTool(tool_name:) -> tool_name |> should.equal("audit_voice_drift")
    _ -> panic as "voice_drift should be DirectTool"
  }
}

pub fn judgement_jobs_use_agent_delegation_test() {
  let configs = workers.build_configs(base_cfg())

  let cons = find_config(configs, "consolidation")
  case cons.invocation {
    AgentDelegation(expected_tools:, ..) ->
      expected_tools
      |> should.equal(["consolidate_memory", "write_consolidation_report"])
    _ -> panic as "consolidation should be AgentDelegation"
  }

  let goal = find_config(configs, "goal_review")
  case goal.invocation {
    AgentDelegation(expected_tools:, ..) ->
      expected_tools |> should.equal(["list_learning_goals"])
    _ -> panic as "goal_review should be AgentDelegation"
  }

  let skill = find_config(configs, "skill_decay")
  case skill.invocation {
    AgentDelegation(expected_tools:, ..) -> expected_tools |> should.equal([])
    _ -> panic as "skill_decay should be AgentDelegation"
  }

  let strat = find_config(configs, "strategy_review")
  case strat.invocation {
    AgentDelegation(expected_tools:, ..) -> expected_tools |> should.equal([])
    _ -> panic as "strategy_review should be AgentDelegation"
  }
}

pub fn default_intervals_match_retired_scheduler_cadences_test() {
  let configs = workers.build_configs(base_cfg())
  let hour_ms = 60 * 60 * 1000

  find_config(configs, "affect_correlation").interval_ms
  |> should.equal(168 * hour_ms)
  find_config(configs, "fabrication_audit").interval_ms
  |> should.equal(24 * hour_ms)
  find_config(configs, "voice_drift").interval_ms
  |> should.equal(24 * hour_ms)

  find_config(configs, "consolidation").interval_ms
  |> should.equal(168 * hour_ms)
  find_config(configs, "goal_review").interval_ms |> should.equal(24 * hour_ms)
  find_config(configs, "skill_decay").interval_ms
  |> should.equal(168 * hour_ms)
  find_config(configs, "strategy_review").interval_ms
  |> should.equal(336 * hour_ms)
}

pub fn interval_overrides_from_config_test() {
  let cfg =
    config.AppConfig(
      ..base_cfg(),
      meta_consolidation_interval_hours: Some(1),
      meta_goal_review_interval_hours: Some(2),
      meta_skill_decay_interval_hours: Some(3),
      meta_strategy_review_interval_hours: Some(4),
      meta_affect_correlation_interval_hours: Some(5),
      meta_fabrication_audit_interval_hours: Some(6),
      meta_voice_drift_interval_hours: Some(7),
    )
  let configs = workers.build_configs(cfg)
  let hour_ms = 60 * 60 * 1000
  find_config(configs, "consolidation").interval_ms |> should.equal(1 * hour_ms)
  find_config(configs, "goal_review").interval_ms |> should.equal(2 * hour_ms)
  find_config(configs, "skill_decay").interval_ms |> should.equal(3 * hour_ms)
  find_config(configs, "strategy_review").interval_ms
  |> should.equal(4 * hour_ms)
  find_config(configs, "affect_correlation").interval_ms
  |> should.equal(5 * hour_ms)
  find_config(configs, "fabrication_audit").interval_ms
  |> should.equal(6 * hour_ms)
  find_config(configs, "voice_drift").interval_ms |> should.equal(7 * hour_ms)
}

pub fn agent_instructions_reference_expected_tools_test() {
  // AgentDelegation instructions must name the tools we listed in
  // expected_tools — otherwise the worker log-warn fires every tick
  // because the agent naturally won't know to call them.
  let configs = workers.build_configs(base_cfg())

  let cons = find_config(configs, "consolidation")
  case cons.invocation {
    AgentDelegation(instruction:, ..) -> {
      should.be_true(string.contains(instruction, "consolidate_memory"))
      should.be_true(string.contains(instruction, "write_consolidation_report"))
    }
    _ -> Nil
  }

  let goal = find_config(configs, "goal_review")
  case goal.invocation {
    AgentDelegation(instruction:, ..) ->
      should.be_true(string.contains(instruction, "list_learning_goals"))
    _ -> Nil
  }
}

pub fn worker_names_are_not_meta_learning_prefixed_test() {
  // Worker names must NOT start with "meta_learning_" — that prefix is
  // used by the scheduler's migration filter to sweep legacy persisted
  // jobs. Using it here would risk the migration filter eating our
  // own workers' output if they were ever re-routed through the log.
  let configs = workers.build_configs(base_cfg())
  list.each(configs, fn(c) {
    should.be_false(string.starts_with(c.name, "meta_learning_"))
  })
}
