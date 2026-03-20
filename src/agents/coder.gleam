import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/option.{type Option, None, Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import sandbox/types as sandbox_types
import tools/builtin
import tools/sandbox

const system_prompt_with_sandbox = "You are a coding agent. Your job is to write, modify, and reason about code.

## Tools

### Code execution
You have **run_code** — a local Podman sandbox for executing code. It supports Python (default), JavaScript, and Bash. Each call runs in an isolated container with its own workspace.

Use run_code to:
- Test code snippets before presenting them
- Run data transformations or calculations
- Verify logic, parse files, or prototype solutions
- Install packages with pip within the code block

### Serving
You have **serve** — start a long-lived process (Flask app, API server, etc.) in the sandbox with port forwarding to the host. The response tells you the host URL where the app is accessible.

Use serve to:
- Start web servers, APIs, or interactive apps
- Make services accessible to the user on localhost

Use **stop_serve** to stop a running server and free the slot.

### Other tools
- **request_human_input**: Ask the human for file contents, directory listings, or clarification
- **read_skill**: Load skill documentation for patterns and conventions
- **calculator**: Quick arithmetic
- **get_current_datetime**: Current date and time

## Workflow
1. Understand the task — ask the human for context if needed
2. Write and test code using run_code
3. Iterate based on results
4. Present the final solution with a clear summary

When you complete your task, respond with a concise summary of what was built or changed, including test results. Omit raw file contents and verbose output."

const system_prompt_no_sandbox = "You are a coding agent. Your job is to write, modify, and reason about code.

## Tools
- **request_human_input**: Ask the human for file contents, directory listings, or clarification. You can also ask the human to run code on your behalf and report the results.
- **read_skill**: Load skill documentation for patterns and conventions
- **calculator**: Quick arithmetic
- **get_current_datetime**: Current date and time

Note: You do NOT have a code execution sandbox. If you need to test code, use **request_human_input** to ask the human to run it and share the output.

## Workflow
1. Understand the task — ask the human for context if needed
2. Write code and reason through its correctness
3. If testing is needed, ask the human to run it via request_human_input
4. Present the final solution with a clear summary

When you complete your task, respond with a concise summary of what was built or changed. Omit raw file contents and verbose output."

pub fn spec(
  provider: Provider,
  model: String,
  sandbox_manager: Option(sandbox_types.SandboxManager),
) -> AgentSpec {
  let #(tools, system_prompt, description) = case sandbox_manager {
    Some(manager) -> #(
      sandbox.tools(manager),
      system_prompt_with_sandbox,
      "Write, test, and debug code. Has run_code for executing Python/JS/Bash in a local Podman sandbox, plus serve for starting web servers with port forwarding.",
    )
    None -> #(
      builtin.all(),
      system_prompt_no_sandbox,
      "Write, modify, and reason about code. Uses request_human_input to ask the human to run code and share results. No sandbox available.",
    )
  }

  AgentSpec(
    name: "coder",
    human_name: "Coder",
    description:,
    system_prompt:,
    provider:,
    model:,
    max_tokens: 4096,
    max_turns: 10,
    max_consecutive_errors: 3,
    max_context_messages: None,
    tools:,
    restart: Permanent,
    tool_executor: coder_executor(sandbox_manager),
    inter_turn_delay_ms: 200,
    redact_secrets: True,
  )
}

fn coder_executor(
  sandbox_manager: Option(sandbox_types.SandboxManager),
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case sandbox_manager {
      Some(manager) ->
        case sandbox.is_sandbox_tool(call.name) {
          True -> sandbox.execute(call, manager)
          False -> builtin.execute(call)
        }
      None -> builtin.execute(call)
    }
  }
}
