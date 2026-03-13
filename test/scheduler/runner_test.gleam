import agent/types as agent_types
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import profile/types as profile_types
import scheduler/runner
import scheduler/types.{
  type ScheduledJob, Completed, GetStatus, JobComplete, JobFailed, Running,
  StopAll,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_task(name: String, interval_ms: Int) -> profile_types.ScheduleTaskConfig {
  profile_types.ScheduleTaskConfig(
    name:,
    query: "test query for " <> name,
    interval_ms:,
    start_at: None,
    delivery: profile_types.FileDelivery(
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
    runner.start(tasks, cognitive, "/tmp/springdrift-test-no-cp.json")

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  list.length(jobs) |> should.equal(1)
}

pub fn start_with_multiple_tasks_test() {
  let cognitive = auto_reply_cognitive()
  let tasks = [make_task("alpha", 600_000), make_task("beta", 600_000)]
  let assert Ok(sched) =
    runner.start(tasks, cognitive, "/tmp/springdrift-test-no-cp2.json")

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
    runner.start(tasks, cognitive, "/tmp/springdrift-test-no-cp3.json")

  process.send(sched, StopAll)
  process.sleep(100)
}

// ---------------------------------------------------------------------------
// Full flow: tick fires → job runs → auto-reply → Completed
// ---------------------------------------------------------------------------

pub fn auto_execution_completes_job_test() {
  let cognitive = auto_reply_cognitive()
  // initial_delay returns 0, so tick fires at 1ms
  let tasks = [make_task("auto-run", 600_000)]
  let assert Ok(sched) =
    runner.start(tasks, cognitive, "/tmp/springdrift-test-no-cp-auto.json")

  // Wait for the full flow: tick → spawn_job → UserInput → reply → JobComplete
  process.sleep(2000)

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  let assert Ok(job) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "auto-run" })
  job.status |> should.equal(Completed)
  // At least one run; timing may allow a second tick
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
    runner.start(tasks, cognitive, "/tmp/springdrift-test-no-cp7.json")

  process.send(sched, JobComplete(name: "ghost-job", result: "boo"))
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
    runner.start(tasks, cognitive, "/tmp/springdrift-test-no-cp8.json")

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
    runner.start([], cognitive, "/tmp/springdrift-test-no-cp10.json")

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  list.length(jobs) |> should.equal(0)
}

// ---------------------------------------------------------------------------
// Job transitions through Running to Completed
// ---------------------------------------------------------------------------

pub fn job_transitions_through_running_test() {
  let cognitive = auto_reply_cognitive()
  let tasks = [make_task("transitions", 600_000)]
  let assert Ok(sched) =
    runner.start(tasks, cognitive, "/tmp/springdrift-test-no-cp-trans.json")

  // Query very quickly — tick has fired (1ms) so status should be Running or later
  process.sleep(50)
  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)
  let assert Ok(job) =
    list.find(jobs, fn(j: ScheduledJob) { j.name == "transitions" })
  // Job should be Running or already Completed (timing-dependent)
  case job.status {
    Running -> Nil
    Completed -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Multiple auto-executed tasks all complete
// ---------------------------------------------------------------------------

pub fn multiple_tasks_all_complete_test() {
  let cognitive = auto_reply_cognitive()
  let tasks = [
    make_task("task-1", 600_000),
    make_task("task-2", 600_000),
  ]
  let assert Ok(sched) =
    runner.start(tasks, cognitive, "/tmp/springdrift-test-no-cp-multi.json")

  // Wait for both to complete
  process.sleep(2000)

  let status_subj = process.new_subject()
  process.send(sched, GetStatus(reply_to: status_subj))
  let assert Ok(jobs) = process.receive(status_subj, 5000)

  let completed_count =
    list.count(jobs, fn(j: ScheduledJob) { j.status == Completed })
  completed_count |> should.equal(2)
}
