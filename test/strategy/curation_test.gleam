////
//// Tests for the three curation events (Renamed, DescriptionUpdated,
//// Superseded) and the pruning helpers (over_cap, prune_candidates).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import strategy/log as strategy_log
import strategy/types.{
  Observed, OperatorDefined, Strategy, StrategyArchived, StrategyCreated,
  StrategyDescriptionUpdated, StrategyOutcome, StrategyRenamed,
  StrategySuperseded, StrategyUsed,
}

fn ts(n: Int) -> String {
  let pad = case n < 10 {
    True -> "0"
    False -> ""
  }
  "2026-04-19T10:" <> pad <> int_to_str(n) <> ":00"
}

fn int_to_str(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    _ -> "9"
  }
}

fn create(id: String, name: String) {
  StrategyCreated(
    timestamp: ts(0),
    strategy_id: id,
    name: name,
    description: "original",
    domain_tags: ["testing"],
    source: Observed,
  )
}

// ---------------------------------------------------------------------------
// Rename
// ---------------------------------------------------------------------------

pub fn rename_updates_name_keeps_id_test() {
  let events = [
    create("s1", "Old Name"),
    StrategyRenamed(
      timestamp: ts(1),
      strategy_id: "s1",
      new_name: "Sharper Name",
      reason: "clearer",
    ),
  ]
  case strategy_log.resolve_from_events(events) {
    [s] -> {
      s.id |> should.equal("s1")
      s.name |> should.equal("Sharper Name")
    }
    _ -> should.fail()
  }
}

pub fn rename_unknown_id_is_dropped_test() {
  let events = [
    StrategyRenamed(
      timestamp: ts(1),
      strategy_id: "ghost",
      new_name: "n/a",
      reason: "n/a",
    ),
  ]
  strategy_log.resolve_from_events(events) |> should.equal([])
}

// ---------------------------------------------------------------------------
// Description update
// ---------------------------------------------------------------------------

pub fn description_update_replaces_description_test() {
  let events = [
    create("s1", "N"),
    StrategyDescriptionUpdated(
      timestamp: ts(1),
      strategy_id: "s1",
      new_description: "when pressure > 0.7, delegate first",
      reason: "sharpen",
    ),
  ]
  case strategy_log.resolve_from_events(events) {
    [s] -> s.description |> should.equal("when pressure > 0.7, delegate first")
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Supersede — the meaty one
// ---------------------------------------------------------------------------

pub fn supersede_merges_counts_into_successor_test() {
  let events = [
    create("old", "Old"),
    create("new", "New"),
    // Give each some history
    StrategyUsed(
      timestamp: ts(1),
      strategy_id: "old",
      cycle_id: "c1",
      affect_pressure: None,
    ),
    StrategyOutcome(
      timestamp: ts(1),
      strategy_id: "old",
      cycle_id: "c1",
      success: True,
    ),
    StrategyUsed(
      timestamp: ts(2),
      strategy_id: "old",
      cycle_id: "c2",
      affect_pressure: None,
    ),
    StrategyOutcome(
      timestamp: ts(2),
      strategy_id: "old",
      cycle_id: "c2",
      success: False,
    ),
    StrategyUsed(
      timestamp: ts(3),
      strategy_id: "new",
      cycle_id: "c3",
      affect_pressure: None,
    ),
    StrategyOutcome(
      timestamp: ts(3),
      strategy_id: "new",
      cycle_id: "c3",
      success: True,
    ),
    // Now supersede old by new
    StrategySuperseded(
      timestamp: ts(4),
      old_strategy_id: "old",
      new_strategy_id: "new",
      reason: "duplicates",
    ),
  ]
  let resolved = strategy_log.resolve_from_events(events)
  let old_ = list.find(resolved, fn(s) { s.id == "old" })
  let new_ = list.find(resolved, fn(s) { s.id == "new" })
  case old_, new_ {
    Ok(o), Ok(n) -> {
      o.active |> should.equal(False)
      o.superseded_by |> should.equal(Some("new"))
      // Successor absorbs predecessor counts
      n.active |> should.equal(True)
      n.total_uses |> should.equal(3)
      n.success_count |> should.equal(2)
      n.failure_count |> should.equal(1)
    }
    _, _ -> should.fail()
  }
}

pub fn supersede_drops_when_either_id_unknown_test() {
  let events = [
    create("new", "New"),
    StrategySuperseded(
      timestamp: ts(1),
      old_strategy_id: "ghost",
      new_strategy_id: "new",
      reason: "typo",
    ),
  ]
  case strategy_log.resolve_from_events(events) {
    [s] -> {
      // new stays active with no merged counts
      s.id |> should.equal("new")
      s.active |> should.equal(True)
      s.total_uses |> should.equal(0)
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Pruning — over_cap + prune_candidates
// ---------------------------------------------------------------------------

fn active_strategy(id: String, uses: Int, successes: Int, last_event: String) {
  Strategy(
    id: id,
    name: id,
    description: "",
    domain_tags: [],
    success_count: successes,
    failure_count: uses - successes,
    total_uses: uses,
    avg_pressure: None,
    source: OperatorDefined,
    active: True,
    last_event_at: last_event,
    superseded_by: None,
  )
}

pub fn over_cap_detects_excess_test() {
  let strategies = [
    active_strategy("s1", 0, 0, ts(0)),
    active_strategy("s2", 0, 0, ts(0)),
    active_strategy("s3", 0, 0, ts(0)),
  ]
  let cfg =
    strategy_log.PruneConfig(
      max_active: 2,
      low_success_threshold: 0.0,
      low_success_min_uses: 0,
      stale_archive_days: 0,
    )
  strategy_log.over_cap(strategies, cfg) |> should.equal(True)
}

pub fn over_cap_respects_zero_as_disabled_test() {
  let strategies = [active_strategy("s1", 0, 0, ts(0))]
  let cfg =
    strategy_log.PruneConfig(
      max_active: 0,
      low_success_threshold: 0.0,
      low_success_min_uses: 0,
      stale_archive_days: 0,
    )
  strategy_log.over_cap(strategies, cfg) |> should.equal(False)
}

pub fn prune_candidates_flags_low_success_test() {
  // One with enough evidence + low success -> candidate.
  // One with enough evidence + high success -> keep.
  // One with too-few uses -> keep (below min_uses threshold).
  let strategies = [
    // 10 uses, 2 successes, Laplace (3/12) = 0.25 → below 0.4 ✓
    active_strategy("failing", 10, 2, ts(1)),
    // 10 uses, 9 successes, Laplace (10/12) = 0.83 → above 0.4 ✗
    active_strategy("thriving", 10, 9, ts(1)),
    // 3 uses, 0 successes → below min_uses, skip
    active_strategy("too_new", 3, 0, ts(1)),
  ]
  let cfg =
    strategy_log.PruneConfig(
      max_active: 100,
      low_success_threshold: 0.4,
      low_success_min_uses: 10,
      stale_archive_days: 0,
    )
  let events =
    strategy_log.prune_candidates(strategies, cfg, ts(2), fn(_) { 0 })
  // Exactly one archive event, for "failing".
  case events {
    [StrategyArchived(strategy_id:, ..)] ->
      strategy_id |> should.equal("failing")
    _ -> should.fail()
  }
}

pub fn prune_candidates_flags_stale_test() {
  let strategies = [
    // Says we're 100 days since last event.
    active_strategy("dusty", 5, 3, "2026-01-01"),
  ]
  let cfg =
    strategy_log.PruneConfig(
      max_active: 100,
      low_success_threshold: 0.0,
      low_success_min_uses: 0,
      stale_archive_days: 60,
    )
  let events =
    strategy_log.prune_candidates(strategies, cfg, ts(2), fn(_) { 100 })
  case events {
    [StrategyArchived(strategy_id:, ..)] -> strategy_id |> should.equal("dusty")
    _ -> should.fail()
  }
}
