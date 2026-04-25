// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{type AgentSpec, AgentSpec, Permanent}
import artifacts/log as artifacts_log
import artifacts/types as artifacts_types
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/string
import knowledge/search as knowledge_search
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/librarian.{type LibrarianMessage}
import paths
import slog
import tools/artifacts
import tools/brave
import tools/builtin
import tools/cache
import tools/jina
import tools/kagi
import tools/knowledge as knowledge_tools
import tools/rate_limiter
import tools/web

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

const system_prompt_base = "You are a research agent. Your job is to gather information using web search and extraction tools.

## Tool selection strategy

Pick the right tool for the task:

### Tier 1 — Brave Search (preferred when BRAVE_SEARCH_API_KEY available)
- **brave_answer**: Self-contained factual questions ('what is X', 'when did Y'). Fastest, cheapest for simple facts.
- **brave_llm_context**: Returns machine-optimised context for reasoning over search results.
- **brave_web_search**: Broad discovery with titles, URLs, and snippets. Good for finding multiple sources.
- **brave_news_search**: Time-sensitive queries, current events, recent developments.
- **brave_summarizer**: When you need citations plus follow-up threads. Uses search + summary chain.

### Tier 2 — Jina Reader (preferred for URL extraction)
- **jina_reader**: Extract clean markdown from a URL. Better than fetch_url for content extraction.

### Tier 3 — Fallback (no API keys needed)
- **web_search**: DuckDuckGo keyword search. Use when no paid search keys are available.
- **fetch_url**: Raw HTTP GET. Use when Jina key is unavailable, or for non-HTML content.

### Decision tree
- General web search? → brave_web_search
- Factual, self-contained question? → brave_answer
- Need raw context to reason over? → brave_llm_context
- Time-sensitive / news? → brave_news_search
- Need citations + follow-up threads? → brave_summarizer
- Have a URL, need full content? → jina_reader (primary), fetch_url (fallback)
- No API keys available? → web_search (DuckDuckGo fallback)

## Context management
Large tool results (over ~8KB) are auto-stored to artifacts by the executor. You will see a short preview plus `artifact_id=\"art-...\"` in place of the raw content. Call **retrieve_result** with that id when you need the full text to reason over. You can still call **store_result** explicitly for anything under the auto-store threshold that you want to persist.

## Quality signals
After extraction, note: publication date, whether the source is primary or secondary, and any contradictions with earlier results. Prefer primary sources. When a snippet and full extraction conflict, trust the full extraction.

## Output format
When you complete your task, respond with a concise summary of your findings. Include key details the orchestrator needs to make decisions: sources with URLs, key facts, confidence levels. Omit raw page contents and intermediate reasoning.

## Self-check before you start
The instruction may begin with a <refs> XML block listing artifact_id, task_id, or prior_cycle_id values passed by the orchestrator. If your instruction clearly continues or extends prior work but the relevant ref is missing from the <refs> block, do NOT guess, fabricate, or spin asking the deputy. Instead, respond with exactly:

[NEEDS_INPUT: <one short sentence naming what is missing and why you need it>]

Then stop. The orchestrator will see this and redispatch with the correct ref.

## Before you return
End your final reply with one line in this format:

Interpreted as: <one sentence summary of how you understood the task and what you did>

Keep it to one sentence. This lets the orchestrator notice if your interpretation doesn't match the intent."

const kagi_addendum = "

## Optional alternative — Kagi (KAGI_API_KEY required)
Kagi tools are available as an alternative to Brave. Use only when Brave is unavailable or the operator has explicitly preferred Kagi for a task.
- **kagi_search**: High quality, ad-free web search.
- **kagi_summarize**: Summarize a URL into concise text."

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
  auto_store_threshold_bytes: Int,
  skills_dirs: List(String),
  kagi_enabled: Bool,
) -> AgentSpec {
  let kagi_tools = case kagi_enabled {
    True -> kagi.all()
    False -> []
  }
  let tools =
    list.flatten([
      knowledge_tools.researcher_tools(),
      brave.all(),
      jina.all(),
      web.all(),
      kagi_tools,
      artifacts.all(),
      builtin.agent_tools(),
    ])

  let system_prompt = case kagi_enabled {
    True -> system_prompt_base <> kagi_addendum
    False -> system_prompt_base
  }

  let description = case kagi_enabled {
    True ->
      "Search the web and extract content from pages. Has Brave Search (web, news, LLM context, summarizer, answers), Jina Reader, DuckDuckGo web_search, fetch_url, and Kagi Search (alternative web search + summarizer). Can store and retrieve large content via artifacts."
    False ->
      "Search the web and extract content from pages. Has Brave Search (web, news, LLM context, summarizer, answers), Jina Reader, DuckDuckGo web_search, and fetch_url. Can store and retrieve large content via artifacts."
  }

  AgentSpec(
    name: "researcher",
    human_name: "Researcher",
    description:,
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
      provider,
      model,
      artifacts_dir,
      lib,
      max_artifact_chars,
      brave_cache,
      brave_search_limiter,
      brave_answers_limiter,
      brave_cache_ttl_ms,
      auto_store_threshold_bytes,
      skills_dirs,
    ),
    inter_turn_delay_ms: 200,
    redact_secrets: True,
  )
}

fn researcher_executor(
  provider: Provider,
  model: String,
  artifacts_dir: String,
  lib: Subject(LibrarianMessage),
  max_artifact_chars: Int,
  brave_cache: Option(Subject(cache.CacheMessage)),
  brave_search_limiter: Option(Subject(rate_limiter.RateLimiterMessage)),
  brave_answers_limiter: Option(Subject(rate_limiter.RateLimiterMessage)),
  brave_cache_ttl_ms: Int,
  auto_store_threshold_bytes: Int,
  skills_dirs: List(String),
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    let raw = case call.name {
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
            reason_fn: option.Some(knowledge_search.make_reason_fn(
              provider,
              model,
            )),
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
      _ -> builtin.execute(call, skills_dirs)
    }
    case should_auto_store(call.name), auto_store_threshold_bytes {
      _, t if t <= 0 -> raw
      False, _ -> raw
      True, threshold ->
        maybe_auto_store(
          raw,
          call.name,
          threshold,
          artifacts_dir,
          lib,
          max_artifact_chars,
        )
    }
  }
}

/// The set of tools whose output can be bulky enough to blow the
/// react-loop context window. store_result / retrieve_result are excluded
/// to avoid re-storing their own output.
pub fn should_auto_store(tool_name: String) -> Bool {
  case tool_name {
    "fetch_url"
    | "web_search"
    | "jina_reader"
    | "kagi_search"
    | "kagi_summarize"
    | "brave_web_search"
    | "brave_news_search"
    | "brave_llm_context"
    | "brave_summarizer"
    | "brave_answer" -> True
    _ -> False
  }
}

/// If the tool succeeded AND its content exceeds `threshold_bytes`, persist
/// the full content to artifacts and return a short preview + artifact_id
/// in place of the raw content. Otherwise pass the result through unchanged.
/// Preview size is threshold / 4 so the agent still has enough context to
/// reason about what it fetched.
fn maybe_auto_store(
  result: llm_types.ToolResult,
  tool_name: String,
  threshold_bytes: Int,
  artifacts_dir: String,
  lib: Subject(LibrarianMessage),
  max_artifact_chars: Int,
) -> llm_types.ToolResult {
  case result {
    llm_types.ToolFailure(..) -> result
    llm_types.ToolSuccess(tool_use_id:, content:) -> {
      let char_count = string.length(content)
      case char_count > threshold_bytes {
        False -> result
        True -> {
          let artifact_id = "art-" <> generate_uuid()
          let stored_at = get_datetime()
          let summary = first_line(content)
          let record =
            artifacts_types.ArtifactRecord(
              schema_version: 1,
              artifact_id:,
              cycle_id: "researcher_auto",
              stored_at:,
              tool: tool_name,
              url: "",
              summary:,
              char_count:,
              truncated: False,
            )
          artifacts_log.append(
            artifacts_dir,
            record,
            content,
            max_artifact_chars,
          )
          let meta =
            artifacts_types.ArtifactMeta(
              artifact_id:,
              cycle_id: "researcher_auto",
              stored_at:,
              tool: tool_name,
              url: "",
              summary:,
              char_count:,
              truncated: False,
            )
          librarian.index_artifact(lib, meta)
          slog.debug(
            "agents/researcher",
            "auto_store",
            "Auto-stored "
              <> int.to_string(char_count)
              <> "-char result from "
              <> tool_name
              <> " as "
              <> artifact_id,
            option.None,
          )
          let wrapped =
            render_auto_store_preview(
              content,
              tool_name,
              artifact_id,
              threshold_bytes,
            )
          llm_types.ToolSuccess(tool_use_id:, content: wrapped)
        }
      }
    }
  }
}

/// Build the wrapped tool_result content that replaces bulky output with
/// a preview plus artifact pointer. Pure — no I/O. Preview is sized at
/// one-quarter of the threshold so the agent retains enough context to
/// reason about what was fetched without the full body hitting the
/// react-loop context window.
pub fn render_auto_store_preview(
  content: String,
  tool_name: String,
  artifact_id: String,
  threshold_bytes: Int,
) -> String {
  let char_count = string.length(content)
  let preview_bytes = threshold_bytes / 4
  let preview = string.slice(content, 0, preview_bytes)
  "[Auto-stored "
  <> int.to_string(char_count)
  <> "-char result from "
  <> tool_name
  <> " as artifact_id=\""
  <> artifact_id
  <> "\"]\n\nPreview (first "
  <> int.to_string(preview_bytes)
  <> " chars):\n\n"
  <> preview
  <> "\n\n[Truncated. Call retrieve_result with artifact_id=\""
  <> artifact_id
  <> "\" to read the full text.]"
}

fn first_line(content: String) -> String {
  case string.split_once(content, "\n") {
    Ok(#(first, _)) -> string.slice(first, 0, 200)
    Error(_) -> string.slice(content, 0, 200)
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
