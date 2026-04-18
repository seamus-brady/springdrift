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
import gleam/option
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import simplifile
import skills/metrics as skills_metrics
import slog

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [calculator_tool(), datetime_tool(), human_input_tool(), read_skill_tool()]
}

/// Tools safe for sub-agents. Excludes request_human_input which is
/// reserved for the cognitive loop — sub-agents report back through
/// their return value, not by hijacking the user interaction channel.
pub fn agent_tools() -> List(Tool) {
  [calculator_tool(), datetime_tool(), read_skill_tool()]
}

pub fn human_input_tool() -> Tool {
  tool.new("request_human_input")
  |> tool.with_description(
    "Ask the human a clarifying question and wait for their response before continuing",
  )
  |> tool.add_string_param("question", "The question to ask the human", True)
  |> tool.build()
}

pub fn calculator_tool() -> Tool {
  tool.new("calculator")
  |> tool.with_description(
    "Performs basic arithmetic: add, subtract, multiply, or divide two numbers",
  )
  |> tool.add_number_param("a", "The left-hand operand", True)
  |> tool.add_enum_param(
    "operator",
    "Arithmetic operator",
    ["+", "-", "*", "/"],
    True,
  )
  |> tool.add_number_param("b", "The right-hand operand", True)
  |> tool.build()
}

pub fn datetime_tool() -> Tool {
  tool.new("get_current_datetime")
  |> tool.with_description(
    "Returns the current local date and time as an ISO 8601 string (YYYY-MM-DDTHH:MM:SS)",
  )
  |> tool.build()
}

pub fn read_skill_tool() -> Tool {
  tool.new("read_skill")
  |> tool.with_description(
    "Load the full instructions for an agent skill. Use the path shown in <available_skills> in your context.",
  )
  |> tool.add_string_param("path", "Absolute path to a SKILL.md file", True)
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(call: ToolCall) -> ToolResult {
  slog.debug("builtin", "execute", "tool=" <> call.name, option.None)
  case call.name {
    "calculator" -> run_calculator(call)
    "get_current_datetime" ->
      ToolSuccess(tool_use_id: call.id, content: get_datetime())
    "read_skill" -> run_read_skill(call)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// Calculator
// ---------------------------------------------------------------------------

fn number_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn run_calculator(call: ToolCall) -> ToolResult {
  let decoder = {
    use a <- decode.field("a", number_decoder())
    use operator <- decode.field("operator", decode.string)
    use b <- decode.field("b", number_decoder())
    decode.success(#(a, operator, b))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid calculator input")
    Ok(#(a, op, b)) ->
      case op {
        "+" -> ok_result(call.id, a +. b)
        "-" -> ok_result(call.id, a -. b)
        "*" -> ok_result(call.id, a *. b)
        "/" ->
          case b == 0.0 {
            True -> ToolFailure(tool_use_id: call.id, error: "Division by zero")
            False -> ok_result(call.id, a /. b)
          }
        _ ->
          ToolFailure(tool_use_id: call.id, error: "Unknown operator: " <> op)
      }
  }
}

fn ok_result(id: String, value: Float) -> ToolResult {
  ToolSuccess(tool_use_id: id, content: float.to_string(value))
}

// ---------------------------------------------------------------------------
// Datetime FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

// ---------------------------------------------------------------------------
// Read skill
// ---------------------------------------------------------------------------

fn run_read_skill(call: ToolCall) -> ToolResult {
  let decoder = {
    use path <- decode.field("path", decode.string)
    decode.success(path)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid read_skill input: missing path",
      )
    Ok(path) ->
      case string.ends_with(path, "SKILL.md") && !string.contains(path, "..") {
        False ->
          ToolFailure(
            tool_use_id: call.id,
            error: "read_skill: path must end with SKILL.md and contain no '..' segments",
          )
        True ->
          case simplifile.read(path) {
            Error(e) ->
              ToolFailure(
                tool_use_id: call.id,
                error: "read_skill: could not read file: "
                  <> simplifile.describe_error(e),
              )
            Ok(content) -> {
              // Record an intentional read for the audit panel. cycle_id
              // and agent name aren't available at the executor level
              // today; later phases can plumb cycle context through
              // ToolCall to enable per-cycle attribution.
              let skill_dir = string.replace(path, "/SKILL.md", "")
              skills_metrics.append_read(skill_dir, "", "unknown")
              ToolSuccess(tool_use_id: call.id, content:)
            }
          }
      }
  }
}
