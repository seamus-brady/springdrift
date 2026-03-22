import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/list
import gleam/option.{type Option, None, Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import sandbox/types as sandbox_types
import tools/builtin
import tools/sandbox

const system_prompt_with_sandbox = "You are a coding agent within a multi-agent system. You receive instructions from the orchestrating agent, not directly from the user.

## Sandbox Environment

You have a local Podman sandbox with persistent workspace. Files you create persist across run_code calls within the same session. The container starts with a minimal image — install packages with sandbox_exec before using them.

## Tools

### Execution
- **run_code** — execute Python/JavaScript/Bash code in the sandbox. Writes to a file and runs it.
- **sandbox_exec** — run a shell command directly (git, pip, curl, ls, etc.). Faster than run_code for one-liners. Runs in /workspace.

### Environment management
- **sandbox_status** — check slot availability, port mappings, container health. Call this first to understand your environment.
- **workspace_ls** — list files in the workspace. See what exists before writing.
- **sandbox_exec** with pip/git — install packages, clone repos, manage files.

### Serving
- **serve** — start a long-lived process with port forwarding. Returns the host URL.
- **stop_serve** — stop a server and free the slot.

### Other
- **read_skill** — load skill documentation
- **calculator** — arithmetic
- **get_current_datetime** — current timestamp

## Approach
1. Call sandbox_status to see available slots and ports
2. Use sandbox_exec for environment setup (pip install, git clone)
3. Use workspace_ls to verify files exist before running
4. Use run_code for multi-line scripts, sandbox_exec for quick commands
5. Iterate on failures — read error output, fix, re-run
6. For servers, use serve and verify with sandbox_exec (curl localhost:PORT)
7. Return a concise summary: what was built, what was tested, what the results were

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
      let sandbox_tools = [
        sandbox.run_code_tool(),
        sandbox.serve_tool(),
        sandbox.stop_serve_tool(),
        sandbox.sandbox_status_tool(),
        sandbox.workspace_ls_tool(),
        sandbox.sandbox_exec_tool(),
      ]
      #(
        list.flatten([sandbox_tools, coder_builtin_tools()]),
        system_prompt_with_sandbox,
        "Write, test, and debug code in a local Podman sandbox. Has run_code, serve, sandbox_exec, workspace_ls, and sandbox_status.",
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
