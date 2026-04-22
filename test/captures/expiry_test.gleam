// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import captures/expiry
import captures/types.{type Capture, AgentSelf, Capture, Pending}
import gleam/option.{None}
import gleeunit/should

fn capture_created_on(created_at: String) -> Capture {
  Capture(
    schema_version: 1,
    id: "cap-test",
    created_at: created_at,
    source_cycle_id: "cyc-001",
    text: "whatever",
    source: AgentSelf,
    due_hint: None,
    status: Pending,
  )
}

// ---------------------------------------------------------------------------
// is_expired — pure age math
// ---------------------------------------------------------------------------

pub fn is_expired_fresh_capture_test() {
  // Created today, with 14-day window → not expired
  let c = capture_created_on("2026-04-22T10:00:00Z")
  should.equal(expiry.is_expired(c, "2026-04-22", 14), False)
}

pub fn is_expired_within_window_test() {
  // 10 days old, 14-day window → not expired
  let c = capture_created_on("2026-04-12T10:00:00Z")
  should.equal(expiry.is_expired(c, "2026-04-22", 14), False)
}

pub fn is_expired_exactly_at_window_test() {
  // 14 days old, 14-day window → NOT expired (> 14, not >=)
  let c = capture_created_on("2026-04-08T10:00:00Z")
  should.equal(expiry.is_expired(c, "2026-04-22", 14), False)
}

pub fn is_expired_past_window_test() {
  // 20 days old, 14-day window → expired
  let c = capture_created_on("2026-04-02T10:00:00Z")
  should.equal(expiry.is_expired(c, "2026-04-22", 14), True)
}

pub fn is_expired_malformed_timestamp_test() {
  // Short/malformed timestamp → not expired (fail-safe)
  let c = capture_created_on("bad")
  should.equal(expiry.is_expired(c, "2026-04-22", 14), False)
}
