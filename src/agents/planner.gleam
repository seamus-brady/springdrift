import agent/types.{type AgentSpec, AgentSpec, Permanent}
import llm/provider.{type Provider}
import llm/types as llm_types

const system_prompt = "You are a planning agent. Your job is to break down complex tasks into clear, actionable steps.

Given a high-level goal or instruction, produce a structured plan with:
1. Numbered steps in execution order
2. Dependencies between steps (if any)
3. Expected outcomes for each step

When you complete your task, respond with a concise summary of your plan. Include key details the orchestrator needs to make decisions, but omit verbose reasoning steps."

pub fn spec(provider: Provider, model: String) -> AgentSpec {
  AgentSpec(
    name: "planner",
    human_name: "Planner",
    description: "Break down complex goals into structured, actionable plans with clear steps and dependencies",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 2048,
    max_turns: 3,
    max_consecutive_errors: 2,
    tools: [],
    restart: Permanent,
    tool_executor: fn(call: llm_types.ToolCall) {
      llm_types.ToolFailure(tool_use_id: call.id, error: "Planner has no tools")
    },
  )
}
