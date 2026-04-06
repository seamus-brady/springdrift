//// Scheduler checkpoint persistence — atomic writes for job state survival.
////
//// Uses tmp + rename for atomic file writes. Stores job history and state
//// in a JSON checkpoint file for restart reconciliation.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import paths
import scheduler/types.{
  type JobStatus, type ScheduledJob, AgentJob, Appointment, Cancelled, Completed,
  Failed, ForAgent, ForUser, Pending, ProfileJob, RecurringTask, Reminder,
  Running, ScheduledJob, Todo,
}
import simplifile
import slog

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

// ---------------------------------------------------------------------------
// Checkpoint types
// ---------------------------------------------------------------------------

pub type Checkpoint {
  Checkpoint(jobs: List(ScheduledJob), saved_at: String)
}

// ---------------------------------------------------------------------------
// Save — atomic write via tmp + rename
// ---------------------------------------------------------------------------

/// Save scheduler state to a checkpoint file atomically.
pub fn save(path: String, jobs: List(ScheduledJob)) -> Result(Nil, String) {
  let checkpoint_json = encode_checkpoint(jobs)
  let tmp_path = path <> ".tmp." <> generate_uuid()
  case simplifile.write(tmp_path, checkpoint_json) {
    Error(_) -> {
      let _ = simplifile.delete(tmp_path)
      Error("Could not write checkpoint tmp file")
    }
    Ok(_) ->
      case rename(tmp_path, path) {
        Ok(_) -> {
          slog.debug(
            "scheduler/persist",
            "save",
            "Checkpoint saved to " <> path,
            None,
          )
          Ok(Nil)
        }
        Error(_) -> {
          let _ = simplifile.delete(tmp_path)
          Error("Could not rename checkpoint file")
        }
      }
  }
}

/// Load scheduler state from a checkpoint file.
pub fn load(path: String) -> Result(Checkpoint, String) {
  case simplifile.read(path) {
    Error(_) -> Error("Checkpoint file not found: " <> path)
    Ok(contents) ->
      case json.parse(contents, checkpoint_decoder()) {
        Ok(checkpoint) -> {
          slog.info(
            "scheduler/persist",
            "load",
            "Loaded checkpoint with "
              <> int_to_string(list.length(checkpoint.jobs))
              <> " jobs",
            None,
          )
          Ok(checkpoint)
        }
        Error(_) -> Error("Could not parse checkpoint file")
      }
  }
}

// ---------------------------------------------------------------------------
// Reconciliation — merge checkpoint state with current config
// ---------------------------------------------------------------------------

/// Reconcile loaded checkpoint state with current task configs.
/// Jobs in the checkpoint that match current config are restored.
/// New jobs from config get fresh state. Removed jobs are dropped.
pub fn reconcile(
  checkpoint_jobs: List(ScheduledJob),
  config_names: List(String),
) -> List(ScheduledJob) {
  list.filter(checkpoint_jobs, fn(job) { list.contains(config_names, job.name) })
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

fn encode_checkpoint(jobs: List(ScheduledJob)) -> String {
  json.to_string(
    json.object([
      #("saved_at", json.string(get_datetime())),
      #("jobs", json.array(jobs, encode_job)),
    ]),
  )
}

pub fn encode_job(job: ScheduledJob) -> json.Json {
  json.object([
    #("name", json.string(job.name)),
    #("query", json.string(job.query)),
    #("interval_ms", json.int(job.interval_ms)),
    #("status", json.string(status_to_string(job.status))),
    #("last_run_ms", case job.last_run_ms {
      Some(ms) -> json.int(ms)
      None -> json.null()
    }),
    #("last_result", case job.last_result {
      Some(r) -> json.string(r)
      None -> json.null()
    }),
    #("run_count", json.int(job.run_count)),
    #("error_count", json.int(job.error_count)),
    #("job_source", json.string(job_source_to_string(job.job_source))),
    #("kind", json.string(kind_to_string(job.kind))),
    #("due_at", case job.due_at {
      Some(d) -> json.string(d)
      None -> json.null()
    }),
    #("for_", json.string(for_target_to_string(job.for_))),
    #("title", json.string(job.title)),
    #("body", json.string(job.body)),
    #("duration_minutes", json.int(job.duration_minutes)),
    #("tags", json.array(job.tags, json.string)),
    #("created_at", json.string(job.created_at)),
    #("fired_count", json.int(job.fired_count)),
    #("recurrence_end_at", case job.recurrence_end_at {
      Some(d) -> json.string(d)
      None -> json.null()
    }),
    #("max_occurrences", case job.max_occurrences {
      Some(n) -> json.int(n)
      None -> json.null()
    }),
  ])
}

pub fn status_to_string(status: JobStatus) -> String {
  case status {
    Pending -> "pending"
    Running -> "running"
    Completed -> "completed"
    Cancelled -> "cancelled"
    Failed(reason:) -> "failed:" <> reason
  }
}

fn job_source_to_string(source: types.JobSource) -> String {
  case source {
    ProfileJob -> "profile"
    AgentJob -> "agent"
  }
}

pub fn kind_to_string(kind: types.JobKind) -> String {
  case kind {
    RecurringTask -> "recurring_task"
    Reminder -> "reminder"
    Todo -> "todo"
    Appointment -> "appointment"
  }
}

fn for_target_to_string(target: types.ForTarget) -> String {
  case target {
    ForAgent -> "agent"
    ForUser -> "user"
  }
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

fn checkpoint_decoder() -> decode.Decoder(Checkpoint) {
  use saved_at <- decode.optional_field("saved_at", "", decode.string)
  use jobs <- decode.field("jobs", decode.list(job_decoder()))
  decode.success(Checkpoint(jobs:, saved_at:))
}

pub fn job_decoder() -> decode.Decoder(ScheduledJob) {
  use name <- decode.field("name", decode.string)
  use query <- decode.optional_field("query", "", decode.string)
  use interval_ms <- decode.optional_field(
    "interval_ms",
    86_400_000,
    decode.int,
  )
  use status_str <- decode.optional_field("status", "pending", decode.string)
  use last_run_ms <- decode.optional_field(
    "last_run_ms",
    None,
    decode.optional(decode.int),
  )
  use last_result <- decode.optional_field(
    "last_result",
    None,
    decode.optional(decode.string),
  )
  use run_count <- decode.optional_field("run_count", 0, decode.int)
  use error_count <- decode.optional_field("error_count", 0, decode.int)
  use job_source_str <- decode.optional_field(
    "job_source",
    "profile",
    decode.string,
  )
  use kind_str <- decode.optional_field("kind", "recurring_task", decode.string)
  use due_at <- decode.optional_field(
    "due_at",
    None,
    decode.optional(decode.string),
  )
  use for_str <- decode.optional_field("for_", "agent", decode.string)
  use title <- decode.optional_field("title", "", decode.string)
  use body <- decode.optional_field("body", "", decode.string)
  use duration_minutes <- decode.optional_field(
    "duration_minutes",
    0,
    decode.int,
  )
  use tags <- decode.optional_field("tags", [], decode.list(decode.string))
  use created_at <- decode.optional_field("created_at", "", decode.string)
  use fired_count <- decode.optional_field("fired_count", 0, decode.int)
  use recurrence_end_at <- decode.optional_field(
    "recurrence_end_at",
    None,
    decode.optional(decode.string),
  )
  use max_occurrences <- decode.optional_field(
    "max_occurrences",
    None,
    decode.optional(decode.int),
  )
  let status = parse_status(status_str)
  let job_source = parse_job_source(job_source_str)
  let kind = parse_kind(kind_str)
  let for_ = parse_for_target(for_str)
  let effective_title = case title {
    "" -> name
    t -> t
  }
  decode.success(ScheduledJob(
    name:,
    query:,
    interval_ms:,
    delivery: default_delivery(),
    only_if_changed: False,
    status:,
    last_run_ms:,
    last_result:,
    run_count:,
    error_count:,
    job_source:,
    kind:,
    due_at:,
    for_:,
    title: effective_title,
    body:,
    duration_minutes:,
    tags:,
    created_at:,
    fired_count:,
    recurrence_end_at:,
    max_occurrences:,
  ))
}

fn parse_status(s: String) -> JobStatus {
  case s {
    "pending" -> Pending
    "running" -> Pending
    "completed" -> Completed
    "cancelled" -> Cancelled
    _ ->
      case has_prefix(s, "failed:") {
        True -> Failed(reason: drop_prefix(s, "failed:"))
        False -> Pending
      }
  }
}

fn parse_job_source(s: String) -> types.JobSource {
  case s {
    "agent" -> AgentJob
    _ -> ProfileJob
  }
}

pub fn parse_kind(s: String) -> types.JobKind {
  case s {
    "reminder" -> Reminder
    "todo" -> Todo
    "appointment" -> Appointment
    _ -> RecurringTask
  }
}

pub fn parse_for_target(s: String) -> types.ForTarget {
  case s {
    "user" -> ForUser
    _ -> ForAgent
  }
}

fn has_prefix(s: String, prefix: String) -> Bool {
  string.starts_with(s, prefix)
}

fn drop_prefix(s: String, prefix: String) -> String {
  string.drop_start(s, string.length(prefix))
}

fn int_to_string(n: Int) -> String {
  int.to_string(n)
}

fn default_delivery() -> types.DeliveryConfig {
  types.FileDelivery(
    directory: paths.scheduler_outputs_dir(),
    format: "markdown",
  )
}

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

/// Rename a file atomically (wrapper around Erlang file:rename).
fn rename(from: String, to: String) -> Result(Nil, Nil) {
  case do_rename(from, to) {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

@external(erlang, "springdrift_ffi", "file_rename")
fn do_rename(from: String, to: String) -> Bool
