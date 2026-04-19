//// Strategy curation tools — meta-learning Phase A bootstrap follow-up.
////
//// Five tools the cognitive loop can use to populate and curate the
//// Strategy Registry directly. Append `StrategyEvent`s to the
//// per-day JSONL log; current state is derived by replay (no in-place
//// mutation, every change is auditable).
////
//// Why these exist: the original design said "new strategies enter via
//// `propose_strategies_from_patterns` or operator seed", which left an
//// agent with an empty registry no in-band path to populate it. The
//// `seed_strategy` tool closes that loop. The four curation tools
//// (rename, update_description, supersede, archive) let the agent
//// improve its own registry over time without losing the audit trail.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import paths
import slog
import strategy/log as strategy_log
import strategy/types as strategy_types

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

// ---------------------------------------------------------------------------
// Rate limit on direct seeding (default 5/day) — same forcing-function
// motivation as the Remembrancer's pattern-mined proposer.
// ---------------------------------------------------------------------------

const max_seeded_strategies_per_day = 5

// ---------------------------------------------------------------------------
// Tool set
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [
    seed_strategy_tool(),
    rename_strategy_tool(),
    update_strategy_description_tool(),
    supersede_strategy_tool(),
    archive_strategy_tool(),
    list_strategies_tool(),
  ]
}

pub fn is_strategy_tool(name: String) -> Bool {
  name == "seed_strategy"
  || name == "rename_strategy"
  || name == "update_strategy_description"
  || name == "supersede_strategy"
  || name == "archive_strategy"
  || name == "list_strategies"
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

fn seed_strategy_tool() -> Tool {
  tool.new("seed_strategy")
  |> tool.with_description(
    "Register a new named approach in the Strategy Registry. Use this "
    <> "deliberately — the registry is meant to be a small playbook, not "
    <> "a junk drawer. Rate-limited to 5 new strategies per day. The id "
    <> "you choose is permanent (use snake_case, e.g. "
    <> "'verify-with-canary-before-trusting'); name and description can "
    <> "be edited later via rename_strategy and update_strategy_description.",
  )
  |> tool.add_string_param(
    "id",
    "Stable strategy id (snake_case). Must be unique. References from CBR "
      <> "cases and goals will use this — choose carefully.",
    True,
  )
  |> tool.add_string_param(
    "name",
    "Short human-readable name (e.g. 'Verify with canary before trusting').",
    True,
  )
  |> tool.add_string_param(
    "description",
    "What the strategy is and when to use it. Concrete and observable.",
    True,
  )
  |> tool.add_string_param(
    "domain_tags",
    "Comma-separated domain tags (e.g. 'research,delegation'). Optional.",
    False,
  )
  |> tool.build()
}

fn rename_strategy_tool() -> Tool {
  tool.new("rename_strategy")
  |> tool.with_description(
    "Update a strategy's human-readable name. The id stays stable so all "
    <> "existing references continue to resolve. Use when the original name "
    <> "no longer captures what the strategy actually means in practice.",
  )
  |> tool.add_string_param("id", "Strategy id to rename", True)
  |> tool.add_string_param("new_name", "New human-readable name", True)
  |> tool.add_string_param("reason", "Why the rename", True)
  |> tool.build()
}

fn update_strategy_description_tool() -> Tool {
  tool.new("update_strategy_description")
  |> tool.with_description(
    "Sharpen or clarify a strategy's description. Use when the original "
    <> "description was vague (e.g. 'saves cycles but costs clarity' — when "
    <> "exactly?) or when accumulated experience has refined what the "
    <> "strategy really means.",
  )
  |> tool.add_string_param("id", "Strategy id", True)
  |> tool.add_string_param("new_description", "New description", True)
  |> tool.add_string_param("reason", "What changed and why", True)
  |> tool.build()
}

fn supersede_strategy_tool() -> Tool {
  tool.new("supersede_strategy")
  |> tool.with_description(
    "Declare that one strategy is absorbed by another (deduplication or "
    <> "evolution). The successor inherits the predecessor's success/failure "
    <> "counts. The predecessor goes inactive but stays in the log with a "
    <> "pointer to the successor for audit. Use when two strategies turn out "
    <> "to describe the same approach.",
  )
  |> tool.add_string_param(
    "old_id",
    "Strategy id being absorbed (will go inactive)",
    True,
  )
  |> tool.add_string_param(
    "new_id",
    "Strategy id that absorbs it (must already exist; counts merge in)",
    True,
  )
  |> tool.add_string_param("reason", "Why these are the same approach", True)
  |> tool.build()
}

fn archive_strategy_tool() -> Tool {
  tool.new("archive_strategy")
  |> tool.with_description(
    "Mark a strategy inactive. Use when the approach is no longer earning "
    <> "its keep (sustained low success rate) or when it has been replaced "
    <> "by a better approach without a clean supersession relationship. "
    <> "The history stays in the log.",
  )
  |> tool.add_string_param("id", "Strategy id to archive", True)
  |> tool.add_string_param("reason", "Why archive", True)
  |> tool.build()
}

fn list_strategies_tool() -> Tool {
  tool.new("list_strategies")
  |> tool.with_description(
    "List strategies, optionally filtered by status. Default returns "
    <> "active strategies ranked by Laplace-smoothed success rate.",
  )
  |> tool.add_enum_param(
    "status_filter",
    "Filter by status. Default: active.",
    ["active", "inactive", "all"],
    False,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub type StrategyContext {
  StrategyContext(cycle_id: String)
}

pub fn execute(call: ToolCall, ctx: StrategyContext) -> ToolResult {
  case call.name {
    "seed_strategy" -> run_seed(call, ctx)
    "rename_strategy" -> run_rename(call, ctx)
    "update_strategy_description" -> run_update_description(call, ctx)
    "supersede_strategy" -> run_supersede(call, ctx)
    "archive_strategy" -> run_archive(call, ctx)
    "list_strategies" -> run_list(call)
    _ ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Unknown strategies tool: " <> call.name,
      )
  }
}

fn run_seed(call: ToolCall, ctx: StrategyContext) -> ToolResult {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use name <- decode.field("name", decode.string)
    use description <- decode.field("description", decode.string)
    use domain_tags <- decode.optional_field("domain_tags", "", decode.string)
    decode.success(#(id, name, description, domain_tags))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid seed_strategy input")
    Ok(#(id, name, description, domain_tags_str)) -> {
      let dir = paths.strategy_log_dir()
      // Reject duplicate ids — they would conflict with existing strategies
      // and quietly overwrite the description/name on replay.
      let existing = strategy_log.resolve_current(dir)
      case list.any(existing, fn(s) { s.id == id }) {
        True ->
          ToolFailure(
            tool_use_id: call.id,
            error: "seed_strategy: strategy id '"
              <> id
              <> "' already exists. Use rename_strategy or "
              <> "update_strategy_description to change it, or supersede_strategy "
              <> "to replace it.",
          )
        False -> {
          // Rate limit: count today's StrategyCreated events with source
          // = OperatorDefined (seeded directly, not pattern-mined).
          let today = get_date()
          let today_events = strategy_log.load_date(dir, today)
          let seeded_today =
            list.count(today_events, fn(ev) {
              case ev {
                strategy_types.StrategyCreated(
                  source: strategy_types.OperatorDefined,
                  ..,
                ) -> True
                _ -> False
              }
            })
          case seeded_today >= max_seeded_strategies_per_day {
            True ->
              ToolFailure(
                tool_use_id: call.id,
                error: "seed_strategy rate limit reached ("
                  <> int.to_string(max_seeded_strategies_per_day)
                  <> "/day). The registry is meant to be small. Use "
                  <> "propose_strategies_from_patterns for bulk mining.",
              )
            False -> {
              let domain_tags = case string.trim(domain_tags_str) {
                "" -> []
                s ->
                  s
                  |> string.split(",")
                  |> list.map(string.trim)
                  |> list.filter(fn(t) { t != "" })
              }
              let event =
                strategy_types.StrategyCreated(
                  timestamp: get_datetime(),
                  strategy_id: id,
                  name: name,
                  description: description,
                  domain_tags: domain_tags,
                  // Seeds from the cognitive loop are agent-led but
                  // deliberate — treat as OperatorDefined for source
                  // attribution. (The agent IS the operator from the
                  // registry's perspective when it explicitly seeds.)
                  source: strategy_types.OperatorDefined,
                )
              strategy_log.append(dir, event)
              slog.info(
                "tools/strategies",
                "seed_strategy",
                "Seeded strategy " <> id,
                Some(ctx.cycle_id),
              )
              ToolSuccess(
                tool_use_id: call.id,
                content: "Seeded strategy: "
                  <> id
                  <> " (rate-limit "
                  <> int.to_string(seeded_today + 1)
                  <> "/"
                  <> int.to_string(max_seeded_strategies_per_day)
                  <> " today)",
              )
            }
          }
        }
      }
    }
  }
}

fn run_rename(call: ToolCall, ctx: StrategyContext) -> ToolResult {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use new_name <- decode.field("new_name", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(#(id, new_name, reason))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid rename_strategy input")
    Ok(#(id, new_name, reason)) -> {
      case ensure_exists(id) {
        Error(msg) -> ToolFailure(tool_use_id: call.id, error: msg)
        Ok(_) -> {
          strategy_log.append(
            paths.strategy_log_dir(),
            strategy_types.StrategyRenamed(
              timestamp: get_datetime(),
              strategy_id: id,
              new_name: new_name,
              reason: reason,
            ),
          )
          slog.info(
            "tools/strategies",
            "rename_strategy",
            "Renamed " <> id <> " -> " <> new_name,
            Some(ctx.cycle_id),
          )
          ToolSuccess(
            tool_use_id: call.id,
            content: "Renamed " <> id <> " to '" <> new_name <> "'",
          )
        }
      }
    }
  }
}

fn run_update_description(call: ToolCall, ctx: StrategyContext) -> ToolResult {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use new_description <- decode.field("new_description", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(#(id, new_description, reason))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid update_strategy_description input",
      )
    Ok(#(id, new_description, reason)) -> {
      case ensure_exists(id) {
        Error(msg) -> ToolFailure(tool_use_id: call.id, error: msg)
        Ok(_) -> {
          strategy_log.append(
            paths.strategy_log_dir(),
            strategy_types.StrategyDescriptionUpdated(
              timestamp: get_datetime(),
              strategy_id: id,
              new_description: new_description,
              reason: reason,
            ),
          )
          slog.info(
            "tools/strategies",
            "update_strategy_description",
            "Updated description for " <> id,
            Some(ctx.cycle_id),
          )
          ToolSuccess(
            tool_use_id: call.id,
            content: "Updated description for " <> id,
          )
        }
      }
    }
  }
}

fn run_supersede(call: ToolCall, ctx: StrategyContext) -> ToolResult {
  let decoder = {
    use old_id <- decode.field("old_id", decode.string)
    use new_id <- decode.field("new_id", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(#(old_id, new_id, reason))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid supersede_strategy input",
      )
    Ok(#(old_id, new_id, reason)) -> {
      case old_id == new_id {
        True ->
          ToolFailure(
            tool_use_id: call.id,
            error: "supersede_strategy: old_id and new_id must differ",
          )
        False -> {
          case ensure_exists(old_id), ensure_exists(new_id) {
            Error(msg), _ -> ToolFailure(tool_use_id: call.id, error: msg)
            _, Error(msg) -> ToolFailure(tool_use_id: call.id, error: msg)
            Ok(_), Ok(_) -> {
              strategy_log.append(
                paths.strategy_log_dir(),
                strategy_types.StrategySuperseded(
                  timestamp: get_datetime(),
                  old_strategy_id: old_id,
                  new_strategy_id: new_id,
                  reason: reason,
                ),
              )
              slog.info(
                "tools/strategies",
                "supersede_strategy",
                old_id <> " -> " <> new_id,
                Some(ctx.cycle_id),
              )
              ToolSuccess(
                tool_use_id: call.id,
                content: "Superseded "
                  <> old_id
                  <> " by "
                  <> new_id
                  <> " (counts merged into successor)",
              )
            }
          }
        }
      }
    }
  }
}

fn run_archive(call: ToolCall, ctx: StrategyContext) -> ToolResult {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(#(id, reason))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid archive_strategy input")
    Ok(#(id, reason)) -> {
      case ensure_exists(id) {
        Error(msg) -> ToolFailure(tool_use_id: call.id, error: msg)
        Ok(_) -> {
          strategy_log.append(
            paths.strategy_log_dir(),
            strategy_types.StrategyArchived(
              timestamp: get_datetime(),
              strategy_id: id,
              reason: reason,
            ),
          )
          slog.info(
            "tools/strategies",
            "archive_strategy",
            "Archived " <> id,
            Some(ctx.cycle_id),
          )
          ToolSuccess(tool_use_id: call.id, content: "Archived " <> id)
        }
      }
    }
  }
}

fn run_list(call: ToolCall) -> ToolResult {
  let decoder = {
    use status_filter <- decode.optional_field(
      "status_filter",
      "active",
      decode.string,
    )
    decode.success(status_filter)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid list_strategies input")
    Ok(filter) -> {
      let all = strategy_log.resolve_current(paths.strategy_log_dir())
      let filtered = case filter {
        "all" -> all
        "inactive" -> list.filter(all, fn(s) { !s.active })
        _ -> strategy_log.active_ranked(all)
      }
      let body = case filtered {
        [] -> "(no strategies matching filter '" <> filter <> "')"
        _ ->
          string.join(
            list.map(filtered, fn(s) {
              let sr = strategy_log.success_rate(s)
              "- "
              <> s.id
              <> " ('"
              <> s.name
              <> "') status="
              <> case s.active {
                True -> "active"
                False ->
                  case s.superseded_by {
                    Some(by) -> "superseded by " <> by
                    None -> "archived"
                  }
              }
              <> " success_rate="
              <> int_to_str_2dp(sr)
              <> " uses="
              <> int.to_string(s.total_uses)
            }),
            "\n",
          )
      }
      let payload =
        json.object([
          #("filter", json.string(filter)),
          #("count", json.int(list.length(filtered))),
        ])
      ToolSuccess(
        tool_use_id: call.id,
        content: json.to_string(payload) <> "\n\n" <> body,
      )
    }
  }
}

fn ensure_exists(id: String) -> Result(Nil, String) {
  let strategies = strategy_log.resolve_current(paths.strategy_log_dir())
  case list.find(strategies, fn(s) { s.id == id }) {
    Ok(_) -> Ok(Nil)
    Error(_) ->
      Error(
        "strategy id '"
        <> id
        <> "' not found. Use list_strategies to see "
        <> "what's in the registry.",
      )
  }
}

fn int_to_str_2dp(f: Float) -> String {
  let scaled = f *. 100.0
  let n = case scaled <. 0.0 {
    True -> 0
    False ->
      // Floor to int with simple casting via add then int.parse-style
      // approach: multiply, round to int.
      float_to_int_floor(scaled +. 0.5)
  }
  let pct = int.to_string(n)
  case string.length(pct) {
    1 -> "0.0" <> pct
    2 -> "0." <> pct
    _ -> {
      let head = string.drop_end(pct, 2)
      let tail = string.slice(pct, string.length(pct) - 2, 2)
      head <> "." <> tail
    }
  }
}

@external(erlang, "erlang", "trunc")
fn float_to_int_floor(f: Float) -> Int
