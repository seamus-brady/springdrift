/// Shell tool: run_shell (delegates to sandbox Docker actor).
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option, None, Some}
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import sandbox.{type SandboxMessage, RunCommand}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [run_shell_tool()]
}

fn run_shell_tool() -> Tool {
  tool.new("run_shell")
  |> tool.with_description(
    "Run a shell command in a sandboxed Docker container. The project directory is mounted at /workspace. State persists across calls within a session.",
  )
  |> tool.add_string_param("command", "The shell command to execute", True)
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
    "run_shell" -> run_shell(call, sandbox)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// run_shell
// ---------------------------------------------------------------------------

fn run_shell(
  call: ToolCall,
  sandbox: Option(process.Subject(SandboxMessage)),
) -> ToolResult {
  case sandbox {
    None ->
      ToolFailure(tool_use_id: call.id, error: "Docker sandbox not available")
    Some(subj) -> {
      let decoder = {
        use command <- decode.field("command", decode.string)
        decode.success(command)
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Invalid run_shell input: missing command",
          )
        Ok(cmd) -> {
          let reply_subj = process.new_subject()
          process.send(subj, RunCommand(cmd:, reply_to: reply_subj))
          case process.receive_forever(reply_subj) {
            Ok(output) -> ToolSuccess(tool_use_id: call.id, content: output)
            Error(output) ->
              ToolFailure(
                tool_use_id: call.id,
                error: "Command failed:\n" <> output,
              )
          }
        }
      }
    }
  }
}
