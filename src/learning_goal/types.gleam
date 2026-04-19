//// Learning Goals Store — meta-learning Phase C.
////
//// A `LearningGoal` is a self-directed objective: the agent decides what
//// it wants to get better at, why, and what evidence would constitute
//// achievement. Goals link to strategies (Phase A) when the approach is
//// known, and accumulate cycle IDs as evidence as work progresses.
////
//// Storage is append-only JSONL via `learning_goal/log.gleam`. The
//// derived current state is computed by replaying the event log.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{type Option}

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// Where the goal came from. `OperatorDirected` is privileged — the agent
/// should not abandon operator-directed goals without explicit permission.
pub type GoalSource {
  SelfIdentified
  RemembrancerSuggested
  OperatorDirected
  PatternMined
}

pub type GoalStatus {
  ActiveGoal
  AchievedGoal
  AbandonedGoal
  PausedGoal
}

/// Resolved current state of a goal after replaying the event log.
pub type LearningGoal {
  LearningGoal(
    id: String,
    title: String,
    rationale: String,
    /// Free-text criteria the agent will use to judge achievement.
    acceptance_criteria: String,
    /// Optional link to a Strategy Registry entry — the named approach
    /// the agent intends to use for this goal.
    strategy_id: Option(String),
    /// 0.0–1.0. Operator-directed goals may carry priority 1.0.
    priority: Float,
    status: GoalStatus,
    /// Cycle IDs that contributed evidence toward (or against)
    /// achievement. Append-only — pruning happens at archival time.
    evidence: List(String),
    source: GoalSource,
    created_at: String,
    /// ISO timestamp of the most recent event for this goal.
    last_event_at: String,
    /// Affect pressure (0.0–100.0) at the time the goal was created.
    /// None when no affect snapshot was available. Lets the agent
    /// later compare goal-progress affect against the baseline state
    /// when the goal was set.
    affect_baseline: Option(Float),
  )
}

// ---------------------------------------------------------------------------
// Event log entries — append-only.
// ---------------------------------------------------------------------------

pub type GoalEvent {
  /// A new learning goal enters the store.
  GoalCreated(
    timestamp: String,
    goal_id: String,
    title: String,
    rationale: String,
    acceptance_criteria: String,
    strategy_id: Option(String),
    priority: Float,
    source: GoalSource,
    /// Pressure (0.0–100.0) snapshot from the latest affect reading at
    /// creation time. None when no snapshot was available.
    affect_baseline: Option(Float),
  )
  /// A cycle contributed evidence toward (or against) the goal.
  GoalEvidenceAdded(timestamp: String, goal_id: String, cycle_id: String)
  /// Status transition: active -> achieved/abandoned/paused, or paused
  /// -> active. Reason is free text recorded for the audit trail.
  GoalStatusChanged(
    timestamp: String,
    goal_id: String,
    new_status: GoalStatus,
    reason: String,
  )
}
