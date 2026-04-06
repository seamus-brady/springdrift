// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import planner/log
import planner/types.{
  Blocker, Draft, EndeavourActive, EndeavourBlocked, Phase, PhaseComplete,
  PhaseInProgress, PhaseNotStarted, SessionScheduled, WorkSession,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// new_endeavour
// ---------------------------------------------------------------------------

pub fn new_endeavour_has_defaults_test() {
  let e =
    types.new_endeavour(
      "end-1",
      types.SystemEndeavour,
      "Title",
      "Desc",
      "2026-04-01T09:00:00",
    )
  e.endeavour_id |> should.equal("end-1")
  e.status |> should.equal(Draft)
  e.goal |> should.equal("")
  e.success_criteria |> should.equal([])
  e.phases |> should.equal([])
  e.blockers |> should.equal([])
  e.work_sessions |> should.equal([])
  e.replan_count |> should.equal(0)
  e.total_cycles |> should.equal(0)
  e.total_tokens |> should.equal(0)
}

// ---------------------------------------------------------------------------
// Phase operations via resolve
// ---------------------------------------------------------------------------

pub fn add_phase_resolves_test() {
  let e =
    types.new_endeavour("end-1", types.SystemEndeavour, "T", "D", "2026-04-01")
  let phase =
    Phase(
      name: "Research",
      description: "Gather data",
      status: PhaseNotStarted,
      task_ids: [],
      depends_on: [],
      milestone: Some("Data collected"),
      estimated_sessions: 3,
      actual_sessions: 0,
    )
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.AddPhase(endeavour_id: "end-1", phase:),
  ]
  let resolved = log.resolve_endeavours(ops)
  let assert [r] = resolved
  list.length(r.phases) |> should.equal(1)
  let assert [p] = r.phases
  p.name |> should.equal("Research")
  p.status |> should.equal(PhaseNotStarted)
}

pub fn update_phase_resolves_test() {
  let e =
    types.new_endeavour("end-1", types.SystemEndeavour, "T", "D", "2026-04-01")
  let phase =
    Phase(
      name: "Research",
      description: "Gather data",
      status: PhaseNotStarted,
      task_ids: [],
      depends_on: [],
      milestone: None,
      estimated_sessions: 2,
      actual_sessions: 0,
    )
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.AddPhase(endeavour_id: "end-1", phase:),
    types.UpdatePhase(
      endeavour_id: "end-1",
      phase_name: "Research",
      status: PhaseInProgress,
    ),
  ]
  let resolved = log.resolve_endeavours(ops)
  let assert [r] = resolved
  let assert [p] = r.phases
  p.status |> should.equal(PhaseInProgress)
}

pub fn advance_phase_to_complete_test() {
  let e =
    types.new_endeavour("end-1", types.SystemEndeavour, "T", "D", "2026-04-01")
  let p1 =
    Phase(
      name: "Phase1",
      description: "",
      status: PhaseNotStarted,
      task_ids: [],
      depends_on: [],
      milestone: None,
      estimated_sessions: 1,
      actual_sessions: 0,
    )
  let p2 =
    Phase(
      name: "Phase2",
      description: "",
      status: PhaseNotStarted,
      task_ids: [],
      depends_on: [],
      milestone: None,
      estimated_sessions: 1,
      actual_sessions: 0,
    )
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.AddPhase(endeavour_id: "end-1", phase: p1),
    types.AddPhase(endeavour_id: "end-1", phase: p2),
    types.UpdatePhase(
      endeavour_id: "end-1",
      phase_name: "Phase1",
      status: PhaseComplete,
    ),
    types.UpdatePhase(
      endeavour_id: "end-1",
      phase_name: "Phase2",
      status: PhaseInProgress,
    ),
  ]
  let resolved = log.resolve_endeavours(ops)
  let assert [r] = resolved
  let assert [ph1, ph2] = r.phases
  ph1.status |> should.equal(PhaseComplete)
  ph2.status |> should.equal(PhaseInProgress)
}

// ---------------------------------------------------------------------------
// Blocker operations
// ---------------------------------------------------------------------------

pub fn add_blocker_resolves_test() {
  let e =
    types.new_endeavour("end-1", types.SystemEndeavour, "T", "D", "2026-04-01")
  let blocker =
    Blocker(
      id: "blk-1",
      description: "Paywalled source",
      detected_at: "2026-04-01T10:00:00",
      resolution_strategy: "Use alternative source",
      requires_human: False,
      resolved_at: None,
      resolution: None,
    )
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.AddBlocker(endeavour_id: "end-1", blocker:),
  ]
  let resolved = log.resolve_endeavours(ops)
  let assert [r] = resolved
  list.length(r.blockers) |> should.equal(1)
  let assert [b] = r.blockers
  b.id |> should.equal("blk-1")
  b.resolved_at |> should.equal(None)
}

pub fn resolve_blocker_test() {
  let e =
    types.new_endeavour("end-1", types.SystemEndeavour, "T", "D", "2026-04-01")
  let blocker =
    Blocker(
      id: "blk-1",
      description: "Missing access",
      detected_at: "2026-04-01T10:00:00",
      resolution_strategy: "Request access",
      requires_human: True,
      resolved_at: None,
      resolution: None,
    )
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.AddBlocker(endeavour_id: "end-1", blocker:),
    types.ResolveBlocker(
      endeavour_id: "end-1",
      blocker_id: "blk-1",
      resolution: "Access granted",
      at: "2026-04-01T11:00:00",
    ),
  ]
  let resolved = log.resolve_endeavours(ops)
  let assert [r] = resolved
  let assert [b] = r.blockers
  b.resolved_at |> should.equal(Some("2026-04-01T11:00:00"))
  b.resolution |> should.equal(Some("Access granted"))
}

// ---------------------------------------------------------------------------
// Work session operations
// ---------------------------------------------------------------------------

pub fn schedule_session_resolves_test() {
  let e =
    types.new_endeavour("end-1", types.SystemEndeavour, "T", "D", "2026-04-01")
  let session =
    WorkSession(
      session_id: "sess-1",
      scheduled_at: "2026-04-02T09:00:00",
      status: SessionScheduled,
      phase: "Research",
      focus: "Gather market data",
      max_cycles: 5,
      max_tokens: 200_000,
      actual_cycles: 0,
      actual_tokens: 0,
      outcome: None,
    )
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.ScheduleSession(endeavour_id: "end-1", session:),
  ]
  let resolved = log.resolve_endeavours(ops)
  let assert [r] = resolved
  list.length(r.work_sessions) |> should.equal(1)
  r.next_session |> should.equal(Some("2026-04-02T09:00:00"))
}

// ---------------------------------------------------------------------------
// Replan
// ---------------------------------------------------------------------------

pub fn replan_replaces_phases_test() {
  let e =
    types.new_endeavour("end-1", types.SystemEndeavour, "T", "D", "2026-04-01")
  let p1 =
    Phase(
      name: "Old",
      description: "",
      status: PhaseNotStarted,
      task_ids: [],
      depends_on: [],
      milestone: None,
      estimated_sessions: 1,
      actual_sessions: 0,
    )
  let p2 =
    Phase(
      name: "New1",
      description: "Revised",
      status: PhaseNotStarted,
      task_ids: [],
      depends_on: [],
      milestone: None,
      estimated_sessions: 2,
      actual_sessions: 0,
    )
  let p3 =
    Phase(
      name: "New2",
      description: "Added",
      status: PhaseNotStarted,
      task_ids: [],
      depends_on: [],
      milestone: None,
      estimated_sessions: 1,
      actual_sessions: 0,
    )
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.AddPhase(endeavour_id: "end-1", phase: p1),
    types.Replan(endeavour_id: "end-1", reason: "Scope changed", new_phases: [
      p2,
      p3,
    ]),
  ]
  let resolved = log.resolve_endeavours(ops)
  let assert [r] = resolved
  list.length(r.phases) |> should.equal(2)
  r.replan_count |> should.equal(1)
  let assert [rp1, _rp2] = r.phases
  rp1.name |> should.equal("New1")
}

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

pub fn record_metrics_accumulates_test() {
  let e =
    types.new_endeavour("end-1", types.SystemEndeavour, "T", "D", "2026-04-01")
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.RecordMetrics(endeavour_id: "end-1", cycles: 5, tokens: 50_000),
    types.RecordMetrics(endeavour_id: "end-1", cycles: 3, tokens: 30_000),
  ]
  let resolved = log.resolve_endeavours(ops)
  let assert [r] = resolved
  r.total_cycles |> should.equal(8)
  r.total_tokens |> should.equal(80_000)
}

// ---------------------------------------------------------------------------
// Status transitions
// ---------------------------------------------------------------------------

pub fn status_transitions_test() {
  let e =
    types.new_endeavour("end-1", types.SystemEndeavour, "T", "D", "2026-04-01")
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.UpdateEndeavourStatus(endeavour_id: "end-1", status: EndeavourActive),
    types.UpdateEndeavourStatus(endeavour_id: "end-1", status: EndeavourBlocked),
  ]
  let resolved = log.resolve_endeavours(ops)
  let assert [r] = resolved
  r.status |> should.equal(EndeavourBlocked)
}

// ---------------------------------------------------------------------------
// Approval config
// ---------------------------------------------------------------------------

pub fn default_approval_config_test() {
  let cfg = types.default_approval_config()
  cfg.phase_transition |> should.equal(types.Auto)
  cfg.budget_increase |> should.equal(types.RequireApproval)
  cfg.completion |> should.equal(types.RequireApproval)
  cfg.replan |> should.equal(types.Notify)
}
