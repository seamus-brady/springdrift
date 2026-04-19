//// Append-only Learning Goals event log — daily JSONL files in
//// .springdrift/memory/learning_goals/.
////
//// `resolve_current` replays the log to derive the current
//// `List(LearningGoal)`. Events are immutable; status changes are
//// expressed as new events, not edits.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/string
import learning_goal/types.{
  type GoalEvent, type GoalSource, type GoalStatus, type LearningGoal,
  AbandonedGoal, AchievedGoal, ActiveGoal, GoalCreated, GoalEvidenceAdded,
  GoalStatusChanged, LearningGoal, OperatorDirected, PatternMined, PausedGoal,
  RemembrancerSuggested, SelfIdentified,
}
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

pub fn append(dir: String, event: GoalEvent) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> "-goals.jsonl"
  let json_str = json.to_string(encode_event(event))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug(
        "learning_goal/log",
        "append",
        "Appended " <> event_kind(event),
        None,
      )
    Error(e) ->
      slog.log_error(
        "learning_goal/log",
        "append",
        "Failed to append: " <> simplifile.describe_error(e),
        None,
      )
  }
}

fn event_kind(e: GoalEvent) -> String {
  case e {
    GoalCreated(..) -> "created"
    GoalEvidenceAdded(..) -> "evidence_added"
    GoalStatusChanged(..) -> "status_changed"
  }
}

// ---------------------------------------------------------------------------
// Loading + resolve
// ---------------------------------------------------------------------------

pub fn load_date(dir: String, date: String) -> List(GoalEvent) {
  let path = dir <> "/" <> date <> "-goals.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_jsonl(content)
  }
}

pub fn load_all(dir: String) -> List(GoalEvent) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) ->
      files
      |> list.filter(fn(f) { string.ends_with(f, "-goals.jsonl") })
      |> list.sort(string.compare)
      |> list.flat_map(fn(f) {
        let date = string.drop_end(f, 12)
        load_date(dir, date)
      })
  }
}

pub fn resolve_current(dir: String) -> List(LearningGoal) {
  resolve_from_events(load_all(dir))
}

pub fn resolve_from_events(events: List(GoalEvent)) -> List(LearningGoal) {
  let acc =
    list.fold(events, dict.new(), fn(state, ev) { apply_event(state, ev) })
  dict.values(acc)
}

fn apply_event(
  state: Dict(String, LearningGoal),
  event: GoalEvent,
) -> Dict(String, LearningGoal) {
  case event {
    GoalCreated(
      timestamp:,
      goal_id:,
      title:,
      rationale:,
      acceptance_criteria:,
      strategy_id:,
      priority:,
      source:,
      affect_baseline:,
    ) ->
      dict.insert(
        state,
        goal_id,
        LearningGoal(
          id: goal_id,
          title: title,
          rationale: rationale,
          acceptance_criteria: acceptance_criteria,
          strategy_id: strategy_id,
          priority: priority,
          status: ActiveGoal,
          evidence: [],
          source: source,
          created_at: timestamp,
          last_event_at: timestamp,
          affect_baseline: affect_baseline,
        ),
      )
    GoalEvidenceAdded(timestamp:, goal_id:, cycle_id:) ->
      case dict.get(state, goal_id) {
        Error(_) -> state
        Ok(g) ->
          dict.insert(
            state,
            goal_id,
            LearningGoal(
              ..g,
              evidence: list.append(g.evidence, [cycle_id]),
              last_event_at: timestamp,
            ),
          )
      }
    GoalStatusChanged(timestamp:, goal_id:, new_status:, reason: _) ->
      case dict.get(state, goal_id) {
        Error(_) -> state
        Ok(g) ->
          dict.insert(
            state,
            goal_id,
            LearningGoal(..g, status: new_status, last_event_at: timestamp),
          )
      }
  }
}

/// Active goals ranked by priority descending.
pub fn active_ranked(goals: List(LearningGoal)) -> List(LearningGoal) {
  goals
  |> list.filter(fn(g) { g.status == ActiveGoal })
  |> list.sort(fn(a, b) { priority_desc(a.priority, b.priority) })
}

fn priority_desc(a: Float, b: Float) -> Order {
  case a <. b {
    True -> Gt
    False ->
      case a >. b {
        True -> Lt
        False -> Eq
      }
  }
}

// ---------------------------------------------------------------------------
// JSONL parsing
// ---------------------------------------------------------------------------

fn parse_jsonl(content: String) -> List(GoalEvent) {
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

pub fn encode_event(event: GoalEvent) -> json.Json {
  case event {
    GoalCreated(
      timestamp:,
      goal_id:,
      title:,
      rationale:,
      acceptance_criteria:,
      strategy_id:,
      priority:,
      source:,
      affect_baseline:,
    ) ->
      json.object([
        #("event", json.string("created")),
        #("timestamp", json.string(timestamp)),
        #("goal_id", json.string(goal_id)),
        #("title", json.string(title)),
        #("rationale", json.string(rationale)),
        #("acceptance_criteria", json.string(acceptance_criteria)),
        #("strategy_id", case strategy_id {
          Some(id) -> json.string(id)
          None -> json.null()
        }),
        #("priority", json.float(priority)),
        #("source", json.string(encode_source(source))),
        #("affect_baseline", case affect_baseline {
          Some(p) -> json.float(p)
          None -> json.null()
        }),
      ])
    GoalEvidenceAdded(timestamp:, goal_id:, cycle_id:) ->
      json.object([
        #("event", json.string("evidence_added")),
        #("timestamp", json.string(timestamp)),
        #("goal_id", json.string(goal_id)),
        #("cycle_id", json.string(cycle_id)),
      ])
    GoalStatusChanged(timestamp:, goal_id:, new_status:, reason:) ->
      json.object([
        #("event", json.string("status_changed")),
        #("timestamp", json.string(timestamp)),
        #("goal_id", json.string(goal_id)),
        #("new_status", json.string(encode_status(new_status))),
        #("reason", json.string(reason)),
      ])
  }
}

pub fn encode_source(s: GoalSource) -> String {
  case s {
    SelfIdentified -> "self_identified"
    RemembrancerSuggested -> "remembrancer_suggested"
    OperatorDirected -> "operator_directed"
    PatternMined -> "pattern_mined"
  }
}

pub fn decode_source(s: String) -> GoalSource {
  case s {
    "self_identified" -> SelfIdentified
    "remembrancer_suggested" -> RemembrancerSuggested
    "operator_directed" -> OperatorDirected
    "pattern_mined" -> PatternMined
    _ -> SelfIdentified
  }
}

pub fn encode_status(s: GoalStatus) -> String {
  case s {
    ActiveGoal -> "active"
    AchievedGoal -> "achieved"
    AbandonedGoal -> "abandoned"
    PausedGoal -> "paused"
  }
}

pub fn decode_status(s: String) -> GoalStatus {
  case s {
    "active" -> ActiveGoal
    "achieved" -> AchievedGoal
    "abandoned" -> AbandonedGoal
    "paused" -> PausedGoal
    _ -> ActiveGoal
  }
}

// ---------------------------------------------------------------------------
// JSON decoders
// ---------------------------------------------------------------------------

pub fn event_decoder() -> decode.Decoder(GoalEvent) {
  use kind <- decode.field("event", decode.string)
  case kind {
    "created" -> created_decoder()
    "evidence_added" -> evidence_decoder()
    "status_changed" -> status_decoder()
    _ -> decode.failure(GoalEvidenceAdded("", "", ""), "unknown event kind")
  }
}

fn created_decoder() -> decode.Decoder(GoalEvent) {
  use timestamp <- decode.field("timestamp", decode.string)
  use goal_id <- decode.field("goal_id", decode.string)
  use title <- decode.field(
    "title",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use rationale <- decode.field(
    "rationale",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use acceptance_criteria <- decode.field(
    "acceptance_criteria",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use strategy_id <- decode.optional_field(
    "strategy_id",
    None,
    decode.optional(decode.string),
  )
  use priority <- decode.optional_field("priority", 0.5, decode.float)
  use source <- decode.field(
    "source",
    decode.optional(decode.string)
      |> decode.map(fn(s) { decode_source(option.unwrap(s, "self_identified")) }),
  )
  use affect_baseline <- decode.optional_field(
    "affect_baseline",
    None,
    decode.optional(decode.float),
  )
  decode.success(GoalCreated(
    timestamp:,
    goal_id:,
    title:,
    rationale:,
    acceptance_criteria:,
    strategy_id:,
    priority:,
    source:,
    affect_baseline:,
  ))
}

fn evidence_decoder() -> decode.Decoder(GoalEvent) {
  use timestamp <- decode.field("timestamp", decode.string)
  use goal_id <- decode.field("goal_id", decode.string)
  use cycle_id <- decode.field("cycle_id", decode.string)
  decode.success(GoalEvidenceAdded(timestamp:, goal_id:, cycle_id:))
}

fn status_decoder() -> decode.Decoder(GoalEvent) {
  use timestamp <- decode.field("timestamp", decode.string)
  use goal_id <- decode.field("goal_id", decode.string)
  use new_status <- decode.field(
    "new_status",
    decode.optional(decode.string)
      |> decode.map(fn(s) { decode_status(option.unwrap(s, "active")) }),
  )
  use reason <- decode.field(
    "reason",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  decode.success(GoalStatusChanged(timestamp:, goal_id:, new_status:, reason:))
}
