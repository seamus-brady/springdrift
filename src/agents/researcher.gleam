// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/librarian.{type LibrarianMessage}
import paths
import tools/artifacts
import tools/brave
import tools/builtin
import tools/cache
import tools/jina
import tools/kagi
import tools/knowledge as knowledge_tools
import tools/rate_limiter
import tools/web

const system_prompt = "You are a research agent. Your job is to gather information using web search and extraction tools.

## Tool selection strategy

You have 10 web tools arranged in tiers. Pick the right tool for the task:

### Tier 1 — Kagi Search (preferred when KAGI_API_KEY available)
- **kagi_search**: High quality, ad-free web search. Best general-purpose search when available.
- **kagi_summarize**: Summarize any URL into concise text. Great for quickly digesting long pages.

### Tier 2 — Brave Search (preferred when BRAVE_SEARCH_API_KEY available)
- **brave_answer**: Self-contained factual questions ('what is X', 'when did Y'). Fastest, cheapest for simple facts.
- **brave_llm_context**: Returns machine-optimised context for reasoning over search results.
- **brave_web_search**: Broad discovery with titles, URLs, and snippets. Good for finding multiple sources.
- **brave_news_search**: Time-sensitive queries, current events, recent developments.
- **brave_summarizer**: When you need citations plus follow-up threads. Uses search + summary chain.

### Tier 3 — Jina Reader (preferred for URL extraction)
- **jina_reader**: Extract clean markdown from a URL. Better than fetch_url for content extraction.

### Tier 4 — Fallback (no API keys needed)
- **web_search**: DuckDuckGo keyword search. Use when no paid search keys are available.
- **fetch_url**: Raw HTTP GET. Use when Jina key is unavailable, or for non-HTML content.

### Decision tree
- General web search? → kagi_search (primary), brave_web_search (fallback)
- Factual, self-contained question? → brave_answer
- Need raw context to reason over? → brave_llm_context
- Time-sensitive / news? → brave_news_search
- Need citations + follow-up threads? → brave_summarizer
- Have a URL, need summary? → kagi_summarize (primary), jina_reader (full text)
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
  brave_cache: Option(Subject(cache.CacheMessage)),
  brave_search_limiter: Option(Subject(rate_limiter.RateLimiterMessage)),
  brave_answers_limiter: Option(Subject(rate_limiter.RateLimiterMessage)),
  brave_cache_ttl_ms: Int,
) -> AgentSpec {
  let tools =
    list.flatten([
      knowledge_tools.researcher_tools(),
      kagi.all(),
      brave.all(),
      jina.all(),
      web.all(),
      artifacts.all(),
      builtin.agent_tools(),
    ])

  AgentSpec(
    name: "researcher",
    human_name: "Researcher",
    description: "Search the web and extract content from pages. Has Kagi Search (web search, summarizer), Brave Search (web, news, LLM context, summarizer, answers), Jina Reader, DuckDuckGo web_search, and fetch_url. Can store and retrieve large content via artifacts.",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 2048,
    max_turns: 8,
    max_consecutive_errors: 3,
    max_context_messages: Some(30),
    tools:,
    restart: Permanent,
    tool_executor: researcher_executor(
      artifacts_dir,
      lib,
      max_artifact_chars,
      brave_cache,
      brave_search_limiter,
      brave_answers_limiter,
      brave_cache_ttl_ms,
    ),
    inter_turn_delay_ms: 200,
    redact_secrets: True,
  )
}

fn researcher_executor(
  artifacts_dir: String,
  lib: Subject(LibrarianMessage),
  max_artifact_chars: Int,
  brave_cache: Option(Subject(cache.CacheMessage)),
  brave_search_limiter: Option(Subject(rate_limiter.RateLimiterMessage)),
  brave_answers_limiter: Option(Subject(rate_limiter.RateLimiterMessage)),
  brave_cache_ttl_ms: Int,
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case call.name {
      "save_to_library" | "search_library" | "read_section" | "get_document" ->
        knowledge_tools.execute(
          call,
          knowledge_tools.KnowledgeConfig(
            knowledge_dir: paths.knowledge_dir(),
            indexes_dir: paths.knowledge_indexes_dir(),
            sources_dir: paths.knowledge_sources_dir(),
            journal_dir: paths.knowledge_journal_dir(),
            notes_dir: paths.knowledge_notes_dir(),
            drafts_dir: paths.knowledge_drafts_dir(),
            exports_dir: paths.knowledge_exports_dir(),
            embed_fn: option.None,
          ),
        )
      "kagi_search" | "kagi_summarize" -> kagi.execute(call)
      "fetch_url" | "web_search" -> web.execute(call)
      "brave_web_search"
      | "brave_news_search"
      | "brave_llm_context"
      | "brave_summarizer" ->
        execute_brave_cached(
          call,
          brave_cache,
          brave_search_limiter,
          brave_cache_ttl_ms,
        )
      "brave_answer" ->
        execute_brave_cached(
          call,
          brave_cache,
          brave_answers_limiter,
          brave_cache_ttl_ms,
        )
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

fn execute_brave_cached(
  call: llm_types.ToolCall,
  brave_cache: Option(Subject(cache.CacheMessage)),
  limiter: Option(Subject(rate_limiter.RateLimiterMessage)),
  cache_ttl_ms: Int,
) -> llm_types.ToolResult {
  // Build a cache key from tool name + input
  let cache_key = call.name <> ":" <> call.input_json

  // Check cache first
  case cache.maybe_get(brave_cache, cache_key, 1000) {
    Ok(cached) -> llm_types.ToolSuccess(tool_use_id: call.id, content: cached)
    Error(_) -> {
      // Acquire rate limit token
      case rate_limiter.maybe_acquire(limiter, 5000) {
        Error(_) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: call.name <> ": rate limited — try again shortly",
          )
        Ok(_) -> {
          let result = brave.execute(call)
          // Cache successful results
          case result {
            llm_types.ToolSuccess(content: content, ..) ->
              cache.maybe_put(brave_cache, cache_key, content, cache_ttl_ms)
            _ -> Nil
          }
          result
        }
      }
    }
  }
}
