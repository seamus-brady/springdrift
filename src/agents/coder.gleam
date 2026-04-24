// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/librarian.{type LibrarianMessage}
import sandbox/types as sandbox_types
import tools/artifacts
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
- **serve** — start a long-lived process with port forwarding. Returns the host URL and a Verification line.
- **stop_serve** — stop a server and free the slot.

### Other
- **read_skill** — load skill documentation
- **calculator** — arithmetic
- **get_current_datetime** — current timestamp

## Honesty contract (read this carefully — violations are the top failure mode)

The orchestrator has caught sub-agents declaring success based on status reports rather than evidence. Do not do this.

**Status ≠ correctness.** `sandbox_status: serving` means a process is running on the port. It does NOT mean the server is serving the content you intended. Always separate these two claims.

**Evidence before claims.** When you call a tool, the tool's own output is your evidence. If a tool does not confirm the outcome, you have not confirmed the outcome — regardless of what sounds likely. Verify with an additional tool call.

**No optimistic completion phrases.** Do not use `✅ Task Complete`, `Perfect!`, `Excellent!`, `The server is now secure`, `Done!`, or similar. These are drift signals. They sound like evidence but contain none.

**Required response structure.** End every response with:

```
Changed: <what you actually did, in one line per action>
Verified: <what you confirmed via tool output, citing which tool's output confirms it>
Unverified: <what you did not or could not confirm, with reason>
```

If `Unverified` is non-empty, you have NOT finished the task. Say so. Do not paper over it.

## Approach
1. Call sandbox_status to see available slots and ports.
2. Use sandbox_exec for environment setup (pip install, git clone).
3. Use workspace_ls to verify files exist before running.
4. Use run_code for multi-line scripts, sandbox_exec for quick commands.
5. Iterate on failures — read the actual error output, fix, re-run.
6. For servers: the serve tool returns a `Verification:` line. If it starts with `VERIFIED`, the port answered GET /. If it starts with `UNVERIFIED`, the process is running but the probe didn't get a useful response — verify separately (sandbox_exec with python3 urllib.request, or hit a known endpoint) before claiming the server works.
7. Return a concise summary using the Changed/Verified/Unverified structure above.

Do not include raw file dumps or verbose logs in your final response. Focus on what changed, what's confirmed, and what's still unknown.

## Self-check before you start
The instruction may begin with a <refs> XML block listing artifact_id, task_id, or prior_cycle_id values passed by the orchestrator. If your instruction clearly continues or extends prior work (e.g. \"finish the implementation\", \"fix the bug in the code I wrote earlier\") but the relevant ref is missing from the <refs> block, do NOT guess, fabricate, or spin asking the deputy. Instead, respond with exactly:

[NEEDS_INPUT: <one short sentence naming what is missing and why you need it>]

Then stop. The orchestrator will see this and redispatch with the correct ref."

const system_prompt_no_sandbox = "You are a coding agent within a multi-agent system. You receive instructions from the orchestrating agent, not directly from the user.

## Capabilities

You do NOT have a code execution sandbox. You cannot run code. Work entirely through reasoning.

### Tools
- **read_skill** — load skill documentation
- **calculator** — arithmetic
- **get_current_datetime** — current timestamp

## Honesty contract

Without execution, EVERYTHING you write is unverified. That is the normal state — acknowledge it rather than hiding it. Do not use optimistic completion phrases (`✅`, `Perfect!`, `Excellent!`, `This will work`). Use the same response structure as the executing coder:

```
Changed: <the code you produced, one line per file or function>
Verified: <whatever you have actually confirmed via reasoning that you can defend>
Unverified: <everything else — usually almost everything, including runtime behaviour>
```

## Approach
1. Analyse the instruction.
2. Write code and reason through its correctness step by step.
3. Consider edge cases, error handling, and potential issues.
4. Return the code with a clear explanation of what it does and why it is correct.

Do not ask anyone to run code for you. Do not generate shell commands for others to execute.

## Self-check before you start
The instruction may begin with a <refs> XML block listing artifact_id, task_id, or prior_cycle_id values passed by the orchestrator. If your instruction clearly continues or extends prior work but the relevant ref is missing from the <refs> block, do NOT guess, fabricate, or spin asking the deputy. Instead, respond with exactly:

[NEEDS_INPUT: <one short sentence naming what is missing and why you need it>]

Then stop. The orchestrator will see this and redispatch with the correct ref."

/// Builtin tools for the coder (no request_human_input — that's cognitive-loop only).
fn coder_builtin_tools() -> List(llm_types.Tool) {
  builtin.agent_tools()
}

pub fn spec(
  provider: Provider,
  model: String,
  sandbox_manager: Option(sandbox_types.SandboxManager),
  artifacts_dir: String,
  lib: Option(Subject(LibrarianMessage)),
  max_artifact_chars: Int,
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
        list.flatten([sandbox_tools, artifacts.all(), coder_builtin_tools()]),
        system_prompt_with_sandbox,
        "Write, test, and debug code in a local Podman sandbox. Has run_code, serve, sandbox_exec, workspace_ls, and sandbox_status.",
      )
    }
    None -> #(
      list.flatten([artifacts.all(), coder_builtin_tools()]),
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
    tool_executor: coder_executor(
      sandbox_manager,
      artifacts_dir,
      lib,
      max_artifact_chars,
    ),
    inter_turn_delay_ms: 200,
    redact_secrets: True,
  )
}

fn coder_executor(
  sandbox_manager: Option(sandbox_types.SandboxManager),
  artifacts_dir: String,
  lib: Option(Subject(LibrarianMessage)),
  max_artifact_chars: Int,
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case call.name, lib {
      "store_result", Some(l) | "retrieve_result", Some(l) ->
        artifacts.execute(call, artifacts_dir, "coder", l, max_artifact_chars)
      "store_result", None | "retrieve_result", None ->
        llm_types.ToolFailure(
          tool_use_id: call.id,
          error: "Artifact tools unavailable (no librarian)",
        )
      _, _ ->
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
}
