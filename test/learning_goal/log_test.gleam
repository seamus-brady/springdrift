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
import learning_goal/log as goal_log
import learning_goal/types.{
  AbandonedGoal, AchievedGoal, ActiveGoal, GoalCreated, GoalEvidenceAdded,
  GoalStatusChanged, OperatorDirected, SelfIdentified,
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

fn create(id: String, title: String, priority: Float) {
  GoalCreated(
    timestamp: ts(0),
    goal_id: id,
    title: title,
    rationale: "test rationale",
    acceptance_criteria: "test criteria",
    strategy_id: None,
    priority: priority,
    source: SelfIdentified,
    affect_baseline: None,
  )
}

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

pub fn resolve_empty_test() {
  goal_log.resolve_from_events([])
  |> should.equal([])
}

pub fn resolve_single_create_test() {
  let goals = goal_log.resolve_from_events([create("g1", "First goal", 0.5)])
  case goals {
    [g] -> {
      g.id |> should.equal("g1")
      g.status |> should.equal(ActiveGoal)
      g.evidence |> should.equal([])
    }
    _ -> should.fail()
  }
}

pub fn resolve_evidence_appends_test() {
  let events = [
    create("g1", "G", 0.5),
    GoalEvidenceAdded(timestamp: ts(1), goal_id: "g1", cycle_id: "c-1"),
    GoalEvidenceAdded(timestamp: ts(2), goal_id: "g1", cycle_id: "c-2"),
  ]
  case goal_log.resolve_from_events(events) {
    [g] -> {
      list.length(g.evidence) |> should.equal(2)
      list.contains(g.evidence, "c-1") |> should.equal(True)
      list.contains(g.evidence, "c-2") |> should.equal(True)
    }
    _ -> should.fail()
  }
}

pub fn resolve_status_change_test() {
  let events = [
    create("g1", "G", 0.5),
    GoalStatusChanged(
      timestamp: ts(1),
      goal_id: "g1",
      new_status: AchievedGoal,
      reason: "criteria met",
    ),
  ]
  case goal_log.resolve_from_events(events) {
    [g] -> g.status |> should.equal(AchievedGoal)
    _ -> should.fail()
  }
}

pub fn unknown_goal_events_dropped_test() {
  // Evidence/status for a goal that was never created is silently dropped.
  let events = [
    GoalEvidenceAdded(timestamp: ts(1), goal_id: "ghost", cycle_id: "c"),
    GoalStatusChanged(
      timestamp: ts(2),
      goal_id: "ghost",
      new_status: AbandonedGoal,
      reason: "n/a",
    ),
  ]
  goal_log.resolve_from_events(events) |> should.equal([])
}

// ---------------------------------------------------------------------------
// Ranking
// ---------------------------------------------------------------------------

pub fn active_ranked_orders_by_priority_descending_test() {
  let events = [
    create("low", "Low", 0.2),
    create("high", "High", 0.9),
    create("mid", "Mid", 0.5),
    create("done", "Done", 1.0),
    GoalStatusChanged(
      timestamp: ts(1),
      goal_id: "done",
      new_status: AchievedGoal,
      reason: "ok",
    ),
  ]
  let resolved = goal_log.resolve_from_events(events)
  let ranked = goal_log.active_ranked(resolved)
  // 3 active (low/mid/high); done is achieved and excluded
  list.length(ranked) |> should.equal(3)
  case ranked {
    [first, ..] -> first.id |> should.equal("high")
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// JSON round-trip
// ---------------------------------------------------------------------------

pub fn encode_decode_round_trip_test() {
  let original = [
    create("g1", "G1", 0.7),
    GoalEvidenceAdded(timestamp: ts(1), goal_id: "g1", cycle_id: "c-1"),
    GoalStatusChanged(
      timestamp: ts(2),
      goal_id: "g1",
      new_status: AchievedGoal,
      reason: "done",
    ),
  ]
  let encoded =
    list.map(original, fn(e) { json.to_string(goal_log.encode_event(e)) })
  let decoded =
    list.map(encoded, fn(s) {
      case json.parse(s, goal_log.event_decoder()) {
        Ok(ev) -> ev
        Error(_) -> {
          should.fail()
          panic
        }
      }
    })
  let original_state = goal_log.resolve_from_events(original)
  let round_state = goal_log.resolve_from_events(decoded)
  list.length(original_state) |> should.equal(list.length(round_state))
}

pub fn create_with_strategy_link_test() {
  let event =
    GoalCreated(
      timestamp: ts(0),
      goal_id: "g1",
      title: "Linked goal",
      rationale: "tied to strategy",
      acceptance_criteria: "see strategy outcome",
      strategy_id: Some("strat-1"),
      priority: 0.6,
      source: OperatorDirected,
      affect_baseline: None,
    )
  case goal_log.resolve_from_events([event]) {
    [g] -> g.strategy_id |> should.equal(Some("strat-1"))
    _ -> should.fail()
  }
}
