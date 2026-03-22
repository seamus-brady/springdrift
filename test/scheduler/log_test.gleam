import gleam/list
import gleam/option.{None}
import gleeunit/should
import scheduler/log as schedule_log
import scheduler/types.{
  type ScheduledJob, AgentJob, Appointment, Cancelled, Completed, ForAgent,
  ForUser, Pending, ProfileJob, RecurringTask, Reminder, ScheduledJob, Todo,
}
import simplifile

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir() -> String {
  "/tmp/springdrift-test-schedule-log-" <> unique_id()
}

@external(erlang, "springdrift_ffi", "generate_uuid")
fn unique_id() -> String

fn make_job(name: String, kind: types.JobKind) -> ScheduledJob {
  ScheduledJob(
    name:,
    query: "test query",
    interval_ms: 0,
    delivery: types.FileDelivery(
      directory: ".springdrift/scheduler/outputs",
      format: "markdown",
    ),
    only_if_changed: False,
    status: Pending,
    last_run_ms: None,
    last_result: None,
    run_count: 0,
    error_count: 0,
    job_source: AgentJob,
    kind:,
    due_at: None,
    for_: ForUser,
    title: name,
    body: "test body",
    duration_minutes: 0,
    tags: [],
    created_at: "2026-03-17T10:00:00",
    fired_count: 0,
    recurrence_end_at: None,
    max_occurrences: None,
  )
}

fn cleanup(dir: String) -> Nil {
  let _ = simplifile.delete_all([dir])
  Nil
}

// ---------------------------------------------------------------------------
// append + load_all roundtrip
// ---------------------------------------------------------------------------

pub fn append_and_load_all_roundtrip_test() {
  let dir = test_dir()
  let job = make_job("test-reminder", Reminder)
  schedule_log.append(dir, job, types.Create)

  let ops = schedule_log.load_all(dir)
  list.length(ops) |> should.equal(1)
  let assert [#(loaded_job, op)] = ops
  loaded_job.name |> should.equal("test-reminder")
  op |> should.equal(types.Create)

  cleanup(dir)
}

// ---------------------------------------------------------------------------
// resolve_current with Create
// ---------------------------------------------------------------------------

pub fn resolve_current_create_test() {
  let dir = test_dir()
  let job = make_job("my-todo", Todo)
  schedule_log.append(dir, job, types.Create)

  let resolved = schedule_log.resolve_current(dir)
  list.length(resolved) |> should.equal(1)
  let assert [r] = resolved
  r.name |> should.equal("my-todo")
  r.status |> should.equal(Pending)

  cleanup(dir)
}

// ---------------------------------------------------------------------------
// resolve_current with Complete
// ---------------------------------------------------------------------------

pub fn resolve_current_complete_test() {
  let dir = test_dir()
  let job = make_job("complete-me", Reminder)
  schedule_log.append(dir, job, types.Create)
  schedule_log.append(dir, job, types.Complete)

  let resolved = schedule_log.resolve_current(dir)
  let assert [r] = resolved
  r.status |> should.equal(Completed)

  cleanup(dir)
}

// ---------------------------------------------------------------------------
// resolve_current with Cancel
// ---------------------------------------------------------------------------

pub fn resolve_current_cancel_test() {
  let dir = test_dir()
  let job = make_job("cancel-me", Reminder)
  schedule_log.append(dir, job, types.Create)
  schedule_log.append(dir, job, types.Cancel)

  let resolved = schedule_log.resolve_current(dir)
  let assert [r] = resolved
  r.status |> should.equal(Cancelled)

  cleanup(dir)
}

// ---------------------------------------------------------------------------
// resolve_current with Fire (one-shot)
// ---------------------------------------------------------------------------

pub fn resolve_current_fire_one_shot_test() {
  let dir = test_dir()
  let job = make_job("fire-once", Reminder)
  schedule_log.append(dir, job, types.Create)
  schedule_log.append(dir, job, types.Fire)

  let resolved = schedule_log.resolve_current(dir)
  let assert [r] = resolved
  // One-shot (interval_ms=0) → Completed after fire
  r.status |> should.equal(Completed)
  r.fired_count |> should.equal(1)

  cleanup(dir)
}

// ---------------------------------------------------------------------------
// resolve_current with Fire (recurring)
// ---------------------------------------------------------------------------

pub fn resolve_current_fire_recurring_test() {
  let dir = test_dir()
  let job =
    ScheduledJob(..make_job("fire-recurring", Reminder), interval_ms: 3_600_000)
  schedule_log.append(dir, job, types.Create)
  schedule_log.append(dir, job, types.Fire)

  let resolved = schedule_log.resolve_current(dir)
  let assert [r] = resolved
  // Recurring → back to Pending after fire
  r.status |> should.equal(Pending)
  r.fired_count |> should.equal(1)

  cleanup(dir)
}

// ---------------------------------------------------------------------------
// resolve_current with Update
// ---------------------------------------------------------------------------

pub fn resolve_current_update_test() {
  let dir = test_dir()
  let job = make_job("update-me", Todo)
  schedule_log.append(dir, job, types.Create)
  let updated = ScheduledJob(..job, title: "Updated Title", body: "New body")
  schedule_log.append(dir, updated, types.Update)

  let resolved = schedule_log.resolve_current(dir)
  let assert [r] = resolved
  r.title |> should.equal("Updated Title")
  r.body |> should.equal("New body")

  cleanup(dir)
}

// ---------------------------------------------------------------------------
// Multiple jobs
// ---------------------------------------------------------------------------

pub fn resolve_current_multiple_jobs_test() {
  let dir = test_dir()
  schedule_log.append(dir, make_job("job-a", Reminder), types.Create)
  schedule_log.append(dir, make_job("job-b", Todo), types.Create)
  schedule_log.append(dir, make_job("job-c", Appointment), types.Create)

  let resolved = schedule_log.resolve_current(dir)
  list.length(resolved) |> should.equal(3)

  cleanup(dir)
}

// ---------------------------------------------------------------------------
// Corrupt line skipping
// ---------------------------------------------------------------------------

pub fn corrupt_line_skipped_test() {
  let dir = test_dir()
  let _ = simplifile.create_directory_all(dir)

  // Write a valid line, a corrupt line, and another valid line
  let job1 = make_job("good-1", Reminder)
  schedule_log.append(dir, job1, types.Create)

  // Inject a corrupt line directly
  let assert Ok(files) = simplifile.read_directory(dir)
  let assert [filename] =
    list.filter(files, fn(f) {
      case f {
        _ -> True
      }
    })
  let path = dir <> "/" <> filename
  let _ = simplifile.append(path, "THIS IS NOT JSON\n")

  let job2 = make_job("good-2", Todo)
  schedule_log.append(dir, job2, types.Create)

  let ops = schedule_log.load_all(dir)
  // Should have 2 valid entries, corrupt line skipped
  list.length(ops) |> should.equal(2)

  cleanup(dir)
}

// ---------------------------------------------------------------------------
// Empty directory
// ---------------------------------------------------------------------------

pub fn empty_directory_test() {
  let dir = test_dir()
  let resolved = schedule_log.resolve_current(dir)
  list.length(resolved) |> should.equal(0)
}

// ---------------------------------------------------------------------------
// op_to_string roundtrip
// ---------------------------------------------------------------------------

pub fn op_to_string_test() {
  schedule_log.op_to_string(types.Create) |> should.equal("create")
  schedule_log.op_to_string(types.Complete) |> should.equal("complete")
  schedule_log.op_to_string(types.Cancel) |> should.equal("cancel")
  schedule_log.op_to_string(types.Fire) |> should.equal("fire")
  schedule_log.op_to_string(types.Update) |> should.equal("update")
}

// ---------------------------------------------------------------------------
// Profile job with RecurringTask kind
// ---------------------------------------------------------------------------

pub fn profile_recurring_task_test() {
  let dir = test_dir()
  let job =
    ScheduledJob(
      ..make_job("daily-check", RecurringTask),
      job_source: ProfileJob,
      interval_ms: 86_400_000,
      for_: ForAgent,
    )
  schedule_log.append(dir, job, types.Create)

  let resolved = schedule_log.resolve_current(dir)
  let assert [r] = resolved
  r.kind |> should.equal(RecurringTask)
  r.job_source |> should.equal(ProfileJob)

  cleanup(dir)
}

// ---------------------------------------------------------------------------
// Tags preserved
// ---------------------------------------------------------------------------

pub fn tags_preserved_test() {
  let dir = test_dir()
  let job =
    ScheduledJob(..make_job("tagged", Reminder), tags: ["work", "urgent"])
  schedule_log.append(dir, job, types.Create)

  let resolved = schedule_log.resolve_current(dir)
  let assert [r] = resolved
  r.tags |> should.equal(["work", "urgent"])

  cleanup(dir)
}

// ---------------------------------------------------------------------------
// Migrate checkpoint (integration — only tests no-op when no checkpoint)
// ---------------------------------------------------------------------------

pub fn migrate_no_checkpoint_noop_test() {
  let dir = test_dir()
  // Should not crash when checkpoint doesn't exist
  schedule_log.migrate_checkpoint(dir, "/tmp/nonexistent-checkpoint.json")
  let resolved = schedule_log.resolve_current(dir)
  list.length(resolved) |> should.equal(0)
}
