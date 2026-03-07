//// Scheduler checkpoint persistence — atomic writes for job state survival.
////
//// Uses tmp + rename for atomic file writes. Stores job history and state
//// in a JSON checkpoint file for restart reconciliation.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import profile/types as profile_types
import scheduler/types.{
  type JobStatus, type ScheduledJob, Completed, Failed, Pending, Running,
  ScheduledJob,
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

fn encode_job(job: ScheduledJob) -> json.Json {
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
  ])
}

fn status_to_string(status: JobStatus) -> String {
  case status {
    Pending -> "pending"
    Running -> "running"
    Completed -> "completed"
    Failed(reason:) -> "failed:" <> reason
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

fn job_decoder() -> decode.Decoder(ScheduledJob) {
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
  let status = parse_status(status_str)
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
  ))
}

fn parse_status(s: String) -> JobStatus {
  case s {
    "pending" -> Pending
    "running" -> Pending
    "completed" -> Completed
    _ ->
      case has_prefix(s, "failed:") {
        True -> Failed(reason: drop_prefix(s, "failed:"))
        False -> Pending
      }
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

fn default_delivery() -> profile_types.DeliveryConfig {
  profile_types.FileDelivery(directory: "./reports", format: "markdown")
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
