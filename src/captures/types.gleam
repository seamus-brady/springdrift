//// Capture — commitment-shaped statements caught by the post-cycle scanner.
////
//// The MVP commitment tracker records captures detected in prose: agent
//// self-promises ("I'll check X later") and operator asks for deferred work
//// ("check the logs tomorrow"). Captures are either clarified to a
//// scheduled cycle via the existing scheduler, dismissed with a reason, or
//// auto-expired after a configurable age.
////
//// The full GTD pipeline (Next Actions, Waiting For, Someday, autonomous
//// engage, weekly review) is deferred — see
//// docs/roadmap/archived/commitment-tracker-gtd.md.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{type Option}

// ---------------------------------------------------------------------------
// Core type
// ---------------------------------------------------------------------------

pub type Capture {
  Capture(
    schema_version: Int,
    id: String,
    created_at: String,
    source_cycle_id: String,
    text: String,
    source: CaptureSource,
    due_hint: Option(String),
    status: CaptureStatus,
  )
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Who the capture originated from.
///
/// `AgentSelf`   — agent made the promise in its own output
/// `OperatorAsk` — operator asked for deferred work in an input message
/// `InboundComms`— derived from an email or webhook (via comms agent)
pub type CaptureSource {
  AgentSelf
  OperatorAsk
  InboundComms
}

/// Lifecycle state of a capture. Derived by replaying CaptureOps.
pub type CaptureStatus {
  /// Captured but not yet clarified or dismissed.
  Pending
  /// Scheduled cycle created for this capture; carries the scheduler job id.
  ClarifiedToCalendar(scheduler_job_id: String)
  /// Dropped explicitly by the agent or operator with a reason.
  Dismissed(reason: String)
  /// Auto-expired by the daily sweep after exceeding captures_expiry_days.
  Expired
  /// Commitment was delivered on. The reason records how the agent or an
  /// auto-satisfy heuristic concluded the work was done.
  Satisfied(reason: String)
}

// ---------------------------------------------------------------------------
// Op log variants
// ---------------------------------------------------------------------------

/// An op in the append-only captures log. Replay in timestamp order to
/// resolve current `Capture` state.
pub type CaptureOp {
  /// First appearance of a capture.
  Created(capture: Capture)
  /// Capture clarified to a scheduled cycle.
  ClarifyToCalendar(id: String, scheduler_job_id: String, note: String)
  /// Explicitly dropped with a reason.
  Dismiss(id: String, reason: String)
  /// Auto-expired by the daily sweep.
  Expire(id: String)
  /// Commitment delivered on. Reason may be agent-supplied or an auto
  /// heuristic ("auto: matches task TASK-123").
  Satisfy(id: String, reason: String)
}
