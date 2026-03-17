//// Append-only scheduler log — JSON-L files in .springdrift/memory/schedule/.
////
//// Each day gets its own file (YYYY-MM-DD-schedule.jsonl). Operations are
//// encoded as self-contained JSON objects, one per line. Follows the same
//// pattern as cbr/log.gleam and facts/log.gleam.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import scheduler/persist
import scheduler/types.{
  type ScheduleOp, type ScheduledJob, Cancel, Cancelled, Complete, Completed,
  Create, Fire, Pending, ScheduledJob, Update,
}
import simplifile
import slog

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms() -> Int

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

/// Append a schedule operation to today's log file.
pub fn append(dir: String, job: ScheduledJob, op: ScheduleOp) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> "-schedule.jsonl"
  let json_str = json.to_string(encode_record(job, op))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug(
        "scheduler/log",
        "append",
        "Appended " <> op_to_string(op) <> " for " <> job.name,
        Some(job.name),
      )
    Error(e) ->
      slog.log_error(
        "scheduler/log",
        "append",
        "Failed to append: " <> simplifile.describe_error(e),
        Some(job.name),
      )
  }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// Load all operations from all date files in the directory.
pub fn load_all(dir: String) -> List(#(ScheduledJob, ScheduleOp)) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      files
      |> list.filter(fn(f) { string.ends_with(f, "-schedule.jsonl") })
      |> list.sort(string.compare)
      |> list.flat_map(fn(f) {
        let path = dir <> "/" <> f
        case simplifile.read(path) {
          Error(_) -> []
          Ok(content) -> parse_jsonl(content)
        }
      })
    }
  }
}

/// Replay all operations to derive current live state per job name.
pub fn resolve_current(dir: String) -> List(ScheduledJob) {
  let ops = load_all(dir)
  let state =
    list.fold(ops, dict.new(), fn(acc, entry) {
      let #(job, op) = entry
      case op {
        Create -> dict.insert(acc, job.name, job)
        Update -> {
          case dict.get(acc, job.name) {
            Error(_) -> dict.insert(acc, job.name, job)
            Ok(existing) -> {
              let merged =
                ScheduledJob(
                  ..existing,
                  title: case job.title != "" {
                    True -> job.title
                    False -> existing.title
                  },
                  body: case job.body != "" {
                    True -> job.body
                    False -> existing.body
                  },
                  due_at: case job.due_at {
                    Some(_) -> job.due_at
                    None -> existing.due_at
                  },
                  tags: case job.tags {
                    [] -> existing.tags
                    t -> t
                  },
                )
              dict.insert(acc, job.name, merged)
            }
          }
        }
        Complete -> {
          case dict.get(acc, job.name) {
            Error(_) -> acc
            Ok(existing) ->
              dict.insert(
                acc,
                job.name,
                ScheduledJob(..existing, status: Completed),
              )
          }
        }
        Cancel -> {
          case dict.get(acc, job.name) {
            Error(_) -> acc
            Ok(existing) ->
              dict.insert(
                acc,
                job.name,
                ScheduledJob(..existing, status: Cancelled),
              )
          }
        }
        Fire -> {
          case dict.get(acc, job.name) {
            Error(_) -> acc
            Ok(existing) -> {
              let now = monotonic_now_ms()
              let updated =
                ScheduledJob(
                  ..existing,
                  fired_count: existing.fired_count + 1,
                  last_run_ms: Some(now),
                  status: case existing.interval_ms > 0 {
                    True -> Pending
                    False -> Completed
                  },
                )
              dict.insert(acc, job.name, updated)
            }
          }
        }
      }
    })
  dict.values(state)
}

// ---------------------------------------------------------------------------
// Migration from checkpoint
// ---------------------------------------------------------------------------

/// Migrate old checkpoint JSON to JSONL format.
/// Reads old checkpoint, writes Create ops to JSONL, deletes checkpoint.
pub fn migrate_checkpoint(schedule_dir: String, checkpoint_path: String) -> Nil {
  case simplifile.is_file(checkpoint_path) {
    Ok(True) -> {
      case persist.load(checkpoint_path) {
        Ok(checkpoint) -> {
          list.each(checkpoint.jobs, fn(job) {
            append(schedule_dir, job, Create)
          })
          let _ = simplifile.delete(checkpoint_path)
          slog.info(
            "scheduler/log",
            "migrate_checkpoint",
            "Migrated checkpoint to JSONL",
            None,
          )
        }
        Error(_) -> {
          slog.warn(
            "scheduler/log",
            "migrate_checkpoint",
            "Could not parse checkpoint for migration",
            None,
          )
        }
      }
    }
    _ -> Nil
  }
}

// ---------------------------------------------------------------------------
// JSON encoding
// ---------------------------------------------------------------------------

fn encode_record(job: ScheduledJob, op: ScheduleOp) -> json.Json {
  json.object([
    #("operation", json.string(op_to_string(op))),
    #("timestamp", json.string(get_datetime())),
    #("job", persist.encode_job(job)),
  ])
}

pub fn op_to_string(op: ScheduleOp) -> String {
  case op {
    Create -> "create"
    Complete -> "complete"
    Cancel -> "cancel"
    Fire -> "fire"
    Update -> "update"
  }
}

fn parse_op(s: String) -> ScheduleOp {
  case s {
    "create" -> Create
    "complete" -> Complete
    "cancel" -> Cancel
    "fire" -> Fire
    "update" -> Update
    _ -> Create
  }
}

// ---------------------------------------------------------------------------
// JSON decoding
// ---------------------------------------------------------------------------

fn record_decoder() -> decode.Decoder(#(ScheduledJob, ScheduleOp)) {
  use op_str <- decode.field("operation", decode.string)
  use job <- decode.field("job", persist.job_decoder())
  decode.success(#(job, parse_op(op_str)))
}

fn parse_jsonl(content: String) -> List(#(ScheduledJob, ScheduleOp)) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, record_decoder()) {
      Ok(entry) -> Ok(entry)
      Error(_) -> Error(Nil)
    }
  })
}
