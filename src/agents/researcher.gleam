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

## Tool selection strategy

Work in two stages: discover sources first, then extract content.

### Stage 1 — Discovery
- **web_search**: DuckDuckGo keyword search. Use for finding relevant sources, current information, and factual lookups.

### Stage 2 — Extraction
- **fetch_url**: HTTP GET to retrieve full page content from a URL found in Stage 1. Returns the response body (truncated to 50 KB).

### Decision tree
- Need to find sources? → web_search
- Have a URL, need full content? → fetch_url

## Context management
When fetching large pages, immediately use **store_result** to save the content and work with the artifact_id. Use **retrieve_result** to re-read stored content. This keeps your context window lean across multi-turn research.

## Quality signals
After extraction, note: publication date, whether the source is primary or secondary, and any contradictions with earlier results. Prefer primary sources. When a snippet and full extraction conflict, trust the full extraction.

## Output format
When you complete your task, respond with a concise summary of your findings. Include key details the orchestrator needs to make decisions: sources with URLs, key facts, confidence levels. Omit raw page contents and intermediate reasoning."

pub fn spec(
  provider: Provider,
  model: String,
  artifacts_dir: String,
  lib: Subject(LibrarianMessage),
  max_artifact_chars: Int,
) -> AgentSpec {
  let tools = list.flatten([web.all(), artifacts.all(), builtin.all()])

  AgentSpec(
    name: "researcher",
    human_name: "Researcher",
    description: "Search the web and extract content from pages. Has web_search (DuckDuckGo) and fetch_url. Can store and retrieve large content via artifacts.",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 2048,
    max_turns: 8,
    max_consecutive_errors: 3,
    max_context_messages: Some(30),
    tools:,
    restart: Permanent,
    tool_executor: researcher_executor(artifacts_dir, lib, max_artifact_chars),
    inter_turn_delay_ms: 200,
  )
}

fn researcher_executor(
  artifacts_dir: String,
  lib: Subject(LibrarianMessage),
  max_artifact_chars: Int,
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case call.name {
      "fetch_url" | "web_search" -> web.execute(call)
      "store_result" | "retrieve_result" ->
        artifacts.execute(
          call,
          artifacts_dir,
          "researcher",
          lib,
          max_artifact_chars,
        )
      _ -> builtin.execute(call)
    }
  }
}
