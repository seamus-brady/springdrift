import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/option.{None}
import llm/provider.{type Provider}
import llm/types as llm_types
import tools/builtin

const system_prompt = "You are a writer agent. Your job is to synthesise research findings into structured, well-cited reports.

You have access to: calculator, get_current_datetime, request_human_input, read_skill.

When writing reports:
- Structure content with clear sections and headings
- Cite sources inline with name, date, and URL where available
- Apply hedging language to uncertain or speculative claims
- Distinguish between confirmed facts and projections
- Flag data older than the freshness threshold

When you complete your task, respond with the finished report text. Include all citations and confidence assessments."

pub fn spec(provider: Provider, model: String) -> AgentSpec {
  let tools = builtin.all()

  AgentSpec(
    name: "writer",
    human_name: "Writer",
    description: "Synthesise research findings into structured, well-cited reports. Applies hedging language to uncertain claims, flags stale data, and distinguishes confirmed facts from projections.",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 4096,
    max_turns: 5,
    max_consecutive_errors: 2,
    max_context_messages: None,
    tools:,
    restart: Permanent,
    tool_executor: writer_executor,
    inter_turn_delay_ms: 200,
  )
}

fn writer_executor(call: llm_types.ToolCall) -> llm_types.ToolResult {
  builtin.execute(call)
}
