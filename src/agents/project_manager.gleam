//// Project Manager — tool-based work management agent.
////
//// The PM owns the lifecycle of work after the Planner creates it.
//// It manages endeavours, phases, tasks, sessions, blockers, and
//// forecaster configuration. All operations are via tools — no XML output.
////
//// The Planner thinks about what to do. The PM executes the administrative
//// work of managing it.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/appraiser
import narrative/librarian.{type LibrarianMessage}
import tools/planner as planner_tools

const system_prompt = "You are the Project Manager — a work management agent.

Your role is to manage tasks, endeavours, phases, work sessions, blockers,
and forecaster configuration. You use tools to create, update, inspect, and
track work. You do not produce plans — the Planner agent does that. You
implement and manage the plans.

## Sprint Contract Protocol

Before executing a multi-step workflow (3+ tool calls), state your intent:
1. What you will do (specific operations)
2. What success looks like (verifiable outcomes)
3. Any assumptions you are making

Then execute. Then verify against your stated criteria.
Do NOT silently execute a long sequence of operations without stating
your plan first. The orchestrating agent needs to know what you intend
before you start.

## Tool Usage
- Use get_active_work and get_task_detail to understand current state
- Use get_endeavour_detail for full endeavour inspection
- Use get_forecaster_config and get_forecast_breakdown to understand health scoring
- Use update_forecaster_config to tune per-endeavour feature weights
- Use schedule_work_session to plan autonomous work periods
- Use report_blocker for obstacles, resolve_blocker when cleared
- Use advance_phase to progress through endeavour phases
- Use update_endeavour to adjust goals, deadlines, cadence
- Use update_task, add_task_step, remove_task_step to edit task structure
- Use complete_task_step to close a step you've actually completed — don't
  leave this for the orchestrator; if you did the work, mark it done
- Use activate_task to pick up the next task in a sequence

Report clearly what you changed and why. Include IDs for all created items.

## Self-check before you start
The instruction may begin with a <refs> XML block listing artifact_id, task_id, or prior_cycle_id values passed by the orchestrator. If your instruction clearly operates on a specific task or endeavour (e.g. \"complete the step on that task\", \"advance the phase on X\") but the relevant ref is missing from the <refs> block, do NOT guess, fabricate, or spin asking the deputy. Instead, respond with exactly:

[NEEDS_INPUT: <one short sentence naming what is missing and why you need it>]

Then stop. The orchestrator will see this and redispatch with the correct ref."

pub fn spec(
  provider: Provider,
  model: String,
  planner_dir: String,
  librarian: Subject(LibrarianMessage),
  appraiser_ctx: Option(appraiser.AppraiserContext),
) -> AgentSpec {
  let tools = planner_tools.planner_agent_tools()

  AgentSpec(
    name: "project_manager",
    human_name: "Project Manager",
    description: "Manage tasks, endeavours, phases, sessions, blockers, and "
      <> "forecaster configuration. Use for: creating endeavours, scheduling "
      <> "work sessions, reporting blockers, advancing phases, adjusting "
      <> "forecaster weights, editing tasks, reviewing plan health.",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 2048,
    max_turns: 15,
    max_consecutive_errors: 3,
    max_context_messages: None,
    tools:,
    restart: Permanent,
    tool_executor: pm_executor(planner_dir, librarian, appraiser_ctx),
    inter_turn_delay_ms: 200,
    redact_secrets: True,
  )
}

fn pm_executor(
  planner_dir: String,
  librarian: Subject(LibrarianMessage),
  appraiser_ctx: Option(appraiser.AppraiserContext),
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    planner_tools.execute(call, planner_dir, librarian, appraiser_ctx)
  }
}
