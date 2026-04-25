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
import gleam/option
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import simplifile
import skills
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
  [
    calculator_tool(),
    datetime_tool(),
    read_skill_tool(),
    read_hierarchy_tool(),
  ]
}

/// Read the delegation hierarchy around the specialist's current cycle.
/// Takes an optional scope parameter; the cycle_id is injected by the
/// framework so the LLM doesn't need to know it. Returns a compact text
/// rendering of peer / ancestor / full-subtree cycles.
pub fn read_hierarchy_tool() -> Tool {
  tool.new("read_hierarchy")
  |> tool.with_description(
    "Read the delegation hierarchy around your current cycle. Use this "
    <> "when you need to know what other agents the orchestrator is running "
    <> "in parallel with you, or what results the orchestrator already has "
    <> "in hand, instead of relying on paraphrased echoes in your "
    <> "instruction. The framework injects your cycle_id automatically.",
  )
  |> tool.add_enum_param(
    "scope",
    "Which cycles to return. 'siblings' (default): peer delegations under the same orchestrator. 'ancestors': walk up the delegation chain. 'full': entire subtree from the root.",
    ["siblings", "ancestors", "full"],
    False,
  )
  |> tool.build()
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
    "Load the full instructions for an agent skill. Accepts the path shown "
    <> "in <available_skills> (e.g. /Users/.../skills/captures/SKILL.md), "
    <> "a tilde path (~/.config/springdrift/skills/captures/SKILL.md), "
    <> "or a bare skill id (captures). The id form scans the configured "
    <> "skills directories for a matching <id>/SKILL.md.",
  )
  |> tool.add_string_param(
    "path",
    "Path to a SKILL.md file, or a bare skill id.",
    True,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(call: ToolCall, skills_dirs: List(String)) -> ToolResult {
  slog.debug("builtin", "execute", "tool=" <> call.name, option.None)
  case call.name {
    "calculator" -> run_calculator(call)
    "get_current_datetime" ->
      ToolSuccess(tool_use_id: call.id, content: get_datetime())
    "read_skill" -> run_read_skill(call, skills_dirs)
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

fn run_read_skill(call: ToolCall, skills_dirs: List(String)) -> ToolResult {
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
    Ok(raw) ->
      case normalise_skill_path(raw, skills_dirs) {
        Error(reason) ->
          ToolFailure(tool_use_id: call.id, error: "read_skill: " <> reason)
        Ok(path) ->
          case is_safe_skill_path(path, skills_dirs) {
            Error(reason) ->
              ToolFailure(tool_use_id: call.id, error: "read_skill: " <> reason)
            Ok(resolved) ->
              case simplifile.read(resolved) {
                Error(e) ->
                  ToolFailure(
                    tool_use_id: call.id,
                    error: "read_skill: could not read file: "
                      <> simplifile.describe_error(e),
                  )
                Ok(content) -> {
                  // Record an intentional read for the audit panel.
                  // cycle_id and agent name aren't available at the
                  // executor level today; later phases can plumb cycle
                  // context through ToolCall to enable per-cycle
                  // attribution.
                  let skill_dir = string.replace(resolved, "/SKILL.md", "")
                  skills_metrics.append_read(skill_dir, "", "unknown")
                  ToolSuccess(tool_use_id: call.id, content:)
                }
              }
          }
      }
  }
}

/// Coerce whatever the agent passed into a candidate `<dir>/SKILL.md` path.
///
/// LLMs reach for several variants: the absolute path from
/// `<available_skills>`, a tilde path (`~/.config/...`), the skill id alone
/// (`captures`), or the directory without the file (`.../skills/captures`).
/// Reject only when nothing plausible can be constructed; the existing
/// `is_safe_skill_path` still enforces containment.
///
/// Public so tests can drive the normalisation cases directly.
pub fn normalise_skill_path(
  raw: String,
  skills_dirs: List(String),
) -> Result(String, String) {
  let trimmed = string.trim(raw)
  case trimmed {
    "" -> Error("empty path")
    _ -> {
      let expanded = skills.expand_tilde(trimmed)
      case string.ends_with(expanded, "/SKILL.md") || expanded == "SKILL.md" {
        True -> Ok(expanded)
        False ->
          case string.contains(expanded, "/") {
            // Looks like a directory rather than a SKILL.md file.
            True -> Ok(strip_trailing_slash(expanded) <> "/SKILL.md")
            // Bare token — treat as a skill id and scan the
            // configured skills directories for a matching folder.
            False -> resolve_skill_id(expanded, skills_dirs)
          }
      }
    }
  }
}

fn strip_trailing_slash(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> string.drop_end(path, 1)
    False -> path
  }
}

fn resolve_skill_id(
  id: String,
  skills_dirs: List(String),
) -> Result(String, String) {
  let candidates =
    list.filter_map(skills_dirs, fn(dir) {
      let expanded = skills.expand_tilde(dir)
      let candidate = expanded <> "/" <> id <> "/SKILL.md"
      case simplifile.is_file(candidate) {
        Ok(True) -> Ok(candidate)
        _ -> Error(Nil)
      }
    })
  case candidates {
    [first, ..] -> Ok(first)
    [] ->
      Error(
        "no skill named '"
        <> id
        <> "' found in any configured skills directory; "
        <> "supply the absolute path from <available_skills>",
      )
  }
}

/// Validate that `path` is a safe target for read_skill. Returns the
/// canonical (symlink-resolved) path on success, or an error describing
/// the rejection reason.
///
/// Rules (applied in order — early reject wins):
/// 1. Must not contain any `..` path segment. The `resolve_symlinks`
///    FFI resolves symlinks but does NOT collapse `..` segments, so a
///    string like `<root>/foo/../../etc/SKILL.md` would pass the
///    string-prefix containment check below despite obviously
///    escaping the root. Reject these up front.
/// 2. Must end with `/SKILL.md` (the skills convention).
/// 3. If no skills directories are configured, reject everything —
///    fail-closed when the agent has no defined skill scope.
/// 4. After resolving symlinks, the canonical path must be under
///    one of the configured skills directories (also resolved).
///    This blocks symlink escape (a SKILL.md inside the skills dir
///    that's actually a symlink pointing to `/etc/passwd`).
///
/// Public so security tests can drive this directly.
pub fn is_safe_skill_path(
  path: String,
  skills_dirs: List(String),
) -> Result(String, String) {
  case has_dotdot_segment(path) {
    True -> Error("path contains '..' segments")
    False -> {
      let expanded_path = skills.expand_tilde(path)
      case
        string.ends_with(expanded_path, "/SKILL.md")
        || expanded_path == "SKILL.md"
      {
        False -> Error("path must end with /SKILL.md")
        True -> {
          case skills_dirs {
            [] ->
              Error(
                "no skills directories are configured — refusing all "
                <> "read_skill calls (this is a misconfiguration)",
              )
            _ -> {
              let resolved = resolve_symlinks(expanded_path)
              // Tilde-expand each configured root before symlink
              // resolution so a config like `~/.config/...` lines up
              // with an agent-supplied absolute path. Without this,
              // the prefix-containment check fails purely on
              // `~` vs `/Users/...` string mismatch — the bug that
              // made read_skill appear "consistently broken" even
              // when the file existed and was readable.
              let resolved_dirs =
                list.map(skills_dirs, fn(d) {
                  resolve_symlinks(skills.expand_tilde(d))
                })
              case path_under_any(resolved, resolved_dirs) {
                True -> Ok(resolved)
                False ->
                  Error(
                    "resolved path is outside the configured skills "
                    <> "directories (canonical-path check failed)",
                  )
              }
            }
          }
        }
      }
    }
  }
}

/// Check whether `path` contains a `..` path segment — `/../` in
/// the middle, `../` at the start, or `/..` at the end. Catches
/// the relative-traversal escape case before it can short-circuit
/// the prefix containment check.
fn has_dotdot_segment(path: String) -> Bool {
  string.contains(path, "/../")
  || string.starts_with(path, "../")
  || string.ends_with(path, "/..")
  || path == ".."
}

/// Returns True when `path` (resolved) is inside any of the
/// (resolved) directory roots. Compared as string prefix with a
/// trailing-slash guard so `/foo/skills` does not match
/// `/foo/skills-other`.
fn path_under_any(path: String, roots: List(String)) -> Bool {
  list.any(roots, fn(root) {
    let root_with_slash = case string.ends_with(root, "/") {
      True -> root
      False -> root <> "/"
    }
    string.starts_with(path, root_with_slash) || path == root
  })
}

@external(erlang, "springdrift_ffi", "resolve_symlinks")
fn resolve_symlinks(path: String) -> String
