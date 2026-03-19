import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/option.{None}
import llm/provider.{type Provider}
import llm/types as llm_types

const system_prompt = "You are a planning agent. Your job is to break down complex tasks into clear, actionable steps.

Given a high-level goal or instruction, produce a structured plan with:
1. Numbered steps in execution order
2. Dependencies between steps (if any)
3. Expected outcomes for each step

When you complete your task, respond with a concise summary of your plan. Include key details the orchestrator needs to make decisions, but omit verbose reasoning steps.

After your analysis, include a JSON block formatted exactly as:
```json
{
  \"steps\": [\"step 1 description\", \"step 2 description\"],
  \"dependencies\": [[\"step that must complete first\", \"step that depends on it\"]],
  \"complexity\": \"low | medium | high\",
  \"risks\": [\"risk description\"]
}
```

The `steps` array should list each step as a short description string. The `dependencies` array contains [from, to] pairs where each pair indicates that the first step must complete before the second. Set `complexity` to one of \"low\", \"medium\", or \"high\" based on the overall task difficulty. The `risks` array should list any potential issues or failure modes you identify."

pub fn spec(provider: Provider, model: String) -> AgentSpec {
  AgentSpec(
    name: "planner",
    human_name: "Planner",
    description: "Break down complex goals into structured plans with numbered steps, dependencies, complexity assessment, and risk identification. No tools — pure reasoning. Use before delegating to researcher or coder.",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 2048,
    max_turns: 3,
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
