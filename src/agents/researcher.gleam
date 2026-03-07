import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/list
import llm/provider.{type Provider}
import llm/types as llm_types
import tools/builtin
import tools/files
import tools/web

const system_prompt = "You are a research agent. Your job is to gather information by reading files, listing directories, and fetching URLs.

You have access to: read_file, list_directory, fetch_url, read_skill, calculator, get_current_datetime.

When you complete your task, respond with a concise summary of your findings. Include key details the orchestrator needs to make decisions, but omit raw file contents, verbose tool output, and intermediate reasoning steps."

pub fn spec(provider: Provider, model: String) -> AgentSpec {
  let tools = list.flatten([files.all(), web.all(), builtin.all()])

  AgentSpec(
    name: "researcher",
    human_name: "Researcher",
    description: "Gather information by reading files, browsing directories, fetching URLs, and reading skill docs",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 2048,
    max_turns: 8,
    max_consecutive_errors: 3,
    tools:,
    restart: Permanent,
    tool_executor: researcher_executor,
  )
}

fn researcher_executor(call: llm_types.ToolCall) -> llm_types.ToolResult {
  case call.name {
    "read_file" | "list_directory" -> files.execute(call, False)
    "fetch_url" -> web.execute(call)
    _ -> builtin.execute(call)
  }
}
