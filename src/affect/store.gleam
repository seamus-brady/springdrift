//// Affect store — append-only JSONL persistence for affect snapshots.
////
//// One file per day: .springdrift/memory/affect/YYYY-MM-DD-affect.jsonl

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import affect/types.{type AffectSnapshot}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

/// Append a snapshot to today's affect log.
pub fn append(dir: String, snapshot: AffectSnapshot) -> Nil {
  let _ = simplifile.create_directory_all(dir)
  let date = string.slice(get_datetime(), 0, 10)
  let path = dir <> "/" <> date <> "-affect.jsonl"
  let line = json.to_string(types.encode_snapshot(snapshot)) <> "\n"
  case simplifile.append(path, line) {
    Ok(_) -> Nil
    Error(_) -> {
      slog.warn("affect/store", "append", "Failed to write affect log", None)
      Nil
    }
  }
}

/// Load the most recent N snapshots across date files.
pub fn load_recent(dir: String, n: Int) -> List(AffectSnapshot) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      let affect_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, "-affect.jsonl") })
        |> list.sort(string.compare)
        |> list.reverse
      load_from_files(dir, affect_files, n, [])
    }
  }
}

fn load_from_files(
  dir: String,
  files: List(String),
  remaining: Int,
  acc: List(AffectSnapshot),
) -> List(AffectSnapshot) {
  case remaining <= 0 || list.is_empty(files) {
    True -> list.reverse(acc)
    False -> {
      let assert [file, ..rest] = files
      let path = dir <> "/" <> file
      let snapshots = load_file(path)
      let reversed = list.reverse(snapshots)
      let taken = list.take(reversed, remaining)
      let new_acc = list.append(list.reverse(taken), acc)
      load_from_files(dir, rest, remaining - list.length(taken), new_acc)
    }
  }
}

fn load_file(path: String) -> List(AffectSnapshot) {
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) ->
      string.split(content, "\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.filter_map(fn(line) {
        case json.parse(line, types.snapshot_decoder()) {
          Ok(s) -> Ok(s)
          Error(_) -> Error(Nil)
        }
      })
  }
}

/// Get the most recent snapshot, if any.
pub fn latest(dir: String) -> Option(AffectSnapshot) {
  case load_recent(dir, 1) {
    [s] -> Some(s)
    _ -> None
  }
}
