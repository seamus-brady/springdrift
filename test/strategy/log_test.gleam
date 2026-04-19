// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import strategy/log as strategy_log
import strategy/types.{
  type StrategyEvent, Observed, Proposed, Strategy, StrategyArchived,
  StrategyCreated, StrategyOutcome, StrategyUsed,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn ts(n: Int) -> String {
  // Monotonic-ish timestamps for replay ordering
  let pad = case n < 10 {
    True -> "0"
    False -> ""
  }
  "2026-04-18T10:" <> pad <> int_to_string(n) <> ":00"
}

fn int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    10 -> "10"
    11 -> "11"
    12 -> "12"
    _ -> "99"
  }
}

fn create(id: String, name: String) -> StrategyEvent {
  StrategyCreated(
    timestamp: ts(0),
    strategy_id: id,
    name: name,
    description: "test",
    domain_tags: ["testing"],
    source: Observed,
  )
}

fn used(id: String, n: Int) -> StrategyEvent {
  StrategyUsed(
    timestamp: ts(n),
    strategy_id: id,
    cycle_id: "cycle-" <> int_to_string(n),
    affect_pressure: None,
  )
}

fn outcome(id: String, n: Int, success: Bool) -> StrategyEvent {
  StrategyOutcome(
    timestamp: ts(n),
    strategy_id: id,
    cycle_id: "cycle-" <> int_to_string(n),
    success: success,
  )
}

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

pub fn resolve_empty_test() {
  strategy_log.resolve_from_events([])
  |> should.equal([])
}

pub fn resolve_single_create_test() {
  let events = [create("delegate-then-synth", "Delegate then Synthesise")]
  let strategies = strategy_log.resolve_from_events(events)
  list.length(strategies) |> should.equal(1)
}

pub fn resolve_use_increments_total_uses_test() {
  let events = [create("s1", "S1"), used("s1", 1), used("s1", 2)]
  let strategies = strategy_log.resolve_from_events(events)
  case strategies {
    [s] -> {
      s.total_uses |> should.equal(2)
      s.success_count |> should.equal(0)
    }
    _ -> should.fail()
  }
}

pub fn resolve_outcome_split_test() {
  let events = [
    create("s1", "S1"),
    used("s1", 1),
    outcome("s1", 1, True),
    used("s1", 2),
    outcome("s1", 2, False),
    used("s1", 3),
    outcome("s1", 3, True),
  ]
  let strategies = strategy_log.resolve_from_events(events)
  case strategies {
    [s] -> {
      s.total_uses |> should.equal(3)
      s.success_count |> should.equal(2)
      s.failure_count |> should.equal(1)
    }
    _ -> should.fail()
  }
}

pub fn resolve_archived_clears_active_test() {
  let events = [
    create("s1", "S1"),
    StrategyArchived(timestamp: ts(2), strategy_id: "s1", reason: "obsolete"),
  ]
  let strategies = strategy_log.resolve_from_events(events)
  case strategies {
    [s] -> s.active |> should.equal(False)
    _ -> should.fail()
  }
}

pub fn unknown_strategy_events_are_dropped_test() {
  // StrategyUsed for an id that was never created should be silently
  // ignored — guarantees the resolver doesn't synthesise ghost strategies.
  let events = [used("never-created", 1)]
  strategy_log.resolve_from_events(events)
  |> should.equal([])
}

pub fn affect_pressure_averaged_test() {
  let events = [
    create("s1", "S1"),
    StrategyUsed(
      timestamp: ts(1),
      strategy_id: "s1",
      cycle_id: "c1",
      affect_pressure: Some(0.4),
    ),
    StrategyUsed(
      timestamp: ts(2),
      strategy_id: "s1",
      cycle_id: "c2",
      affect_pressure: Some(0.6),
    ),
  ]
  let strategies = strategy_log.resolve_from_events(events)
  case strategies {
    [s] ->
      case s.avg_pressure {
        Some(p) -> {
          // Allow tiny float wobble.
          let diff = p -. 0.5
          let abs_diff = case diff <. 0.0 {
            True -> -1.0 *. diff
            False -> diff
          }
          case abs_diff <. 0.001 {
            True -> Nil
            False -> should.fail()
          }
        }
        None -> should.fail()
      }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Ranking
// ---------------------------------------------------------------------------

pub fn active_ranked_orders_by_success_rate_test() {
  // s_high: 3/3 -> Laplace 4/5 = 0.8
  // s_low:  1/3 -> Laplace 2/5 = 0.4
  let strategies = [
    Strategy(
      id: "s_low",
      name: "Low",
      description: "",
      domain_tags: [],
      success_count: 1,
      failure_count: 2,
      total_uses: 3,
      avg_pressure: None,
      source: Proposed,
      active: True,
      last_event_at: ts(1),
      superseded_by: None,
    ),
    Strategy(
      id: "s_high",
      name: "High",
      description: "",
      domain_tags: [],
      success_count: 3,
      failure_count: 0,
      total_uses: 3,
      avg_pressure: None,
      source: Proposed,
      active: True,
      last_event_at: ts(1),
      superseded_by: None,
    ),
    Strategy(
      id: "s_archived",
      name: "Archived",
      description: "",
      domain_tags: [],
      success_count: 999,
      failure_count: 0,
      total_uses: 999,
      avg_pressure: None,
      source: Observed,
      active: False,
      last_event_at: ts(1),
      superseded_by: None,
    ),
  ]
  let ranked = strategy_log.active_ranked(strategies)
  list.length(ranked) |> should.equal(2)
  case ranked {
    [first, ..] -> first.id |> should.equal("s_high")
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// JSON round-trip
// ---------------------------------------------------------------------------

pub fn encode_decode_round_trip_test() {
  let events = [
    create("strat-1", "Strategy One"),
    used("strat-1", 1),
    outcome("strat-1", 1, True),
    StrategyArchived(timestamp: ts(2), strategy_id: "strat-1", reason: "test"),
  ]
  // Encode each, parse each back, verify resolver agrees.
  let encoded =
    list.map(events, fn(e) { json.to_string(strategy_log.encode_event(e)) })
  let decoded =
    list.map(encoded, fn(s) {
      case json.parse(s, strategy_log.event_decoder()) {
        Ok(ev) -> ev
        Error(_) -> {
          should.fail()
          panic
        }
      }
    })
  let original_state = strategy_log.resolve_from_events(events)
  let round_tripped_state = strategy_log.resolve_from_events(decoded)
  list.length(original_state)
  |> should.equal(list.length(round_tripped_state))
}
