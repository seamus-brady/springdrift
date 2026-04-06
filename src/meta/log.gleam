//// Meta observer JSONL persistence — append-only log for cross-session continuity.
////
//// Each MetaObservation is appended after the observer processes it.
//// At startup, recent observations are replayed to restore MetaState.
//// Observations older than `max_days` are dropped during replay (decay).
//// Threshold adaptations decay toward config defaults over time.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import meta/types.{
  type FalsePositiveAnnotation, type MetaConfig, type MetaObservation,
  type MetaState,
}
import simplifile
import slog

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

@external(erlang, "springdrift_ffi", "days_between")
fn days_between(date_a: String, date_b: String) -> Int

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

fn meta_dir() -> String {
  case get_env("SPRINGDRIFT_DATA_DIR") {
    Ok(dir) -> dir <> "/memory/meta"
    Error(_) -> ".springdrift/memory/meta"
  }
}

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

/// Append a meta observation to today's JSONL file.
pub fn append(obs: MetaObservation) -> Nil {
  let dir = meta_dir()
  let date = get_date()
  let path = dir <> "/" <> date <> "-meta.jsonl"
  let _ = simplifile.create_directory_all(dir)
  let entry = encode_observation(obs)
  case simplifile.append(path, json.to_string(entry) <> "\n") {
    Ok(_) -> Nil
    Error(e) ->
      slog.log_error(
        "meta/log",
        "append",
        "Failed to append: " <> simplifile.describe_error(e),
        Some(obs.cycle_id),
      )
  }
}

/// Append a false positive annotation to today's JSONL file.
pub fn append_false_positive(fp: FalsePositiveAnnotation) -> Nil {
  let dir = meta_dir()
  let date = get_date()
  let path = dir <> "/" <> date <> "-meta.jsonl"
  let _ = simplifile.create_directory_all(dir)
  let entry =
    json.object([
      #("type", json.string("false_positive")),
      #("cycle_id", json.string(fp.cycle_id)),
      #("reason", json.string(fp.reason)),
      #("timestamp", json.string(fp.timestamp)),
    ])
  case simplifile.append(path, json.to_string(entry) <> "\n") {
    Ok(_) -> Nil
    Error(e) ->
      slog.log_error(
        "meta/log",
        "append_false_positive",
        "Failed to append: " <> simplifile.describe_error(e),
        Some(fp.cycle_id),
      )
  }
}

/// Load false positive annotations from recent JSONL files.
pub fn load_false_positives(max_days: Int) -> List(FalsePositiveAnnotation) {
  let dir = meta_dir()
  let today = get_date()
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) ->
      files
      |> list.filter(fn(f) { string.ends_with(f, "-meta.jsonl") })
      |> list.filter(fn(f) {
        let date = string.slice(f, 0, 10)
        days_between(date, today) <= max_days
      })
      |> list.sort(string.compare)
      |> list.flat_map(fn(f) {
        let path = dir <> "/" <> f
        case simplifile.read(path) {
          Error(_) -> []
          Ok(contents) -> parse_false_positives(contents)
        }
      })
  }
}

fn parse_false_positives(contents: String) -> List(FalsePositiveAnnotation) {
  contents
  |> string.split("\n")
  |> list.filter(fn(l) { string.trim(l) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, false_positive_decoder()) {
      Ok(fp) -> Ok(fp)
      Error(_) -> Error(Nil)
    }
  })
}

fn false_positive_decoder() -> decode.Decoder(FalsePositiveAnnotation) {
  use entry_type <- decode.optional_field("type", "", decode.string)
  use cycle_id <- decode.field("cycle_id", decode.string)
  use reason <- decode.optional_field("reason", "", decode.string)
  use timestamp <- decode.optional_field("timestamp", "", decode.string)
  case entry_type {
    "false_positive" ->
      decode.success(types.FalsePositiveAnnotation(
        cycle_id:,
        reason:,
        timestamp:,
      ))
    _ ->
      decode.failure(
        types.FalsePositiveAnnotation(cycle_id: "", reason: "", timestamp: ""),
        "not a false_positive entry",
      )
  }
}

// ---------------------------------------------------------------------------
// Load with decay
// ---------------------------------------------------------------------------

/// Load meta observations from JSONL, dropping entries older than max_days.
pub fn load_recent(max_days: Int) -> List(MetaObservation) {
  let dir = meta_dir()
  let today = get_date()
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) ->
      files
      |> list.filter(fn(f) { string.ends_with(f, "-meta.jsonl") })
      |> list.filter(fn(f) {
        // Extract date from filename (YYYY-MM-DD-meta.jsonl)
        let date = string.slice(f, 0, 10)
        days_between(date, today) <= max_days
      })
      |> list.sort(string.compare)
      |> list.flat_map(fn(f) {
        let path = dir <> "/" <> f
        case simplifile.read(path) {
          Error(_) -> []
          Ok(contents) -> parse_observations(contents)
        }
      })
  }
}

/// Restore MetaState from persisted observations.
/// Replays observations through the observer to rebuild streaks and signals.
/// Threshold decay: if the most recent observation is older than decay_hours,
/// the restored state uses fresh config thresholds (full reset).
pub fn restore_state(config: MetaConfig, max_days: Int) -> MetaState {
  let observations = load_recent(max_days)
  let false_positives = load_false_positives(max_days)
  let base_state = types.initial_state(config)
  case observations {
    [] -> types.MetaState(..base_state, false_positives:)
    _ -> {
      // Replay observations to rebuild state
      let state =
        list.fold(observations, base_state, fn(state, obs) {
          types.record_observation(state, obs)
        })
      // Rebuild streaks from the replayed observations
      let recent = list.take(state.observations, 10)
      let rejection_streak = count_trailing(recent, types.has_rejection)
      let elevated_streak =
        count_trailing(recent, fn(obs) {
          types.max_score(obs) >=. config.elevated_score_threshold
        })
      types.MetaState(
        ..state,
        rejection_streak:,
        elevated_score_streak: elevated_streak,
        // Don't carry forward pending interventions across sessions
        pending_intervention: types.NoIntervention,
        // Don't carry forward signals — they'll be re-detected
        last_signals: [],
        // Restore false positive annotations
        false_positives:,
      )
    }
  }
}

/// Count consecutive True values from the start of a list.
fn count_trailing(
  items: List(MetaObservation),
  pred: fn(MetaObservation) -> Bool,
) -> Int {
  case items {
    [] -> 0
    [first, ..rest] ->
      case pred(first) {
        True -> 1 + count_trailing(rest, pred)
        False -> 0
      }
  }
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

fn encode_observation(obs: MetaObservation) -> json.Json {
  json.object([
    #("cycle_id", json.string(obs.cycle_id)),
    #("timestamp", json.string(obs.timestamp)),
    #(
      "gate_decisions",
      json.array(obs.gate_decisions, fn(g) {
        json.object([
          #("gate", json.string(g.gate)),
          #("decision", json.string(g.decision)),
          #("score", json.float(g.score)),
        ])
      }),
    ),
    #("tokens_used", json.int(obs.tokens_used)),
    #("tool_call_count", json.int(obs.tool_call_count)),
    #("had_delegations", json.bool(obs.had_delegations)),
  ])
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

fn parse_observations(contents: String) -> List(MetaObservation) {
  contents
  |> string.split("\n")
  |> list.filter(fn(l) { string.trim(l) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, observation_decoder()) {
      Ok(obs) -> Ok(obs)
      Error(_) -> Error(Nil)
    }
  })
}

fn observation_decoder() -> decode.Decoder(MetaObservation) {
  use cycle_id <- decode.field("cycle_id", decode.string)
  use timestamp <- decode.optional_field("timestamp", "", decode.string)
  use gate_decisions <- decode.optional_field(
    "gate_decisions",
    [],
    decode.list(gate_decision_decoder()),
  )
  use tokens_used <- decode.optional_field("tokens_used", 0, decode.int)
  use tool_call_count <- decode.optional_field("tool_call_count", 0, decode.int)
  use had_delegations <- decode.optional_field(
    "had_delegations",
    False,
    decode.bool,
  )
  decode.success(types.MetaObservation(
    cycle_id:,
    timestamp:,
    gate_decisions:,
    tokens_used:,
    tool_call_count:,
    had_delegations:,
  ))
}

fn gate_decision_decoder() -> decode.Decoder(types.GateDecisionSummary) {
  use gate <- decode.field("gate", decode.string)
  use decision <- decode.optional_field("decision", "", decode.string)
  use score <- decode.optional_field("score", 0.0, decode.float)
  decode.success(types.GateDecisionSummary(gate:, decision:, score:))
}
