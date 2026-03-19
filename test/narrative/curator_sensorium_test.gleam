//// Tests for curator sensorium rendering helpers.
////
//// These functions are pure — no actor startup needed.

import agent/types as agent_types
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import narrative/curator
import planner/types as planner_types

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
      ),
      planner_types.PlanStep(
        index: 2,
        description: "step2",
        status: planner_types.Pending,
        completed_at: None,
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
  )
}

fn make_endeavour(id: String, title: String) -> planner_types.Endeavour {
  planner_types.Endeavour(
    endeavour_id: id,
    origin: planner_types.SystemEndeavour,
    title: title,
    description: "endeavour desc",
    status: planner_types.Open,
    task_ids: [],
    created_at: "2026-03-19T09:00:00",
    updated_at: "2026-03-19T09:00:00",
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

pub fn tasks_no_active_tasks_but_open_endeavour_renders_test() {
  let endeavour = make_endeavour("end-001", "Long project")
  // No active tasks, but open endeavour — should still render
  let result = curator.render_sensorium_tasks([], [endeavour])
  result
  |> string.contains("<tasks active=\"0\" endeavours=\"1\">")
  |> should.equal(True)
  result |> string.contains("id=\"end-001\"") |> should.equal(True)
}
