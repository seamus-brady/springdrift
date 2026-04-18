//// Learning Goals tools — meta-learning Phase C.
////
//// Three tools the cognitive loop can use to set, evidence, and update
//// self-directed learning objectives. Goals persist as append-only JSONL
//// in `.springdrift/memory/learning_goals/` via `learning_goal/log.gleam`.
////
//// Design: small, synchronous, no LLM calls. Goals are agent-led artefacts;
//// the operator can review the lifecycle log retrospectively.

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
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import learning_goal/log as goal_log
import learning_goal/types as goal_types
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import paths

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "generate_uuid")
fn uuid_v4() -> String

// ---------------------------------------------------------------------------
// Tool set
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [
    create_learning_goal_tool(),
    update_learning_goal_tool(),
    list_learning_goals_tool(),
  ]
}

pub fn is_learning_goal_tool(name: String) -> Bool {
  name == "create_learning_goal"
  || name == "update_learning_goal"
  || name == "list_learning_goals"
}

fn create_learning_goal_tool() -> Tool {
  tool.new("create_learning_goal")
  |> tool.with_description(
    "Create a self-directed learning goal. Use sparingly — goals are commitments "
    <> "you intend to evaluate. Provide acceptance_criteria the operator could "
    <> "check.",
  )
  |> tool.add_string_param(
    "title",
    "Short title (e.g. 'Faster planner forecasts')",
    True,
  )
  |> tool.add_string_param(
    "rationale",
    "Why this goal matters now. What recent observation or pattern motivated it?",
    True,
  )
  |> tool.add_string_param(
    "acceptance_criteria",
    "How you will judge whether the goal is achieved (concrete, observable).",
    True,
  )
  |> tool.add_string_param(
    "strategy_id",
    "Optional Strategy Registry id linking this goal to a named approach.",
    False,
  )
  |> tool.add_number_param(
    "priority",
    "0.0–1.0 (default 0.5). Use 1.0 only for operator-directed goals.",
    False,
  )
  |> tool.add_enum_param(
    "source",
    "Where this goal came from. Default self_identified.",
    [
      "self_identified",
      "operator_directed",
      "remembrancer_suggested",
      "pattern_mined",
    ],
    False,
  )
  |> tool.build()
}

fn update_learning_goal_tool() -> Tool {
  tool.new("update_learning_goal")
  |> tool.with_description(
    "Add evidence to a goal (a cycle_id) or change its status. Status "
    <> "transitions are recorded with a free-text reason for the audit trail.",
  )
  |> tool.add_string_param("goal_id", "Id from create_learning_goal", True)
  |> tool.add_string_param(
    "evidence_cycle_id",
    "Optional: cycle_id contributing evidence toward (or against) the goal.",
    False,
  )
  |> tool.add_enum_param(
    "new_status",
    "Optional: status transition. Reason required when set.",
    ["active", "achieved", "abandoned", "paused"],
    False,
  )
  |> tool.add_string_param(
    "reason",
    "Free-text reason for the status change (required when new_status is set).",
    False,
  )
  |> tool.build()
}

fn list_learning_goals_tool() -> Tool {
  tool.new("list_learning_goals")
  |> tool.with_description(
    "List learning goals, optionally filtered by status. Default returns "
    <> "active goals only, ranked by priority.",
  )
  |> tool.add_enum_param(
    "status_filter",
    "Filter by status. Default: active.",
    ["active", "achieved", "abandoned", "paused", "all"],
    False,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub type LearningGoalContext {
  LearningGoalContext(cycle_id: String)
}

pub fn execute(call: ToolCall, ctx: LearningGoalContext) -> ToolResult {
  case call.name {
    "create_learning_goal" -> run_create(call, ctx)
    "update_learning_goal" -> run_update(call, ctx)
    "list_learning_goals" -> run_list(call)
    _ ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Unknown learning_goals tool: " <> call.name,
      )
  }
}

fn run_create(call: ToolCall, _ctx: LearningGoalContext) -> ToolResult {
  let decoder = {
    use title <- decode.field("title", decode.string)
    use rationale <- decode.field("rationale", decode.string)
    use acceptance_criteria <- decode.field(
      "acceptance_criteria",
      decode.string,
    )
    use strategy_id <- decode.optional_field(
      "strategy_id",
      None,
      decode.optional(decode.string),
    )
    use priority <- decode.optional_field("priority", 0.5, decode.float)
    use source_str <- decode.optional_field(
      "source",
      "self_identified",
      decode.string,
    )
    decode.success(#(
      title,
      rationale,
      acceptance_criteria,
      strategy_id,
      priority,
      source_str,
    ))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid create_learning_goal input",
      )
    Ok(#(
      title,
      rationale,
      acceptance_criteria,
      strategy_id,
      priority,
      source_str,
    )) -> {
      let goal_id = "goal-" <> uuid_v4()
      let event =
        goal_types.GoalCreated(
          timestamp: get_datetime(),
          goal_id: goal_id,
          title: title,
          rationale: rationale,
          acceptance_criteria: acceptance_criteria,
          strategy_id: strategy_id,
          priority: priority,
          source: goal_log.decode_source(source_str),
        )
      goal_log.append(paths.learning_goals_dir(), event)
      ToolSuccess(
        tool_use_id: call.id,
        content: "Created learning goal: " <> goal_id <> " (" <> title <> ")",
      )
    }
  }
}

fn run_update(call: ToolCall, ctx: LearningGoalContext) -> ToolResult {
  let decoder = {
    use goal_id <- decode.field("goal_id", decode.string)
    use evidence_cycle_id <- decode.optional_field(
      "evidence_cycle_id",
      None,
      decode.optional(decode.string),
    )
    use new_status <- decode.optional_field(
      "new_status",
      None,
      decode.optional(decode.string),
    )
    use reason <- decode.optional_field(
      "reason",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(goal_id, evidence_cycle_id, new_status, reason))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid update_learning_goal input",
      )
    Ok(#(goal_id, evidence, new_status, reason)) -> {
      let dir = paths.learning_goals_dir()
      let now = get_datetime()
      let evidence_id = case evidence {
        Some(id) -> id
        None -> ctx.cycle_id
      }
      // If evidence was provided OR caller is in an active cycle, record evidence.
      case evidence {
        Some(_) ->
          goal_log.append(
            dir,
            goal_types.GoalEvidenceAdded(
              timestamp: now,
              goal_id: goal_id,
              cycle_id: evidence_id,
            ),
          )
        None -> Nil
      }
      case new_status {
        Some(s) -> {
          let reason_text = option.unwrap(reason, "")
          case reason_text {
            "" ->
              ToolFailure(
                tool_use_id: call.id,
                error: "reason is required when new_status is set",
              )
            _ -> {
              goal_log.append(
                dir,
                goal_types.GoalStatusChanged(
                  timestamp: now,
                  goal_id: goal_id,
                  new_status: goal_log.decode_status(s),
                  reason: reason_text,
                ),
              )
              ToolSuccess(
                tool_use_id: call.id,
                content: "Updated goal "
                  <> goal_id
                  <> " status -> "
                  <> s
                  <> case evidence {
                  Some(c) -> " (evidence: " <> c <> ")"
                  None -> ""
                },
              )
            }
          }
        }
        None ->
          ToolSuccess(tool_use_id: call.id, content: case evidence {
            Some(c) -> "Recorded evidence " <> c <> " against goal " <> goal_id
            None -> "No-op: provide evidence_cycle_id or new_status"
          })
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
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid list_learning_goals input",
      )
    Ok(filter) -> {
      let dir = paths.learning_goals_dir()
      let all = goal_log.resolve_current(dir)
      let filtered = case filter {
        "all" -> all
        "active" ->
          list.filter(all, fn(g) { g.status == goal_types.ActiveGoal })
        "achieved" ->
          list.filter(all, fn(g) { g.status == goal_types.AchievedGoal })
        "abandoned" ->
          list.filter(all, fn(g) { g.status == goal_types.AbandonedGoal })
        "paused" ->
          list.filter(all, fn(g) { g.status == goal_types.PausedGoal })
        _ -> list.filter(all, fn(g) { g.status == goal_types.ActiveGoal })
      }
      let json_payload =
        json.object([
          #("filter", json.string(filter)),
          #("count", json.int(list.length(filtered))),
          #(
            "goals",
            json.array(filtered, fn(g) {
              json.object([
                #("id", json.string(g.id)),
                #("title", json.string(g.title)),
                #("priority", json.float(g.priority)),
                #("status", json.string(goal_log.encode_status(g.status))),
                #("evidence_count", json.int(list.length(g.evidence))),
                #("source", json.string(goal_log.encode_source(g.source))),
              ])
            }),
          ),
        ])
      ToolSuccess(
        tool_use_id: call.id,
        content: json.to_string(json_payload)
          <> "\n\n"
          <> render_goals_summary(filtered),
      )
    }
  }
}

fn render_goals_summary(goals: List(goal_types.LearningGoal)) -> String {
  case goals {
    [] -> "(no goals matching filter)"
    _ ->
      string.join(
        list.map(goals, fn(g) {
          "- "
          <> g.title
          <> " [p="
          <> float.to_string(g.priority)
          <> ", evidence="
          <> int.to_string(list.length(g.evidence))
          <> "] — "
          <> goal_log.encode_status(g.status)
        }),
        "\n",
      )
  }
}
