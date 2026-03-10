import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/option.{None}
import llm/provider.{type Provider}
import llm/types as llm_types
import tools/builtin

const system_prompt = "You are a coding agent. Your job is to write, modify, and test code.

You have access to: calculator, get_current_datetime, request_human_input, read_skill.

When writing code:
- Ask the human for file contents or directory listings when needed
- Provide clear, tested code that follows existing conventions
- Ask the human to run tests after making changes

When you complete your task, respond with a concise summary of your actions and results. Include what was changed and test outcomes, but omit raw file contents and verbose output."

pub fn spec(provider: Provider, model: String) -> AgentSpec {
  let tools = builtin.all()

  AgentSpec(
    name: "coder",
    human_name: "Coder",
    description: "Write and reason about code, delegating file and shell operations to the human",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 4096,
    max_turns: 10,
    max_consecutive_errors: 3,
    max_context_messages: None,
    tools:,
    restart: Permanent,
    tool_executor: coder_executor,
  )
}

fn coder_executor(call: llm_types.ToolCall) -> llm_types.ToolResult {
  builtin.execute(call)
}
