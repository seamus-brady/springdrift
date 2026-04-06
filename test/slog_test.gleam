// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/json
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import slog

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// level_to_string / level_from_string
// ---------------------------------------------------------------------------

pub fn level_to_string_debug_test() {
  slog.level_to_string(slog.Debug) |> should.equal("debug")
}

pub fn level_to_string_info_test() {
  slog.level_to_string(slog.Info) |> should.equal("info")
}

pub fn level_to_string_warn_test() {
  slog.level_to_string(slog.Warn) |> should.equal("warn")
}

pub fn level_to_string_error_test() {
  slog.level_to_string(slog.LogError) |> should.equal("error")
}

pub fn level_from_string_roundtrip_test() {
  slog.level_from_string("debug") |> should.equal(slog.Debug)
  slog.level_from_string("info") |> should.equal(slog.Info)
  slog.level_from_string("warn") |> should.equal(slog.Warn)
  slog.level_from_string("error") |> should.equal(slog.LogError)
}

pub fn level_from_string_unknown_defaults_debug_test() {
  slog.level_from_string("unknown") |> should.equal(slog.Debug)
}

// ---------------------------------------------------------------------------
// encode / decode roundtrip
// ---------------------------------------------------------------------------

pub fn encode_decode_roundtrip_test() {
  let entry =
    slog.LogEntry(
      timestamp: "2026-03-05T10:30:00",
      level: slog.Info,
      module: "test_mod",
      function: "test_fn",
      message: "hello world",
      cycle_id: Some("abc-123"),
    )
  let json_str = json.to_string(slog.encode_entry(entry))
  let result = json.parse(json_str, slog.entry_decoder())
  result |> should.be_ok
  let assert Ok(decoded) = result
  decoded.timestamp |> should.equal("2026-03-05T10:30:00")
  decoded.level |> should.equal(slog.Info)
  decoded.module |> should.equal("test_mod")
  decoded.function |> should.equal("test_fn")
  decoded.message |> should.equal("hello world")
  decoded.cycle_id |> should.equal(Some("abc-123"))
}

pub fn encode_decode_no_cycle_id_test() {
  let entry =
    slog.LogEntry(
      timestamp: "2026-03-05T10:30:00",
      level: slog.Debug,
      module: "m",
      function: "f",
      message: "msg",
      cycle_id: None,
    )
  let json_str = json.to_string(slog.encode_entry(entry))
  let assert Ok(decoded) = json.parse(json_str, slog.entry_decoder())
  decoded.cycle_id |> should.equal(None)
}

// ---------------------------------------------------------------------------
// debug creates file output
// ---------------------------------------------------------------------------

pub fn debug_creates_entry_test() {
  // Init logger with stderr disabled
  slog.init(False)

  // Write a test entry
  slog.debug("test_module", "test_function", "test_message", None)

  // Verify we can load entries (will include our entry)
  let entries = slog.load_entries()
  let found =
    entries
    |> list_has(fn(e) {
      e.module == "test_module" && e.function == "test_function"
    })
  found |> should.be_true
}

// ---------------------------------------------------------------------------
// load_entries
// ---------------------------------------------------------------------------

pub fn load_entries_returns_list_test() {
  slog.init(False)
  // Just verify it doesn't crash and returns a list
  let entries = slog.load_entries()
  // entries is a list (may be empty or have entries from other tests)
  { list.length(entries) >= 0 } |> should.be_true
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

import gleam/list

fn list_has(items: List(a), predicate: fn(a) -> Bool) -> Bool {
  list.any(items, predicate)
}
