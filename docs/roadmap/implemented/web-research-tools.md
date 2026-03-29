# Web Research Tools and Client Libraries — Implementation Record

**Status**: Implemented
**Date**: 2026-03-16 onwards
**Source**: search-agent-plan.md, client-libraries-plan.md, tools_web_additions.gleam

---

## Table of Contents

- [Overview](#overview)
- [Tools](#tools)
  - [Core Web Tools (`tools/web.gleam`)](#core-web-tools-toolswebgleam)
  - [Brave Search Tools (`tools/brave.gleam`)](#brave-search-tools-toolsbravegleam)
  - [Jina Reader (`tools/jina.gleam`)](#jina-reader-toolsjinagleam)
  - [Artifact Tools (`tools/artifacts.gleam`)](#artifact-tools-toolsartifactsgleam)
- [Tool Selection Decision Tree](#tool-selection-decision-tree)
- [Degradation Paths](#degradation-paths)
- [Configuration](#configuration)
- [Researcher Agent (`agents/researcher.gleam`)](#researcher-agent-agentsresearchergleam)


## Overview

Web research capabilities for the researcher agent: search, extraction, and artifact storage.

## Tools

### Core Web Tools (`tools/web.gleam`)

| Tool | API | Auth | Purpose |
|---|---|---|---|
| `web_search` | DuckDuckGo HTML | None | Discovery — find relevant pages |
| `fetch_url` | Raw HTTP GET | None | Extraction — get page content (50KB truncation) |

### Brave Search Tools (`tools/brave.gleam`)

| Tool | API | Auth | Purpose |
|---|---|---|---|
| `brave_web_search` | Brave Search API | `BRAVE_API_KEY` | Multiple sources with snippets |
| `brave_answer` | Brave Answers | `BRAVE_API_KEY` | Self-contained factual questions |
| `brave_llm_context` | Brave Answers | `BRAVE_API_KEY` | Machine-optimised research context |
| `brave_news_search` | Brave News | `BRAVE_API_KEY` | Time-sensitive current events |
| `brave_summarizer` | Brave Summarizer | `BRAVE_API_KEY` | Citations and follow-up threads |

### Jina Reader (`tools/jina.gleam`)

| Tool | API | Auth | Purpose |
|---|---|---|---|
| `jina_reader` | Jina Reader API | `JINA_API_KEY` | Full markdown extraction from URL |

### Artifact Tools (`tools/artifacts.gleam`)

| Tool | Purpose |
|---|---|
| `store_result` | Store large content to disk (returns compact artifact_id) |
| `retrieve_result` | Retrieve stored content by ID |

## Tool Selection Decision Tree

From HOW_TO.md — the researcher agent follows this priority:

1. `brave_answer` — fastest, self-contained factual questions
2. `brave_llm_context` — default for most research
3. `brave_web_search` — multiple sources with snippets
4. `brave_news_search` — time-sensitive events
5. `jina_reader` — full markdown from a known URL
6. `web_search` — DuckDuckGo fallback (no key required)
7. `fetch_url` — raw HTTP GET fallback (no key required)

## Degradation Paths

- No `BRAVE_API_KEY` → use `web_search` (DuckDuckGo)
- No `JINA_API_KEY` → use `fetch_url`
- No network → coder uses `request_human_input` for manual input

## Configuration

```toml
[services]
duckduckgo_url = "https://html.duckduckgo.com/html/"
brave_search_base_url = "https://api.search.brave.com"
brave_answers_base_url = "https://api.search.brave.com"
jina_reader_base_url = "https://r.jina.ai/"

[limits]
max_fetch_chars = 50000
web_search_max_results = 5
brave_search_max_results = 20
brave_rate_limit_rps = 20
brave_answers_rate_limit_rps = 2
brave_cache_ttl_ms = 300000
```

## Researcher Agent (`agents/researcher.gleam`)

- Tools: web tools + artifact tools + builtin (agent_tools, no request_human_input)
- max_turns=8, max_context_messages=30 (sliding window for lean multi-turn research)
- Permanent restart strategy
- Captures `artifacts_dir` and `librarian` via closure-based tool executor
- Structured output: `ResearcherFindings` with sources and dead ends
