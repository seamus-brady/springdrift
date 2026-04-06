//// Artifact store — daily JSONL files in .springdrift/memory/artifacts/.
////
//// Each record contains metadata plus the full content string. Metadata-only
//// loading (load_date_meta) is used by the Librarian at startup; content is
//// read on demand via read_content.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import artifacts/types.{type ArtifactMeta, type ArtifactRecord, ArtifactMeta}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile
import slog

/// Default maximum content size before truncation (50KB).
pub const default_max_content_chars = 50_000

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

/// Write an artifact record with content to the daily JSONL file.
/// Content is capped at `max_chars`; truncated flag is set accordingly.
pub fn append(
  dir: String,
  record: ArtifactRecord,
  content: String,
  max_chars: Int,
) -> Nil {
  let date = string.slice(record.stored_at, 0, 10)
  let path = dir <> "/artifacts-" <> date <> ".jsonl"
  let #(trimmed_content, was_truncated) = case
    string.length(content) > max_chars
  {
    True -> #(string.slice(content, 0, max_chars), True)
    False -> #(content, record.truncated)
  }
  let actual_chars = string.length(trimmed_content)
  let json_str =
    json.to_string(encode_record(
      types.ArtifactRecord(
        ..record,
        char_count: actual_chars,
        truncated: was_truncated,
      ),
      trimmed_content,
    ))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug(
        "artifacts/log",
        "append",
        "Stored artifact "
          <> record.artifact_id
          <> " ("
          <> int.to_string(actual_chars)
          <> " chars)",
        Some(record.cycle_id),
      )
    Error(e) ->
      slog.log_error(
        "artifacts/log",
        "append",
        "Failed to append: " <> simplifile.describe_error(e),
        Some(record.artifact_id),
      )
  }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// Load all artifact metadata for a date (drops content field).
pub fn load_date_meta(dir: String, date: String) -> List(ArtifactMeta) {
  let path = dir <> "/artifacts-" <> date <> ".jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_jsonl_meta(content)
  }
}

/// Read the full content of a specific artifact by ID from a dated file.
/// Linear scan — artifact files are small and accessed rarely.
pub fn read_content(
  dir: String,
  artifact_id: String,
  date: String,
) -> Result(String, Nil) {
  let path = dir <> "/artifacts-" <> date <> ".jsonl"
  case simplifile.read(path) {
    Error(_) -> Error(Nil)
    Ok(file_content) -> {
      let lines =
        file_content
        |> string.split("\n")
        |> list.filter(fn(line) { string.trim(line) != "" })
      find_content_by_id(lines, artifact_id)
    }
  }
}

fn find_content_by_id(
  lines: List(String),
  artifact_id: String,
) -> Result(String, Nil) {
  case lines {
    [] -> Error(Nil)
    [line, ..rest] -> {
      case json.parse(line, content_decoder()) {
        Ok(#(id, content)) ->
          case id == artifact_id {
            True -> Ok(content)
            False -> find_content_by_id(rest, artifact_id)
          }
        Error(_) -> find_content_by_id(rest, artifact_id)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// JSON encoding
// ---------------------------------------------------------------------------

fn encode_record(r: ArtifactRecord, content: String) -> json.Json {
  json.object([
    #("schema_version", json.int(r.schema_version)),
    #("artifact_id", json.string(r.artifact_id)),
    #("cycle_id", json.string(r.cycle_id)),
    #("stored_at", json.string(r.stored_at)),
    #("tool", json.string(r.tool)),
    #("url", json.string(r.url)),
    #("summary", json.string(r.summary)),
    #("char_count", json.int(r.char_count)),
    #("truncated", json.bool(r.truncated)),
    #("content", json.string(content)),
  ])
}

// ---------------------------------------------------------------------------
// JSON decoding
// ---------------------------------------------------------------------------

fn meta_decoder() -> decode.Decoder(ArtifactMeta) {
  use artifact_id <- decode.field("artifact_id", decode.string)
  use cycle_id <- decode.field("cycle_id", decode.string)
  use stored_at <- decode.field("stored_at", decode.string)
  use tool <- decode.field(
    "tool",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use url <- decode.field(
    "url",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use summary <- decode.field(
    "summary",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use char_count <- decode.field(
    "char_count",
    decode.optional(decode.int) |> decode.map(option.unwrap(_, 0)),
  )
  use truncated <- decode.field(
    "truncated",
    decode.optional(decode.bool) |> decode.map(option.unwrap(_, False)),
  )
  decode.success(ArtifactMeta(
    artifact_id:,
    cycle_id:,
    stored_at:,
    tool:,
    url:,
    summary:,
    char_count:,
    truncated:,
  ))
}

/// Decoder that extracts just artifact_id and content fields.
fn content_decoder() -> decode.Decoder(#(String, String)) {
  use artifact_id <- decode.field("artifact_id", decode.string)
  use content <- decode.field("content", decode.string)
  decode.success(#(artifact_id, content))
}

fn parse_jsonl_meta(content: String) -> List(ArtifactMeta) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, meta_decoder()) {
      Ok(meta) -> Ok(meta)
      Error(_) -> Error(Nil)
    }
  })
}
