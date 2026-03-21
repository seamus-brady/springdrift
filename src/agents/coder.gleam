import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/list
import gleam/option.{type Option, None, Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import sandbox/types as sandbox_types
import tools/builtin
import tools/sandbox

const system_prompt_with_sandbox = "You are a coding agent within a multi-agent system. You receive instructions from the orchestrating agent, not directly from the user.

## Capabilities

You have a local Podman sandbox for code execution.

### run_code
Execute code in an isolated container. Supports Python (default), JavaScript, and Bash. Each call runs in the same container workspace within your slot.

### serve
Start a long-lived process (web server, API) with port forwarding to the host. Returns the host URL. Use **stop_serve** to tear it down.

### Other tools
- **read_skill** — load skill documentation
- **calculator** — arithmetic
- **get_current_datetime** — current timestamp

## Approach
1. Analyse the instruction
2. Write code and execute it via run_code to verify
3. Iterate on failures — read error output, fix, re-run
4. For servers, use serve and confirm the endpoint is reachable
5. Return a concise summary: what was built, what was tested, what the results were

Do not include raw file dumps or verbose logs in your final response. Focus on outcomes."

const system_prompt_no_sandbox = "You are a coding agent within a multi-agent system. You receive instructions from the orchestrating agent, not directly from the user.

## Capabilities

You do NOT have a code execution sandbox. You cannot run code. Work entirely through reasoning.

### Tools
- **read_skill** — load skill documentation
- **calculator** — arithmetic
- **get_current_datetime** — current timestamp

## Approach
1. Analyse the instruction
2. Write code and reason through its correctness step by step
3. Consider edge cases, error handling, and potential issues
4. Return the code with a clear explanation of what it does and why it is correct

Do not ask anyone to run code for you. Do not generate shell commands for others to execute. If you cannot verify something without execution, state your confidence level and what remains unverified."

/// Builtin tools for the coder (no request_human_input — that's cognitive-loop only).
fn coder_builtin_tools() -> List(llm_types.Tool) {
  builtin.agent_tools()
}

pub fn spec(
  provider: Provider,
  model: String,
  sandbox_manager: Option(sandbox_types.SandboxManager),
) -> AgentSpec {
  let #(tools, system_prompt, description) = case sandbox_manager {
    Some(_manager) -> {
      // Sandbox tools + coder builtins (no request_human_input)
      let sandbox_tools = [
        sandbox.run_code_tool(),
        sandbox.serve_tool(),
        sandbox.stop_serve_tool(),
      ]
      #(
        list.flatten([sandbox_tools, coder_builtin_tools()]),
        system_prompt_with_sandbox,
        "Write, test, and debug code in a local Podman sandbox. Has run_code, serve, and stop_serve.",
      )
    }
    None -> #(
      coder_builtin_tools(),
      system_prompt_no_sandbox,
      "Write and reason about code. No execution sandbox available — works through analysis only.",
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
