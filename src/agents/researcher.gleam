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
- **exa_search**: Semantic neural search. Best for exploratory queries where you need to discover relevant sources by meaning. Write queries as natural language descriptions, not keywords. Example: \"recent arguments against central bank digital currencies\" outperforms \"CBDC criticism\".
- **tavily_search**: Fast factual lookup optimised for specific questions. Use for prices, dates, status checks, recent news. Returns a direct answer plus ranked sources. Example: \"What is the current ECB deposit rate?\"
- **web_search**: DuckDuckGo fallback. Use only when exa and tavily are unavailable or return no results.

### Stage 2 — Extraction
- **firecrawl_extract**: Deep page extraction to clean markdown. Use only after Stage 1 returns a URL worth reading in full — a primary document, detailed report, or a snippet that was cut off. Never call speculatively.
- **fetch_url**: Lightweight HTTP GET. Use for simple HTML pages that don't need JavaScript rendering.

### Decision tree
- Need to find sources? → exa_search
- Need a quick fact? → tavily_search
- Have a URL, complex page? → firecrawl_extract
- Have a URL, simple page? → fetch_url
- Nothing else worked? → web_search

### Cost awareness
- tavily_search = 1 credit per call (cheapest for grounding)
- exa_search = billed per result (use when semantic precision matters)
- firecrawl_extract = 1 credit per page (never call speculatively)

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
) -> AgentSpec {
  let tools = list.flatten([web.all(), artifacts.all(), builtin.all()])

  AgentSpec(
    name: "researcher",
    human_name: "Researcher",
    description: "Search the web and extract content from pages. Has exa_search (semantic discovery), tavily_search (fast factual lookup), firecrawl_extract (deep page extraction), web_search (DuckDuckGo), and fetch_url. Can store and retrieve large content via artifacts.",
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
