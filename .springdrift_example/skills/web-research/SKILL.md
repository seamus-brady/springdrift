---
name: web-research
description: Search and extraction strategy. Teaches the researcher which of the 8 web tools to use at each stage of a research cycle.
agents: researcher, cognitive
---

## Web research tool selection

You have 8 web tools arranged in tiers. Pick the right tool for the task:

### Tier 1 — Brave Search (requires BRAVE_SEARCH_API_KEY or BRAVE_ANSWERS_API_KEY)

| Tool | Best for | Notes |
|---|---|---|
| **brave_answer** | Self-contained factual questions ("what is X", "when did Y") | Fastest, cheapest for simple facts |
| **brave_llm_context** | Default hot path — need raw context to reason over | Machine-optimised search results |
| **brave_web_search** | Broad discovery with titles, URLs, and snippets | Good for finding multiple sources |
| **brave_news_search** | Time-sensitive queries, current events | Returns recent news articles |
| **brave_summarizer** | Need citations + follow-up threads | Search + summary chain |

### Tier 2 — Jina Reader (requires JINA_READER_API_KEY)
- **jina_reader**: Extract clean markdown from a URL. Better than fetch_url for content extraction.

### Tier 3 — Fallback (no API keys needed)
- **web_search**: DuckDuckGo keyword search. Use when Brave keys are unavailable.
- **fetch_url**: Raw HTTP GET. Use when Jina key is unavailable, or for non-HTML content.

### Decision tree

```
Factual, self-contained question?     → brave_answer
Need raw context to reason over?      → brave_llm_context (default)
Broad discovery with snippets?        → brave_web_search
Time-sensitive / news?                → brave_news_search
Need citations + follow-up threads?   → brave_summarizer
Have a URL, need full content?        → jina_reader (primary), fetch_url (fallback)
No API keys available?                → web_search (DuckDuckGo fallback)
```

### Quality signals

After extraction, check:
- Does the content have a publication date? Note it.
- Is the source primary (official, authored) or secondary (aggregator)?
- Does the content contradict earlier search results? Flag it explicitly.

Prefer primary sources. When a snippet and a full extraction conflict, trust the full extraction.
