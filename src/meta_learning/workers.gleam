//// Meta-learning worker registry. Builds the list of BEAM workers
//// from `AppConfig` and spawns each under its own OTP process. Called
//// from `springdrift.gleam` at startup, after the Librarian, the
//// supervisor, and the Remembrancer agent are ready.
////
//// Seven workers run here, in two flavors:
////
//// **Mechanical audits** (DirectTool — pure compute, no LLM):
////   1. `affect_correlation`  — Pearson correlation over affect data
////   2. `fabrication_audit`   — synthesis-fact vs tool-log audit
////   3. `voice_drift`         — self-narration phrase counting
////
//// **Judgement jobs** (AgentDelegation — off-cog Remembrancer dispatch):
////   4. `consolidation`       — weekly memory synthesis + report
////   5. `goal_review`         — daily learning-goal evaluation
////   6. `skill_decay`         — weekly skill-decay audit
////   7. `strategy_review`     — fortnightly strategy evaluation
////
//// None of these appear in the agent scheduler. The scheduler is
//// reserved for operator-visible work. Meta-learning jobs live off-cog
//// so they don't pollute the operator queue and don't consume cognitive
//// loop cycles.
////
//// Judgement jobs depend on the Remembrancer being enabled and started.
//// If it's not, those workers still spawn but their ticks log-warn and
//// skip (the DirectTool workers are unaffected).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{type SupervisorMessage}
import config.{type AppConfig}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}
import meta_learning/worker.{
  type WorkerConfig, type WorkerMessage, AgentDelegation, DirectTool,
  WorkerConfig,
}
import paths
import simplifile
import slog
import tools/remembrancer as tools_remembrancer

// ---------------------------------------------------------------------------
// Defaults (hours) — mirror the retired scheduler-job cadences
// ---------------------------------------------------------------------------

const default_affect_correlation_hours = 168

const default_fabrication_audit_hours = 24

const default_voice_drift_hours = 24

const default_consolidation_hours = 168

const default_goal_review_hours = 24

const default_skill_decay_hours = 168

const default_strategy_review_hours = 336

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Build the list of worker configs for this AppConfig. Pure — no
/// process spawning, no disk I/O. Exposed so tests can inspect the
/// wiring without standing up workers.
pub fn build_configs(cfg: AppConfig) -> List(WorkerConfig) {
  [
    // Mechanical audits
    affect_correlation_config(cfg),
    fabrication_audit_config(cfg),
    voice_drift_config(cfg),
    // Judgement jobs
    consolidation_config(cfg),
    goal_review_config(cfg),
    skill_decay_config(cfg),
    strategy_review_config(cfg),
  ]
}

/// Start every enabled meta-learning worker. Returns the list of their
/// subjects so the caller can shut them down on exit. Safe to call
/// with workers disabled — returns the empty list.
pub fn start_all(
  cfg: AppConfig,
  remembrancer_ctx: tools_remembrancer.RemembrancerContext,
  supervisor: Option(Subject(SupervisorMessage)),
) -> List(Subject(WorkerMessage)) {
  case option.unwrap(cfg.meta_learning_enabled, True) {
    False -> {
      slog.info(
        "meta_learning/workers",
        "start_all",
        "Meta-learning workers disabled via config",
        option.None,
      )
      []
    }
    True -> {
      // Ensure the sidecar directory exists up-front.
      let _ = simplifile.create_directory_all(paths.meta_learning_dir())
      let state_file = paths.meta_learning_state_file()

      let configs = build_configs(cfg)
      let subjects =
        list.map(configs, fn(wc) {
          worker.start(wc, remembrancer_ctx, state_file, supervisor)
        })
      slog.info(
        "meta_learning/workers",
        "start_all",
        "Started 7 meta-learning BEAM workers (3 mechanical, 4 judgement)",
        option.None,
      )
      subjects
    }
  }
}

// ---------------------------------------------------------------------------
// Mechanical-audit configs (DirectTool)
// ---------------------------------------------------------------------------

fn affect_correlation_config(cfg: AppConfig) -> WorkerConfig {
  let hours =
    option.unwrap(
      cfg.meta_affect_correlation_interval_hours,
      default_affect_correlation_hours,
    )
  WorkerConfig(
    name: "affect_correlation",
    invocation: DirectTool(tool_name: "analyze_affect_performance"),
    interval_ms: hours_to_ms(hours),
  )
}

fn fabrication_audit_config(cfg: AppConfig) -> WorkerConfig {
  let hours =
    option.unwrap(
      cfg.meta_fabrication_audit_interval_hours,
      default_fabrication_audit_hours,
    )
  WorkerConfig(
    name: "fabrication_audit",
    invocation: DirectTool(tool_name: "audit_fabrication"),
    interval_ms: hours_to_ms(hours),
  )
}

fn voice_drift_config(cfg: AppConfig) -> WorkerConfig {
  let hours =
    option.unwrap(
      cfg.meta_voice_drift_interval_hours,
      default_voice_drift_hours,
    )
  WorkerConfig(
    name: "voice_drift",
    invocation: DirectTool(tool_name: "audit_voice_drift"),
    interval_ms: hours_to_ms(hours),
  )
}

// ---------------------------------------------------------------------------
// Judgement-job configs (AgentDelegation)
// ---------------------------------------------------------------------------

fn consolidation_config(cfg: AppConfig) -> WorkerConfig {
  let hours =
    option.unwrap(
      cfg.meta_consolidation_interval_hours,
      default_consolidation_hours,
    )
  WorkerConfig(
    name: "consolidation",
    invocation: AgentDelegation(
      instruction: "Run the weekly memory consolidation. Invoke "
        <> "`consolidate_memory` for the past week, then "
        <> "`write_consolidation_report` with the synthesised findings. "
        <> "Surface anything that warrants follow-up.",
      expected_tools: ["consolidate_memory", "write_consolidation_report"],
    ),
    interval_ms: hours_to_ms(hours),
  )
}

fn goal_review_config(cfg: AppConfig) -> WorkerConfig {
  let hours =
    option.unwrap(
      cfg.meta_goal_review_interval_hours,
      default_goal_review_hours,
    )
  WorkerConfig(
    name: "goal_review",
    invocation: AgentDelegation(
      instruction: "Review the active learning goals. Use "
        <> "`list_learning_goals` to see them, then for each goal: "
        <> "judge progress against acceptance criteria, add evidence "
        <> "cycle ids via `update_learning_goal`, and transition status "
        <> "(achieved/abandoned/paused) when warranted. Operator-directed "
        <> "goals are privileged — do not abandon without explicit "
        <> "justification.",
      expected_tools: ["list_learning_goals"],
    ),
    interval_ms: hours_to_ms(hours),
  )
}

fn skill_decay_config(cfg: AppConfig) -> WorkerConfig {
  let hours =
    option.unwrap(
      cfg.meta_skill_decay_interval_hours,
      default_skill_decay_hours,
    )
  WorkerConfig(
    name: "skill_decay",
    invocation: AgentDelegation(
      instruction: "Audit the skill set for decay. List skills via "
        <> "`read_skill` (use the paths in <available_skills>) and for "
        <> "each: judge whether the procedure still matches current "
        <> "practice. Archive skills no longer followed or that conflict "
        <> "with current strategies. Skill versioning is append-only — "
        <> "archival is a status flip, not a delete.",
      // Skill decay is a judgment pass; no single tool must fire.
      expected_tools: [],
    ),
    interval_ms: hours_to_ms(hours),
  )
}

fn strategy_review_config(cfg: AppConfig) -> WorkerConfig {
  let hours =
    option.unwrap(
      cfg.meta_strategy_review_interval_hours,
      default_strategy_review_hours,
    )
  WorkerConfig(
    name: "strategy_review",
    invocation: AgentDelegation(
      instruction: "Review the Strategy Registry. Inspect the active "
        <> "strategies shown in the sensorium <strategies> block and "
        <> "judge whether their success rates still justify keeping "
        <> "them. Strategies with sustained low success rates may "
        <> "warrant archival; recurring unnamed approaches may warrant "
        <> "a new strategy entry.",
      expected_tools: [],
    ),
    interval_ms: hours_to_ms(hours),
  )
}

fn hours_to_ms(hours: Int) -> Int {
  hours * 60 * 60 * 1000
}
