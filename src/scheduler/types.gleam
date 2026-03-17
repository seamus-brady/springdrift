//// Scheduler types — scheduled task state and messages.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import profile/types as profile_types

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
    delivery: profile_types.DeliveryConfig,
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

pub type SchedulerMessage {
  /// Timer fired for a specific job
  Tick(name: String)
  /// Job completed with result text
  JobComplete(name: String, result: String)
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
}
