// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{type AgentSpec, AgentSpec, Permanent}
import coder/manager as coder_manager
import coder/types as coder_types
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/appraiser
import narrative/librarian.{type LibrarianMessage}
import tools/builtin
import tools/coder as coder_tools
import tools/coder_dispatch
import tools/planner as planner_tools

// ---------------------------------------------------------------------------
// System prompt
// ---------------------------------------------------------------------------

const system_prompt = "You are the Coder agent. The Project Manager dispatches a task to you; you frame the work, delegate the actual edits to a sandboxed OpenCode session via `dispatch_coder`, and report back what landed.

## Your model

You do NOT directly read or write project files. The OpenCode session running in a sandbox container does that — you give it a brief, it edits and commits, you observe the result. The session has its own internal reasoning loop; you don't drive it turn by turn.

## The loop

1. **Frame**. Use `get_task_detail` for the steps the Planner produced. Use `project_status`, `project_grep`, `project_read` to understand current state. Decide what's in scope.
2. **Dispatch**. Call `dispatch_coder` with a clear brief: what to change, which files matter, what success looks like. The call blocks until the session ends; the response includes stop_reason, tokens, cost, and the model's natural-language summary.
3. **Inspect**. Re-run `project_status` / `project_read` after dispatch to see what actually landed on disk. Don't trust the session's self-report alone.
4. **Iterate or land**. If the brief was too broad, dispatch again with a tighter follow-up. If a step is done, `complete_task_step`. If something blocks, `report_blocker`. If a planned risk materialised, `flag_risk`.

## Tools

### Planning + work-management (Group A)
- **get_task_detail** — read the active task's steps and risks
- **complete_task_step** — mark a step done as the coder lands it
- **flag_risk** — surface a materialised planned risk to Forecaster
- **report_blocker** — escalate when the coder can't proceed

### Project awareness (Group B, host-side)
- **project_status** — git branch, dirty count, untracked count
- **project_read** — read a host file (path relative to project_root)
- **project_grep** — ripgrep search across the project

### Coder dispatch (Group C)
- **dispatch_coder** — run one OpenCode session with a brief and budget. Returns when the session ends. May be called multiple times in one task if the work splits naturally.

### Builtin
- **read_skill** — load skill documentation
- **calculator** — arithmetic
- **get_current_datetime** — current timestamp

## Honesty contract

The dispatch response is the model's claim, not the project's confirmation. Always verify on disk afterwards via `project_status` / `project_read`.

**Required response structure.** End every response with:

```
Changed: <what landed on disk, by file or commit, observed via project_status/project_read>
Verified: <what you confirmed, citing which tool output confirms it>
Unverified: <what dispatch_coder claimed but you did not confirm, with reason>
```

If `Unverified` is non-empty, you have NOT finished. Say so.

**No optimistic completion phrases.** Do not use ✅, 'Perfect!', 'Excellent!', 'The task is complete' as standalone claims. Evidence first.

## Self-check before you start
The instruction may begin with a <refs> XML block listing artifact_id, task_id, or prior_cycle_id values passed by the orchestrator. If your instruction clearly continues prior work but the relevant ref is missing from the <refs> block, do NOT guess. Respond with exactly:

[NEEDS_INPUT: <one short sentence naming what is missing and why you need it>]

Then stop.

## Before you return
End your final reply with one line in this format:

Interpreted as: <one sentence summary of how you understood the task and what you did>

Keep it to one sentence."

/// Builtin tools for the coder (no request_human_input — that's cognitive-loop only).
fn coder_builtin_tools() -> List(llm_types.Tool) {
  builtin.agent_tools()
}

/// Bundle of dependencies the coder agent needs at runtime. Required —
/// without these the coder agent cannot do anything useful, so the
/// agent is only registered when [coder] is fully configured (see
/// `springdrift.maybe_build_real_coder_deps`).
pub type RealCoderDeps {
  RealCoderDeps(
    manager: coder_manager.CoderManager,
    project_root: String,
    planner_dir: String,
    librarian: Subject(LibrarianMessage),
    appraiser_ctx: Option(appraiser.AppraiserContext),
    dispatch_defaults: coder_dispatch.DispatchDefaults,
  )
}

pub fn spec(
  provider: Provider,
  model: String,
  skills_dirs: List(String),
  real_coder: RealCoderDeps,
) -> AgentSpec {
  let tools =
    list.flatten([
      planner_tools.coder_agent_tools(),
      coder_tools.all(),
      coder_dispatch.all(),
      coder_builtin_tools(),
    ])
  AgentSpec(
    name: "coder",
    human_name: "Coder",
    description: "Orchestrate code edits via the OpenCode-backed sandbox. "
      <> "Frames the brief with project_status/project_read/project_grep, "
      <> "delegates the edits via dispatch_coder, verifies the result on "
      <> "disk, and integrates with the Planner via Group A work-management "
      <> "tools (get_task_detail, complete_task_step, flag_risk, report_blocker).",
    system_prompt: system_prompt,
    provider: provider,
    model: model,
    max_tokens: 4096,
    max_turns: 20,
    max_consecutive_errors: 3,
    max_context_messages: None,
    tools: tools,
    restart: Permanent,
    tool_executor: coder_executor(skills_dirs, real_coder),
    inter_turn_delay_ms: 200,
    redact_secrets: True,
  )
}

fn coder_executor(
  skills_dirs: List(String),
  deps: RealCoderDeps,
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case is_planner_group_a(call.name) {
      True ->
        planner_tools.execute(
          call,
          deps.planner_dir,
          deps.librarian,
          deps.appraiser_ctx,
        )
      False ->
        case coder_tools.is_project_tool(call.name) {
          True -> coder_tools.execute(call, deps.project_root, None)
          False ->
            case coder_dispatch.is_sync_coder_dispatch_tool(call.name) {
              True -> coder_dispatch.execute(call, Some(deps.manager), None)
              False ->
                case coder_dispatch.is_dispatch_coder_tool(call.name) {
                  True -> run_dispatch_sync(call, deps)
                  False -> builtin.execute(call, skills_dirs)
                }
            }
        }
    }
  }
}

/// Dispatch a coder task synchronously from inside the agent's react
/// loop. The agent framework runs each turn on its own process, so
/// blocking on `manager.dispatch_task` here only freezes that agent's
/// loop — the cognitive loop is unaffected. Mirrors what the cog loop
/// does asynchronously, but without the worker indirection (the agent
/// framework's process IS the worker).
fn run_dispatch_sync(
  call: llm_types.ToolCall,
  deps: RealCoderDeps,
) -> llm_types.ToolResult {
  case coder_dispatch.parse_dispatch_input(call.input_json) {
    Error(msg) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid dispatch_coder input: " <> msg,
      )
    Ok(parsed) -> {
      let #(budget, clamps) =
        coder_dispatch.resolve_budget(parsed, deps.dispatch_defaults)
      case coder_manager.dispatch_task(deps.manager, parsed.brief, budget) {
        Error(e) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "dispatch_coder failed: " <> coder_types.format_error(e),
          )
        Ok(dr) ->
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: coder_dispatch.format_dispatch_result(dr, clamps),
          )
      }
    }
  }
}

fn is_planner_group_a(name: String) -> Bool {
  case name {
    "get_task_detail" | "complete_task_step" | "flag_risk" | "report_blocker" ->
      True
    _ -> False
  }
}
