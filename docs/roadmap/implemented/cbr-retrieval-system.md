# CBR Retrieval System — Implementation Record

**Status**: Implemented
**Date**: 2026-03-19 onwards
**Source**: cbr-review.md, paperwings_spec.md, Memento (2508.16153), ACE (2510.04618)

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [CbrCase Structure](#cbrcase-structure)
- [Retrieval Scoring](#retrieval-scoring)
- [Retrieval Cap](#retrieval-cap)
- [Self-Improvement Loop](#self-improvement-loop)
- [Categories](#categories)
- [Confidence Decay](#confidence-decay)
- [Embedding Support](#embedding-support)


## Overview

Case-Based Reasoning memory with weighted multi-signal retrieval, optional semantic embeddings, self-improving usage tracking, and typed categories.

## Architecture

```
cbr/types.gleam   — CbrCase, CbrProblem, CbrSolution, CbrOutcome, CbrUsageStats, CbrCategory
cbr/log.gleam     — Append-only JSONL persistence with lenient decoders
cbr/bridge.gleam  — CaseBase (inverted index + embeddings), weighted retrieval, utility scoring
```

## CbrCase Structure

```gleam
CbrCase(
  case_id, source_narrative_id,
  problem: CbrProblem(user_input, intent, domain, entities, keywords),
  solution: CbrSolution(approach, agents_used, tools_used, steps),
  outcome: CbrOutcome(status, confidence, assessment, pitfalls),
  category: Option(CbrCategory),      // Strategy | CodePattern | Troubleshooting | Pitfall | DomainKnowledge
  usage_stats: Option(CbrUsageStats), // retrieval_count, success_count, helpful, harmful
)
```

## Retrieval Scoring

6-signal weighted fusion:

| Signal | Default Weight | Source |
|---|---|---|
| Field score | 0.35 | Intent/domain match, keyword/entity Jaccard |
| Index overlap | 0.25 | Inverted index token overlap |
| Recency | 0.15 | Creation date ranking |
| Domain match | 0.10 | Exact domain match bonus |
| Embedding cosine | 0.00 (0.10 when available) | Ollama semantic embeddings |
| Utility score | 0.15 | (successes + 1) / (retrievals + 2) Laplace smoothing |

When embeddings unavailable, embedding weight redistributed. When utility data unavailable (None), utility score defaults to 0.5 (neutral).

## Retrieval Cap

K=4 maximum cases returned per query (per Memento paper finding that more causes context pollution). Configurable via `cbr_max_results`.

## Self-Improvement Loop

1. `recall_cases` returns cases → IDs recorded in `CognitiveState.retrieved_case_ids`
2. Archivist writes cycle outcome → updates usage stats on retrieved cases via Librarian
3. `retrieval_count` always incremented; `retrieval_success_count` incremented on success
4. Utility score blended into future retrieval scoring
5. Cases with `harmful_count > helpful_count * 2` and `retrieval_count > 5` flagged for deprecation

## Categories

Assigned deterministically by the Archivist based on cycle outcome:

| Condition | Category |
|---|---|
| Success + code terms in approach | CodePattern |
| Success | Strategy |
| Failure + non-empty pitfalls | Pitfall |
| Failure | Troubleshooting |
| Partial | DomainKnowledge |

Curator organises injected cases by category in the system prompt.

## Confidence Decay

CBR case outcome confidence decays at retrieval time:
```
confidence_t = confidence_0 * 2^(-age_days / half_life_days)
```
Default half-life: 60 days. Configurable via `cbr_decay_half_life_days`.

## Embedding Support

Optional Ollama embeddings via `embedding.gleam`:
- HTTP client for `/api/embeddings` endpoint
- Startup probe verifies Ollama is running with model pulled
- `make_embed_fn` closure for the Librarian
- Cosine similarity in retrieval scoring
- Configurable: `cbr_embedding_enabled`, `cbr_embedding_model`, `cbr_embedding_base_url`
