import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import profile/types as profile_types
import scheduler/persist
import scheduler/types.{
  type ScheduledJob, Completed, ForAgent, Pending, ProfileJob, RecurringTask,
  ScheduledJob,
}
import simplifile

fn test_job(name: String) -> ScheduledJob {
  ScheduledJob(
    name:,
    query: "test query for " <> name,
    interval_ms: 3_600_000,
    delivery: profile_types.FileDelivery(
      directory: ".springdrift/scheduler/outputs",
      format: "markdown",
    ),
    only_if_changed: False,
    status: Pending,
    last_run_ms: None,
    last_result: None,
    run_count: 0,
    error_count: 0,
    job_source: ProfileJob,
    kind: RecurringTask,
    due_at: None,
    for_: ForAgent,
    title: name,
    body: "",
    duration_minutes: 0,
    tags: [],
    created_at: "",
    fired_count: 0,
    recurrence_end_at: None,
    max_occurrences: None,
  )
}

pub fn save_and_load_roundtrip_test() {
  let path = "/tmp/springdrift_test_checkpoint.json"
  let _ = simplifile.delete(path)
  let jobs = [
    ScheduledJob(..test_job("job-a"), status: Completed, run_count: 3),
    ScheduledJob(..test_job("job-b"), status: Pending),
  ]
  let assert Ok(_) = persist.save(path, jobs)
  let assert Ok(checkpoint) = persist.load(path)
  list.length(checkpoint.jobs) |> should.equal(2)
  let assert Ok(first) = list.first(checkpoint.jobs)
  first.name |> should.equal("job-a")
  first.run_count |> should.equal(3)
  let _ = simplifile.delete(path)
  Nil
}

pub fn save_atomic_creates_file_test() {
  let path = "/tmp/springdrift_test_atomic.json"
  let _ = simplifile.delete(path)
  let assert Ok(_) = persist.save(path, [test_job("atomic")])
  let assert Ok(True) = simplifile.is_file(path)
  let _ = simplifile.delete(path)
  Nil
}

pub fn load_missing_file_errors_test() {
  let result = persist.load("/tmp/springdrift_nonexistent_checkpoint.json")
  result |> should.be_error
}

pub fn load_invalid_json_errors_test() {
  let path = "/tmp/springdrift_test_bad_checkpoint.json"
  let _ = simplifile.write(path, "not json {{{")
  let result = persist.load(path)
  result |> should.be_error
  let _ = simplifile.delete(path)
  Nil
}

pub fn reconcile_keeps_matching_jobs_test() {
  let jobs = [
    test_job("keep-me"),
    test_job("remove-me"),
    test_job("also-keep"),
  ]
  let config_names = ["keep-me", "also-keep"]
  let result = persist.reconcile(jobs, config_names)
  list.length(result) |> should.equal(2)
  let names = list.map(result, fn(j) { j.name })
  should.be_true(list.contains(names, "keep-me"))
  should.be_true(list.contains(names, "also-keep"))
  should.be_false(list.contains(names, "remove-me"))
}

pub fn reconcile_empty_config_removes_all_test() {
  let jobs = [test_job("job-1"), test_job("job-2")]
  let result = persist.reconcile(jobs, [])
  result |> should.equal([])
}

pub fn save_preserves_last_result_test() {
  let path = "/tmp/springdrift_test_last_result.json"
  let _ = simplifile.delete(path)
  let jobs = [
    ScheduledJob(
      ..test_job("with-result"),
      last_result: Some("Previous output text"),
      last_run_ms: Some(1_000_000),
    ),
  ]
  let assert Ok(_) = persist.save(path, jobs)
  let assert Ok(checkpoint) = persist.load(path)
  let assert Ok(job) = list.first(checkpoint.jobs)
  job.last_run_ms |> should.equal(Some(1_000_000))
  job.last_result |> should.equal(Some("Previous output text"))
  let _ = simplifile.delete(path)
  Nil
}

pub fn save_preserves_error_count_test() {
  let path = "/tmp/springdrift_test_errors.json"
  let _ = simplifile.delete(path)
  let jobs = [ScheduledJob(..test_job("errored"), error_count: 5)]
  let assert Ok(_) = persist.save(path, jobs)
  let assert Ok(checkpoint) = persist.load(path)
  let assert Ok(job) = list.first(checkpoint.jobs)
  job.error_count |> should.equal(5)
  let _ = simplifile.delete(path)
  Nil
}
