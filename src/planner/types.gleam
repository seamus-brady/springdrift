//// Planner types — Tasks, Endeavours, Phases, Work Sessions, Blockers.
////
//// A Task is a unit of planned work with steps, dependencies, and risks.
//// An Endeavour is a living work programme: phased, self-scheduling,
//// with blocker tracking, stakeholder communication, and adaptation.
//// Both persist as append-only JSONL operations, with state derived by replay.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/types as dprime_types
import gleam/option.{type Option}
import narrative/appraisal_types

// ---------------------------------------------------------------------------
// Task
// ---------------------------------------------------------------------------

pub type TaskStatus {
  Pending
  Active
  Complete
  Failed
  Abandoned
}

pub type TaskOrigin {
  SystemTask
  UserTask
}

pub type PlanStep {
  PlanStep(
    index: Int,
    description: String,
    status: TaskStatus,
    completed_at: Option(String),
    verification: Option(String),
  )
}

pub type PlannerTask {
  PlannerTask(
    task_id: String,
    endeavour_id: Option(String),
    origin: TaskOrigin,
    title: String,
    description: String,
    status: TaskStatus,
    plan_steps: List(PlanStep),
    dependencies: List(#(String, String)),
    complexity: String,
    risks: List(String),
    materialised_risks: List(String),
    created_at: String,
    updated_at: String,
    cycle_ids: List(String),
    forecast_score: Option(Float),
    forecast_breakdown: Option(List(ForecastBreakdown)),
    pre_mortem: Option(appraisal_types.PreMortem),
    post_mortem: Option(appraisal_types.PostMortem),
  )
}

// ---------------------------------------------------------------------------
// Forecast breakdown — per-feature scores from the last Forecaster evaluation
// ---------------------------------------------------------------------------

pub type ForecastBreakdown {
  ForecastBreakdown(
    feature_name: String,
    magnitude: Int,
    rationale: String,
    weighted_score: Float,
  )
}

// ---------------------------------------------------------------------------
// Phase — a coherent chunk of work within an Endeavour
// ---------------------------------------------------------------------------

pub type PhaseStatus {
  PhaseNotStarted
  PhaseInProgress
  PhaseComplete
  PhaseBlocked(reason: String)
  PhaseSkipped(reason: String)
}

pub type Phase {
  Phase(
    name: String,
    description: String,
    status: PhaseStatus,
    task_ids: List(String),
    depends_on: List(String),
    milestone: Option(String),
    estimated_sessions: Int,
    actual_sessions: Int,
  )
}

// ---------------------------------------------------------------------------
// Work Session — a scheduled period of autonomous work
// ---------------------------------------------------------------------------

pub type SessionStatus {
  SessionScheduled
  SessionInProgress
  SessionCompleted(outcome: String)
  SessionSkipped(reason: String)
  SessionFailed(reason: String)
}

pub type WorkSession {
  WorkSession(
    session_id: String,
    scheduled_at: String,
    status: SessionStatus,
    phase: String,
    focus: String,
    max_cycles: Int,
    max_tokens: Int,
    actual_cycles: Int,
    actual_tokens: Int,
    outcome: Option(String),
  )
}

pub type SessionCadence {
  FixedInterval(interval_ms: Int)
  Weekdays(time: String)
  Custom(cron: String)
}

// ---------------------------------------------------------------------------
// Blocker — something preventing progress
// ---------------------------------------------------------------------------

pub type Blocker {
  Blocker(
    id: String,
    description: String,
    detected_at: String,
    resolution_strategy: String,
    requires_human: Bool,
    resolved_at: Option(String),
    resolution: Option(String),
  )
}

// ---------------------------------------------------------------------------
// Stakeholder — who needs updates and how
// ---------------------------------------------------------------------------

pub type StakeholderRole {
  Owner
  Reviewer
  StakeholderObserver
}

pub type UpdatePreference {
  OnMilestone
  OnBlocker
  Periodic(cadence: String)
  AllUpdates
}

pub type Stakeholder {
  Stakeholder(
    name: String,
    channel: String,
    address: Option(String),
    role: StakeholderRole,
    update_preference: UpdatePreference,
  )
}

// ---------------------------------------------------------------------------
// Approval gates — configurable per-endeavour
// ---------------------------------------------------------------------------

pub type ApprovalMode {
  Auto
  Notify
  RequireApproval
}

pub type ApprovalConfig {
  ApprovalConfig(
    phase_transition: ApprovalMode,
    budget_increase: ApprovalMode,
    external_communication: ApprovalMode,
    replan: ApprovalMode,
    completion: ApprovalMode,
  )
}

pub fn default_approval_config() -> ApprovalConfig {
  ApprovalConfig(
    phase_transition: Auto,
    budget_increase: RequireApproval,
    external_communication: Auto,
    replan: Notify,
    completion: RequireApproval,
  )
}

// ---------------------------------------------------------------------------
// Endeavour — a living work programme
// ---------------------------------------------------------------------------

pub type EndeavourStatus {
  Draft
  EndeavourActive
  EndeavourBlocked
  OnHold
  EndeavourComplete
  EndeavourFailed
  /// Legacy status — maps from old "open" status
  Open
  EndeavourAbandoned
}

pub type EndeavourOrigin {
  SystemEndeavour
  UserEndeavour
}

pub type Endeavour {
  Endeavour(
    endeavour_id: String,
    origin: EndeavourOrigin,
    title: String,
    description: String,
    status: EndeavourStatus,
    task_ids: List(String),
    created_at: String,
    updated_at: String,
    // ── Goal (new) ──
    goal: String,
    success_criteria: List(String),
    deadline: Option(String),
    // ── Work structure (new) ──
    phases: List(Phase),
    // ── Schedule (new) ──
    work_sessions: List(WorkSession),
    next_session: Option(String),
    session_cadence: Option(SessionCadence),
    // ── Communication (new) ──
    stakeholders: List(Stakeholder),
    last_update_sent: Option(String),
    update_cadence: Option(String),
    // ── Adaptation (new) ──
    blockers: List(Blocker),
    replan_count: Int,
    original_phase_count: Int,
    // ── Approval (new) ──
    approval_config: ApprovalConfig,
    // ── Forecaster overrides (per-endeavour) ──
    feature_overrides: Option(List(dprime_types.Feature)),
    threshold_override: Option(Float),
    forecast_score: Option(Float),
    forecast_breakdown: Option(List(ForecastBreakdown)),
    // ── Metrics (new) ──
    total_cycles: Int,
    total_tokens: Int,
    // ── Appraisal ──
    post_mortem: Option(appraisal_types.EndeavourPostMortem),
  )
}

/// Create a minimal endeavour with defaults for all new fields.
/// Used by backward-compatible decoders and simple creation.
pub fn new_endeavour(
  endeavour_id: String,
  origin: EndeavourOrigin,
  title: String,
  description: String,
  created_at: String,
) -> Endeavour {
  Endeavour(
    endeavour_id:,
    origin:,
    title:,
    description:,
    status: Draft,
    task_ids: [],
    created_at:,
    updated_at: created_at,
    goal: "",
    success_criteria: [],
    deadline: option.None,
    phases: [],
    work_sessions: [],
    next_session: option.None,
    session_cadence: option.None,
    stakeholders: [],
    last_update_sent: option.None,
    update_cadence: option.None,
    blockers: [],
    replan_count: 0,
    original_phase_count: 0,
    approval_config: default_approval_config(),
    feature_overrides: option.None,
    threshold_override: option.None,
    forecast_score: option.None,
    forecast_breakdown: option.None,
    total_cycles: 0,
    total_tokens: 0,
    post_mortem: option.None,
  )
}

// ---------------------------------------------------------------------------
// Task operations (append-only log)
// ---------------------------------------------------------------------------

pub type TaskOp {
  CreateTask(task: PlannerTask)
  UpdateTaskStatus(task_id: String, status: TaskStatus, at: String)
  CompleteStep(task_id: String, step_index: Int, at: String)
  FlagRisk(task_id: String, text: String, at: String)
  AddCycleId(task_id: String, cycle_id: String)
  UpdateForecastScore(task_id: String, score: Float)
  // Task field updates (title, description, steps)
  UpdateTaskFields(
    task_id: String,
    title: Option(String),
    description: Option(String),
    at: String,
  )
  AddTaskStep(task_id: String, description: String, at: String)
  RemoveTaskStep(task_id: String, step_index: Int, at: String)
  UpdateForecastBreakdown(
    task_id: String,
    score: Float,
    breakdown: List(ForecastBreakdown),
  )
  DeleteTask(task_id: String)
  AddPreMortem(task_id: String, pre_mortem: appraisal_types.PreMortem)
  AddPostMortem(task_id: String, post_mortem: appraisal_types.PostMortem)
}

// ---------------------------------------------------------------------------
// Endeavour operations (append-only log)
// ---------------------------------------------------------------------------

pub type EndeavourOp {
  // Original operations (backward compatible)
  CreateEndeavour(endeavour: Endeavour)
  AddTaskToEndeavour(endeavour_id: String, task_id: String)
  UpdateEndeavourStatus(endeavour_id: String, status: EndeavourStatus)
  // Phase management (new)
  UpdatePhase(endeavour_id: String, phase_name: String, status: PhaseStatus)
  AddPhase(endeavour_id: String, phase: Phase)
  // Blocker management (new)
  AddBlocker(endeavour_id: String, blocker: Blocker)
  ResolveBlocker(
    endeavour_id: String,
    blocker_id: String,
    resolution: String,
    at: String,
  )
  // Session management (new)
  RecordSession(endeavour_id: String, session: WorkSession)
  ScheduleSession(endeavour_id: String, session: WorkSession)
  // Stakeholder communication (new)
  SendUpdate(
    endeavour_id: String,
    stakeholder: String,
    channel: String,
    content: String,
    at: String,
  )
  // Adaptation (new)
  Replan(endeavour_id: String, reason: String, new_phases: List(Phase))
  // Metrics (new)
  RecordMetrics(endeavour_id: String, cycles: Int, tokens: Int)
  // Forecaster config (per-endeavour overrides)
  UpdateForecasterConfig(
    endeavour_id: String,
    feature_overrides: Option(List(dprime_types.Feature)),
    threshold_override: Option(Float),
  )
  // Field updates (goal, criteria, deadline, cadence, approval)
  UpdateEndeavourFields(
    endeavour_id: String,
    goal: Option(String),
    success_criteria: Option(List(String)),
    deadline: Option(String),
    update_cadence: Option(String),
    approval_config: Option(ApprovalConfig),
  )
  // Cancel a scheduled session
  CancelSession(
    endeavour_id: String,
    session_id: String,
    reason: String,
    at: String,
  )
  // Forecast breakdown persistence
  UpdateEndeavourForecastBreakdown(
    endeavour_id: String,
    score: Float,
    breakdown: List(ForecastBreakdown),
  )
  // Delete endeavour
  DeleteEndeavour(endeavour_id: String)
  // Appraisal
  AddEndeavourPostMortem(
    endeavour_id: String,
    post_mortem: appraisal_types.EndeavourPostMortem,
  )
}
