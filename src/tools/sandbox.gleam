//// Sandbox tools for the coder agent — run_code, serve, stop_serve.
////
//// Routes tool calls to the sandbox manager actor.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import llm/verification
import sandbox/types as sandbox_types
import slog

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn run_code_tool() -> Tool {
  tool.new("run_code")
  |> tool.with_description(
    "Execute code in a local Podman sandbox. Returns stdout, stderr, and exit code. The sandbox is isolated — combine operations into a single code block when possible.",
  )
  |> tool.add_string_param(
    "code",
    "The code to execute. For Python, use print() for output.",
    True,
  )
  |> tool.add_string_param(
    "language",
    "Programming language: python (default), javascript, bash",
    False,
  )
  |> tool.build()
}

pub fn serve_tool() -> Tool {
  tool.new("serve")
  |> tool.with_description(
    "Start a long-lived process (web server, API, etc.) in the sandbox with port forwarding. Returns the host URL where the app is accessible. Use stop_serve to stop it.",
  )
  |> tool.add_string_param(
    "code",
    "The server code to run. Must listen on the container port (47200 + port index).",
    True,
  )
  |> tool.add_string_param(
    "language",
    "Programming language: python (default), javascript, bash",
    False,
  )
  |> tool.add_integer_param("port", "Port index 0-4 (default: 0)", False)
  |> tool.build()
}

pub fn stop_serve_tool() -> Tool {
  tool.new("stop_serve")
  |> tool.with_description(
    "Stop a running server in the sandbox and free the slot.",
  )
  |> tool.add_integer_param("slot_id", "The slot ID returned by serve", True)
  |> tool.build()
}

pub fn sandbox_status_tool() -> Tool {
  tool.new("sandbox_status")
  |> tool.with_description(
    "Check sandbox status: which slots are available, busy, serving, or failed. Shows port mappings and workspace paths. Call this to understand your environment before starting work.",
  )
  |> tool.build()
}

pub fn workspace_ls_tool() -> Tool {
  tool.new("workspace_ls")
  |> tool.with_description(
    "List files in the sandbox workspace. Shows what's been created by previous run_code calls. Optionally provide a subdirectory path.",
  )
  |> tool.add_string_param(
    "path",
    "Subdirectory to list (default: workspace root)",
    False,
  )
  |> tool.build()
}

pub fn sandbox_exec_tool() -> Tool {
  tool.new("sandbox_exec")
  |> tool.with_description(
    "Run a shell command directly in the sandbox container. Lighter than run_code — no file written. Use for git operations, pip install, file management, curl, etc. Runs in /workspace as working directory.",
  )
  |> tool.add_string_param("command", "Shell command to execute", True)
  |> tool.build()
}

/// Check if a tool name is a sandbox tool.
pub fn is_sandbox_tool(name: String) -> Bool {
  name == "run_code"
  || name == "serve"
  || name == "stop_serve"
  || name == "sandbox_status"
  || name == "workspace_ls"
  || name == "sandbox_exec"
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

/// Execute a sandbox tool call.
pub fn execute(
  call: ToolCall,
  manager: sandbox_types.SandboxManager,
) -> ToolResult {
  slog.debug("sandbox", "execute", "tool=" <> call.name, None)
  case call.name {
    "run_code" -> execute_run_code(call, manager)
    "serve" -> execute_serve(call, manager)
    "stop_serve" -> execute_stop_serve(call, manager)
    "sandbox_status" -> execute_sandbox_status(call, manager)
    "workspace_ls" -> execute_workspace_ls(call, manager)
    "sandbox_exec" -> execute_sandbox_exec(call, manager)
    _ ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Unknown sandbox tool: " <> call.name,
      )
  }
}

fn execute_run_code(
  call: ToolCall,
  manager: sandbox_types.SandboxManager,
) -> ToolResult {
  let decoder = {
    use code <- decode.field("code", decode.string)
    use language <- decode.optional_field("language", "python", decode.string)
    decode.success(#(code, language))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid run_code input: missing code parameter",
      )
    Ok(#(code, language)) -> {
      // Acquire a slot
      let acquire_subj = process.new_subject()
      process.send(
        manager.subject,
        sandbox_types.Acquire(reply_to: acquire_subj),
      )
      case process.receive(acquire_subj, 5000) {
        Error(_) ->
          ToolFailure(tool_use_id: call.id, error: "Sandbox acquire timeout")
        Ok(Error(msg)) ->
          ToolFailure(tool_use_id: call.id, error: "Sandbox: " <> msg)
        Ok(Ok(slot_id)) -> {
          // Execute
          let exec_subj = process.new_subject()
          process.send(
            manager.subject,
            sandbox_types.Execute(
              slot_id:,
              code:,
              language:,
              timeout_ms: manager.exec_timeout_ms,
              reply_to: exec_subj,
            ),
          )
          let result = case
            process.receive(exec_subj, manager.exec_timeout_ms + 5000)
          {
            Error(_) ->
              ToolFailure(
                tool_use_id: call.id,
                error: "Sandbox execution timeout",
              )
            Ok(Error(msg)) -> ToolFailure(tool_use_id: call.id, error: msg)
            Ok(Ok(exec_result)) -> format_exec_result(call.id, exec_result)
          }
          // Release the slot
          process.send(manager.subject, sandbox_types.Release(slot_id:))
          result
        }
      }
    }
  }
}

fn execute_serve(
  call: ToolCall,
  manager: sandbox_types.SandboxManager,
) -> ToolResult {
  let decoder = {
    use code <- decode.field("code", decode.string)
    use language <- decode.optional_field("language", "python", decode.string)
    use port <- decode.optional_field("port", 0, decode.int)
    decode.success(#(code, language, port))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid serve input: missing code parameter",
      )
    Ok(#(code, language, port_index)) -> {
      // Acquire a slot
      let acquire_subj = process.new_subject()
      process.send(
        manager.subject,
        sandbox_types.Acquire(reply_to: acquire_subj),
      )
      case process.receive(acquire_subj, 5000) {
        Error(_) ->
          ToolFailure(tool_use_id: call.id, error: "Sandbox acquire timeout")
        Ok(Error(msg)) ->
          ToolFailure(tool_use_id: call.id, error: "Sandbox: " <> msg)
        Ok(Ok(slot_id)) -> {
          let serve_subj = process.new_subject()
          process.send(
            manager.subject,
            sandbox_types.Serve(
              slot_id:,
              code:,
              language:,
              port_index:,
              reply_to: serve_subj,
            ),
          )
          case process.receive(serve_subj, 10_000) {
            Error(_) -> {
              process.send(manager.subject, sandbox_types.Release(slot_id:))
              ToolFailure(tool_use_id: call.id, error: "Sandbox serve timeout")
            }
            Ok(Error(msg)) -> {
              process.send(manager.subject, sandbox_types.Release(slot_id:))
              ToolFailure(tool_use_id: call.id, error: msg)
            }
            Ok(Ok(sr)) ->
              ToolSuccess(
                tool_use_id: call.id,
                content: "Server started.\n"
                  <> "Host URL: http://localhost:"
                  <> int.to_string(sr.host_port)
                  <> "\n"
                  <> "Container port: "
                  <> int.to_string(sr.container_port)
                  <> "\n"
                  <> "Slot ID: "
                  <> int.to_string(sr.slot_id)
                  <> " (use this with stop_serve)",
              )
          }
        }
      }
    }
  }
}

fn execute_stop_serve(
  call: ToolCall,
  manager: sandbox_types.SandboxManager,
) -> ToolResult {
  let decoder = {
    use slot_id <- decode.field("slot_id", decode.int)
    decode.success(slot_id)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid stop_serve input: missing slot_id",
      )
    Ok(slot_id) -> {
      let stop_subj = process.new_subject()
      process.send(
        manager.subject,
        sandbox_types.StopServe(slot_id:, reply_to: stop_subj),
      )
      case process.receive(stop_subj, 5000) {
        Error(_) ->
          ToolFailure(tool_use_id: call.id, error: "Sandbox stop_serve timeout")
        Ok(Error(msg)) -> ToolFailure(tool_use_id: call.id, error: msg)
        Ok(Ok(_)) ->
          ToolSuccess(
            tool_use_id: call.id,
            content: "Server stopped and slot "
              <> int.to_string(slot_id)
              <> " released.",
          )
      }
    }
  }
}

fn execute_sandbox_status(
  call: ToolCall,
  manager: sandbox_types.SandboxManager,
) -> ToolResult {
  let status_subj = process.new_subject()
  process.send(manager.subject, sandbox_types.GetStatus(reply_to: status_subj))
  case process.receive(status_subj, 5000) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Sandbox status timeout")
    Ok(slots) -> {
      let lines =
        list.map(slots, fn(slot) {
          let status_str = case slot.status {
            sandbox_types.Ready -> "ready"
            sandbox_types.Busy -> "busy"
            sandbox_types.Failed(reason:) -> "failed: " <> reason
            sandbox_types.Serving(port:) ->
              "serving on localhost:" <> int.to_string(port)
          }
          let ports_str =
            slot.host_ports
            |> list.map(int.to_string)
            |> string.join(", ")
          "Slot "
          <> int.to_string(slot.slot_id)
          <> ": "
          <> status_str
          <> "\n  Workspace: "
          <> slot.workspace
          <> "\n  Host ports: "
          <> ports_str
        })
      let summary =
        "Sandbox: "
        <> int.to_string(list.length(slots))
        <> " slots\n\n"
        <> string.join(lines, "\n\n")
      ToolSuccess(tool_use_id: call.id, content: summary)
    }
  }
}

fn execute_workspace_ls(
  call: ToolCall,
  manager: sandbox_types.SandboxManager,
) -> ToolResult {
  let decoder = {
    use path <- decode.optional_field("path", ".", decode.string)
    decode.success(path)
  }
  let subdir = case json.parse(call.input_json, decoder) {
    Ok(p) -> p
    Error(_) -> "."
  }
  // Acquire a slot to find its workspace, then shell exec ls
  let acquire_subj = process.new_subject()
  process.send(manager.subject, sandbox_types.Acquire(reply_to: acquire_subj))
  case process.receive(acquire_subj, 5000) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Sandbox acquire timeout")
    Ok(Error(msg)) ->
      ToolFailure(tool_use_id: call.id, error: "Sandbox: " <> msg)
    Ok(Ok(slot_id)) -> {
      let ls_subj = process.new_subject()
      let ls_path = case subdir {
        "." | "" -> "/workspace"
        p -> "/workspace/" <> p
      }
      process.send(
        manager.subject,
        sandbox_types.ShellExec(
          slot_id:,
          command: "ls -la " <> ls_path <> " 2>&1",
          timeout_ms: 5000,
          reply_to: ls_subj,
        ),
      )
      let result = case process.receive(ls_subj, 10_000) {
        Error(_) ->
          ToolFailure(tool_use_id: call.id, error: "workspace_ls timeout")
        Ok(Error(msg)) -> ToolFailure(tool_use_id: call.id, error: msg)
        Ok(Ok(exec_result)) ->
          ToolSuccess(
            tool_use_id: call.id,
            content: string.trim(exec_result.stdout <> exec_result.stderr),
          )
      }
      process.send(manager.subject, sandbox_types.Release(slot_id:))
      result
    }
  }
}

fn execute_sandbox_exec(
  call: ToolCall,
  manager: sandbox_types.SandboxManager,
) -> ToolResult {
  let decoder = {
    use command <- decode.field("command", decode.string)
    decode.success(command)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid sandbox_exec input: missing command",
      )
    Ok(command) -> {
      let acquire_subj = process.new_subject()
      process.send(
        manager.subject,
        sandbox_types.Acquire(reply_to: acquire_subj),
      )
      case process.receive(acquire_subj, 5000) {
        Error(_) ->
          ToolFailure(tool_use_id: call.id, error: "Sandbox acquire timeout")
        Ok(Error(msg)) ->
          ToolFailure(tool_use_id: call.id, error: "Sandbox: " <> msg)
        Ok(Ok(slot_id)) -> {
          let exec_subj = process.new_subject()
          process.send(
            manager.subject,
            sandbox_types.ShellExec(
              slot_id:,
              command:,
              timeout_ms: manager.exec_timeout_ms,
              reply_to: exec_subj,
            ),
          )
          let result = case
            process.receive(exec_subj, manager.exec_timeout_ms + 5000)
          {
            Error(_) ->
              ToolFailure(tool_use_id: call.id, error: "Sandbox exec timeout")
            Ok(Error(msg)) -> ToolFailure(tool_use_id: call.id, error: msg)
            Ok(Ok(exec_result)) -> format_exec_result(call.id, exec_result)
          }
          process.send(manager.subject, sandbox_types.Release(slot_id:))
          result
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

fn format_exec_result(
  tool_use_id: String,
  exec_result: sandbox_types.ExecResult,
) -> ToolResult {
  let sections = []
  let sections = case string.trim(exec_result.stderr) {
    "" -> sections
    stderr -> list.append(sections, ["STDERR:\n" <> stderr])
  }
  let sections = case string.trim(exec_result.stdout) {
    "" -> sections
    stdout -> list.append(sections, ["STDOUT:\n" <> stdout])
  }

  let output = case sections {
    [] -> "Code executed successfully (no output)."
    _ -> string.join(sections, "\n\n")
  }

  let output = case exec_result.exit_code {
    0 -> output
    code -> output <> "\n\nExit code: " <> int.to_string(code)
  }

  // Append the canonical Verification: line so the coder (and any
  // future tool consumer) can read a single evidence phrase without
  // parsing stderr/exit_code. Unverified stderr on a zero exit is
  // still marked Unverified — the agent has to judge the content
  // rather than bluff past.
  let outcome =
    verification.from_exec(exec_result.exit_code, exec_result.stderr)
  let output = verification.append(output, outcome)

  case exec_result.exit_code {
    0 -> ToolSuccess(tool_use_id:, content: output)
    _ -> ToolFailure(tool_use_id:, error: output)
  }
}
