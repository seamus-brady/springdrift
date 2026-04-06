// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import scheduler/types

// ---------------------------------------------------------------------------
// encode_job_kind
// ---------------------------------------------------------------------------

pub fn encode_job_kind_recurring_test() {
  types.encode_job_kind(types.RecurringTask) |> should.equal("recurring_task")
}

pub fn encode_job_kind_reminder_test() {
  types.encode_job_kind(types.Reminder) |> should.equal("reminder")
}

pub fn encode_job_kind_todo_test() {
  types.encode_job_kind(types.Todo) |> should.equal("todo")
}

pub fn encode_job_kind_appointment_test() {
  types.encode_job_kind(types.Appointment) |> should.equal("appointment")
}

// ---------------------------------------------------------------------------
// encode_for_target
// ---------------------------------------------------------------------------

pub fn encode_for_target_agent_test() {
  types.encode_for_target(types.ForAgent) |> should.equal("agent")
}

pub fn encode_for_target_user_test() {
  types.encode_for_target(types.ForUser) |> should.equal("user")
}

// ---------------------------------------------------------------------------
// encode_job_status
// ---------------------------------------------------------------------------

pub fn encode_job_status_pending_test() {
  types.encode_job_status(types.Pending) |> should.equal("pending")
}

pub fn encode_job_status_running_test() {
  types.encode_job_status(types.Running) |> should.equal("running")
}

pub fn encode_job_status_failed_test() {
  types.encode_job_status(types.Failed(reason: "timeout"))
  |> should.equal("failed: timeout")
}

// ---------------------------------------------------------------------------
// encode_job — full JSON encoding
// ---------------------------------------------------------------------------

pub fn encode_job_has_required_fields_test() {
  let job =
    types.ScheduledJob(
      name: "test-job",
      query: "test query",
      interval_ms: 60_000,
      delivery: types.FileDelivery(directory: "/tmp", format: "markdown"),
      only_if_changed: False,
      status: types.Pending,
      last_run_ms: None,
      last_result: Some("some result"),
      run_count: 3,
      error_count: 1,
      job_source: types.ProfileJob,
      kind: types.RecurringTask,
      due_at: None,
      for_: types.ForAgent,
      title: "Test Job",
      body: "",
      duration_minutes: 0,
      tags: ["daily", "report"],
      created_at: "2026-03-17T10:00:00",
      fired_count: 5,
      recurrence_end_at: None,
      max_occurrences: None,
    )
  let json_str = json.to_string(types.encode_job(job))
  should.be_true(string.contains(json_str, "\"name\":\"test-job\""))
  should.be_true(string.contains(json_str, "\"kind\":\"recurring_task\""))
  should.be_true(string.contains(json_str, "\"status\":\"pending\""))
  should.be_true(string.contains(json_str, "\"for\":\"agent\""))
  should.be_true(string.contains(json_str, "\"run_count\":3"))
  should.be_true(string.contains(json_str, "\"fired_count\":5"))
  should.be_true(string.contains(json_str, "\"daily\""))
  should.be_true(string.contains(json_str, "\"report\""))
}

pub fn encode_job_truncates_last_result_test() {
  let long_result = string.repeat("x", 300)
  let job =
    types.ScheduledJob(
      name: "trunc-test",
      query: "",
      interval_ms: 0,
      delivery: types.FileDelivery(directory: "/tmp", format: "md"),
      only_if_changed: False,
      status: types.Completed,
      last_run_ms: None,
      last_result: Some(long_result),
      run_count: 0,
      error_count: 0,
      job_source: types.AgentJob,
      kind: types.Todo,
      due_at: None,
      for_: types.ForUser,
      title: "Truncate",
      body: "",
      duration_minutes: 0,
      tags: [],
      created_at: "",
      fired_count: 0,
      recurrence_end_at: None,
      max_occurrences: None,
    )
  let json_str = json.to_string(types.encode_job(job))
  // The JSON should NOT contain 300 x's — truncated to 200
  should.be_false(string.contains(json_str, string.repeat("x", 300)))
  should.be_true(string.contains(json_str, string.repeat("x", 200)))
}
