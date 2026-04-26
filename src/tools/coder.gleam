//// Host-side project-awareness tools for the coder agent.
////
//// **project_status** — git status, branch, dirty/untracked count
//// **project_read**   — read a host file (decide what to put in scope)
//// **project_grep**   — ripgrep search across the project
////
//// These run on the Springdrift host (not inside the coder slot). They
//// give the agent enough context to draft a `dispatch_coder` brief
//// before delegating the actual edit work to the OpenCode session.
////
//// Verification (run_tests/run_build/run_format) and session control
//// (coder_start_session/send/end_session) used to live here too. Both
//// were removed in R6 of the real-coder rebuild — the OpenCode session
//// does its own iteration internally, so host-side scaffolding around
//// it was the kind of layer that fails at 3am for an autonomous system.

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
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import sandbox/podman_ffi
import simplifile
import slog

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [project_status_tool(), project_read_tool(), project_grep_tool()]
}

pub fn is_project_tool(name: String) -> Bool {
  case name {
    "project_status" | "project_read" | "project_grep" -> True
    _ -> False
  }
}

fn project_status_tool() -> Tool {
  tool.new("project_status")
  |> tool.with_description(
    "Inspect the project's git working tree: current branch, dirty file "
    <> "count, untracked file count. Use before dispatch_coder to decide "
    <> "what's already changed and frame the brief accordingly.",
  )
  |> tool.build()
}

fn project_read_tool() -> Tool {
  tool.new("project_read")
  |> tool.with_description(
    "Read a host project file by path (relative to project_root). Returns "
    <> "the contents truncated to 50KB. Use to inspect a file before "
    <> "deciding it should be in scope for the coder dispatch, or to verify "
    <> "what the coder produced after a commit.",
  )
  |> tool.add_string_param(
    "path",
    "Path relative to project_root (e.g. 'src/foo.gleam'). Must not escape "
      <> "the project root via '..' or absolute paths.",
    True,
  )
  |> tool.build()
}

fn project_grep_tool() -> Tool {
  tool.new("project_grep")
  |> tool.with_description(
    "Ripgrep search across the project. Returns matching lines with file "
    <> "paths and line numbers. Use to locate symbols, definitions, or "
    <> "test fixtures before drafting a coder brief.",
  )
  |> tool.add_string_param("pattern", "Regex pattern (ripgrep syntax)", True)
  |> tool.add_string_param(
    "glob",
    "Optional file glob to narrow the search (e.g. '*.gleam', 'src/**/*.py').",
    False,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(
  call: ToolCall,
  project_root: String,
  cycle_id: Option(String),
) -> ToolResult {
  slog.debug("coder", "execute", "tool=" <> call.name, cycle_id)
  case call.name {
    "project_status" -> run_project_status(call, project_root)
    "project_read" -> run_project_read(call, project_root)
    "project_grep" -> run_project_grep(call, project_root)
    _ ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Unknown coder tool: " <> call.name,
      )
  }
}

// ---------------------------------------------------------------------------
// Implementations
// ---------------------------------------------------------------------------

fn run_project_status(call: ToolCall, project_root: String) -> ToolResult {
  case
    run_in(project_root, "git", ["status", "--porcelain=v2", "--branch"], 5000)
  {
    Error(e) ->
      ToolFailure(tool_use_id: call.id, error: "project_status failed: " <> e)
    Ok(#(_exit, stdout, _stderr)) ->
      ToolSuccess(tool_use_id: call.id, content: summarise_status(stdout))
  }
}

fn summarise_status(porcelain: String) -> String {
  let lines = string.split(porcelain, "\n")
  let branch =
    lines
    |> list.find(fn(l) { string.starts_with(l, "# branch.head") })
    |> result_to_optional
    |> option.map(fn(l) {
      string.replace(l, "# branch.head ", "") |> string.trim
    })
    |> option.unwrap("(unknown)")

  let file_lines =
    list.filter(lines, fn(l) {
      !string.starts_with(l, "#") && string.length(l) > 0
    })
  let dirty =
    list.count(file_lines, fn(l) {
      string.starts_with(l, "1 ") || string.starts_with(l, "2 ")
    })
  let untracked = list.count(file_lines, fn(l) { string.starts_with(l, "? ") })

  "branch: "
  <> branch
  <> "\ndirty: "
  <> int.to_string(dirty)
  <> "\nuntracked: "
  <> int.to_string(untracked)
}

fn run_project_read(call: ToolCall, project_root: String) -> ToolResult {
  let decoder = {
    use path <- decode.field("path", decode.string)
    decode.success(path)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "project_read needs `path`")
    Ok(rel_path) ->
      case validate_project_path(rel_path) {
        Error(reason) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "project_read rejected: " <> reason,
          )
        Ok(_) -> {
          let full = project_root <> "/" <> rel_path
          case simplifile.read(full) {
            Error(e) ->
              ToolFailure(
                tool_use_id: call.id,
                error: "project_read failed: " <> string.inspect(e),
              )
            Ok(content) -> {
              let truncated = case string.length(content) > 50_000 {
                True ->
                  string.slice(content, 0, 50_000)
                  <> "\n... [truncated at 50KB]"
                False -> content
              }
              ToolSuccess(tool_use_id: call.id, content: truncated)
            }
          }
        }
      }
  }
}

fn run_project_grep(call: ToolCall, project_root: String) -> ToolResult {
  let decoder = {
    use pattern <- decode.field("pattern", decode.string)
    use glob <- decode.optional_field("glob", "", decode.string)
    decode.success(#(pattern, glob))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "project_grep needs `pattern`")
    Ok(#(pattern, glob)) -> {
      let base_args = ["-n", "-H", "--max-count=20", "--max-columns=200"]
      let glob_args = case glob {
        "" -> []
        g -> ["-g", g]
      }
      let args = list.flatten([base_args, glob_args, [pattern, "."]])
      case run_in(project_root, "rg", args, 10_000) {
        Error(e) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "project_grep failed (is ripgrep installed?): " <> e,
          )
        Ok(#(_, stdout, _)) -> {
          let truncated = case string.length(stdout) > 30_000 {
            True ->
              string.slice(stdout, 0, 30_000) <> "\n... [truncated at 30KB]"
            False -> stdout
          }
          ToolSuccess(tool_use_id: call.id, content: truncated)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn run_in(
  cwd: String,
  cmd: String,
  args: List(String),
  timeout_ms: Int,
) -> Result(#(Int, String, String), String) {
  // run_cmd doesn't natively support cwd, so we use `env -C` to set cwd
  // and exec via argv (no shell, no injection).
  let full_args = list.flatten([["-C", cwd, cmd], args])
  case podman_ffi.run_cmd("env", full_args, timeout_ms) {
    Error(e) -> Error(e)
    Ok(r) -> Ok(#(r.exit_code, r.stdout, r.stderr))
  }
}

fn validate_project_path(path: String) -> Result(Nil, String) {
  case path {
    "" -> Error("empty path")
    _ ->
      case string.starts_with(path, "/") {
        True ->
          Error("absolute paths not allowed; use relative to project_root")
        False ->
          case string.contains(path, "..") {
            True -> Error("'..' not allowed in path")
            False -> Ok(Nil)
          }
      }
  }
}

fn result_to_optional(r: Result(a, b)) -> Option(a) {
  case r {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}
