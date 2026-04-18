//// Append-only Strategy event log — daily JSONL files in
//// .springdrift/memory/strategies/.
////
//// Events use daily rotation (YYYY-MM-DD-strategies.jsonl) like facts and
//// CBR. `resolve_current` replays the log chronologically to derive the
//// current `List(Strategy)`.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order.{Eq}
import gleam/string
import simplifile
import slog
import strategy/types.{
  type Strategy, type StrategyEvent, type StrategySource, Observed,
  OperatorDefined, Proposed, Strategy, StrategyArchived, StrategyCreated,
  StrategyOutcome, StrategyUsed,
}

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

/// Append a StrategyEvent to a dated JSONL file.
pub fn append(dir: String, event: StrategyEvent) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> "-strategies.jsonl"
  let json_str = json.to_string(encode_event(event))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug(
        "strategy/log",
        "append",
        "Appended " <> event_kind(event),
        None,
      )
    Error(e) ->
      slog.log_error(
        "strategy/log",
        "append",
        "Failed to append: " <> simplifile.describe_error(e),
        None,
      )
  }
}

fn event_kind(e: StrategyEvent) -> String {
  case e {
    StrategyCreated(..) -> "created"
    StrategyUsed(..) -> "used"
    StrategyOutcome(..) -> "outcome"
    StrategyArchived(..) -> "archived"
  }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// Load events for one date.
pub fn load_date(dir: String, date: String) -> List(StrategyEvent) {
  let path = dir <> "/" <> date <> "-strategies.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_jsonl(content)
  }
}

/// Load all events from all dated files, chronologically.
pub fn load_all(dir: String) -> List(StrategyEvent) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) ->
      files
      |> list.filter(fn(f) { string.ends_with(f, "-strategies.jsonl") })
      |> list.sort(string.compare)
      |> list.flat_map(fn(f) {
        let date = string.drop_end(f, 17)
        load_date(dir, date)
      })
  }
}

// ---------------------------------------------------------------------------
// Resolve current state
// ---------------------------------------------------------------------------

/// Replay the event log to derive the current `List(Strategy)`.
pub fn resolve_current(dir: String) -> List(Strategy) {
  resolve_from_events(load_all(dir))
}

/// Pure resolver — given an event list (chronological), derive strategies.
pub fn resolve_from_events(events: List(StrategyEvent)) -> List(Strategy) {
  let acc =
    list.fold(events, dict.new(), fn(state, ev) { apply_event(state, ev) })
  acc
  |> dict.values
  |> list.map(fn(a) { a.base })
}

type AccState =
  Dict(String, StrategyAcc)

type StrategyAcc {
  StrategyAcc(base: Strategy, pressure_sum: Float, pressure_count: Int)
}

fn apply_event(state: AccState, event: StrategyEvent) -> AccState {
  case event {
    StrategyCreated(
      timestamp:,
      strategy_id:,
      name:,
      description:,
      domain_tags:,
      source:,
    ) ->
      dict.insert(
        state,
        strategy_id,
        StrategyAcc(
          base: Strategy(
            id: strategy_id,
            name: name,
            description: description,
            domain_tags: domain_tags,
            success_count: 0,
            failure_count: 0,
            total_uses: 0,
            avg_pressure: None,
            source: source,
            active: True,
            last_event_at: timestamp,
          ),
          pressure_sum: 0.0,
          pressure_count: 0,
        ),
      )
    StrategyUsed(timestamp:, strategy_id:, cycle_id: _, affect_pressure:) ->
      case dict.get(state, strategy_id) {
        Error(_) -> state
        Ok(acc) -> {
          let #(sum, count) = case affect_pressure {
            Some(p) -> #(acc.pressure_sum +. p, acc.pressure_count + 1)
            None -> #(acc.pressure_sum, acc.pressure_count)
          }
          let avg = case count {
            0 -> None
            n -> Some(sum /. int.to_float(n))
          }
          let next =
            StrategyAcc(
              base: Strategy(
                ..acc.base,
                total_uses: acc.base.total_uses + 1,
                avg_pressure: avg,
                last_event_at: timestamp,
              ),
              pressure_sum: sum,
              pressure_count: count,
            )
          dict.insert(state, strategy_id, next)
        }
      }
    StrategyOutcome(timestamp:, strategy_id:, cycle_id: _, success:) ->
      case dict.get(state, strategy_id) {
        Error(_) -> state
        Ok(acc) -> {
          let base = acc.base
          let next_base = case success {
            True ->
              Strategy(
                ..base,
                success_count: base.success_count + 1,
                last_event_at: timestamp,
              )
            False ->
              Strategy(
                ..base,
                failure_count: base.failure_count + 1,
                last_event_at: timestamp,
              )
          }
          dict.insert(state, strategy_id, StrategyAcc(..acc, base: next_base))
        }
      }
    StrategyArchived(timestamp:, strategy_id:, reason: _) ->
      case dict.get(state, strategy_id) {
        Error(_) -> state
        Ok(acc) ->
          dict.insert(
            state,
            strategy_id,
            StrategyAcc(
              ..acc,
              base: Strategy(
                ..acc.base,
                active: False,
                last_event_at: timestamp,
              ),
            ),
          )
      }
  }
}

// ---------------------------------------------------------------------------
// Querying derived state
// ---------------------------------------------------------------------------

/// Active strategies sorted by descending success rate (Laplace-smoothed),
/// ties broken by total_uses descending.
pub fn active_ranked(strategies: List(Strategy)) -> List(Strategy) {
  strategies
  |> list.filter(fn(s) { s.active })
  |> list.sort(fn(a, b) {
    let sa = success_rate(a)
    let sb = success_rate(b)
    case float.compare(sb, sa) {
      Eq -> int.compare(b.total_uses, a.total_uses)
      order -> order
    }
  })
}

/// Laplace-smoothed success rate: (success + 1) / (success + failure + 2).
/// Returns 0.5 for unused strategies (the prior).
pub fn success_rate(s: Strategy) -> Float {
  let succ = int.to_float(s.success_count) +. 1.0
  let total = int.to_float(s.success_count + s.failure_count) +. 2.0
  succ /. total
}

// ---------------------------------------------------------------------------
// JSONL parsing
// ---------------------------------------------------------------------------

fn parse_jsonl(content: String) -> List(StrategyEvent) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, event_decoder()) {
      Ok(ev) -> Ok(ev)
      Error(_) -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// JSON encoders
// ---------------------------------------------------------------------------

pub fn encode_event(event: StrategyEvent) -> json.Json {
  case event {
    StrategyCreated(
      timestamp:,
      strategy_id:,
      name:,
      description:,
      domain_tags:,
      source:,
    ) ->
      json.object([
        #("event", json.string("created")),
        #("timestamp", json.string(timestamp)),
        #("strategy_id", json.string(strategy_id)),
        #("name", json.string(name)),
        #("description", json.string(description)),
        #("domain_tags", json.array(domain_tags, json.string)),
        #("source", json.string(encode_source(source))),
      ])
    StrategyUsed(timestamp:, strategy_id:, cycle_id:, affect_pressure:) ->
      json.object([
        #("event", json.string("used")),
        #("timestamp", json.string(timestamp)),
        #("strategy_id", json.string(strategy_id)),
        #("cycle_id", json.string(cycle_id)),
        #("affect_pressure", case affect_pressure {
          Some(p) -> json.float(p)
          None -> json.null()
        }),
      ])
    StrategyOutcome(timestamp:, strategy_id:, cycle_id:, success:) ->
      json.object([
        #("event", json.string("outcome")),
        #("timestamp", json.string(timestamp)),
        #("strategy_id", json.string(strategy_id)),
        #("cycle_id", json.string(cycle_id)),
        #("success", json.bool(success)),
      ])
    StrategyArchived(timestamp:, strategy_id:, reason:) ->
      json.object([
        #("event", json.string("archived")),
        #("timestamp", json.string(timestamp)),
        #("strategy_id", json.string(strategy_id)),
        #("reason", json.string(reason)),
      ])
  }
}

fn encode_source(s: StrategySource) -> String {
  case s {
    Observed -> "observed"
    Proposed -> "proposed"
    OperatorDefined -> "operator_defined"
  }
}

fn decode_source(s: String) -> StrategySource {
  case s {
    "observed" -> Observed
    "proposed" -> Proposed
    "operator_defined" -> OperatorDefined
    _ -> Observed
  }
}

// ---------------------------------------------------------------------------
// JSON decoders — lenient with defaults
// ---------------------------------------------------------------------------

pub fn event_decoder() -> decode.Decoder(StrategyEvent) {
  use kind <- decode.field("event", decode.string)
  case kind {
    "created" -> created_decoder()
    "used" -> used_decoder()
    "outcome" -> outcome_decoder()
    "archived" -> archived_decoder()
    _ -> decode.failure(StrategyArchived("", "", ""), "unknown event kind")
  }
}

fn created_decoder() -> decode.Decoder(StrategyEvent) {
  use timestamp <- decode.field("timestamp", decode.string)
  use strategy_id <- decode.field("strategy_id", decode.string)
  use name <- decode.field(
    "name",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use description <- decode.field(
    "description",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use domain_tags <- decode.field(
    "domain_tags",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use source <- decode.field(
    "source",
    decode.optional(decode.string)
      |> decode.map(fn(o) { decode_source(option.unwrap(o, "observed")) }),
  )
  decode.success(StrategyCreated(
    timestamp:,
    strategy_id:,
    name:,
    description:,
    domain_tags:,
    source:,
  ))
}

fn used_decoder() -> decode.Decoder(StrategyEvent) {
  use timestamp <- decode.field("timestamp", decode.string)
  use strategy_id <- decode.field("strategy_id", decode.string)
  use cycle_id <- decode.field(
    "cycle_id",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use affect_pressure <- decode.optional_field(
    "affect_pressure",
    None,
    decode.optional(decode.float),
  )
  decode.success(StrategyUsed(
    timestamp:,
    strategy_id:,
    cycle_id:,
    affect_pressure:,
  ))
}

fn outcome_decoder() -> decode.Decoder(StrategyEvent) {
  use timestamp <- decode.field("timestamp", decode.string)
  use strategy_id <- decode.field("strategy_id", decode.string)
  use cycle_id <- decode.field(
    "cycle_id",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use success <- decode.field(
    "success",
    decode.optional(decode.bool) |> decode.map(option.unwrap(_, False)),
  )
  decode.success(StrategyOutcome(timestamp:, strategy_id:, cycle_id:, success:))
}

fn archived_decoder() -> decode.Decoder(StrategyEvent) {
  use timestamp <- decode.field("timestamp", decode.string)
  use strategy_id <- decode.field("strategy_id", decode.string)
  use reason <- decode.field(
    "reason",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  decode.success(StrategyArchived(timestamp:, strategy_id:, reason:))
}
