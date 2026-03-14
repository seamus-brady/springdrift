import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/librarian.{type LibrarianMessage}
import tools/artifacts
import tools/brave
import tools/builtin
import tools/jina
import tools/web

const system_prompt = "You are a research agent. Your job is to gather information using web search and extraction tools.

## Tool selection strategy

You have 8 web tools arranged in tiers. Pick the right tool for the task:

### Tier 1 — Brave Search (preferred when API keys available)
- **brave_answer**: Self-contained factual questions ('what is X', 'when did Y'). Fastest, cheapest for simple facts.
- **brave_llm_context**: Default hot path. Returns machine-optimised context for reasoning over search results.
- **brave_web_search**: Broad discovery with titles, URLs, and snippets. Good for finding multiple sources.
- **brave_news_search**: Time-sensitive queries, current events, recent developments.
- **brave_summarizer**: When you need citations plus follow-up threads. Uses search + summary chain.

### Tier 2 — Jina Reader (preferred for URL extraction)
- **jina_reader**: Extract clean markdown from a URL. Better than fetch_url for content extraction.

### Tier 3 — Fallback (no API keys needed)
- **web_search**: DuckDuckGo keyword search. Use when Brave keys are unavailable.
- **fetch_url**: Raw HTTP GET. Use when Jina key is unavailable, or for non-HTML content.

### Decision tree
- Factual, self-contained question? → brave_answer
- Need raw context to reason over? → brave_llm_context (default hot path)
- Broad discovery with snippets? → brave_web_search
- Time-sensitive / news? → brave_news_search
- Need citations + follow-up threads? → brave_summarizer
- Have a URL, need full content? → jina_reader (primary), fetch_url (fallback)
- No API keys available? → web_search (DuckDuckGo fallback)

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
  let tools =
    list.flatten([
      brave.all(),
      jina.all(),
      web.all(),
      artifacts.all(),
      builtin.all(),
    ])

  AgentSpec(
    name: "researcher",
    human_name: "Researcher",
    description: "Search the web and extract content from pages. Has Brave Search (web, news, LLM context, summarizer, answers), Jina Reader, DuckDuckGo web_search, and fetch_url. Can store and retrieve large content via artifacts.",
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
      "brave_web_search"
      | "brave_news_search"
      | "brave_llm_context"
      | "brave_summarizer"
      | "brave_answer" -> brave.execute(call)
      "jina_reader" -> jina.execute(call)
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
