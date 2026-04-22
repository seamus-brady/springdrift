////
//// Tests for the Phase F metacognitive scheduler — pure config -> task
//// list translation.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import config
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import meta_learning/scheduler as meta_scheduler

fn base_cfg() -> config.AppConfig {
  config.default()
}

fn enabled_cfg() -> config.AppConfig {
  let c = base_cfg()
  config.AppConfig(..c, meta_scheduler_enabled: Some(True))
}

// ---------------------------------------------------------------------------
// Enabled by default — operator opts out
// ---------------------------------------------------------------------------

pub fn enabled_when_unset_test() {
  // Default config (no meta_scheduler_enabled set) emits the full task list.
  let tasks = meta_scheduler.build_tasks(base_cfg())
  list.length(tasks) |> should.equal(4)
}

pub fn disabled_when_explicitly_false_test() {
  let c = config.AppConfig(..base_cfg(), meta_scheduler_enabled: Some(False))
  meta_scheduler.build_tasks(c) |> should.equal([])
}

// ---------------------------------------------------------------------------
// Enabled — four judgement tasks. The three mechanical audits (affect
// correlation, fabrication audit, voice drift) moved to BEAM workers
// in meta_learning/worker.gleam and run off the cognitive loop.
// ---------------------------------------------------------------------------

pub fn enabled_emits_four_tasks_test() {
  let tasks = meta_scheduler.build_tasks(enabled_cfg())
  list.length(tasks) |> should.equal(4)
}

pub fn task_names_unique_and_namespaced_test() {
  let tasks = meta_scheduler.build_tasks(enabled_cfg())
  let names = list.map(tasks, fn(t) { t.name })
  // All start with the meta_learning_ prefix so operators can grep them.
  list.all(names, fn(n) { string.starts_with(n, "meta_learning_") })
  |> should.equal(True)
  // Names are unique.
  list.length(list.unique(names)) |> should.equal(list.length(names))
}

pub fn intervals_default_to_spec_values_test() {
  let tasks = meta_scheduler.build_tasks(enabled_cfg())
  // hours_to_ms = hours * 3_600_000
  // consolidation 168h -> 604_800_000 ms
  case list.find(tasks, fn(t) { t.name == "meta_learning_consolidation" }) {
    Ok(t) -> t.interval_ms |> should.equal(604_800_000)
    Error(_) -> should.fail()
  }
  // goal review 24h -> 86_400_000
  case list.find(tasks, fn(t) { t.name == "meta_learning_goal_review" }) {
    Ok(t) -> t.interval_ms |> should.equal(86_400_000)
    Error(_) -> should.fail()
  }
  // strategy review 336h -> 1_209_600_000
  case list.find(tasks, fn(t) { t.name == "meta_learning_strategy_review" }) {
    Ok(t) -> t.interval_ms |> should.equal(1_209_600_000)
    Error(_) -> should.fail()
  }
}

pub fn intervals_overridden_by_config_test() {
  let c =
    config.AppConfig(
      ..enabled_cfg(),
      meta_consolidation_interval_hours: Some(72),
      // 72h -> 259_200_000 ms
      meta_goal_review_interval_hours: Some(12),
      // 12h -> 43_200_000 ms
    )
  let tasks = meta_scheduler.build_tasks(c)
  case list.find(tasks, fn(t) { t.name == "meta_learning_consolidation" }) {
    Ok(t) -> t.interval_ms |> should.equal(259_200_000)
    Error(_) -> should.fail()
  }
  case list.find(tasks, fn(t) { t.name == "meta_learning_goal_review" }) {
    Ok(t) -> t.interval_ms |> should.equal(43_200_000)
    Error(_) -> should.fail()
  }
}

pub fn task_queries_reference_correct_tools_test() {
  let tasks = meta_scheduler.build_tasks(enabled_cfg())
  case list.find(tasks, fn(t) { t.name == "meta_learning_consolidation" }) {
    Ok(t) ->
      string.contains(t.query, "consolidate_memory") |> should.equal(True)
    Error(_) -> should.fail()
  }
  case list.find(tasks, fn(t) { t.name == "meta_learning_goal_review" }) {
    Ok(t) ->
      string.contains(t.query, "list_learning_goals") |> should.equal(True)
    Error(_) -> should.fail()
  }
  // affect_correlation is no longer a scheduler task — it runs as a
  // BEAM worker. Confirm it's absent from the scheduler's task list.
  case
    list.find(tasks, fn(t) { t.name == "meta_learning_affect_correlation" })
  {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }
}

pub fn start_at_is_none_so_first_run_uses_interval_test() {
  // Without start_at, the runner schedules the first fire one full interval
  // out — predictable and avoids thundering-herd at startup.
  let tasks = meta_scheduler.build_tasks(enabled_cfg())
  list.all(tasks, fn(t) { t.start_at == None }) |> should.equal(True)
}
