//// Sandbox tools for the coder agent — run_code, serve, stop_serve.
////
//// Routes tool calls to the sandbox manager actor.

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

/// Check if a tool name is a sandbox tool.
pub fn is_sandbox_tool(name: String) -> Bool {
  name == "run_code" || name == "serve" || name == "stop_serve"
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

  case exec_result.exit_code {
    0 -> ToolSuccess(tool_use_id:, content: output)
    _ -> ToolFailure(tool_use_id:, error: output)
  }
}
