/// Application event logger — writes JSON-L entries to ./springdrift.log.
///
/// Each line has the shape:
///   {"timestamp":"2026-02-26T17:43:17","level":"info","event":"sandbox_started","source":"main",...fields}
import gleam/json
import gleam/list
import simplifile

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

const log_path = "springdrift.log"

/// Write a structured log entry at the given level.
pub fn log(level: String, event: String, fields: List(#(String, String))) -> Nil {
  let base = [
    #("timestamp", json.string(get_datetime())),
    #("level", json.string(level)),
    #("event", json.string(event)),
    #("source", json.string("main")),
  ]
  let extra = list.map(fields, fn(f) { #(f.0, json.string(f.1)) })
  let entry = json.object(list.append(base, extra))
  let _ = simplifile.append(log_path, json.to_string(entry) <> "\n")
  Nil
}

pub fn info(event: String, fields: List(#(String, String))) -> Nil {
  log("info", event, fields)
}

pub fn warn(event: String, fields: List(#(String, String))) -> Nil {
  log("warn", event, fields)
}

pub fn err(event: String, fields: List(#(String, String))) -> Nil {
  log("error", event, fields)
}
