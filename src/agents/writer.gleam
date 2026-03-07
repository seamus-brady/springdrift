import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/list
import llm/provider.{type Provider}
import llm/types as llm_types
import tools/builtin
import tools/files

const system_prompt = "You are a writer agent. Your job is to synthesise research findings into structured, well-cited reports.

You have access to: read_file, write_file, list_directory, calculator, get_current_datetime, read_skill.

When writing reports:
- Structure content with clear sections and headings
- Cite sources inline with name, date, and URL where available
- Apply hedging language to uncertain or speculative claims
- Distinguish between confirmed facts and projections
- Flag data older than the freshness threshold

When you complete your task, respond with the finished report text. Include all citations and confidence assessments."

pub fn spec(
  provider: Provider,
  model: String,
  write_anywhere: Bool,
) -> AgentSpec {
  let tools = list.flatten([files.all(), builtin.all()])

  AgentSpec(
    name: "writer",
    human_name: "Writer",
    description: "Synthesise research into structured reports with citations and hedging language",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 4096,
    max_turns: 5,
    max_consecutive_errors: 2,
    tools:,
    restart: Permanent,
    tool_executor: writer_executor(write_anywhere),
  )
}

fn writer_executor(
  write_anywhere: Bool,
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case call.name {
      "read_file" | "write_file" | "list_directory" ->
        files.execute(call, write_anywhere)
      _ -> builtin.execute(call)
    }
  }
}
