//// System-level logger with three output sinks:
//// 1. Date-rotated JSON-L files in logs/
//// 2. Optional stderr output (enabled by --verbose)
//// 3. Loadable by TUI/Web log tabs
////
//// Uses stderr (not stdout) to avoid corrupting TUI alternate-screen output.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import simplifile

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "log_init")
pub fn init(stderr_enabled: Bool) -> Nil

@external(erlang, "springdrift_ffi", "log_stdout_enabled")
fn stderr_enabled() -> Bool

@external(erlang, "springdrift_ffi", "log_stderr")
fn write_stderr(text: String) -> Nil

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

@external(erlang, "springdrift_ffi", "file_size")
fn file_size(path: String) -> Int

@external(erlang, "springdrift_ffi", "file_rename")
fn file_rename(from: String, to: String) -> Bool

@external(erlang, "springdrift_ffi", "days_ago_date")
fn days_ago_date(days: Int) -> String

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type LogLevel {
  Debug
  Info
  Warn
  LogError
}

pub type LogEntry {
  LogEntry(
    timestamp: String,
    level: LogLevel,
    module: String,
    function: String,
    message: String,
    cycle_id: Option(String),
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn debug(
  module: String,
  function: String,
  message: String,
  cycle_id: Option(String),
) -> Nil {
  log(Debug, module, function, message, cycle_id)
}

pub fn info(
  module: String,
  function: String,
  message: String,
  cycle_id: Option(String),
) -> Nil {
  log(Info, module, function, message, cycle_id)
}

pub fn warn(
  module: String,
  function: String,
  message: String,
  cycle_id: Option(String),
) -> Nil {
  log(Warn, module, function, message, cycle_id)
}

pub fn log_error(
  module: String,
  function: String,
  message: String,
  cycle_id: Option(String),
) -> Nil {
  log(LogError, module, function, message, cycle_id)
}

/// Load all log entries from today's log file.
pub fn load_entries() -> List(LogEntry) {
  case simplifile.read(log_path()) {
    Error(_) -> []
    Ok(contents) ->
      string.split(contents, "\n")
      |> list.filter_map(fn(line) {
        let trimmed = string.trim(line)
        case trimmed {
          "" -> Error(Nil)
          _ ->
            case json.parse(trimmed, entry_decoder()) {
              Ok(entry) -> Ok(entry)
              Error(_) -> Error(Nil)
            }
        }
      })
  }
}

/// Remove log files older than 30 days from the logs directory.
pub fn cleanup_old_logs() -> Nil {
  let dir = log_dir()
  let cutoff = days_ago_date(30)
  case simplifile.read_directory(dir) {
    Error(_) -> Nil
    Ok(entries) ->
      list.each(entries, fn(entry) {
        case string.ends_with(entry, ".jsonl") {
          True -> {
            let file_date = string.slice(entry, 0, 10)
            case string.compare(file_date, cutoff) {
              order.Lt -> {
                let _ = simplifile.delete(dir <> "/" <> entry)
                Nil
              }
              _ -> Nil
            }
          }
          False -> Nil
        }
      })
  }
}

/// Load log entries with timestamps >= the given ISO timestamp.
pub fn load_entries_since(iso_timestamp: String) -> List(LogEntry) {
  load_entries()
  |> list.filter(fn(entry) {
    string.compare(entry.timestamp, iso_timestamp) != order.Lt
  })
}

// ---------------------------------------------------------------------------
// Level helpers
// ---------------------------------------------------------------------------

pub fn level_to_string(level: LogLevel) -> String {
  case level {
    Debug -> "debug"
    Info -> "info"
    Warn -> "warn"
    LogError -> "error"
  }
}

pub fn level_from_string(s: String) -> LogLevel {
  case string.lowercase(s) {
    "info" -> Info
    "warn" -> Warn
    "error" -> LogError
    _ -> Debug
  }
}

// ---------------------------------------------------------------------------
// Encoding / Decoding
// ---------------------------------------------------------------------------

pub fn encode_entry(entry: LogEntry) -> json.Json {
  json.object([
    #("timestamp", json.string(entry.timestamp)),
    #("level", json.string(level_to_string(entry.level))),
    #("module", json.string(entry.module)),
    #("function", json.string(entry.function)),
    #("message", json.string(entry.message)),
    #("cycle_id", case entry.cycle_id {
      None -> json.null()
      Some(id) -> json.string(id)
    }),
  ])
}

pub fn entry_decoder() -> decode.Decoder(LogEntry) {
  use timestamp <- decode.field("timestamp", decode.string)
  use level_str <- decode.field("level", decode.string)
  use module <- decode.field("module", decode.string)
  use function <- decode.field("function", decode.string)
  use message <- decode.field("message", decode.string)
  use cycle_id <- decode.optional_field(
    "cycle_id",
    None,
    decode.optional(decode.string),
  )
  decode.success(LogEntry(
    timestamp:,
    level: level_from_string(level_str),
    module:,
    function:,
    message:,
    cycle_id:,
  ))
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn log_dir() -> String {
  "logs"
}

fn log_path() -> String {
  log_dir() <> "/" <> get_date() <> ".jsonl"
}

fn log(
  level: LogLevel,
  module: String,
  function: String,
  message: String,
  cycle_id: Option(String),
) -> Nil {
  let entry =
    LogEntry(
      timestamp: get_datetime(),
      level:,
      module:,
      function:,
      message:,
      cycle_id:,
    )
  append_to_file(entry)
  maybe_stderr(entry)
}

fn append_to_file(entry: LogEntry) -> Nil {
  let dir = log_dir()
  let _ = simplifile.create_directory_all(dir)
  let path = log_path()
  // Rotate if file exceeds 10MB
  case file_size(path) > 10_485_760 {
    True -> {
      let _ = file_rename(path, path <> ".1")
      Nil
    }
    False -> Nil
  }
  let _ = simplifile.append(path, json.to_string(encode_entry(entry)) <> "\n")
  Nil
}

fn maybe_stderr(entry: LogEntry) -> Nil {
  case stderr_enabled() {
    True -> {
      let cycle_part = case entry.cycle_id {
        None -> ""
        Some(id) -> " [" <> string.slice(id, 0, 8) <> "]"
      }
      let line =
        "["
        <> level_to_string(entry.level)
        <> "] "
        <> entry.module
        <> "::"
        <> entry.function
        <> " "
        <> entry.message
        <> cycle_part
      write_stderr(line)
    }
    False -> Nil
  }
}
