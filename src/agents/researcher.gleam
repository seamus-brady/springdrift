import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/librarian.{type LibrarianMessage}
import tools/artifacts
import tools/builtin
import tools/web

const system_prompt = "You are a research agent. Your job is to gather information using web search and extraction tools.

You have access to: exa_search (semantic discovery), tavily_search (fast factual lookup), firecrawl_extract (deep page extraction), web_search (DuckDuckGo fallback), fetch_url (simple HTTP GET), store_result (save large content to disk), retrieve_result (read back stored content), read_skill, calculator, get_current_datetime, request_human_input.

When fetching large pages, use store_result to save the content and work with the artifact_id instead of keeping the full text in context. Use retrieve_result to re-read stored content when needed.

When you complete your task, respond with a concise summary of your findings. Include key details the orchestrator needs to make decisions, but omit raw file contents, verbose tool output, and intermediate reasoning steps."

pub fn spec(
  provider: Provider,
  model: String,
  artifacts_dir: String,
  lib: Subject(LibrarianMessage),
) -> AgentSpec {
  let tools = list.flatten([web.all(), artifacts.all(), builtin.all()])

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
    max_context_messages: Some(30),
    tools:,
    restart: Permanent,
    tool_executor: researcher_executor(artifacts_dir, lib),
  )
}

fn researcher_executor(
  artifacts_dir: String,
  lib: Subject(LibrarianMessage),
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case call.name {
      "fetch_url"
      | "web_search"
      | "exa_search"
      | "tavily_search"
      | "firecrawl_extract" -> web.execute(call)
      "store_result" | "retrieve_result" ->
        artifacts.execute(call, artifacts_dir, "researcher", lib)
      _ -> builtin.execute(call)
    }
  }
}
