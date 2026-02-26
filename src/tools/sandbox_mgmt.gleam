/// Sandbox management tools: sandbox_status, sandbox_logs, restart_sandbox.
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import sandbox.{type SandboxMessage, GetLogs, GetStatus, Restart, SandboxRunning}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [sandbox_status_tool(), sandbox_logs_tool(), restart_sandbox_tool()]
}

fn sandbox_status_tool() -> Tool {
  tool.new("sandbox_status")
  |> tool.with_description(
    "Check the Docker sandbox container status, including container ID and exposed ports.",
  )
  |> tool.build()
}

fn sandbox_logs_tool() -> Tool {
  tool.new("sandbox_logs")
  |> tool.with_description(
    "Retrieve the last N lines of container-level output from the Docker sandbox. Shows stdout/stderr of container processes, not exec'd commands.",
  )
  |> tool.add_integer_param(
    "lines",
    "Number of log lines to return (default: 50)",
    False,
  )
  |> tool.build()
}

fn restart_sandbox_tool() -> Tool {
  tool.new("restart_sandbox")
  |> tool.with_description(
    "Stop and restart the Docker sandbox container. Files in /workspace are preserved.",
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(
  call: ToolCall,
  sandbox: Option(process.Subject(SandboxMessage)),
) -> ToolResult {
  case call.name {
    "sandbox_status" -> sandbox_status(call, sandbox)
    "sandbox_logs" -> sandbox_logs(call, sandbox)
    "restart_sandbox" -> restart_sandbox(call, sandbox)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// sandbox_status
// ---------------------------------------------------------------------------

fn sandbox_status(
  call: ToolCall,
  sandbox: Option(process.Subject(SandboxMessage)),
) -> ToolResult {
  case sandbox {
    None ->
      ToolFailure(tool_use_id: call.id, error: "Docker sandbox not available")
    Some(subj) -> {
      let reply_subj = process.new_subject()
      process.send(subj, GetStatus(reply_to: reply_subj))
      let status = process.receive_forever(reply_subj)
      let SandboxRunning(container_id:, ports:) = status
      let ports_str = string.join(list.map(ports, int.to_string), ", ")
      let content =
        "Container: "
        <> container_id
        <> "\nStatus: Running\nPorts: "
        <> ports_str
      ToolSuccess(tool_use_id: call.id, content:)
    }
  }
}

// ---------------------------------------------------------------------------
// sandbox_logs
// ---------------------------------------------------------------------------

fn sandbox_logs(
  call: ToolCall,
  sandbox: Option(process.Subject(SandboxMessage)),
) -> ToolResult {
  case sandbox {
    None ->
      ToolFailure(tool_use_id: call.id, error: "Docker sandbox not available")
    Some(subj) -> {
      let decoder = {
        use lines <- decode.optional_field("lines", 50, decode.int)
        decode.success(lines)
      }
      let lines = case json.parse(call.input_json, decoder) {
        Ok(n) -> n
        Error(_) -> 50
      }
      let reply_subj = process.new_subject()
      process.send(subj, GetLogs(lines:, reply_to: reply_subj))
      case process.receive_forever(reply_subj) {
        Ok(output) -> ToolSuccess(tool_use_id: call.id, content: output)
        Error(msg) -> ToolFailure(tool_use_id: call.id, error: msg)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// restart_sandbox
// ---------------------------------------------------------------------------

fn restart_sandbox(
  call: ToolCall,
  sandbox: Option(process.Subject(SandboxMessage)),
) -> ToolResult {
  case sandbox {
    None ->
      ToolFailure(tool_use_id: call.id, error: "Docker sandbox not available")
    Some(subj) -> {
      let reply_subj = process.new_subject()
      process.send(subj, Restart(reply_to: reply_subj))
      case process.receive(reply_subj, 30_000) {
        Ok(Ok(Nil)) ->
          ToolSuccess(
            tool_use_id: call.id,
            content: "Sandbox restarted successfully",
          )
        Ok(Error(msg)) ->
          ToolFailure(tool_use_id: call.id, error: "Restart failed: " <> msg)
        Error(Nil) ->
          ToolFailure(tool_use_id: call.id, error: "Restart timed out")
      }
    }
  }
}
