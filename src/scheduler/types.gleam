//// Scheduler types — scheduled task state and messages.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string

// ---------------------------------------------------------------------------
// Schedule task config (moved from profile/types)
// ---------------------------------------------------------------------------

/// Delivery configuration for scheduled tasks.
pub type DeliveryConfig {
  FileDelivery(directory: String, format: String)
  WebhookDelivery(url: String, method: String, headers: List(#(String, String)))
}

/// A scheduled task definition.
pub type ScheduleTaskConfig {
  ScheduleTaskConfig(
    name: String,
    query: String,
    interval_ms: Int,
    start_at: Option(String),
    delivery: DeliveryConfig,
    only_if_changed: Bool,
    /// Phase 3 fluency/grounding. Tools the scheduled cycle must invoke
    /// for the job to count as successful. When a job prompt explicitly
    /// names a tool (e.g. "invoke `analyze_affect_performance`"), the
    /// runner checks the completing cycle's tool log and marks the job
    /// failed if any required tool did not fire. Empty list disables
    /// the check — the default for jobs that don't name specific tools.
    required_tools: List(String),
  )
}

// ---------------------------------------------------------------------------
// Job enumerations
// ---------------------------------------------------------------------------

/// Who created this job.
pub type JobSource {
  /// Loaded from schedule.toml at startup; static interval jobs
  ProfileJob
  /// Created at runtime by the scheduler agent
  AgentJob
}

/// What kind of scheduled item this is.
pub type JobKind {
  /// Fires query on interval, delivers result (existing behaviour)
  RecurringTask
  /// Fires body text as UserInput or notification at due_at
  Reminder
  /// No timer; tracked for listing/reference only
  Todo
  /// Reminder with duration; fires at due_at
  Appointment
}

/// Where a fired item is delivered.
pub type ForTarget {
  /// Inject as UserInput into the cognitive loop
  ForAgent
  /// Send as SchedulerReminder notification to TUI
  ForUser
}

/// Operation type for JSONL log records.
pub type ScheduleOp {
  Create
  Complete
  Cancel
  Fire
  Update
}

// ---------------------------------------------------------------------------
// Scheduled job state
// ---------------------------------------------------------------------------

pub type JobStatus {
  Pending
  Running
  Completed
  Cancelled
  Failed(reason: String)
}

pub type ScheduledJob {
  ScheduledJob(
    // ── existing ────────────────────────────────────────────────────
    name: String,
    query: String,
    interval_ms: Int,
    delivery: DeliveryConfig,
    only_if_changed: Bool,
    status: JobStatus,
    last_run_ms: Option(Int),
    last_result: Option(String),
    run_count: Int,
    error_count: Int,
    // ── new ─────────────────────────────────────────────────────────
    job_source: JobSource,
    kind: JobKind,
    due_at: Option(String),
    for_: ForTarget,
    title: String,
    body: String,
    duration_minutes: Int,
    tags: List(String),
    created_at: String,
    fired_count: Int,
    recurrence_end_at: Option(String),
    max_occurrences: Option(Int),
    /// Phase 3 fluency/grounding. Tools the cycle must invoke for the
    /// fire to count as success. Empty = check disabled.
    required_tools: List(String),
  )
}

// ---------------------------------------------------------------------------
// Job update — partial updates for existing jobs
// ---------------------------------------------------------------------------

pub type JobUpdate {
  JobUpdate(
    title: Option(String),
    body: Option(String),
    due_at: Option(String),
    tags: Option(List(String)),
  )
}

// ---------------------------------------------------------------------------
// Job query — filter criteria for GetJobs
// ---------------------------------------------------------------------------

pub type JobQuery {
  JobQuery(
    kinds: List(JobKind),
    statuses: List(JobStatus),
    for_: Option(ForTarget),
    overdue_only: Bool,
    max_results: Int,
  )
}

// ---------------------------------------------------------------------------
// Scheduler messages
// ---------------------------------------------------------------------------

/// Idle-gate config. When the cognitive loop has seen a UserInput
/// within `idle_window_ms`, recurring ticks defer by `retry_interval_ms`
/// rather than fire — up to `max_defer_ms` after the scheduled fire
/// time, at which point the job fires regardless so long-running chats
/// cannot starve recurring work forever. Set `idle_window_ms = 0` to
/// disable gating entirely (back to pre-fix behaviour).
pub type IdleConfig {
  IdleConfig(idle_window_ms: Int, max_defer_ms: Int, retry_interval_ms: Int)
}

/// Sensible defaults: 10 min idle window, 60 min max defer, 60 s retry.
pub fn default_idle_config() -> IdleConfig {
  IdleConfig(
    idle_window_ms: 10 * 60 * 1000,
    max_defer_ms: 60 * 60 * 1000,
    retry_interval_ms: 60_000,
  )
}

/// Gating disabled. Used in tests and when the operator explicitly
/// opts out via `scheduler_idle_window_minutes = 0`.
pub fn disabled_idle_config() -> IdleConfig {
  IdleConfig(idle_window_ms: 0, max_defer_ms: 0, retry_interval_ms: 60_000)
}

pub type SchedulerMessage {
  /// Timer fired for a specific job
  Tick(name: String)
  /// Cognitive pushes this every time a UserInput arrives. The runner
  /// records the timestamp and uses it to gate recurring ticks against
  /// an active operator conversation.
  UserInputObserved(at_ms: Int)
  /// Job completed with result text, token usage, and the list of tools
  /// that fired during the cycle. Used by the runner to apply the
  /// required_tools check: if any required tool is absent from
  /// tools_fired, the job is marked failed instead of complete.
  JobComplete(
    name: String,
    result: String,
    tokens_used: Int,
    tools_fired: List(String),
  )
  /// Job failed
  JobFailed(name: String, reason: String)
  /// Stop all scheduled jobs
  StopAll
  /// Get current job statuses
  GetStatus(reply_to: Subject(List(ScheduledJob)))
  /// Stuck job timeout check
  StuckJobCheck(name: String)
  /// Add a new agent-created job. Returns the assigned name.
  AddJob(job: ScheduledJob, reply_to: Subject(Result(String, String)))
  /// Remove a job and cancel its timer.
  RemoveJob(name: String, reply_to: Subject(Result(Nil, String)))
  /// Update title, body, due_at, or tags on a pending job.
  UpdateJob(
    name: String,
    updates: JobUpdate,
    reply_to: Subject(Result(Nil, String)),
  )
  /// Query jobs by kind, status, for_ target.
  GetJobs(query: JobQuery, reply_to: Subject(List(ScheduledJob)))
  /// Mark a job completed (for Todos and Reminders).
  CompleteJob(name: String, reply_to: Subject(Result(Nil, String)))
  /// Get remaining budget for the current hour (cycles + tokens).
  GetBudgetRemaining(reply_to: Subject(BudgetStatus))
  /// Remove all cancelled and completed one-shot jobs from ETS.
  PurgeCancelled(reply_to: Subject(Int))
}

/// Budget status for the current rolling hour window.
pub type BudgetStatus {
  BudgetStatus(
    cycles_used: Int,
    cycles_limit: Int,
    tokens_used: Int,
    tokens_limit: Int,
  )
}

// ---------------------------------------------------------------------------
// JSON encoding — scheduler job state for web admin
// ---------------------------------------------------------------------------

pub fn encode_job(job: ScheduledJob) -> json.Json {
  json.object([
    #("name", json.string(job.name)),
    #("title", json.string(job.title)),
    #("kind", json.string(encode_job_kind(job.kind))),
    #("status", json.string(encode_job_status(job.status))),
    #("for", json.string(encode_for_target(job.for_))),
    #("interval_ms", json.int(job.interval_ms)),
    #("due_at", case job.due_at {
      Some(d) -> json.string(d)
      None -> json.null()
    }),
    #("run_count", json.int(job.run_count)),
    #("error_count", json.int(job.error_count)),
    #("fired_count", json.int(job.fired_count)),
    #("tags", json.array(job.tags, json.string)),
    #("last_result", case job.last_result {
      Some(r) -> json.string(string.slice(r, 0, 200))
      None -> json.null()
    }),
  ])
}

pub fn encode_job_kind(kind: JobKind) -> String {
  case kind {
    RecurringTask -> "recurring_task"
    Reminder -> "reminder"
    Todo -> "todo"
    Appointment -> "appointment"
  }
}

pub fn encode_for_target(target: ForTarget) -> String {
  case target {
    ForAgent -> "agent"
    ForUser -> "user"
  }
}

pub fn encode_job_status(status: JobStatus) -> String {
  case status {
    Pending -> "pending"
    Running -> "running"
    Completed -> "completed"
    Cancelled -> "cancelled"
    Failed(reason:) -> "failed: " <> reason
  }
}
