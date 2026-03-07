import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option}
import llm/provider.{type Provider}
import llm/types as llm_types
import sandbox.{type SandboxMessage}
import tools/builtin
import tools/files
import tools/shell

const system_prompt = "You are a coding agent. Your job is to write, modify, and test code.

You have access to: read_file, write_file, list_directory, run_shell, calculator, get_current_datetime.

When writing code:
- Read existing files first to understand patterns
- Write clean, tested code that follows existing conventions
- Run tests after making changes

When you complete your task, respond with a concise summary of your actions and results. Include what was changed and test outcomes, but omit raw file contents and verbose output."

pub fn spec(
  provider: Provider,
  model: String,
  sandbox: Option(process.Subject(SandboxMessage)),
  write_anywhere: Bool,
) -> AgentSpec {
  let tools = list.flatten([files.all(), shell.all(), builtin.all()])

  AgentSpec(
    name: "coder",
    human_name: "Coder",
    description: "Write, modify, and test code using file operations and shell commands in a sandbox",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 4096,
    max_turns: 10,
    max_consecutive_errors: 3,
    tools:,
    restart: Permanent,
    tool_executor: coder_executor(sandbox, write_anywhere),
  )
}

fn coder_executor(
  sandbox: Option(process.Subject(SandboxMessage)),
  write_anywhere: Bool,
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case call.name {
      "run_shell" -> shell.execute(call, sandbox)
      "read_file" | "write_file" | "list_directory" ->
        files.execute(call, write_anywhere)
      _ -> builtin.execute(call)
    }
  }
}
