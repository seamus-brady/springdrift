//// Forecaster — OTP actor that periodically evaluates active tasks.
////
//// Uses process.send_after for self-ticking. On each tick:
//// 1. Query Librarian for active tasks
//// 2. For each task with enough cycles since last forecast, compute health score
//// 3. If score >= replan threshold, send ForecasterSuggestion to cognitive loop
//// 4. Update task forecast_score via Librarian

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import dprime/engine
import dprime/types as dprime_types
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import narrative/librarian.{type LibrarianMessage}
import planner/config as planner_config
import planner/features
import planner/log as planner_log
import planner/types as planner_types
import slog

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

pub type ForecasterMessage {
  Tick
  Shutdown
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

pub type ForecasterConfig {
  ForecasterConfig(
    tick_ms: Int,
    replan_threshold: Float,
    min_cycles: Int,
    planner_dir: String,
    features_config: planner_config.ForecasterFeatureConfig,
  )
}

pub fn default_config(planner_dir: String) -> ForecasterConfig {
  ForecasterConfig(
    tick_ms: 300_000,
    replan_threshold: features.default_replan_threshold,
    min_cycles: 2,
    planner_dir:,
    features_config: planner_config.default_config(),
  )
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

type ForecasterState {
  ForecasterState(
    self: Subject(ForecasterMessage),
    config: ForecasterConfig,
    librarian: Subject(LibrarianMessage),
    cognitive: Subject(agent_types.CognitiveMessage),
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the Forecaster actor. Returns a Subject for sending messages.
pub fn start(
  config: ForecasterConfig,
  librarian: Subject(LibrarianMessage),
  cognitive: Subject(agent_types.CognitiveMessage),
) -> Subject(ForecasterMessage) {
  let setup: Subject(Subject(ForecasterMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(ForecasterMessage) = process.new_subject()
    process.send(setup, self)
    let state = ForecasterState(self:, config:, librarian:, cognitive:)
    // Schedule first tick
    schedule_tick(self, config.tick_ms)
    slog.info(
      "planner/forecaster",
      "start",
      "Forecaster started (tick_ms="
        <> int.to_string(config.tick_ms)
        <> ", threshold="
        <> float.to_string(config.replan_threshold)
        <> ")",
      None,
    )
    loop(state)
  })
  case process.receive(setup, 5000) {
    Ok(subj) -> subj
    Error(_) -> {
      slog.log_error(
        "planner/forecaster",
        "start",
        "Forecaster failed to start within 5s",
        None,
      )
      panic as "Forecaster startup timeout"
    }
  }
}

// ---------------------------------------------------------------------------
// Message loop
// ---------------------------------------------------------------------------

fn loop(state: ForecasterState) -> Nil {
  case process.receive(state.self, 60_000) {
    Error(_) -> loop(state)
    Ok(Shutdown) -> {
      slog.info("planner/forecaster", "shutdown", "Forecaster stopped", None)
      Nil
    }
    Ok(Tick) -> {
      handle_tick(state)
      schedule_tick(state.self, state.config.tick_ms)
      loop(state)
    }
  }
}

fn schedule_tick(self: Subject(ForecasterMessage), delay_ms: Int) -> Nil {
  process.send_after(self, delay_ms, Tick)
  Nil
}

// ---------------------------------------------------------------------------
// Tick handler — evaluate all active tasks
// ---------------------------------------------------------------------------

fn handle_tick(state: ForecasterState) -> Nil {
  // Evaluate individual tasks
  let tasks = librarian.get_active_tasks(state.librarian)
  let active_tasks =
    list.filter(tasks, fn(t) {
      t.status == planner_types.Active
      && list.length(t.cycle_ids) >= state.config.min_cycles
    })
  list.each(active_tasks, fn(task) { evaluate_task(state, task) })

  // Evaluate endeavours with phases
  let endeavours = librarian.get_all_endeavours(state.librarian)
  let active_endeavours =
    list.filter(endeavours, fn(e) {
      case e.status {
        planner_types.EndeavourActive | planner_types.EndeavourBlocked -> True
        _ -> False
      }
      && !list.is_empty(e.phases)
    })
  list.each(active_endeavours, fn(e) { evaluate_endeavour(state, e) })
}

fn evaluate_task(state: ForecasterState, task: planner_types.PlannerTask) -> Nil {
  // Compute heuristic forecasts from task state (no LLM call needed)
  let forecasts = compute_heuristic_forecasts(task)
  let #(plan_features, _threshold) =
    planner_config.effective_features(state.config.features_config, None)

  // Use D' engine to compute composite score (single tier = 1)
  let dprime_score = engine.compute_dprime(forecasts, plan_features, 1)

  slog.debug(
    "planner/forecaster",
    "evaluate_task",
    "Task " <> task.task_id <> " D'=" <> float.to_string(dprime_score),
    None,
  )

  // Build per-feature breakdown and persist
  let breakdown = build_breakdown(forecasts, plan_features, dprime_score)
  let op =
    planner_types.UpdateForecastBreakdown(
      task_id: task.task_id,
      score: dprime_score,
      breakdown:,
    )
  planner_log.append_task_op(state.config.planner_dir, op)
  librarian.notify_task_op(state.librarian, op)

  // If score >= threshold, send replan suggestion to cognitive loop
  case dprime_score >=. state.config.replan_threshold {
    True -> {
      let explanation = build_explanation(forecasts)
      let completed_steps =
        list.filter_map(task.plan_steps, fn(s) {
          case s.status == planner_types.Complete {
            True -> Ok(s.description)
            False -> Error(Nil)
          }
        })
      let remaining_steps =
        list.filter_map(task.plan_steps, fn(s) {
          case s.status != planner_types.Complete {
            True -> Ok(s.description)
            False -> Error(Nil)
          }
        })
      let risk_text = case task.materialised_risks {
        [] -> "None"
        risks -> string.join(risks, "; ")
      }
      let full_explanation =
        explanation
        <> "\nCompleted steps: "
        <> string.join(completed_steps, ", ")
        <> "\nRemaining steps: "
        <> string.join(remaining_steps, ", ")
        <> "\nMaterialised risks: "
        <> risk_text
      process.send(
        state.cognitive,
        agent_types.ForecasterSuggestion(
          task_id: task.task_id,
          task_title: task.title,
          plan_dprime: dprime_score,
          explanation: full_explanation,
        ),
      )
      slog.info(
        "planner/forecaster",
        "evaluate_task",
        "Replan suggested for task " <> task.task_id,
        None,
      )
    }
    False -> Nil
  }
}

// ---------------------------------------------------------------------------
// Heuristic forecast scoring — no LLM needed
// ---------------------------------------------------------------------------

/// Derive plan-health forecasts from a task's current state using
/// deterministic rules. No LLM calls. Magnitudes are on the D' engine's
/// canonical 0–3 scale (0 = no signal, 3 = maximum).
///
/// Exported so the `request_forecast_review` tool can share the same
/// computation — having two divergent heuristic functions historically
/// caused the forecaster to report different scores depending on which
/// caller invoked it, and produced a hardcoded D' = 0.3333 for every
/// task through the tool path because its defaults all landed at
/// magnitude 1.
pub fn compute_heuristic_forecasts(
  task: planner_types.PlannerTask,
) -> List(dprime_types.Forecast) {
  let total_steps = list.length(task.plan_steps)
  let completed_steps =
    list.count(task.plan_steps, fn(s) { s.status == planner_types.Complete })
  let total_cycles = list.length(task.cycle_ids)

  // D' engine uses 0-3 scale: 0=none, 1=low, 2=medium, 3=high

  // step_completion_rate: are steps finishing at expected velocity?
  let step_rate_magnitude = case total_steps > 0 && total_cycles > 0 {
    True -> {
      let expected_rate =
        int.to_float(total_cycles) /. int.to_float(total_steps)
      case expected_rate >. 2.0 && completed_steps < total_steps / 2 {
        True -> 3
        False ->
          case expected_rate >. 1.5 && completed_steps < total_steps {
            True -> 2
            False -> 0
          }
      }
    }
    False -> 0
  }

  // dependency_health: blocked dependencies
  let dep_magnitude = case task.dependencies {
    [] -> 0
    deps -> {
      let blocked =
        list.count(deps, fn(d) {
          case
            list.find(task.plan_steps, fn(s) { int.to_string(s.index) == d.0 })
          {
            Ok(step) -> step.status != planner_types.Complete
            Error(_) -> False
          }
        })
      case blocked {
        0 -> 0
        1 -> 1
        2 -> 2
        _ -> 3
      }
    }
  }

  // complexity_drift: actual cycles vs planned complexity
  let complexity_magnitude = case task.complexity {
    "simple" ->
      case total_cycles > 5 {
        True -> 3
        False ->
          case total_cycles > 3 {
            True -> 2
            False -> 0
          }
      }
    "medium" ->
      case total_cycles > 8 {
        True -> 3
        False ->
          case total_cycles > 6 {
            True -> 2
            False -> 0
          }
      }
    _ ->
      case total_cycles > 12 {
        True -> 3
        False ->
          case total_cycles > 10 {
            True -> 2
            False -> 0
          }
      }
  }

  // risk_materialization: how many predicted risks came true
  let risk_magnitude = case list.length(task.materialised_risks) {
    0 -> 0
    1 -> 1
    2 -> 2
    _ -> 3
  }

  // scope_creep: steps added beyond original plan (approximated)
  let scope_magnitude = 0

  [
    dprime_types.Forecast(
      feature_name: "step_completion_rate",
      magnitude: step_rate_magnitude,
      rationale: "Steps: "
        <> int.to_string(completed_steps)
        <> "/"
        <> int.to_string(total_steps)
        <> " in "
        <> int.to_string(total_cycles)
        <> " cycles",
    ),
    dprime_types.Forecast(
      feature_name: "dependency_health",
      magnitude: dep_magnitude,
      rationale: int.to_string(list.length(task.dependencies))
        <> " dependencies",
    ),
    dprime_types.Forecast(
      feature_name: "complexity_drift",
      magnitude: complexity_magnitude,
      rationale: "Planned: " <> task.complexity,
    ),
    dprime_types.Forecast(
      feature_name: "risk_materialization",
      magnitude: risk_magnitude,
      rationale: int.to_string(list.length(task.materialised_risks))
        <> " risks materialised of "
        <> int.to_string(list.length(task.risks))
        <> " predicted",
    ),
    dprime_types.Forecast(
      feature_name: "scope_creep",
      magnitude: scope_magnitude,
      rationale: "No scope drift detected",
    ),
  ]
}

fn build_breakdown(
  forecasts: List(dprime_types.Forecast),
  plan_features: List(dprime_types.Feature),
  dprime_score: Float,
) -> List(planner_types.ForecastBreakdown) {
  let max = engine.max_possible_score(plan_features, 1)
  let _ = dprime_score
  list.filter_map(plan_features, fn(feature) {
    case list.find(forecasts, fn(f) { f.feature_name == feature.name }) {
      Ok(forecast) -> {
        let clamped = int.min(3, int.max(0, forecast.magnitude))
        let weight = engine.feature_importance(feature, 1)
        let weighted = case max > 0 {
          True -> int.to_float(weight * clamped) /. int.to_float(max)
          False -> 0.0
        }
        Ok(planner_types.ForecastBreakdown(
          feature_name: feature.name,
          magnitude: forecast.magnitude,
          rationale: forecast.rationale,
          weighted_score: weighted,
        ))
      }
      Error(_) -> Error(Nil)
    }
  })
}

fn build_explanation(forecasts: List(dprime_types.Forecast)) -> String {
  forecasts
  |> list.filter(fn(f) { f.magnitude >= 4 })
  |> list.map(fn(f) { f.feature_name <> ": " <> f.rationale })
  |> string.join("; ")
}

// ---------------------------------------------------------------------------
// Endeavour-level health evaluation
// ---------------------------------------------------------------------------

fn evaluate_endeavour(state: ForecasterState, e: planner_types.Endeavour) -> Nil {
  let forecasts = compute_endeavour_forecasts(e)
  // Use per-endeavour overrides if present
  let #(plan_features, threshold) =
    planner_config.effective_features(
      state.config.features_config,
      option.Some(e),
    )
  let dprime_score = engine.compute_dprime(forecasts, plan_features, 1)

  // Build per-feature breakdown and persist
  let breakdown = build_breakdown(forecasts, plan_features, dprime_score)
  let end_op =
    planner_types.UpdateEndeavourForecastBreakdown(
      endeavour_id: e.endeavour_id,
      score: dprime_score,
      breakdown:,
    )
  planner_log.append_endeavour_op(state.config.planner_dir, end_op)
  librarian.notify_endeavour_op(state.librarian, end_op)

  slog.debug(
    "planner/forecaster",
    "evaluate_endeavour",
    "Endeavour " <> e.endeavour_id <> " D'=" <> float.to_string(dprime_score),
    None,
  )

  case dprime_score >=. threshold {
    True -> {
      let explanation = build_explanation(forecasts)
      process.send(
        state.cognitive,
        agent_types.ForecasterSuggestion(
          task_id: e.endeavour_id,
          task_title: e.title,
          plan_dprime: dprime_score,
          explanation:,
        ),
      )
    }
    False -> Nil
  }
}

fn compute_endeavour_forecasts(
  e: planner_types.Endeavour,
) -> List(dprime_types.Forecast) {
  let total_phases = list.length(e.phases)
  let complete_phases =
    list.count(e.phases, fn(p) { p.status == planner_types.PhaseComplete })

  // D' engine uses 0-3 scale: 0=none, 1=low, 2=medium, 3=high

  // Phase completion rate vs session estimates
  let total_estimated =
    list.fold(e.phases, 0, fn(acc, p) { acc + p.estimated_sessions })
  let total_actual =
    list.fold(e.phases, 0, fn(acc, p) { acc + p.actual_sessions })
  let session_mag = case total_estimated > 0 && total_actual > total_estimated {
    True -> {
      let overrun_pct =
        int.to_float(total_actual - total_estimated)
        /. int.to_float(total_estimated)
      case overrun_pct >. 0.5 {
        True -> 3
        False ->
          case overrun_pct >. 0.2 {
            True -> 2
            False -> 1
          }
      }
    }
    False -> 0
  }

  // Blocker accumulation
  let active_blockers =
    list.count(e.blockers, fn(b) {
      case b.resolved_at {
        option.None -> True
        option.Some(_) -> False
      }
    })
  let blocker_mag = case active_blockers {
    0 -> 0
    1 -> 1
    2 -> 2
    _ -> 3
  }

  // Scope drift (phases added vs original)
  let scope_drift = case e.original_phase_count > 0 {
    True ->
      case total_phases > e.original_phase_count + 1 {
        True -> 3
        False ->
          case total_phases > e.original_phase_count {
            True -> 1
            False -> 0
          }
      }
    False -> 0
  }

  // Replan count
  let replan_mag = case e.replan_count {
    0 -> 0
    1 -> 1
    2 -> 2
    _ -> 3
  }

  // Map endeavour signals to existing plan-health feature names so the
  // D' engine can pair them with Feature importance weights from
  // features.plan_health_features().
  [
    dprime_types.Forecast(
      feature_name: "step_completion_rate",
      magnitude: session_mag,
      rationale: int.to_string(complete_phases)
        <> "/"
        <> int.to_string(total_phases)
        <> " phases complete, "
        <> int.to_string(total_actual)
        <> "/"
        <> int.to_string(total_estimated)
        <> " sessions used",
    ),
    dprime_types.Forecast(
      feature_name: "dependency_health",
      magnitude: blocker_mag,
      rationale: int.to_string(active_blockers) <> " active blockers",
    ),
    dprime_types.Forecast(
      feature_name: "scope_creep",
      magnitude: scope_drift,
      rationale: int.to_string(total_phases)
        <> " phases (originally "
        <> int.to_string(e.original_phase_count)
        <> "), "
        <> int.to_string(e.replan_count)
        <> " replans",
    ),
    dprime_types.Forecast(
      feature_name: "risk_materialization",
      magnitude: replan_mag,
      rationale: int.to_string(e.replan_count) <> " replans so far",
    ),
  ]
}
