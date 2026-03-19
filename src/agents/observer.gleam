import agent/types.{type AgentSpec, AgentSpec, Transient}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/librarian.{type LibrarianMessage}
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
- Recommendations (if explicitly requested)"

pub fn spec(
  provider: Provider,
  model: String,
  narrative_dir: String,
  librarian: Subject(LibrarianMessage),
  memory_limits: memory.MemoryLimits,
  introspect_ctx: Option(memory.IntrospectContext),
) -> AgentSpec {
  let tools = memory.observer_tools()

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
      librarian,
      memory_limits,
      introspect_ctx,
    ),
    inter_turn_delay_ms: 0,
    redact_secrets: True,
  )
}

fn observer_executor(
  narrative_dir: String,
  librarian: Subject(LibrarianMessage),
  memory_limits: memory.MemoryLimits,
  introspect_ctx: Option(memory.IntrospectContext),
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    memory.execute(
      call,
      narrative_dir,
      Some(librarian),
      None,
      introspect_ctx,
      memory_limits,
    )
  }
}
