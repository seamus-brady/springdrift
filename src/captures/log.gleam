//// Append-only Capture op log — daily JSONL files in
//// .springdrift/memory/captures/.
////
//// Files are `YYYY-MM-DD-captures.jsonl`. State is derived by replaying
//// the op log (`resolve_from_list`). Five op variants: Created,
//// ClarifyToCalendar, Dismiss, Expire, Satisfy.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import captures/types.{
  type Capture, type CaptureOp, type CaptureSource, type CaptureStatus,
  AgentSelf, Capture, ClarifiedToCalendar, ClarifyToCalendar, Created, Dismiss,
  Dismissed, Expire, Expired, InboundComms, OperatorAsk, Pending, Satisfied,
  Satisfy,
}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

/// Append a CaptureOp to today's dated JSONL file.
pub fn append(dir: String, op: CaptureOp) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> "-captures.jsonl"
  let json_str = json.to_string(encode_op(op))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug(
        "captures/log",
        "append",
        "Appended " <> op_tag(op),
        op_cycle_id(op),
      )
    Error(e) ->
      slog.log_error(
        "captures/log",
        "append",
        "Failed to append: " <> simplifile.describe_error(e),
        op_cycle_id(op),
      )
  }
}

fn op_tag(op: CaptureOp) -> String {
  case op {
    Created(c) -> "Created " <> c.id
    ClarifyToCalendar(id, _, _) -> "ClarifyToCalendar " <> id
    Dismiss(id, _) -> "Dismiss " <> id
    Expire(id) -> "Expire " <> id
    Satisfy(id, _) -> "Satisfy " <> id
  }
}

fn op_cycle_id(op: CaptureOp) -> Option(String) {
  case op {
    Created(c) -> Some(c.source_cycle_id)
    _ -> None
  }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// Load ops for a specific date (YYYY-MM-DD).
pub fn load_date(dir: String, date: String) -> List(CaptureOp) {
  let path = dir <> "/" <> date <> "-captures.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_jsonl(content)
  }
}

/// Load all ops from all dated files, in chronological order.
pub fn load_all(dir: String) -> List(CaptureOp) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      files
      |> list.filter(fn(f) { string.ends_with(f, "-captures.jsonl") })
      |> list.sort(string.compare)
      |> list.flat_map(fn(f) {
        let date = string.drop_end(f, 15)
        load_date(dir, date)
      })
    }
  }
}

// ---------------------------------------------------------------------------
// Resolve — replay ops to current Capture state
// ---------------------------------------------------------------------------

/// Resolve current captures from disk. Returns all captures in their latest
/// state, including non-pending ones. Filter with `filter_status` if you
/// only want a subset.
pub fn resolve_current(dir: String) -> List(Capture) {
  load_all(dir) |> resolve_from_list
}

/// Resolve captures from an in-memory op list (for tests + reuse).
pub fn resolve_from_list(ops: List(CaptureOp)) -> List(Capture) {
  list.fold(ops, [], fn(acc, op) { apply_op(acc, op) })
  |> list.reverse
}

fn apply_op(acc: List(Capture), op: CaptureOp) -> List(Capture) {
  case op {
    Created(c) ->
      // Prepend so fold accumulates in reverse; caller re-reverses for
      // chronological output.
      case find(acc, c.id) {
        Some(_) -> acc
        // Duplicate id — skip; log replays must be idempotent.
        None -> [c, ..acc]
      }
    ClarifyToCalendar(id, job_id, _note) ->
      update_status(acc, id, ClarifiedToCalendar(job_id))
    Dismiss(id, reason) -> update_status(acc, id, Dismissed(reason))
    Expire(id) -> update_status(acc, id, Expired)
    Satisfy(id, reason) -> update_status(acc, id, Satisfied(reason))
  }
}

fn find(captures: List(Capture), id: String) -> Option(Capture) {
  list.find(captures, fn(c) { c.id == id }) |> option.from_result
}

fn update_status(
  captures: List(Capture),
  id: String,
  new_status: CaptureStatus,
) -> List(Capture) {
  list.map(captures, fn(c) {
    case c.id == id {
      True -> Capture(..c, status: new_status)
      False -> c
    }
  })
}

/// Only pending captures — the common query.
pub fn filter_pending(captures: List(Capture)) -> List(Capture) {
  list.filter(captures, fn(c) {
    case c.status {
      Pending -> True
      _ -> False
    }
  })
}

/// Look up a capture by id among the resolved state.
pub fn find_by_id(captures: List(Capture), id: String) -> Result(Capture, Nil) {
  list.find(captures, fn(c) { c.id == id })
}

// ---------------------------------------------------------------------------
// JSONL parsing
// ---------------------------------------------------------------------------

fn parse_jsonl(content: String) -> List(CaptureOp) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, op_decoder()) {
      Ok(op) -> Ok(op)
      Error(_) -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// JSON encoding
// ---------------------------------------------------------------------------

pub fn encode_op(op: CaptureOp) -> json.Json {
  case op {
    Created(c) ->
      json.object([
        #("op", json.string("created")),
        #("capture", encode_capture(c)),
      ])
    ClarifyToCalendar(id, job_id, note) ->
      json.object([
        #("op", json.string("clarify_to_calendar")),
        #("id", json.string(id)),
        #("scheduler_job_id", json.string(job_id)),
        #("note", json.string(note)),
      ])
    Dismiss(id, reason) ->
      json.object([
        #("op", json.string("dismiss")),
        #("id", json.string(id)),
        #("reason", json.string(reason)),
      ])
    Expire(id) ->
      json.object([#("op", json.string("expire")), #("id", json.string(id))])
    Satisfy(id, reason) ->
      json.object([
        #("op", json.string("satisfy")),
        #("id", json.string(id)),
        #("reason", json.string(reason)),
      ])
  }
}

pub fn encode_capture(c: Capture) -> json.Json {
  json.object([
    #("schema_version", json.int(c.schema_version)),
    #("id", json.string(c.id)),
    #("created_at", json.string(c.created_at)),
    #("source_cycle_id", json.string(c.source_cycle_id)),
    #("text", json.string(c.text)),
    #("source", json.string(encode_source(c.source))),
    #("due_hint", case c.due_hint {
      Some(h) -> json.string(h)
      None -> json.null()
    }),
    #("status", encode_status(c.status)),
  ])
}

fn encode_source(s: CaptureSource) -> String {
  case s {
    AgentSelf -> "agent_self"
    OperatorAsk -> "operator_ask"
    InboundComms -> "inbound_comms"
  }
}

fn encode_status(s: CaptureStatus) -> json.Json {
  case s {
    Pending -> json.object([#("kind", json.string("pending"))])
    ClarifiedToCalendar(job_id) ->
      json.object([
        #("kind", json.string("clarified_to_calendar")),
        #("scheduler_job_id", json.string(job_id)),
      ])
    Dismissed(reason) ->
      json.object([
        #("kind", json.string("dismissed")),
        #("reason", json.string(reason)),
      ])
    Expired -> json.object([#("kind", json.string("expired"))])
    Satisfied(reason) ->
      json.object([
        #("kind", json.string("satisfied")),
        #("reason", json.string(reason)),
      ])
  }
}

// ---------------------------------------------------------------------------
// JSON decoding — lenient
// ---------------------------------------------------------------------------

pub fn op_decoder() -> decode.Decoder(CaptureOp) {
  use op_tag <- decode.field("op", decode.string)
  case op_tag {
    "created" -> {
      use capture <- decode.field("capture", capture_decoder())
      decode.success(Created(capture))
    }
    "clarify_to_calendar" -> {
      use id <- decode.field("id", decode.string)
      use job_id <- decode.field("scheduler_job_id", decode.string)
      use note <- decode.field(
        "note",
        decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
      )
      decode.success(ClarifyToCalendar(id, job_id, note))
    }
    "dismiss" -> {
      use id <- decode.field("id", decode.string)
      use reason <- decode.field(
        "reason",
        decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
      )
      decode.success(Dismiss(id, reason))
    }
    "expire" -> {
      use id <- decode.field("id", decode.string)
      decode.success(Expire(id))
    }
    "satisfy" -> {
      use id <- decode.field("id", decode.string)
      use reason <- decode.field(
        "reason",
        decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
      )
      decode.success(Satisfy(id, reason))
    }
    _ -> decode.failure(Expire(""), "unknown op tag: " <> op_tag)
  }
}

pub fn capture_decoder() -> decode.Decoder(Capture) {
  use schema_version <- decode.field(
    "schema_version",
    decode.optional(decode.int) |> decode.map(option.unwrap(_, 1)),
  )
  use id <- decode.field("id", decode.string)
  use created_at <- decode.field("created_at", decode.string)
  use source_cycle_id <- decode.field(
    "source_cycle_id",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use text <- decode.field("text", decode.string)
  use source <- decode.field(
    "source",
    decode.optional(decode.string)
      |> decode.map(fn(s) { decode_source(option.unwrap(s, "agent_self")) }),
  )
  use due_hint <- decode.field("due_hint", decode.optional(decode.string))
  use status <- decode.field("status", status_decoder())
  decode.success(Capture(
    schema_version:,
    id:,
    created_at:,
    source_cycle_id:,
    text:,
    source:,
    due_hint:,
    status:,
  ))
}

fn decode_source(s: String) -> CaptureSource {
  case s {
    "operator_ask" -> OperatorAsk
    "inbound_comms" -> InboundComms
    _ -> AgentSelf
  }
}

fn status_decoder() -> decode.Decoder(CaptureStatus) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "pending" -> decode.success(Pending)
    "clarified_to_calendar" -> {
      use job_id <- decode.field("scheduler_job_id", decode.string)
      decode.success(ClarifiedToCalendar(job_id))
    }
    "dismissed" -> {
      use reason <- decode.field(
        "reason",
        decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
      )
      decode.success(Dismissed(reason))
    }
    "expired" -> decode.success(Expired)
    "satisfied" -> {
      use reason <- decode.field(
        "reason",
        decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
      )
      decode.success(Satisfied(reason))
    }
    _ -> decode.failure(Pending, "unknown status kind: " <> kind)
  }
}

// ---------------------------------------------------------------------------
// Convenience: read pending captures directly from disk.
// ---------------------------------------------------------------------------

pub fn pending_from_disk(dir: String) -> List(Capture) {
  dir |> resolve_current |> filter_pending
}
