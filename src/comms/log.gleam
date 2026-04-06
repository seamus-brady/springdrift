//// Append-only comms message log — daily JSONL files.
////
//// All sent and received messages are persisted for audit trail.
//// Format: .springdrift/memory/comms/YYYY-MM-DD-comms.jsonl

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import comms/types.{
  type CommsMessage, type DeliveryStatus, type Direction, CommsMessage,
  Delivered, Email, Failed, Inbound, Outbound, Pending, Sent,
}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "days_ago_date")
fn days_ago_date(days: Int) -> String

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

/// Append a CommsMessage to a dated JSONL file.
pub fn append(dir: String, msg: CommsMessage) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> "-comms.jsonl"
  let json_str = json.to_string(encode_message(msg))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug(
        "comms/log",
        "append",
        "Logged " <> direction_to_string(msg.direction) <> " " <> msg.message_id,
        msg.cycle_id,
      )
    Error(e) ->
      slog.log_error(
        "comms/log",
        "append",
        "Failed to append: " <> simplifile.describe_error(e),
        Some(msg.message_id),
      )
  }
}

/// Count outbound messages in the last N hours (for rate limiting).
pub fn count_recent_outbound(dir: String, hours: Int) -> Int {
  // Load today's file and yesterday's (covers hour boundaries at midnight)
  let entries = load_recent(dir, 2)
  let cutoff = hours_ago_iso(hours)
  list.count(entries, fn(m) {
    m.direction == Outbound && string.compare(m.timestamp, cutoff) != order.Lt
  })
}

/// Returns an ISO timestamp N hours in the past.
/// String comparison works for ISO 8601 timestamps (YYYY-MM-DDTHH:MM:SS).
fn hours_ago_iso(hours: Int) -> String {
  let now_str = get_datetime()
  // Parse the ISO timestamp, subtract hours, re-format
  // Use simple string math: extract hour, subtract, handle underflow
  case string.length(now_str) >= 19 {
    False -> ""
    True -> {
      let date_part = string.slice(now_str, 0, 11)
      let hour_str = string.slice(now_str, 11, 2)
      let rest = string.slice(now_str, 13, 6)
      case int.parse(hour_str) {
        Error(_) -> ""
        Ok(hour) -> {
          let new_hour = hour - hours
          case new_hour >= 0 {
            True -> date_part <> pad_int(new_hour) <> rest
            False -> {
              // Rolled past midnight — use yesterday's date with wrapped hour
              let yesterday = days_ago_date(1)
              yesterday <> "T" <> pad_int(new_hour + 24) <> rest
            }
          }
        }
      }
    }
  }
}

fn pad_int(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

pub fn load_recent_raw(dir: String, days: Int) -> List(String) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      let comms_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, "-comms.jsonl") })
        |> list.sort(string.compare)
        |> list.reverse
        |> list.take(days)
      list.flat_map(comms_files, fn(f) {
        case simplifile.read(dir <> "/" <> f) {
          Error(_) -> []
          Ok(content) ->
            string.split(content, "\n")
            |> list.filter(fn(l) { string.trim(l) != "" })
        }
      })
    }
  }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// Load messages for a specific date.
pub fn load_date(dir: String, date: String) -> List(CommsMessage) {
  let path = dir <> "/" <> date <> "-comms.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_jsonl(content)
  }
}

/// Load messages from recent N days.
pub fn load_recent(dir: String, days: Int) -> List(CommsMessage) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      let comms_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, "-comms.jsonl") })
        |> list.sort(string.compare)
        |> list.reverse
        |> list.take(days)
      list.flat_map(comms_files, fn(f) {
        case simplifile.read(dir <> "/" <> f) {
          Ok(content) -> parse_jsonl(content)
          Error(_) -> []
        }
      })
    }
  }
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

fn encode_message(msg: CommsMessage) -> json.Json {
  json.object([
    #("message_id", json.string(msg.message_id)),
    #("thread_id", json.string(msg.thread_id)),
    #("channel", json.string(channel_to_string(msg.channel))),
    #("direction", json.string(direction_to_string(msg.direction))),
    #("from", json.string(msg.from)),
    #("to", json.string(msg.to)),
    #("subject", json.string(msg.subject)),
    #("body_text", json.string(msg.body_text)),
    #("timestamp", json.string(msg.timestamp)),
    #("status", json.string(status_to_string(msg.status))),
    #("cycle_id", case msg.cycle_id {
      Some(id) -> json.string(id)
      None -> json.null()
    }),
  ])
}

fn channel_to_string(ch: types.CommsChannel) -> String {
  case ch {
    Email -> "email"
  }
}

fn direction_to_string(d: Direction) -> String {
  case d {
    Inbound -> "inbound"
    Outbound -> "outbound"
  }
}

fn status_to_string(s: DeliveryStatus) -> String {
  case s {
    Sent -> "sent"
    Delivered -> "delivered"
    Failed(reason) -> "failed:" <> reason
    Pending -> "pending"
  }
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

fn parse_jsonl(content: String) -> List(CommsMessage) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
  |> list.filter_map(fn(line) { json.parse(line, message_decoder()) })
}

fn message_decoder() -> decode.Decoder(CommsMessage) {
  use message_id <- decode.field("message_id", decode.string)
  use thread_id <- decode.optional_field("thread_id", "", decode.string)
  use _channel <- decode.optional_field("channel", "email", decode.string)
  use direction_str <- decode.optional_field(
    "direction",
    "outbound",
    decode.string,
  )
  use from <- decode.optional_field("from", "", decode.string)
  use to <- decode.optional_field("to", "", decode.string)
  use subject <- decode.optional_field("subject", "", decode.string)
  use body_text <- decode.optional_field("body_text", "", decode.string)
  use timestamp <- decode.optional_field("timestamp", "", decode.string)
  use status_str <- decode.optional_field("status", "sent", decode.string)
  use cycle_id <- decode.optional_field(
    "cycle_id",
    None,
    decode.optional(decode.string),
  )
  decode.success(CommsMessage(
    message_id:,
    thread_id:,
    channel: Email,
    direction: parse_direction(direction_str),
    from:,
    to:,
    subject:,
    body_text:,
    timestamp:,
    status: parse_status(status_str),
    cycle_id:,
  ))
}

fn parse_direction(s: String) -> Direction {
  case s {
    "inbound" -> Inbound
    _ -> Outbound
  }
}

fn parse_status(s: String) -> DeliveryStatus {
  case s {
    "sent" -> Sent
    "delivered" -> Delivered
    "pending" -> Pending
    _ ->
      case string.starts_with(s, "failed:") {
        True -> Failed(string.drop_start(s, 7))
        False -> Failed(s)
      }
  }
}
