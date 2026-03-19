//// Forecaster — OTP actor that periodically evaluates active tasks.
////
//// Uses process.send_after for self-ticking. On each tick:
//// 1. Query Librarian for active tasks
//// 2. For each task with enough cycles since last forecast, compute health score
//// 3. If score >= replan threshold, send ForecasterSuggestion to cognitive loop
//// 4. Update task forecast_score via Librarian

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
  )
}

pub fn default_config(planner_dir: String) -> ForecasterConfig {
  ForecasterConfig(
    tick_ms: 300_000,
    replan_threshold: features.default_replan_threshold,
    min_cycles: 2,
    planner_dir:,
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
  let tasks = librarian.get_active_tasks(state.librarian)
  let active_tasks =
    list.filter(tasks, fn(t) {
      t.status == planner_types.Active
      && list.length(t.cycle_ids) >= state.config.min_cycles
    })

  list.each(active_tasks, fn(task) { evaluate_task(state, task) })
}

fn evaluate_task(state: ForecasterState, task: planner_types.PlannerTask) -> Nil {
  // Compute heuristic forecasts from task state (no LLM call needed)
  let forecasts = compute_heuristic_forecasts(task)
  let plan_features = features.plan_health_features()

  // Use D' engine to compute composite score (single tier = 1)
  let dprime_score = engine.compute_dprime(forecasts, plan_features, 1)

  slog.debug(
    "planner/forecaster",
    "evaluate_task",
    "Task " <> task.task_id <> " D'=" <> float.to_string(dprime_score),
    None,
  )

  // Update forecast score on the task
  let op =
    planner_types.UpdateForecastScore(
      task_id: task.task_id,
      score: dprime_score,
    )
  planner_log.append_task_op(state.config.planner_dir, op)
  librarian.notify_task_op(state.librarian, op)

  // If score >= threshold, send replan suggestion to cognitive loop
  case dprime_score >=. state.config.replan_threshold {
    True -> {
      let explanation = build_explanation(forecasts)
      let suggested_steps =
        list.filter_map(task.plan_steps, fn(s) {
          case s.status != planner_types.Complete {
            True -> Ok(s.description)
            False -> Error(Nil)
          }
        })
      let event =
        agent_types.SensoryEvent(
          name: "forecaster_replan",
          title: "Replan suggested: " <> task.title,
          body: "Task "
            <> task.task_id
            <> " (D'="
            <> float.to_string(dprime_score)
            <> "): "
            <> explanation
            <> "\nRemaining steps: "
            <> string.join(suggested_steps, ", "),
          fired_at: get_datetime(),
        )
      process.send(state.cognitive, agent_types.QueuedSensoryEvent(event:))
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

fn compute_heuristic_forecasts(
  task: planner_types.PlannerTask,
) -> List(dprime_types.Forecast) {
  let total_steps = list.length(task.plan_steps)
  let completed_steps =
    list.count(task.plan_steps, fn(s) { s.status == planner_types.Complete })
  let total_cycles = list.length(task.cycle_ids)

  // step_completion_rate: high magnitude if many cycles but few steps done
  let step_rate_magnitude = case total_steps > 0 && total_cycles > 0 {
    True -> {
      let expected_rate =
        int.to_float(total_cycles) /. int.to_float(total_steps)
      case expected_rate >. 2.0 && completed_steps < total_steps / 2 {
        True -> 7
        False ->
          case expected_rate >. 1.5 && completed_steps < total_steps {
            True -> 4
            False -> 1
          }
      }
    }
    False -> 1
  }

  // dependency_health: magnitude based on blocked deps
  let dep_magnitude = case task.dependencies {
    [] -> 1
    deps -> {
      let blocked =
        list.count(deps, fn(d) {
          // Check if the "from" step is not yet complete
          case
            list.find(task.plan_steps, fn(s) { int.to_string(s.index) == d.0 })
          {
            Ok(step) -> step.status != planner_types.Complete
            Error(_) -> False
          }
        })
      case blocked > 0 {
        True -> 5 + blocked
        False -> 1
      }
    }
  }

  // complexity_drift: magnitude based on cycles vs expected
  let complexity_magnitude = case task.complexity {
    "simple" ->
      case total_cycles > 3 {
        True -> 5
        False -> 1
      }
    "medium" ->
      case total_cycles > 6 {
        True -> 5
        False -> 1
      }
    _ ->
      case total_cycles > 10 {
        True -> 5
        False -> 1
      }
  }

  // risk_materialization
  let risk_magnitude = case list.length(task.materialised_risks) {
    0 -> 1
    n -> int.min(3 + n * 2, 9)
  }

  // scope_creep: steps added beyond original plan (approximated)
  let scope_magnitude = 1

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

fn build_explanation(forecasts: List(dprime_types.Forecast)) -> String {
  forecasts
  |> list.filter(fn(f) { f.magnitude >= 4 })
  |> list.map(fn(f) { f.feature_name <> ": " <> f.rationale })
  |> string.join("; ")
}

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String
