// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import frontdoor
import frontdoor/types as frontdoor_types
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
    required_tools: [],
  )
}

/// A cognitive subject that auto-replies to UserInput and SchedulerInput
/// by ClaimCycle'ing + Publishing to Frontdoor, matching how the real
/// cognitive loop routes replies post-migration.
fn auto_reply_cognitive(
  fd: process.Subject(frontdoor_types.FrontdoorMessage),
) -> process.Subject(agent_types.CognitiveMessage) {
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let subj: process.Subject(agent_types.CognitiveMessage) =
      process.new_subject()
    process.send(setup, subj)
    auto_reply_loop(subj, fd)
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

fn auto_reply_loop(
  subj: process.Subject(agent_types.CognitiveMessage),
  fd: process.Subject(frontdoor_types.FrontdoorMessage),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(subj)
  let msg = process.selector_receive_forever(selector)
  case msg {
    agent_types.UserInput(source_id:, text: _) -> {
      mock_publish(fd, source_id, "mock result")
    }
    agent_types.SchedulerInput(source_id:, ..) -> {
      mock_publish(fd, source_id, "mock result")
    }
    _ -> Nil
  }
  auto_reply_loop(subj, fd)
}

fn mock_publish(
  fd: process.Subject(frontdoor_types.FrontdoorMessage),
  source_id: String,
  response: String,
) -> Nil {
  // Generate a stand-in cycle_id, claim it, then publish — mirrors
  // how the real cognitive loop interacts with Frontdoor.
  let cycle_id = "mock-cycle-" <> source_id
  process.send(fd, frontdoor_types.ClaimCycle(cycle_id:, source_id:))
  process.send(
    fd,
    frontdoor_types.Publish(
      output: frontdoor_types.CognitiveReplyOutput(
        cycle_id:,
        response:,
        model: "mock",
        usage: None,
        tools_fired: [],
      ),
    ),
  )
}

// ---------------------------------------------------------------------------
// Start and get status
// ---------------------------------------------------------------------------

pub fn start_returns_subject_test() {
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
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
      fd,
      types.disabled_idle_config(),
    )

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  list.length(jobs) |> should.equal(1)
}

pub fn start_with_multiple_tasks_test() {
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
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
      fd,
      types.disabled_idle_config(),
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
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
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
      fd,
      types.disabled_idle_config(),
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
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  // initial_delay returns 0, so tick fires at 1ms
  let tasks = [make_task("auto-run", 600_000)]
  let assert Ok(sched) =
    runner.start(
      tasks,
      cognitive,
      cp,
      600_000,
      20,
      500_000,
      0,
      fd,
      types.disabled_idle_config(),
    )

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
// Idle-gate: defer recurring ticks while the operator is active
// ---------------------------------------------------------------------------

pub fn idle_gate_defers_when_user_active_test() {
  let cp = "/tmp/springdrift-test-sched-idle"
  clean_schedule_dir(cp)
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  // 100ms job interval — tick fires almost immediately. Idle window
  // is 5s — user activity within the last 5s blocks the fire. Max
  // defer is 10s so the test won't run forever even if a regression
  // disables the gate.
  let idle_cfg =
    types.IdleConfig(
      idle_window_ms: 5000,
      max_defer_ms: 10_000,
      retry_interval_ms: 100,
    )
  let tasks = [make_task("idle-gated", 100)]
  let assert Ok(sched) =
    runner.start(tasks, cognitive, cp, 600_000, 0, 0, 0, fd, idle_cfg)

  // Tell the scheduler the operator just typed. The job should NOT
  // fire while the idle window is in force.
  process.send(sched, types.UserInputObserved(at_ms: monotonic_now_ms_test()))

  // Wait 1s — short enough to stay inside the idle window. Job must
  // not have fired.
  process.sleep(1000)
  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  let assert Ok(job) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "idle-gated" })
  job.run_count |> should.equal(0)
}

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms_test() -> Int

// ---------------------------------------------------------------------------
// Unknown job names are silently ignored
// ---------------------------------------------------------------------------

pub fn unknown_job_complete_ignored_test() {
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
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
      fd,
      types.disabled_idle_config(),
    )

  process.send(
    sched,
    JobComplete(
      name: "ghost-job",
      result: "boo",
      tokens_used: 0,
      tools_fired: [],
    ),
  )
  process.sleep(100)

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  list.length(jobs) |> should.equal(1)
}

pub fn unknown_job_failed_ignored_test() {
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
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
      fd,
      types.disabled_idle_config(),
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
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      "/tmp/springdrift-test-sched10",
      600_000,
      20,
      500_000,
      0,
      fd,
      types.disabled_idle_config(),
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
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let tasks = [make_task("transitions", 600_000)]
  let assert Ok(sched) =
    runner.start(
      tasks,
      cognitive,
      cp,
      600_000,
      20,
      500_000,
      0,
      fd,
      types.disabled_idle_config(),
    )

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
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let tasks = [make_task("task-1", 600_000), make_task("task-2", 600_000)]
  let assert Ok(sched) =
    runner.start(
      tasks,
      cognitive,
      cp,
      600_000,
      20,
      500_000,
      0,
      fd,
      types.disabled_idle_config(),
    )

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
    required_tools: [],
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
    required_tools: [],
  )
}

pub fn complete_job_refuses_recurring_test() {
  let cp = "/tmp/springdrift-test-sched-refuse"
  clean_schedule_dir(cp)
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      cp,
      600_000,
      0,
      0,
      0,
      fd,
      types.disabled_idle_config(),
    )

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
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      cp,
      600_000,
      0,
      0,
      0,
      fd,
      types.disabled_idle_config(),
    )

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
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      cp,
      600_000,
      0,
      0,
      0,
      fd,
      types.disabled_idle_config(),
    )

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

  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      cp,
      600_000,
      0,
      0,
      0,
      fd,
      types.disabled_idle_config(),
    )

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

  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      cp,
      600_000,
      0,
      0,
      0,
      fd,
      types.disabled_idle_config(),
    )

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

  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      cp,
      600_000,
      0,
      0,
      0,
      fd,
      types.disabled_idle_config(),
    )
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
      required_tools: [],
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

  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      cp,
      600_000,
      0,
      0,
      0,
      fd,
      types.disabled_idle_config(),
    )

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

// ---------------------------------------------------------------------------
// Phase 3b required_tools enforcement — scheduled jobs that declare
// required tools are marked JobFailed when those tools did not fire in
// the completing cycle. Turns narrated success into visible failure on
// the scheduler tab.
// ---------------------------------------------------------------------------

pub fn complete_job_with_missing_required_tool_routes_to_failed_test() {
  let cp = "/tmp/springdrift-test-sched-required-missing"
  clean_schedule_dir(cp)
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      cp,
      600_000,
      0,
      0,
      0,
      fd,
      types.disabled_idle_config(),
    )

  // Add a job that requires analyze_affect_performance.
  let add_reply = process.new_subject()
  let job =
    ScheduledJob(..make_recurring_job("needs-analysis"), required_tools: [
      "analyze_affect_performance",
    ])
  process.send(sched, AddJob(job:, reply_to: add_reply))
  let assert Ok(Ok(_)) = process.receive(add_reply, 5000)

  // Simulate a JobComplete where only adjacent tools fired — the
  // required tool is missing. The runner must reroute to JobFailed
  // rather than marking success.
  process.send(
    sched,
    JobComplete(
      name: "needs-analysis",
      result: "I analysed the data...",
      tokens_used: 0,
      tools_fired: ["reflect", "list_affect_history"],
    ),
  )
  process.sleep(200)

  // Verify the job status reflects the failure, not success. The run
  // count should remain at zero since JobFailed does not increment it.
  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  let assert Ok(job2) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "needs-analysis" })
  { job2.error_count >= 1 } |> should.be_true

  process.send(sched, StopAll)
  process.sleep(50)
}

pub fn complete_job_with_required_tools_fired_succeeds_test() {
  let cp = "/tmp/springdrift-test-sched-required-ok"
  clean_schedule_dir(cp)
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      cp,
      600_000,
      0,
      0,
      0,
      fd,
      types.disabled_idle_config(),
    )

  let add_reply = process.new_subject()
  let job =
    ScheduledJob(..make_recurring_job("all-present"), required_tools: [
      "analyze_affect_performance",
    ])
  process.send(sched, AddJob(job:, reply_to: add_reply))
  let assert Ok(Ok(_)) = process.receive(add_reply, 5000)

  // Required tool is in tools_fired — normal completion.
  process.send(
    sched,
    JobComplete(
      name: "all-present",
      result: "analysis complete",
      tokens_used: 0,
      tools_fired: ["analyze_affect_performance", "memory_write"],
    ),
  )
  process.sleep(200)

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  let assert Ok(job2) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "all-present" })
  job2.run_count |> should.equal(1)
  job2.error_count |> should.equal(0)

  process.send(sched, StopAll)
  process.sleep(50)
}

pub fn complete_job_with_empty_required_tools_skips_check_test() {
  let cp = "/tmp/springdrift-test-sched-required-none"
  clean_schedule_dir(cp)
  let fd = frontdoor.start()
  let cognitive = auto_reply_cognitive(fd)
  let assert Ok(sched) =
    runner.start(
      [],
      cognitive,
      cp,
      600_000,
      0,
      0,
      0,
      fd,
      types.disabled_idle_config(),
    )

  // Default required_tools is []; the check is disabled.
  let add_reply = process.new_subject()
  let job = make_recurring_job("no-required")
  process.send(sched, AddJob(job:, reply_to: add_reply))
  let assert Ok(Ok(_)) = process.receive(add_reply, 5000)

  // Complete with an empty tools_fired list — still OK because the job
  // declared no required tools.
  process.send(
    sched,
    JobComplete(
      name: "no-required",
      result: "done",
      tokens_used: 0,
      tools_fired: [],
    ),
  )
  process.sleep(200)

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  let assert Ok(job2) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "no-required" })
  job2.run_count |> should.equal(1)

  process.send(sched, StopAll)
  process.sleep(50)
}
