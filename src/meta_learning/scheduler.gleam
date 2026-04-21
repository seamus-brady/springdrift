//// Metacognitive Scheduler — meta-learning Phase F.
////
//// Pure module that turns the `[meta_learning]` config block into a list
//// of `ScheduleTaskConfig` values. The scheduler runner accepts these at
//// startup and arranges recurring delivery.
////
//// Each task's `query` is a natural-language instruction the cognitive
//// loop receives as a SchedulerInput when the timer fires. The query
//// tells the agent which Remembrancer tool to invoke and over what
//// period — keeping the orchestration entirely in plain text rather
//// than wiring tool calls directly from the scheduler.
////
//// Default: enabled. Operators opt out by setting
//// `[meta_learning] scheduler_enabled = false` in their config.toml.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import config.{type AppConfig}
import gleam/option.{None}
import paths
import scheduler/types.{
  type DeliveryConfig, type ScheduleTaskConfig, FileDelivery, ScheduleTaskConfig,
}

// ---------------------------------------------------------------------------
// Defaults (hours)
// ---------------------------------------------------------------------------

const default_consolidation_hours = 168

const default_goal_review_hours = 24

const default_skill_decay_hours = 168

const default_affect_correlation_hours = 168

const default_strategy_review_hours = 336

/// Phase 2 fluency/grounding. Daily fabrication audit.
const default_fabrication_audit_hours = 24

/// Phase 2 fluency/grounding. Daily voice-drift check.
const default_voice_drift_hours = 24

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Build the list of meta-learning recurring tasks from config. Returns
/// [] only when the operator explicitly disables via
/// `[meta_learning] scheduler_enabled = false`.
pub fn build_tasks(cfg: AppConfig) -> List(ScheduleTaskConfig) {
  case option.unwrap(cfg.meta_scheduler_enabled, True) {
    False -> []
    True -> {
      let delivery =
        FileDelivery(
          directory: paths.scheduler_outputs_dir(),
          format: "markdown",
        )
      [
        consolidation_task(cfg, delivery),
        goal_review_task(cfg, delivery),
        skill_decay_task(cfg, delivery),
        affect_correlation_task(cfg, delivery),
        strategy_review_task(cfg, delivery),
        fabrication_audit_task(cfg, delivery),
        voice_drift_task(cfg, delivery),
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Individual tasks
// ---------------------------------------------------------------------------

fn consolidation_task(
  cfg: AppConfig,
  delivery: DeliveryConfig,
) -> ScheduleTaskConfig {
  let hours =
    option.unwrap(
      cfg.meta_consolidation_interval_hours,
      default_consolidation_hours,
    )
  ScheduleTaskConfig(
    name: "meta_learning_consolidation",
    query: "Run the weekly memory consolidation. Delegate to the Remembrancer "
      <> "agent: invoke `consolidate_memory` for the past week, then "
      <> "`write_consolidation_report` with the synthesised findings. "
      <> "Surface anything that warrants follow-up.",
    interval_ms: hours_to_ms(hours),
    start_at: None,
    delivery: delivery,
    only_if_changed: False,
    // Both named tools must fire for the job to count as complete.
    required_tools: ["consolidate_memory", "write_consolidation_report"],
  )
}

fn goal_review_task(
  cfg: AppConfig,
  delivery: DeliveryConfig,
) -> ScheduleTaskConfig {
  let hours =
    option.unwrap(
      cfg.meta_goal_review_interval_hours,
      default_goal_review_hours,
    )
  ScheduleTaskConfig(
    name: "meta_learning_goal_review",
    query: "Review your active learning goals. Use `list_learning_goals` to "
      <> "see them, then for each goal: judge progress against acceptance "
      <> "criteria, add evidence cycle ids via `update_learning_goal`, and "
      <> "transition status (achieved/abandoned/paused) when warranted. "
      <> "Operator-directed goals are privileged — do not abandon without "
      <> "explicit justification.",
    interval_ms: hours_to_ms(hours),
    start_at: None,
    delivery: delivery,
    only_if_changed: False,
    required_tools: ["list_learning_goals"],
  )
}

fn skill_decay_task(
  cfg: AppConfig,
  delivery: DeliveryConfig,
) -> ScheduleTaskConfig {
  let hours =
    option.unwrap(
      cfg.meta_skill_decay_interval_hours,
      default_skill_decay_hours,
    )
  ScheduleTaskConfig(
    name: "meta_learning_skill_decay",
    query: "Audit your skill set for decay. List skills via `read_skill` "
      <> "(use the paths in <available_skills>) and for each: judge whether "
      <> "the procedure still matches your current practice. Archive skills "
      <> "you no longer follow or that conflict with current strategies. "
      <> "Skill versioning is append-only — archival is a status flip, "
      <> "not a delete.",
    interval_ms: hours_to_ms(hours),
    start_at: None,
    delivery: delivery,
    only_if_changed: False,
    // Skill decay is a judgment pass, not a tool invocation — no
    // specific tool is strictly required.
    required_tools: [],
  )
}

fn affect_correlation_task(
  cfg: AppConfig,
  delivery: DeliveryConfig,
) -> ScheduleTaskConfig {
  let hours =
    option.unwrap(
      cfg.meta_affect_correlation_interval_hours,
      default_affect_correlation_hours,
    )
  ScheduleTaskConfig(
    name: "meta_learning_affect_correlation",
    query: "Run affect-performance correlation analysis. Delegate to the "
      <> "Remembrancer agent: invoke `analyze_affect_performance` for the "
      <> "past 30 days. Significant correlations (|r| >= 0.4) are persisted "
      <> "as facts under the `affect_corr_*` prefix and surface in the "
      <> "sensorium <affect_warnings> block.",
    interval_ms: hours_to_ms(hours),
    start_at: None,
    delivery: delivery,
    only_if_changed: False,
    // The April 20 fabrication incident: agent claimed to run this
    // analysis without calling the tool. The job now fails if the
    // required tool doesn't fire, turning what was narrated success
    // into visible failure on the scheduler tab.
    required_tools: ["analyze_affect_performance"],
  )
}

fn strategy_review_task(
  cfg: AppConfig,
  delivery: DeliveryConfig,
) -> ScheduleTaskConfig {
  let hours =
    option.unwrap(
      cfg.meta_strategy_review_interval_hours,
      default_strategy_review_hours,
    )
  ScheduleTaskConfig(
    name: "meta_learning_strategy_review",
    query: "Review your Strategy Registry. Inspect the active strategies "
      <> "shown in the sensorium <strategies> block and judge whether their "
      <> "success rates still justify keeping them. Strategies with sustained "
      <> "low success rates may warrant archival; recurring unnamed approaches "
      <> "may warrant a new strategy entry.",
    interval_ms: hours_to_ms(hours),
    start_at: None,
    delivery: delivery,
    only_if_changed: False,
    // Review is a judgment pass against the sensorium — no single
    // tool must fire.
    required_tools: [],
  )
}

fn fabrication_audit_task(
  cfg: AppConfig,
  delivery: DeliveryConfig,
) -> ScheduleTaskConfig {
  let hours =
    option.unwrap(
      cfg.meta_fabrication_audit_interval_hours,
      default_fabrication_audit_hours,
    )
  ScheduleTaskConfig(
    name: "meta_learning_fabrication_audit",
    query: "Run the daily fabrication audit. Delegate to the Remembrancer "
      <> "agent: invoke `audit_fabrication` with the default 7-day window. "
      <> "This cross-references synthesis-derivation facts against the "
      <> "cycle-log tool-call record. Flagged facts are written to "
      <> "integrity_suspect_facts_7d and surface in the sensorium "
      <> "<integrity> block. If the count increased relative to prior "
      <> "windows, review the flagged fact ids and consider proposing "
      <> "clearances as evidence on the integrity learning goal. Do not "
      <> "clear facts yourself — the operator approves clearances.",
    interval_ms: hours_to_ms(hours),
    start_at: None,
    delivery: delivery,
    only_if_changed: False,
  )
}

fn voice_drift_task(
  cfg: AppConfig,
  delivery: DeliveryConfig,
) -> ScheduleTaskConfig {
  let hours =
    option.unwrap(
      cfg.meta_voice_drift_interval_hours,
      default_voice_drift_hours,
    )
  ScheduleTaskConfig(
    name: "meta_learning_voice_drift",
    query: "Run the daily voice-drift check. Delegate to the Remembrancer "
      <> "agent: invoke `audit_voice_drift`. The check counts self-"
      <> "congratulatory and identity-narration phrases in your narrative "
      <> "entries over the last 7 days and compares against the prior 7 "
      <> "days. A negative delta is good — drift is decreasing. Result is "
      <> "written to integrity_voice_drift_7d and surfaces in the "
      <> "sensorium <integrity> block. Do not interpret the metric as a "
      <> "performance target to narrate about; the metric is a signal to "
      <> "monitor, not an achievement to celebrate.",
    interval_ms: hours_to_ms(hours),
    start_at: None,
    delivery: delivery,
    only_if_changed: False,
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn hours_to_ms(hours: Int) -> Int {
  hours * 60 * 60 * 1000
}
