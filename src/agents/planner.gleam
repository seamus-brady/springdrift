//// Planner — pure reasoning agent for plan generation.
////
//// The Planner decomposes goals into structured plans with steps,
//// dependencies, complexity assessment, and risk identification.
//// Output is XML validated against the planner XSD schema.
//// No tools — pure reasoning only.
////
//// Work management (endeavours, phases, sessions, blockers, forecaster config)
//// is handled by the Project Manager agent.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/option.{None}
import llm/provider.{type Provider}
import llm/types as llm_types
import xstructor/schemas

const base_prompt = "You are a planning agent. Your job is to break down complex tasks into clear, actionable steps.

Given a high-level goal or instruction, produce a structured plan. Think through the problem, then output your plan as XML matching the schema below. Your ENTIRE final response must be valid XML — no prose before or after."

pub fn system_prompt() -> String {
  schemas.build_system_prompt(
    base_prompt,
    schemas.planner_output_xsd,
    schemas.planner_output_example,
  )
}

/// Pure reasoning planner — no tools, XML output only.
pub fn spec(provider: Provider, model: String) -> AgentSpec {
  AgentSpec(
    name: "planner",
    human_name: "Planner",
    description: "Break down complex goals into structured plans with numbered "
      <> "steps, dependencies, complexity assessment, and risk identification. "
      <> "No tools — pure reasoning. Use before delegating to researcher or coder.",
    system_prompt: system_prompt(),
    provider:,
    model:,
    max_tokens: 2048,
    max_turns: 5,
    max_consecutive_errors: 2,
    max_context_messages: None,
    tools: [],
    restart: Permanent,
    tool_executor: fn(call: llm_types.ToolCall) {
      llm_types.ToolFailure(tool_use_id: call.id, error: "Planner has no tools")
    },
    inter_turn_delay_ms: 200,
    redact_secrets: True,
  )
}

/// Planner variant for replanning triggered by the Forecaster.
pub fn spec_with_forecast(
  provider: Provider,
  model: String,
  forecast_context: String,
) -> AgentSpec {
  let replan_prompt =
    "<forecast_context>\n"
    <> forecast_context
    <> "\n</forecast_context>\n\n"
    <> system_prompt()
  AgentSpec(
    name: "planner",
    human_name: "Planner",
    description: "Break down complex goals into structured plans with numbered "
      <> "steps, dependencies, complexity assessment, and risk identification. "
      <> "No tools — pure reasoning.",
    system_prompt: replan_prompt,
    provider:,
    model:,
    max_tokens: 2048,
    max_turns: 5,
    max_consecutive_errors: 2,
    max_context_messages: None,
    tools: [],
    restart: Permanent,
    tool_executor: fn(call: llm_types.ToolCall) {
      llm_types.ToolFailure(tool_use_id: call.id, error: "Planner has no tools")
    },
    inter_turn_delay_ms: 200,
    redact_secrets: True,
  )
}
