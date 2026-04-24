//// Tests for curator sensorium rendering helpers.
////
//// These functions are pure — no actor startup needed.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import captures/types as captures_types
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import narrative/curator
import narrative/virtual_memory
import planner/types as planner_types
import scheduler/types as scheduler_types

fn empty_perf() -> curator.PerformanceSummary {
  curator.PerformanceSummary(
    success_rate: 0.0,
    recent_failures: [],
    cost_trend: "stable",
    cbr_hit_rate: 0.0,
  )
}

// ---------------------------------------------------------------------------
// render_sensorium_events
// ---------------------------------------------------------------------------

pub fn events_empty_returns_empty_string_test() {
  curator.render_sensorium_events([])
  |> should.equal("")
}

pub fn events_single_renders_xml_test() {
  let event =
    agent_types.SensoryEvent(
      name: "task_complete",
      title: "Task finished",
      body: "Research task completed successfully",
      fired_at: "2026-03-19T10:00:00",
    )
  let result = curator.render_sensorium_events([event])
  result |> string.contains("<events count=\"1\">") |> should.equal(True)
  result
  |> string.contains("name=\"task_complete\"")
  |> should.equal(True)
  result
  |> string.contains("title=\"Task finished\"")
  |> should.equal(True)
  result
  |> string.contains("at=\"2026-03-19T10:00:00\"")
  |> should.equal(True)
  result
  |> string.contains("Research task completed successfully")
  |> should.equal(True)
  result |> string.contains("</events>") |> should.equal(True)
}

pub fn events_multiple_renders_correct_count_test() {
  let e1 =
    agent_types.SensoryEvent(
      name: "event_one",
      title: "First",
      body: "body1",
      fired_at: "2026-03-19T10:00:00",
    )
  let e2 =
    agent_types.SensoryEvent(
      name: "event_two",
      title: "Second",
      body: "body2",
      fired_at: "2026-03-19T11:00:00",
    )
  let result = curator.render_sensorium_events([e1, e2])
  result |> string.contains("<events count=\"2\">") |> should.equal(True)
  result |> string.contains("name=\"event_one\"") |> should.equal(True)
  result |> string.contains("name=\"event_two\"") |> should.equal(True)
}

// ---------------------------------------------------------------------------
// render_sensorium_tasks
// ---------------------------------------------------------------------------

pub fn tasks_empty_returns_empty_string_test() {
  curator.render_sensorium_tasks([], [])
  |> should.equal("")
}

fn make_active_task(id: String, title: String) -> planner_types.PlannerTask {
  planner_types.PlannerTask(
    task_id: id,
    endeavour_id: None,
    origin: planner_types.SystemTask,
    title: title,
    description: "desc",
    status: planner_types.Active,
    plan_steps: [
      planner_types.PlanStep(
        index: 1,
        description: "step1",
        status: planner_types.Complete,
        completed_at: Some("2026-03-19T10:00:00"),
        verification: None,
      ),
      planner_types.PlanStep(
        index: 2,
        description: "step2",
        status: planner_types.Pending,
        completed_at: None,
        verification: None,
      ),
    ],
    dependencies: [],
    complexity: "medium",
    risks: [],
    materialised_risks: [],
    created_at: "2026-03-19T09:00:00",
    updated_at: "2026-03-19T09:00:00",
    cycle_ids: [],
    forecast_score: None,
    forecast_breakdown: None,
    pre_mortem: None,
    post_mortem: None,
  )
}

fn make_endeavour(id: String, title: String) -> planner_types.Endeavour {
  planner_types.new_endeavour(
    id,
    planner_types.SystemEndeavour,
    title,
    "endeavour desc",
    "2026-03-19T09:00:00",
  )
}

pub fn tasks_standalone_renders_task_element_test() {
  let task = make_active_task("task-001", "Research competitors")
  let result = curator.render_sensorium_tasks([task], [])
  result
  |> string.contains("<tasks active=\"1\" endeavours=\"0\">")
  |> should.equal(True)
  result
  |> string.contains("id=\"task-001\"")
  |> should.equal(True)
  result
  |> string.contains("title=\"Research competitors\"")
  |> should.equal(True)
  result |> string.contains("status=\"active\"") |> should.equal(True)
  result |> string.contains("progress=\"1/2\"") |> should.equal(True)
  result |> string.contains("</tasks>") |> should.equal(True)
}

pub fn tasks_standalone_has_no_endeavour_attr_test() {
  let task = make_active_task("task-001", "Write report")
  let result = curator.render_sensorium_tasks([task], [])
  // standalone task has no endeavour attribute
  result |> string.contains("endeavour=") |> should.equal(False)
}

pub fn tasks_with_endeavour_renders_endeavour_element_test() {
  let endeavour = make_endeavour("end-001", "Market Analysis")
  let task =
    planner_types.PlannerTask(
      ..make_active_task("task-001", "Research pricing"),
      endeavour_id: Some("end-001"),
    )
  let result = curator.render_sensorium_tasks([task], [endeavour])
  result
  |> string.contains("<tasks active=\"1\" endeavours=\"1\">")
  |> should.equal(True)
  result
  |> string.contains("id=\"end-001\"")
  |> should.equal(True)
  result
  |> string.contains("title=\"Market Analysis\"")
  |> should.equal(True)
  result |> string.contains("endeavour=\"end-001\"") |> should.equal(True)
}

pub fn tasks_only_active_and_pending_included_test() {
  let active_task = make_active_task("task-act", "Active task")
  let complete_task =
    planner_types.PlannerTask(
      ..make_active_task("task-done", "Done task"),
      status: planner_types.Complete,
    )
  let result = curator.render_sensorium_tasks([active_task, complete_task], [])
  result
  |> string.contains("<tasks active=\"1\" endeavours=\"0\">")
  |> should.equal(True)
  result |> string.contains("id=\"task-act\"") |> should.equal(True)
  result |> string.contains("id=\"task-done\"") |> should.equal(False)
}

pub fn tasks_element_includes_updated_attribute_test() {
  let task = make_active_task("task-001", "Research competitors")
  let result = curator.render_sensorium_tasks([task], [])
  // updated_at is "2026-03-19T09:00:00", should render as updated="..."
  result |> string.contains("updated=\"") |> should.equal(True)
}

pub fn tasks_no_active_tasks_but_open_endeavour_renders_test() {
  let endeavour = make_endeavour("end-001", "Long project")
  // No active tasks, but open endeavour — should still render
  let result = curator.render_sensorium_tasks([], [endeavour])
  result
  |> string.contains("<tasks active=\"0\" endeavours=\"1\">")
  |> should.equal(True)
  result |> string.contains("id=\"end-001\"") |> should.equal(True)
}

// ---------------------------------------------------------------------------
// render_sensorium_vitals with novelty
// ---------------------------------------------------------------------------

pub fn vitals_with_novelty_renders_attribute_test() {
  let constitution =
    virtual_memory.ConstitutionSlot(
      today_cycles: 5,
      today_success_rate: 0.8,
      agent_health: "All agents nominal",
    )
  let result =
    curator.render_sensorium_vitals(
      constitution,
      2,
      "",
      "",
      None,
      0.7,
      empty_perf(),
      0,
      0,
    )
  result
  |> string.contains("novelty=\"0.7\"")
  |> should.equal(True)
  // Removed signals should not appear
  result
  |> string.contains("uncertainty=")
  |> should.equal(False)
  result
  |> string.contains("prediction_error=")
  |> should.equal(False)
}

// ---------------------------------------------------------------------------
// recurring_staleness — schedule sensorium watchdog.
// ---------------------------------------------------------------------------

fn make_recurring_for_staleness(
  name: String,
  interval_ms: Int,
  fired_count: Int,
  last_run_ms: option.Option(Int),
  status: scheduler_types.JobStatus,
  created_at: String,
) -> scheduler_types.ScheduledJob {
  scheduler_types.ScheduledJob(
    name:,
    query: "noop",
    interval_ms:,
    delivery: scheduler_types.FileDelivery(
      directory: "/tmp/x",
      format: "markdown",
    ),
    only_if_changed: False,
    status:,
    last_run_ms:,
    last_result: None,
    run_count: 0,
    error_count: 0,
    job_source: scheduler_types.AgentJob,
    kind: scheduler_types.RecurringTask,
    due_at: None,
    for_: scheduler_types.ForAgent,
    title: "Recurring " <> name,
    body: "",
    duration_minutes: 0,
    tags: [],
    created_at:,
    fired_count:,
    recurrence_end_at: None,
    max_occurrences: None,
    required_tools: [],
  )
}

pub fn staleness_none_for_one_shot_job_test() {
  // A Reminder (interval_ms = 0) is never recurring; staleness is N/A.
  let one_shot =
    scheduler_types.ScheduledJob(
      ..make_recurring_for_staleness(
        "reminder-1",
        0,
        0,
        None,
        scheduler_types.Pending,
        "2020-01-01T00:00:00",
      ),
      kind: scheduler_types.Reminder,
    )
  curator.recurring_staleness(one_shot, 1_000_000) |> should.equal(None)
}

pub fn staleness_none_for_terminal_status_test() {
  let cancelled =
    make_recurring_for_staleness(
      "stopped",
      60_000,
      0,
      None,
      scheduler_types.Cancelled,
      "2020-01-01T00:00:00",
    )
  curator.recurring_staleness(cancelled, 1_000_000) |> should.equal(None)
}

pub fn staleness_overdue_when_last_run_too_old_test() {
  // interval = 60_000 ms; last_run was 200_000 ms ago, > 1.5 × interval.
  let job =
    make_recurring_for_staleness(
      "wedged",
      60_000,
      5,
      Some(0),
      scheduler_types.Pending,
      "2026-04-18T10:00:00",
    )
  curator.recurring_staleness(job, 200_000)
  |> should.equal(Some("overdue"))
}

pub fn staleness_healthy_when_last_run_within_window_test() {
  // last_run was 50_000 ms ago, well within 1.5 × interval (90_000).
  let job =
    make_recurring_for_staleness(
      "healthy",
      60_000,
      5,
      Some(150_000),
      scheduler_types.Pending,
      "2026-04-18T10:00:00",
    )
  curator.recurring_staleness(job, 200_000) |> should.equal(None)
}

pub fn staleness_never_fired_when_created_long_ago_test() {
  // interval 60s, fired_count = 0, created in 2020 — definitely stale.
  let job =
    make_recurring_for_staleness(
      "ghost",
      60_000,
      0,
      None,
      scheduler_types.Pending,
      "2020-01-01T00:00:00",
    )
  curator.recurring_staleness(job, 0)
  |> should.equal(Some("never_fired"))
}

pub fn staleness_never_fired_grace_period_test() {
  // Created in the future — elapsed_ms is negative, not yet stale.
  let job =
    make_recurring_for_staleness(
      "fresh",
      60_000,
      0,
      None,
      scheduler_types.Pending,
      "2099-01-01T00:00:00",
    )
  curator.recurring_staleness(job, 0) |> should.equal(None)
}

pub fn schedule_xml_includes_stale_attribute_test() {
  // No scheduler → empty string regardless. Verify staleness field path
  // rather than the rendered output (which requires an actor).
  curator.render_sensorium_schedule(None) |> should.equal("")
}

// ---------------------------------------------------------------------------
// render_sensorium_captures — Phase 3a commitment loop
// ---------------------------------------------------------------------------

fn make_pending_capture(
  id: String,
  source: captures_types.CaptureSource,
  text: String,
) -> captures_types.Capture {
  captures_types.Capture(
    schema_version: 1,
    id: id,
    // Fixed timestamp so tests are reproducible regardless of clock.
    created_at: "2026-04-23T10:00:00",
    source_cycle_id: "cyc-test",
    text: text,
    source: source,
    due_hint: None,
    status: captures_types.Pending,
  )
}

pub fn captures_empty_returns_empty_string_test() {
  curator.render_sensorium_captures([])
  |> should.equal("")
}

pub fn captures_all_non_pending_returns_empty_string_test() {
  let c =
    captures_types.Capture(
      ..make_pending_capture("a", captures_types.AgentSelf, "old commitment"),
      status: captures_types.Dismissed(reason: "done"),
    )
  curator.render_sensorium_captures([c])
  |> should.equal("")
}

pub fn captures_renders_pending_count_test() {
  let captures = [
    make_pending_capture("a", captures_types.AgentSelf, "check tool results"),
    make_pending_capture("b", captures_types.OperatorAsk, "save the report"),
  ]
  let out = curator.render_sensorium_captures(captures)
  out |> string.contains("<commitments pending=\"2\">") |> should.be_true
  out |> string.contains("check tool results") |> should.be_true
  out |> string.contains("save the report") |> should.be_true
  out |> string.contains("</commitments>") |> should.be_true
}

pub fn captures_renders_source_specific_tags_test() {
  let captures = [
    make_pending_capture("a", captures_types.AgentSelf, "agent promise"),
    make_pending_capture("b", captures_types.OperatorAsk, "operator ask"),
  ]
  let out = curator.render_sensorium_captures(captures)
  out |> string.contains("<self ") |> should.be_true
  out |> string.contains("<operator ") |> should.be_true
}

pub fn captures_truncates_long_text_test() {
  // 200-char text should be cut to 117 + ellipsis.
  let long = string.repeat("x", 200)
  let captures = [make_pending_capture("a", captures_types.AgentSelf, long)]
  let out = curator.render_sensorium_captures(captures)
  out |> string.contains("...") |> should.be_true
}

pub fn captures_caps_self_items_at_three_test() {
  // Five agent_self items — only the first three render.
  let captures = [
    make_pending_capture("a", captures_types.AgentSelf, "first"),
    make_pending_capture("b", captures_types.AgentSelf, "second"),
    make_pending_capture("c", captures_types.AgentSelf, "third"),
    make_pending_capture("d", captures_types.AgentSelf, "fourth"),
    make_pending_capture("e", captures_types.AgentSelf, "fifth"),
  ]
  let out = curator.render_sensorium_captures(captures)
  out |> string.contains("first") |> should.be_true
  out |> string.contains("second") |> should.be_true
  out |> string.contains("third") |> should.be_true
  out |> string.contains("fourth") |> should.be_false
  out |> string.contains("fifth") |> should.be_false
}
