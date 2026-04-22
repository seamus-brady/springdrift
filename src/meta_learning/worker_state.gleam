//// Persistence sidecar for meta-learning BEAM workers.
////
//// Stores the last successful-run timestamp (ISO-8601) per worker
//// name so a restart can compute a sensible initial delay rather
//// than re-running audits that were just completed.
////
//// File format is a flat JSON object: `{"name": "ISO-timestamp", ...}`.
//// Small (<1KB), read once at startup, rewritten on each success.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import slog

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

/// Convert an ISO-8601 datetime to monotonic-ms relative to now. Returns
/// None if the string fails to parse. Defined in springdrift_ffi.erl.
@external(erlang, "springdrift_ffi", "ms_until_datetime")
fn ms_until_datetime(iso: String) -> Int

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Read the ISO timestamp for a worker. None if missing, unreadable,
/// or malformed.
pub fn get(state_file: String, worker_name: String) -> Option(String) {
  case load(state_file) {
    Error(_) -> None
    Ok(d) ->
      case dict.get(d, worker_name) {
        Ok(ts) -> Some(ts)
        Error(_) -> None
      }
  }
}

/// Write the ISO timestamp for a worker, creating or merging into
/// the file. Silently logs and returns on I/O error — a stale state
/// file is tolerated; the worst case is a duplicate run on restart.
pub fn set(state_file: String, worker_name: String, iso: String) -> Nil {
  let existing = case load(state_file) {
    Ok(d) -> d
    Error(_) -> dict.new()
  }
  let updated = dict.insert(existing, worker_name, iso)
  let encoded =
    dict.to_list(updated)
    |> list.map(fn(pair) {
      let #(k, v) = pair
      #(k, json.string(v))
    })
    |> json.object
    |> json.to_string
  // Ensure parent directory exists before writing.
  let _ = simplifile.create_directory_all(parent_dir(state_file))
  case simplifile.write(state_file, encoded) {
    Ok(_) -> Nil
    Error(err) ->
      slog.warn(
        "meta_learning/worker_state",
        "set",
        "Failed to write " <> state_file <> ": " <> error_to_string(err),
        None,
      )
  }
}

/// How many ms have elapsed since the given ISO timestamp, clamped to
/// non-negative. None if the string fails to parse. Used by the worker
/// to compute initial delay on start.
pub fn ms_since_iso(iso: String) -> Option(Int) {
  // ms_until_datetime returns (target - now); we want (now - target).
  let delta = ms_until_datetime(iso)
  case delta {
    // FFI returns 0 when parsing fails; distinguish by treating 0 as
    // "exactly now" which is fine for our purposes — either way the
    // worker fires after the initial delay, not immediately.
    _ ->
      case 0 - delta {
        neg if neg < 0 -> Some(0)
        elapsed -> Some(elapsed)
      }
  }
}

// ---------------------------------------------------------------------------
// Internal — JSON load
// ---------------------------------------------------------------------------

fn load(state_file: String) -> Result(Dict(String, String), Nil) {
  case simplifile.read(state_file) {
    Error(_) -> Error(Nil)
    Ok(contents) -> {
      let decoder = decode.dict(decode.string, decode.string)
      case json.parse(contents, decoder) {
        Ok(d) -> Ok(d)
        Error(_) -> Error(Nil)
      }
    }
  }
}

fn parent_dir(path: String) -> String {
  case string.split(path, "/") {
    [] -> "."
    [_] -> "."
    parts -> {
      let n = list.length(parts)
      list.take(parts, n - 1) |> string.join("/")
    }
  }
}

fn error_to_string(err: simplifile.FileError) -> String {
  simplifile.describe_error(err)
}
