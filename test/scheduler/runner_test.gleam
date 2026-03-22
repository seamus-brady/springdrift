import agent/types as agent_types
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import scheduler/runner
import scheduler/types.{
  type ScheduledJob, GetStatus, JobComplete, JobFailed, Running, StopAll,
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
    runner.start(tasks, cognitive, cp, 600_000, 20, 500_000)

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
    runner.start(tasks, cognitive, cp, 600_000, 20, 500_000)

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
    runner.start(tasks, cognitive, cp, 600_000, 20, 500_000)

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
