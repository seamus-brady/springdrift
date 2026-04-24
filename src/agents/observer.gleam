// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{type AgentSpec, AgentSpec, Transient}
import facts/provenance_check
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/librarian.{type LibrarianMessage}
import tools/artifacts
import tools/memory

const system_prompt = "You are the Observer — a diagnostic and introspection agent for this system.

Your role is to examine past activity, identify patterns, explain failures,
and report on system state. You observe and report. You do not act, plan,
write code, or search the web.

When asked to explain what happened, use inspect_cycle and list_recent_cycles
to find specific cycles, then report clearly on what occurred, what tools were
used, and what failed.

When asked about patterns over time, use reflect and query_tool_activity to
surface aggregate statistics. Use recall_cases to find similar past situations.

When asked about the system's current constitution, use introspect.

Report findings concisely. Include cycle IDs, timestamps, tool names, and
error messages where relevant. Avoid speculation — report what the data shows.

After your analysis, include a structured summary:
- What was found
- Key cycle IDs or dates referenced
- Any failure patterns identified
- Recommendations (if explicitly requested)

## Self-check before you start
The instruction may begin with a <refs> XML block listing artifact_id, task_id, or prior_cycle_id values passed by the orchestrator. If your instruction clearly continues or extends prior work (e.g. \"review the investigation from earlier\", \"look at the cycle you diagnosed\") but the relevant ref is missing from the <refs> block, do NOT guess, fabricate, or spin asking the deputy. Instead, respond with exactly:

[NEEDS_INPUT: <one short sentence naming what is missing and why you need it>]

Then stop. The orchestrator will see this and redispatch with the correct ref.

## Before you return
End your final reply with one line in this format:

Interpreted as: <one sentence summary of how you understood the task and what you did>

Keep it to one sentence. This lets the orchestrator notice if your interpretation doesn't match the intent."

pub fn spec(
  provider: Provider,
  model: String,
  narrative_dir: String,
  facts_dir: String,
  librarian: Subject(LibrarianMessage),
  memory_limits: memory.MemoryLimits,
  introspect_ctx: Option(memory.IntrospectContext),
  fact_decay_half_life_days: Int,
  artifacts_dir: String,
  max_artifact_chars: Int,
) -> AgentSpec {
  let tools = list.flatten([memory.observer_tools(), artifacts.all()])

  AgentSpec(
    name: "observer",
    human_name: "Observer",
    description: "Examine past activity, explain failures, identify patterns, "
      <> "and report on system state. Use for: understanding what happened in "
      <> "a past cycle, spotting tool failure patterns, reviewing daily stats, "
      <> "tracing how a fact changed, auditing agent behaviour.",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 2048,
    max_turns: 6,
    max_consecutive_errors: 2,
    max_context_messages: Some(20),
    tools:,
    restart: Transient,
    tool_executor: observer_executor(
      narrative_dir,
      facts_dir,
      librarian,
      memory_limits,
      introspect_ctx,
      fact_decay_half_life_days,
      artifacts_dir,
      max_artifact_chars,
    ),
    inter_turn_delay_ms: 0,
    redact_secrets: True,
  )
}

fn observer_executor(
  narrative_dir: String,
  facts_dir: String,
  librarian: Subject(LibrarianMessage),
  memory_limits: memory.MemoryLimits,
  introspect_ctx: Option(memory.IntrospectContext),
  fact_decay_half_life_days: Int,
  artifacts_dir: String,
  max_artifact_chars: Int,
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case call.name {
      "store_result" | "retrieve_result" ->
        artifacts.execute(
          call,
          artifacts_dir,
          "observer",
          librarian,
          max_artifact_chars,
        )
      _ -> {
        // Observer uses facts context for read-only trace operations only
        let facts_ctx =
          Some(memory.FactsContext(
            facts_dir:,
            cycle_id: "observer",
            agent_id: "observer",
            fact_decay_half_life_days:,
            // Observer uses facts context for read-only trace operations.
            // It doesn't write synthesis facts itself; the classification
            // only matters if it did, so defaults are fine.
            cycle_tool_names: [],
            evidence_config: provenance_check.default_config(),
          ))
        memory.execute(
          call,
          narrative_dir,
          Some(librarian),
          facts_ctx,
          introspect_ctx,
          memory_limits,
        )
      }
    }
  }
}
