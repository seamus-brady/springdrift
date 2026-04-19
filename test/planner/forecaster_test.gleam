//// Unit tests for the Forecaster's heuristic forecast computation.
////
//// Regression suite around the "constant 0.3333" bug: every task used to
//// score exactly 11/33 = 0.3333 through the tool path because its heuristic
//// defaulted every magnitude to 1 and the D' engine clamped higher values
//// to [0, 3]. After the fix, both the actor path and the tool path share
//// this function, and healthy tasks score near zero.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/engine
import gleam/list
import gleam/option.{None}
import gleeunit/should
import planner/features
import planner/forecaster
import planner/types as planner_types

fn repeat_step(
  n: Int,
  completed: Int,
  idx: Int,
  acc: List(planner_types.PlanStep),
) -> List(planner_types.PlanStep) {
  case idx > n {
    True -> list.reverse(acc)
    False ->
      repeat_step(n, completed, idx + 1, [
        planner_types.PlanStep(
          index: idx,
          description: "step",
          status: case idx <= completed {
            True -> planner_types.Complete
            False -> planner_types.Pending
          },
          completed_at: None,
          verification: None,
        ),
        ..acc
      ])
  }
}

fn repeat_cycle_id(n: Int, idx: Int, acc: List(String)) -> List(String) {
  case idx > n {
    True -> list.reverse(acc)
    False -> repeat_cycle_id(n, idx + 1, ["cycle", ..acc])
  }
}

fn make_task(
  complexity: String,
  total_steps: Int,
  completed_steps: Int,
  total_cycles: Int,
  dependencies: List(#(String, String)),
  materialised_risks: List(String),
) -> planner_types.PlannerTask {
  let steps_list = repeat_step(total_steps, completed_steps, 1, [])
  let cycle_list = repeat_cycle_id(total_cycles, 1, [])
  planner_types.PlannerTask(
    task_id: "task-t",
    endeavour_id: None,
    origin: planner_types.SystemTask,
    title: "t",
    description: "",
    status: planner_types.Active,
    plan_steps: steps_list,
    dependencies: dependencies,
    complexity: complexity,
    risks: [],
    materialised_risks: materialised_risks,
    created_at: "2026-04-18T10:00:00",
    updated_at: "2026-04-18T10:00:00",
    cycle_ids: cycle_list,
    forecast_score: None,
    forecast_breakdown: None,
    pre_mortem: None,
    post_mortem: None,
  )
}

fn score(task: planner_types.PlannerTask) -> Float {
  let forecasts = forecaster.compute_heuristic_forecasts(task)
  engine.compute_dprime(forecasts, features.plan_health_features(), 1)
}

// ---------------------------------------------------------------------------
// Happy path — a healthy task scores near zero, not 0.3333.
// ---------------------------------------------------------------------------

pub fn healthy_task_scores_low_test() {
  // 3 steps, 1 completed, 1 cycle — within normal velocity expectations.
  let task = make_task("medium", 3, 1, 1, [], [])
  score(task) |> should.equal(0.0)
}

pub fn empty_task_scores_zero_test() {
  // Fully empty task — no signal at all, so D' must be 0.
  let task = make_task("medium", 0, 0, 0, [], [])
  score(task) |> should.equal(0.0)
}

// ---------------------------------------------------------------------------
// Regression — distinct tasks score differently.
// Pre-fix: every task regardless of state scored exactly 11/33 = 0.3333.
// ---------------------------------------------------------------------------

pub fn distinct_tasks_score_differently_test() {
  let healthy = make_task("medium", 3, 1, 1, [], [])
  // Simple task spinning for many cycles — complexity drift high.
  let drifting = make_task("simple", 2, 0, 12, [], [])
  let healthy_score = score(healthy)
  let drifting_score = score(drifting)
  { drifting_score >. healthy_score } |> should.be_true()
}

pub fn tasks_do_not_land_at_one_third_test() {
  // Regression guard: a plain active task with no signal must NOT produce
  // the old constant 11/33 = 0.3333…
  let task = make_task("medium", 5, 2, 3, [], [])
  let s = score(task)
  let near_third = s >. 0.32 && s <. 0.34
  near_third |> should.be_false()
}

// ---------------------------------------------------------------------------
// Magnitudes are on the D' engine's 0–3 scale.
// ---------------------------------------------------------------------------

pub fn all_magnitudes_within_zero_to_three_test() {
  let tasks = [
    make_task("simple", 2, 0, 20, [#("1", "2"), #("2", "3")], ["r1", "r2", "r3"]),
    make_task("complex", 10, 0, 15, [], []),
    make_task("", 1, 0, 0, [], []),
  ]
  list.each(tasks, fn(task) {
    let forecasts = forecaster.compute_heuristic_forecasts(task)
    list.each(forecasts, fn(f) {
      { f.magnitude >= 0 && f.magnitude <= 3 }
      |> should.be_true()
    })
  })
}

pub fn scope_creep_always_reports_zero_test() {
  // scope_creep is not yet derivable from task state; the heuristic reports 0
  // for all tasks. Locks that behaviour — reviving with a 1 default would
  // reintroduce the 0.3333 bug when combined with 0 everywhere else.
  let task = make_task("medium", 5, 2, 3, [], [])
  let forecasts = forecaster.compute_heuristic_forecasts(task)
  let assert Ok(scope) =
    list.find(forecasts, fn(f) { f.feature_name == "scope_creep" })
  scope.magnitude |> should.equal(0)
}

pub fn five_features_always_present_test() {
  // compute_dprime treats missing features as magnitude 0; even so the
  // heuristic should always emit all five slots so the breakdown view is
  // comprehensive.
  let task = make_task("medium", 3, 1, 1, [], [])
  let forecasts = forecaster.compute_heuristic_forecasts(task)
  list.length(forecasts) |> should.equal(5)
}
