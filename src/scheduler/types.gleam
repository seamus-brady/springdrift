//// Scheduler types — scheduled task state and messages.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import profile/types as profile_types

// ---------------------------------------------------------------------------
// Scheduled job state
// ---------------------------------------------------------------------------

pub type JobStatus {
  Pending
  Running
  Completed
  Failed(reason: String)
}

pub type ScheduledJob {
  ScheduledJob(
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
}
