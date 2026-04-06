// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import affect/types.{
  AffectSnapshot, Falling, Rising, Stable, baseline, format_compact,
  format_reading, trend_arrow, trend_from_string, trend_to_string,
}
import gleam/json
import gleam/string
import gleeunit/should

// ---------------------------------------------------------------------------
// Trend
// ---------------------------------------------------------------------------

pub fn trend_round_trip_test() {
  trend_to_string(Rising) |> should.equal("rising")
  trend_to_string(Falling) |> should.equal("falling")
  trend_to_string(Stable) |> should.equal("stable")

  trend_from_string("rising") |> should.equal(Rising)
  trend_from_string("falling") |> should.equal(Falling)
  trend_from_string("stable") |> should.equal(Stable)
  trend_from_string("unknown") |> should.equal(Stable)
}

pub fn trend_arrow_test() {
  trend_arrow(Rising) |> should.equal("↑")
  trend_arrow(Falling) |> should.equal("↓")
  trend_arrow(Stable) |> should.equal("↔")
}

// ---------------------------------------------------------------------------
// Baseline
// ---------------------------------------------------------------------------

pub fn baseline_test() {
  let b = baseline()
  b.desperation |> should.equal(0.0)
  b.calm |> should.equal(75.0)
  b.confidence |> should.equal(60.0)
  b.frustration |> should.equal(0.0)
  b.pressure |> should.equal(0.0)
  b.trend |> should.equal(Stable)
}

// ---------------------------------------------------------------------------
// Format
// ---------------------------------------------------------------------------

pub fn format_reading_test() {
  let s =
    AffectSnapshot(
      cycle_id: "test-001",
      timestamp: "2026-04-04T10:00:00",
      desperation: 34.0,
      calm: 61.0,
      confidence: 58.0,
      frustration: 22.0,
      pressure: 31.0,
      trend: Stable,
    )
  let reading = format_reading(s)
  reading |> string.contains("desperation 34%") |> should.be_true
  reading |> string.contains("calm 61%") |> should.be_true
  reading |> string.contains("confidence 58%") |> should.be_true
  reading |> string.contains("frustration 22%") |> should.be_true
  reading |> string.contains("pressure 31%") |> should.be_true
  reading |> string.contains("↔") |> should.be_true
}

pub fn format_compact_test() {
  let s =
    AffectSnapshot(
      cycle_id: "abcdef12-3456-7890",
      timestamp: "2026-04-04T10:00:00",
      desperation: 12.0,
      calm: 71.0,
      confidence: 58.0,
      frustration: 8.0,
      pressure: 17.0,
      trend: Rising,
    )
  let compact = format_compact(s)
  compact |> string.contains("abcdef12") |> should.be_true
  compact |> string.contains("D:12%") |> should.be_true
  compact |> string.contains("↑") |> should.be_true
}

// ---------------------------------------------------------------------------
// Encode/decode round-trip
// ---------------------------------------------------------------------------

pub fn snapshot_encode_decode_test() {
  let original =
    AffectSnapshot(
      cycle_id: "cycle-abc",
      timestamp: "2026-04-04T10:00:00",
      desperation: 25.5,
      calm: 68.3,
      confidence: 42.0,
      frustration: 15.7,
      pressure: 28.1,
      trend: Falling,
    )
  let encoded = json.to_string(types.encode_snapshot(original))
  let assert Ok(decoded) = json.parse(encoded, types.snapshot_decoder())

  decoded.cycle_id |> should.equal("cycle-abc")
  decoded.desperation |> should.equal(25.5)
  decoded.calm |> should.equal(68.3)
  decoded.confidence |> should.equal(42.0)
  decoded.frustration |> should.equal(15.7)
  decoded.pressure |> should.equal(28.1)
  decoded.trend |> should.equal(Falling)
}
