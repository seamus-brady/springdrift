// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleeunit/should
import simplifile
import skills/metrics

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fresh_dir(suffix: String) -> String {
  let dir = "/tmp/skills_metrics_test_" <> suffix
  let _ = simplifile.delete_all([dir])
  let _ = simplifile.create_directory_all(dir)
  dir
}

// ---------------------------------------------------------------------------
// append + load
// ---------------------------------------------------------------------------

pub fn append_read_and_load_test() {
  let dir = fresh_dir("read")
  metrics.append_read(dir, "cycle-1", "researcher")
  metrics.append_read(dir, "cycle-2", "coder")
  let events = metrics.load_all(dir)
  list.length(events) |> should.equal(2)
}

pub fn append_inject_and_outcome_test() {
  let dir = fresh_dir("inject")
  metrics.append_inject(dir, "cycle-1", "researcher")
  metrics.append_outcome(dir, "cycle-1", "researcher", "success")
  let events = metrics.load_all(dir)
  list.length(events) |> should.equal(2)
}

// ---------------------------------------------------------------------------
// counts
// ---------------------------------------------------------------------------

pub fn usage_count_only_counts_reads_test() {
  let dir = fresh_dir("count")
  metrics.append_read(dir, "c1", "a")
  metrics.append_read(dir, "c2", "a")
  metrics.append_inject(dir, "c1", "a")
  metrics.append_outcome(dir, "c1", "a", "success")
  metrics.usage_count(dir) |> should.equal(2)
}

pub fn inject_count_only_counts_injects_test() {
  let dir = fresh_dir("inject_count")
  metrics.append_inject(dir, "c1", "a")
  metrics.append_inject(dir, "c2", "a")
  metrics.append_inject(dir, "c3", "a")
  metrics.append_read(dir, "c1", "a")
  metrics.inject_count(dir) |> should.equal(3)
}

// ---------------------------------------------------------------------------
// last_used
// ---------------------------------------------------------------------------

pub fn last_used_returns_none_for_empty_test() {
  let dir = fresh_dir("empty")
  metrics.last_used(dir) |> should.equal(option.None)
}

pub fn last_used_returns_latest_event_timestamp_test() {
  let dir = fresh_dir("latest")
  metrics.append_read(dir, "c1", "a")
  metrics.append_inject(dir, "c2", "a")
  case metrics.last_used(dir) {
    option.Some(_) -> True |> should.be_true
    option.None -> True |> should.be_false
  }
}

// ---------------------------------------------------------------------------
// summarise
// ---------------------------------------------------------------------------

pub fn summarise_includes_counts_test() {
  let dir = fresh_dir("summary")
  metrics.append_read(dir, "c1", "a")
  metrics.append_read(dir, "c2", "a")
  metrics.append_inject(dir, "c1", "a")
  let s = metrics.summarise(dir)
  string_contains(s, "2 reads") |> should.be_true
  string_contains(s, "1 injects") |> should.be_true
}

import gleam/option
import gleam/string

fn string_contains(s: String, sub: String) -> Bool {
  string.contains(s, sub)
}
