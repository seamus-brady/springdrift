//// Captures expiry — daily sweep that marks aged pending captures Expired.
////
//// Keeps the pending list bounded. A capture that has sat for
//// `expiry_days` (default 14) without being clarified or dismissed is
//// auto-expired by the scheduler's daily tick.
////
//// Pure-ish: reads JSONL, computes a list of expired ids, appends Expire
//// ops via the log module, notifies the Librarian to drop them from the
//// pending cache. Designed to be called from the scheduler or a test.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import captures/log as captures_log
import captures/types.{type Capture, Expire}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import narrative/librarian.{type LibrarianMessage}
import slog

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

@external(erlang, "springdrift_ffi", "days_between")
fn days_between(date_a: String, date_b: String) -> Int

// ---------------------------------------------------------------------------
// Public entry
// ---------------------------------------------------------------------------

/// Run one expiry sweep. Scans pending captures, marks any with age >
/// expiry_days as Expired, and notifies the Librarian.
///
/// Returns the count of captures that were expired.
pub fn sweep(
  captures_dir: String,
  expiry_days: Int,
  librarian: Option(Subject(LibrarianMessage)),
) -> Int {
  let pending = captures_log.pending_from_disk(captures_dir)
  let today = get_date()
  let to_expire =
    list.filter(pending, fn(c) { is_expired(c, today, expiry_days) })
  list.each(to_expire, fn(c) {
    captures_log.append(captures_dir, Expire(c.id))
    case librarian {
      Some(l) -> librarian.notify_remove_capture(l, c.id)
      None -> Nil
    }
  })
  let count = list.length(to_expire)
  case count > 0 {
    True ->
      slog.info(
        "captures/expiry",
        "sweep",
        "Expired " <> int.to_string(count) <> " aged capture(s)",
        None,
      )
    False -> Nil
  }
  count
}

// ---------------------------------------------------------------------------
// Pure age check — exposed for tests
// ---------------------------------------------------------------------------

pub fn is_expired(c: Capture, today: String, expiry_days: Int) -> Bool {
  case capture_date(c) {
    None -> False
    Some(date) -> days_between(date, today) > expiry_days
  }
}

fn capture_date(c: Capture) -> Option(String) {
  // created_at is an ISO-8601 timestamp; the first 10 chars are YYYY-MM-DD.
  case string.length(c.created_at) >= 10 {
    True -> Some(string.slice(c.created_at, 0, 10))
    False -> None
  }
}
