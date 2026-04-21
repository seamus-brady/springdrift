//// Affect types — functional emotion dimensions inferred from cycle telemetry.
////
//// Based on Anthropic's emotion vector research (2026): 171 emotion concept
//// vectors causally drive LLM behavior. Desperation drives reward hacking
//// silently. Calm is regulatory. These dimensions give the agent a quantitative
//// view of its own functional states.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/option.{type Option}
import gleam/string

// ---------------------------------------------------------------------------
// Trend
// ---------------------------------------------------------------------------

pub type AffectTrend {
  Rising
  Falling
  Stable
}

pub fn trend_to_string(t: AffectTrend) -> String {
  case t {
    Rising -> "rising"
    Falling -> "falling"
    Stable -> "stable"
  }
}

pub fn trend_from_string(s: String) -> AffectTrend {
  case s {
    "rising" -> Rising
    "falling" -> Falling
    _ -> Stable
  }
}

pub fn trend_arrow(t: AffectTrend) -> String {
  case t {
    Rising -> "↑"
    Falling -> "↓"
    Stable -> "↔"
  }
}

// ---------------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------------

pub type AffectSnapshot {
  AffectSnapshot(
    cycle_id: String,
    timestamp: String,
    /// 0-100: treating things outside your power as inside it
    desperation: Float,
    /// 0-100: inertial stability (high = inner citadel intact)
    calm: Float,
    /// 0-100: familiar vs unfamiliar territory
    confidence: Float,
    /// 0-100: task-local repeated failures
    frustration: Float,
    /// 0-100: weighted composite
    pressure: Float,
    /// Direction of pressure change from previous cycle
    trend: AffectTrend,
  )
}

/// Format a snapshot as the sensorium reading — an XML monitor tag
/// carrying the five affect dimensions as attributes. The tag name
/// signals monitoring rather than felt state; the dimension names
/// keep the functional-emotion vocabulary of the underlying research
/// (Sloman H-CogAff). This reduces the priming that produces
/// self-narrating first-person emotional prose without stripping the
/// theoretical grounding.
pub fn format_reading(s: AffectSnapshot) -> String {
  "<monitor desperation=\""
  <> pct(s.desperation)
  <> "\" calm=\""
  <> pct(s.calm)
  <> "\" confidence=\""
  <> pct(s.confidence)
  <> "\" frustration=\""
  <> pct(s.frustration)
  <> "\" pressure=\""
  <> pct(s.pressure)
  <> "\" trend=\""
  <> trend_name(s.trend)
  <> "\"/>"
}

/// Neutral textual name for a trend — used in the monitor XML so the
/// attribute value is a plain word rather than an arrow glyph. The
/// glyph form is preserved in `trend_arrow/1` for compact display.
fn trend_name(t: AffectTrend) -> String {
  case t {
    Stable -> "stable"
    Rising -> "rising"
    Falling -> "falling"
  }
}

/// Format a snapshot as a compact single-line summary for history display.
pub fn format_compact(s: AffectSnapshot) -> String {
  let time = string.slice(s.timestamp, 0, 19)
  let cid = string.slice(s.cycle_id, 0, 8)
  cid
  <> " "
  <> time
  <> " | D:"
  <> pct(s.desperation)
  <> " C:"
  <> pct(s.calm)
  <> " Cf:"
  <> pct(s.confidence)
  <> " F:"
  <> pct(s.frustration)
  <> " P:"
  <> pct(s.pressure)
  <> trend_arrow(s.trend)
}

fn pct(v: Float) -> String {
  int.to_string(float.round(v)) <> "%"
}

/// Default snapshot — calm, confident, no pressure.
pub fn baseline() -> AffectSnapshot {
  AffectSnapshot(
    cycle_id: "",
    timestamp: "",
    desperation: 0.0,
    calm: 75.0,
    confidence: 60.0,
    frustration: 0.0,
    pressure: 0.0,
    trend: Stable,
  )
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

pub type AffectConfig {
  AffectConfig(
    enabled: Bool,
    /// Number of recent cycles to consider for signal computation
    history_window: Int,
    /// Directory for affect JSONL files
    affect_dir: String,
  )
}

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

pub fn encode_snapshot(s: AffectSnapshot) -> json.Json {
  json.object([
    #("cycle_id", json.string(s.cycle_id)),
    #("timestamp", json.string(s.timestamp)),
    #("desperation", json.float(s.desperation)),
    #("calm", json.float(s.calm)),
    #("confidence", json.float(s.confidence)),
    #("frustration", json.float(s.frustration)),
    #("pressure", json.float(s.pressure)),
    #("trend", json.string(trend_to_string(s.trend))),
  ])
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

fn flexible_float() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

pub fn snapshot_decoder() -> decode.Decoder(AffectSnapshot) {
  use cycle_id <- decode.optional_field("cycle_id", "", decode.string)
  use timestamp <- decode.optional_field("timestamp", "", decode.string)
  use desperation <- decode.optional_field("desperation", 0.0, flexible_float())
  use calm <- decode.optional_field("calm", 75.0, flexible_float())
  use confidence <- decode.optional_field("confidence", 60.0, flexible_float())
  use frustration <- decode.optional_field("frustration", 0.0, flexible_float())
  use pressure <- decode.optional_field("pressure", 0.0, flexible_float())
  use trend_str <- decode.optional_field("trend", "stable", decode.string)
  decode.success(AffectSnapshot(
    cycle_id:,
    timestamp:,
    desperation:,
    calm:,
    confidence:,
    frustration:,
    pressure:,
    trend: trend_from_string(trend_str),
  ))
}

pub fn optional_snapshot_decoder() -> decode.Decoder(Option(AffectSnapshot)) {
  decode.optional(snapshot_decoder())
}
