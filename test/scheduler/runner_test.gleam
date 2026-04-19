// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import scheduler/log as schedule_log
import scheduler/runner
import scheduler/types.{
  type ScheduledJob, AddJob, AgentJob, Cancelled, Complete, CompleteJob,
  Completed, Create, FileDelivery, ForAgent, GetStatus, JobComplete, JobFailed,
  Pending, RecurringTask, Reminder, Running, ScheduledJob, StopAll, Todo,
}
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_task(name: String, interval_ms: Int) -> types.ScheduleTaskConfig {
  types.ScheduleTaskConfig(
    name:,
    query: "test query for " <> name,
    interval_ms:,
    start_at: None,
    delivery: types.FileDelivery(
      directory: "/tmp/springdrift-test-scheduler",
      format: "markdown",
    ),
    only_if_changed: False,
  )
}

/// A cognitive subject that auto-replies to UserInput messages.
/// The subject is created inside the spawned process to satisfy ownership rules.
fn auto_reply_cognitive() -> process.Subject(agent_types.CognitiveMessage) {
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let subj: process.Subject(agent_types.CognitiveMessage) =
      process.new_subject()
    process.send(setup, subj)
    auto_reply_loop(subj)
  })
  let assert Ok(subj) = process.receive(setup, 5000)
  subj
}

/// Remove a schedule directory so stale state from prior runs doesn't affect timing.
fn clean_schedule_dir(path: String) -> Nil {
  let _ = simplifile.delete(path)
  let _ = simplifile.create_directory_all(path)
  Nil
}

/// Poll scheduler status until `pred` returns True or `remaining_ms` is exhausted.
/// Polls every 100ms.
fn poll_until(
  sched: process.Subject(types.SchedulerMessage),
  pred: fn(List(ScheduledJob)) -> Bool,
  remaining_ms: Int,
) -> List(ScheduledJob) {
  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  case pred(jobs), remaining_ms > 0 {
    True, _ -> jobs
    False, True -> {
      process.sleep(100)
      poll_until(sched, pred, remaining_ms - 100)
    }
    False, False -> jobs
  }
}

fn auto_reply_loop(subj: process.Subject(agent_types.CognitiveMessage)) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(subj)
  let msg = process.selector_receive_forever(selector)
  case msg {
    agent_types.UserInput(text: _, reply_to:) -> {
      process.send(
        reply_to,
        agent_types.CognitiveReply(
          response: "mock result",
          model: "mock",
          usage: None,
        ),
      )
    }
    agent_types.SchedulerInput(reply_to:, ..) -> {
      process.send(
        reply_to,
        agent_types.CognitiveReply(
          response: "mock result",
          model: "mock",
          usage: None,
        ),
      )
    }
    _ -> Nil
  }
  auto_reply_loop(subj)
}

// ---------------------------------------------------------------------------
// Start and get status
// ---------------------------------------------------------------------------

pub fn start_returns_subject_test() {
  let cognitive = auto_reply_cognitive()
  let tasks = [make_task("job-a", 600_000)]
  let assert Ok(sched) =
    runner.start(
      tasks,
      cognitive,
      "/tmp/springdrift-test-sched",
      600_000,
      20,
      500_000,
      0,
    )

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  list.length(jobs) |> should.equal(1)
}

pub fn start_with_multiple_tasks_test() {
  let cognitive = auto_reply_cognitive()
  let tasks = [make_task("alpha", 600_000), make_task("beta", 600_000)]
  let assert Ok(sched) =
    runner.start(
      tasks,
      cognitive,
      "/tmp/springdrift-test-sched2",
      600_000,
      20,
      500_000,
      0,
    )

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  list.length(jobs) |> should.equal(2)
}

// ---------------------------------------------------------------------------
// StopAll
// ---------------------------------------------------------------------------

pub fn stop_all_terminates_test() {
  let cognitive = auto_reply_cognitive()
  let tasks = [make_task("stopping", 600_000)]
  let assert Ok(sched) =
    runner.start(
      tasks,
      cognitive,
      "/tmp/springdrift-test-sched3",
      600_000,
      20,
      500_000,
      0,
    )

  process.send(sched, StopAll)
  process.sleep(100)
}

// ---------------------------------------------------------------------------
// Full flow: tick fires → job runs → auto-reply → Completed
// ---------------------------------------------------------------------------

pub fn auto_execution_completes_job_test() {
  let cp = "/tmp/springdrift-test-sched-auto"
  clean_schedule_dir(cp)
  let cognitive = auto_reply_cognitive()
  // initial_delay returns 0, so tick fires at 1ms
  let tasks = [make_task("auto-run", 600_000)]
  let assert Ok(sched) =
    runner.start(tasks, cognitive, cp, 600_000, 20, 500_000, 0)

  // Poll until the job has run at least once. Recurring tasks return to Pending
  // after each completion, so we check run_count rather than status.
  let jobs =
    poll_until(
      sched,
      fn(js) {
        case list.find(js, fn(j: ScheduledJob) { j.name == "auto-run" }) {
          Ok(j) -> j.run_count >= 1
          Error(_) -> False
        }
      },
      5000,
    )

  let assert Ok(job) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "auto-run" })
  { job.run_count >= 1 } |> should.be_true()
  job.last_result |> should.equal(Some("mock result"))
}

// ---------------------------------------------------------------------------
// Unknown job names are silently ignored
// ---------------------------------------------------------------------------

pub fn unknown_job_complete_ignored_test() {
  let cognitive = auto_reply_cognitive()
  let tasks = [make_task("real-job", 600_000)]
  let assert Ok(sched) =
    runner.start(
      tasks,
      cognitive,
      "/tmp/springdrift-test-sched7",
      600_000,
      20,
      500_000,
      0,
    )

  process.send(
    sched,
    JobComplete(name: "ghost-job", result: "boo", tokens_used: 0),
  )
  process.sleep(100)

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  list.length(jobs) |> should.equal(1)
}

pub fn unknown_job_failed_ignored_test() {
  let cognitive = auto_reply_cognitive()
  let tasks = [make_task("real-job2", 600_000)]
  let assert Ok(sched) =
    runner.start(
      tasks,
      cognitive,
      "/tmp/springdrift-test-sched8",
      600_000,
      20,
      500_000,
      0,
    )

  process.send(sched, JobFailed(name: "ghost-job", reason: "phantom"))
  process.sleep(100)

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  list.length(jobs) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// Empty tasks list
// ---------------------------------------------------------------------------

pub fn start_with_no_tasks_test() {
  let cognitive = auto_reply_cognitive()
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      "/tmp/springdrift-test-sched10",
      600_000,
      20,
      500_000,
      0,
    )

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  list.length(jobs) |> should.equal(0)
}

// ---------------------------------------------------------------------------
// Job transitions through Running to Completed
// ---------------------------------------------------------------------------

pub fn job_transitions_through_running_test() {
  let cp = "/tmp/springdrift-test-sched-trans"
  clean_schedule_dir(cp)
  let cognitive = auto_reply_cognitive()
  let tasks = [make_task("transitions", 600_000)]
  let assert Ok(sched) =
    runner.start(tasks, cognitive, cp, 600_000, 20, 500_000, 0)

  // Poll until the job has left Pending (Running, Completed, or back to Pending
  // with run_count > 0 for recurring tasks).
  let jobs =
    poll_until(
      sched,
      fn(js) {
        case list.find(js, fn(j: ScheduledJob) { j.name == "transitions" }) {
          Ok(j) -> j.status == Running || j.run_count >= 1
          Error(_) -> False
        }
      },
      5000,
    )

  let assert Ok(job) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "transitions" })
  // Job should have transitioned: either still Running, or already completed
  // (recurring tasks return to Pending with run_count incremented).
  { job.status == Running || job.run_count >= 1 } |> should.be_true()
}

// ---------------------------------------------------------------------------
// Multiple auto-executed tasks all complete
// ---------------------------------------------------------------------------

pub fn multiple_tasks_all_complete_test() {
  let cp = "/tmp/springdrift-test-sched-multi"
  clean_schedule_dir(cp)
  let cognitive = auto_reply_cognitive()
  let tasks = [make_task("task-1", 600_000), make_task("task-2", 600_000)]
  let assert Ok(sched) =
    runner.start(tasks, cognitive, cp, 600_000, 20, 500_000, 0)

  // Poll until both jobs have run at least once (recurring tasks return to
  // Pending after completion, so check run_count).
  let jobs =
    poll_until(
      sched,
      fn(js) { list.count(js, fn(j: ScheduledJob) { j.run_count >= 1 }) == 2 },
      5000,
    )

  let ran_count = list.count(jobs, fn(j: ScheduledJob) { j.run_count >= 1 })
  ran_count |> should.equal(2)
}

// ---------------------------------------------------------------------------
// Defensive CompleteJob — recurring jobs with remaining fires must not be
// completed by the agent. Historically `complete_item` blindly marked any
// matching job Completed, which silently killed recurring schedules.
// ---------------------------------------------------------------------------

fn make_recurring_job(name: String) -> ScheduledJob {
  // Long interval so the timer doesn't fire mid-test.
  ScheduledJob(
    name:,
    query: "noop",
    interval_ms: 600_000,
    delivery: FileDelivery(directory: "/tmp/x", format: "markdown"),
    only_if_changed: False,
    status: Pending,
    last_run_ms: None,
    last_result: None,
    run_count: 0,
    error_count: 0,
    job_source: AgentJob,
    kind: RecurringTask,
    due_at: None,
    for_: ForAgent,
    title: "Recurring task " <> name,
    body: "",
    duration_minutes: 0,
    tags: [],
    created_at: "2026-04-18T10:00:00",
    fired_count: 0,
    recurrence_end_at: None,
    max_occurrences: None,
  )
}

fn make_one_shot_reminder(name: String) -> ScheduledJob {
  ScheduledJob(
    name:,
    query: "",
    interval_ms: 0,
    delivery: FileDelivery(directory: "/tmp/x", format: "markdown"),
    only_if_changed: False,
    status: Pending,
    last_run_ms: None,
    last_result: None,
    run_count: 0,
    error_count: 0,
    job_source: AgentJob,
    kind: Reminder,
    due_at: Some("2030-01-01T00:00:00"),
    for_: ForAgent,
    title: "Reminder " <> name,
    body: "remember this",
    duration_minutes: 0,
    tags: [],
    created_at: "2026-04-18T10:00:00",
    fired_count: 0,
    recurrence_end_at: None,
    max_occurrences: None,
  )
}

pub fn complete_job_refuses_recurring_test() {
  let cp = "/tmp/springdrift-test-sched-refuse"
  clean_schedule_dir(cp)
  let cognitive = auto_reply_cognitive()
  let assert Ok(sched) = runner.start([], cognitive, cp, 600_000, 0, 0, 0)

  // Add a recurring task with no fire budget exhaustion.
  let add_reply = process.new_subject()
  process.send(
    sched,
    AddJob(job: make_recurring_job("daily-recap"), reply_to: add_reply),
  )
  let assert Ok(Ok(_)) = process.receive(add_reply, 5000)

  // Try to mark it complete — must be refused.
  let complete_reply = process.new_subject()
  process.send(
    sched,
    CompleteJob(name: "daily-recap", reply_to: complete_reply),
  )
  let assert Ok(result) = process.receive(complete_reply, 5000)
  case result {
    Error(_) -> Nil
    Ok(_) -> panic as "Expected CompleteJob to refuse recurring job"
  }

  // Job must still be Pending, not Completed.
  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  let assert Ok(job) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "daily-recap" })
  job.status |> should.equal(Pending)

  process.send(sched, StopAll)
  process.sleep(50)
}

pub fn complete_job_succeeds_for_one_shot_reminder_test() {
  let cp = "/tmp/springdrift-test-sched-oneshot"
  clean_schedule_dir(cp)
  let cognitive = auto_reply_cognitive()
  let assert Ok(sched) = runner.start([], cognitive, cp, 600_000, 0, 0, 0)

  let add_reply = process.new_subject()
  process.send(
    sched,
    AddJob(job: make_one_shot_reminder("call-mom"), reply_to: add_reply),
  )
  let assert Ok(Ok(_)) = process.receive(add_reply, 5000)

  // One-shot reminder: complete must work.
  let complete_reply = process.new_subject()
  process.send(sched, CompleteJob(name: "call-mom", reply_to: complete_reply))
  let assert Ok(Ok(Nil)) = process.receive(complete_reply, 5000)

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  let assert Ok(job) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "call-mom" })
  job.status |> should.equal(Completed)

  process.send(sched, StopAll)
  process.sleep(50)
}

pub fn complete_job_succeeds_for_recurring_with_max_reached_test() {
  let cp = "/tmp/springdrift-test-sched-maxout"
  clean_schedule_dir(cp)
  let cognitive = auto_reply_cognitive()
  let assert Ok(sched) = runner.start([], cognitive, cp, 600_000, 0, 0, 0)

  // Recurring job that has already exhausted its max_occurrences.
  let job =
    ScheduledJob(
      ..make_recurring_job("hit-limit"),
      max_occurrences: Some(3),
      fired_count: 3,
    )
  let add_reply = process.new_subject()
  process.send(sched, AddJob(job:, reply_to: add_reply))
  let assert Ok(Ok(_)) = process.receive(add_reply, 5000)

  let complete_reply = process.new_subject()
  process.send(sched, CompleteJob(name: "hit-limit", reply_to: complete_reply))
  let assert Ok(Ok(Nil)) = process.receive(complete_reply, 5000)

  process.send(sched, StopAll)
  process.sleep(50)
}

// ---------------------------------------------------------------------------
// Startup recovery — recurring job written as Completed in the JSONL log
// (e.g. by an old build before the defensive CompleteJob fix) gets re-armed
// to Pending on next start, provided it still has fire budget left.
// ---------------------------------------------------------------------------

pub fn recovery_rearms_completed_recurring_job_test() {
  let cp = "/tmp/springdrift-test-sched-recovery"
  clean_schedule_dir(cp)

  // Pre-populate the log: Create a recurring job, then mark it Complete.
  let job = make_recurring_job("lost-recurrence")
  schedule_log.append(cp, job, Create)
  schedule_log.append(cp, ScheduledJob(..job, status: Completed), Complete)

  let cognitive = auto_reply_cognitive()
  let assert Ok(sched) = runner.start([], cognitive, cp, 600_000, 0, 0, 0)

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  let assert Ok(recovered) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "lost-recurrence" })
  recovered.status |> should.equal(Pending)

  process.send(sched, StopAll)
  process.sleep(50)
}

pub fn recovery_leaves_exhausted_recurring_completed_test() {
  let cp = "/tmp/springdrift-test-sched-recovery2"
  clean_schedule_dir(cp)

  // Recurring job that legitimately exhausted its budget — must NOT be revived.
  let job =
    ScheduledJob(
      ..make_recurring_job("naturally-done"),
      max_occurrences: Some(3),
      fired_count: 3,
    )
  schedule_log.append(cp, job, Create)
  schedule_log.append(cp, ScheduledJob(..job, status: Completed), Complete)

  let cognitive = auto_reply_cognitive()
  let assert Ok(sched) = runner.start([], cognitive, cp, 600_000, 0, 0, 0)

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  let assert Ok(found) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "naturally-done" })
  found.status |> should.equal(Completed)

  process.send(sched, StopAll)
  process.sleep(50)
}

// ---------------------------------------------------------------------------
// Auto-purge — old terminal one-shots are dropped at startup; recurring
// jobs are never purged regardless of status or last_run_ms.
// ---------------------------------------------------------------------------

pub fn auto_purge_keeps_recurring_jobs_test() {
  let cp = "/tmp/springdrift-test-sched-purge-keep"
  clean_schedule_dir(cp)

  // Recurring job with last_run far in the past — must still be kept.
  let recurring =
    ScheduledJob(
      ..make_recurring_job("ancient-recurring"),
      last_run_ms: Some(0),
    )
  schedule_log.append(cp, recurring, Create)

  let cognitive = auto_reply_cognitive()
  let assert Ok(sched) = runner.start([], cognitive, cp, 600_000, 0, 0, 0)
  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  list.length(jobs) |> should.equal(1)

  process.send(sched, StopAll)
  process.sleep(50)
}

pub fn auto_purge_drops_old_terminal_one_shot_test() {
  let cp = "/tmp/springdrift-test-sched-purge-drop"
  clean_schedule_dir(cp)

  // Old completed Todo, last_run_ms set to 0 (effectively year 1970).
  // Default retention is 30 days, so this is well outside.
  let stale_todo =
    ScheduledJob(
      name: "old-todo",
      query: "",
      interval_ms: 0,
      delivery: FileDelivery(directory: "/tmp/x", format: "markdown"),
      only_if_changed: False,
      status: Completed,
      last_run_ms: Some(0),
      last_result: None,
      run_count: 1,
      error_count: 0,
      job_source: AgentJob,
      kind: Todo,
      due_at: None,
      for_: ForAgent,
      title: "Old todo",
      body: "",
      duration_minutes: 0,
      tags: [],
      created_at: "2020-01-01T00:00:00",
      fired_count: 1,
      recurrence_end_at: None,
      max_occurrences: None,
    )
  schedule_log.append(cp, stale_todo, Create)
  schedule_log.append(
    cp,
    ScheduledJob(..stale_todo, status: Completed),
    Complete,
  )

  // Fresh cancelled one-shot: last_run_ms = None should NOT be purged
  // (treated as "recent" — never had a chance to age out).
  let fresh_cancelled =
    ScheduledJob(
      ..stale_todo,
      name: "fresh-cancelled",
      status: Cancelled,
      last_run_ms: None,
      title: "Fresh cancelled",
    )
  schedule_log.append(cp, fresh_cancelled, Create)

  let cognitive = auto_reply_cognitive()
  let assert Ok(sched) = runner.start([], cognitive, cp, 600_000, 0, 0, 0)

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  list.find(jobs, fn(j: ScheduledJob) { j.name == "old-todo" })
  |> should.be_error()
  list.find(jobs, fn(j: ScheduledJob) { j.name == "fresh-cancelled" })
  |> should.be_ok()

  process.send(sched, StopAll)
  process.sleep(50)
}
