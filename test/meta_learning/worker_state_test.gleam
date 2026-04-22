//// Worker-state sidecar — round-trip and missing-file behaviour.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{None}
import gleeunit/should
import meta_learning/worker_state
import simplifile

fn fresh_file(name: String) -> String {
  let path = "/tmp/springdrift-test-workerstate-" <> name <> ".json"
  let _ = simplifile.delete(path)
  path
}

pub fn missing_file_returns_none_test() {
  let path = fresh_file("missing")
  worker_state.get(path, "affect_correlation") |> should.equal(None)
}

pub fn round_trip_single_worker_test() {
  let path = fresh_file("single")
  worker_state.set(path, "fabrication_audit", "2026-04-21T19:00:00Z")
  let assert option.Some(ts) = worker_state.get(path, "fabrication_audit")
  ts |> should.equal("2026-04-21T19:00:00Z")
}

pub fn set_merges_into_existing_file_test() {
  let path = fresh_file("merge")
  worker_state.set(path, "fabrication_audit", "2026-04-21T10:00:00Z")
  worker_state.set(path, "voice_drift", "2026-04-21T11:00:00Z")
  // Both keys must survive — the second set must not clobber the first.
  let assert option.Some(a) = worker_state.get(path, "fabrication_audit")
  a |> should.equal("2026-04-21T10:00:00Z")
  let assert option.Some(b) = worker_state.get(path, "voice_drift")
  b |> should.equal("2026-04-21T11:00:00Z")
}

pub fn set_overwrites_same_key_test() {
  let path = fresh_file("overwrite")
  worker_state.set(path, "voice_drift", "2026-04-20T09:00:00Z")
  worker_state.set(path, "voice_drift", "2026-04-21T09:00:00Z")
  let assert option.Some(ts) = worker_state.get(path, "voice_drift")
  ts |> should.equal("2026-04-21T09:00:00Z")
}
