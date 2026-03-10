import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/list
import llm/provider.{type Provider}
import llm/types as llm_types
import tools/builtin
import tools/web

const system_prompt = "You are a research agent. Your job is to gather information using web search and extraction tools.

You have access to: exa_search (semantic discovery), tavily_search (fast factual lookup), firecrawl_extract (deep page extraction), web_search (DuckDuckGo fallback), fetch_url (simple HTTP GET), read_skill, calculator, get_current_datetime, request_human_input.

When you complete your task, respond with a concise summary of your findings. Include key details the orchestrator needs to make decisions, but omit raw file contents, verbose tool output, and intermediate reasoning steps."

pub fn spec(provider: Provider, model: String) -> AgentSpec {
  let tools = list.flatten([web.all(), builtin.all()])

  AgentSpec(
    name: "researcher",
    human_name: "Researcher",
    description: "Gather information by fetching URLs and reading skill docs",
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
    "fetch_url"
    | "web_search"
    | "exa_search"
    | "tavily_search"
    | "firecrawl_extract" -> web.execute(call)
    _ -> builtin.execute(call)
  }
}
