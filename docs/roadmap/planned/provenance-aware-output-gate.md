# Provenance-Aware Output Gate — Specification

**Status**: Planned
**Date**: 2026-03-26
**Dependencies**: Fact provenance (implemented), Artifact store (implemented), CBR usage tracking (implemented)

---

## Table of Contents

- [Overview](#overview)
- [The Problem](#the-problem)
- [Current Flow](#current-flow)
- [Proposed Flow](#proposed-flow)
- [Provenance Query](#provenance-query)
  - [What Counts as Sourced](#what-counts-as-sourced)
  - [What Counts as Unsourced](#what-counts-as-unsourced)
  - [Edge Cases](#edge-cases)
- [Implementation](#implementation)
  - [Claim Extraction](#claim-extraction)
  - [Provenance Lookup](#provenance-lookup)
  - [Scorer Context Enrichment](#scorer-context-enrichment)
  - [Scoring Impact](#scoring-impact)
- [Data Already Available](#data-already-available)
- [Example](#example)
- [Configuration](#configuration)
- [Relationship to Other Specs](#relationship-to-other-specs)
- [Implementation Order](#implementation-order)
- [What This Enables](#what-this-enables)

---

## Overview

Upgrade the output gate's `unsourced_claim` detection from text-level heuristic ("does this look sourced?") to data-level verification ("is there provenance for this claim in memory?").

The data model is already built — `FactProvenance` on every fact, `ArtifactRecord` with cycle linkage, `CbrCase` with `source_narrative_id`. The output gate just doesn't query it yet.

---

## The Problem

The output gate currently asks the LLM scorer: "read this response and judge whether the claims have supporting evidence." The scorer reads the text and guesses. This causes two failures:

1. **False rejection of sourced claims.** The researcher agent fetches data from real URLs, the agent cites those URLs in its response, but the scorer can't verify the URLs exist. It flags the entire report as unsourced.

2. **False acceptance of fabricated claims.** The agent can write "according to Gartner (2026)" with a plausible-sounding URL and the scorer accepts it — the text *looks* sourced even if the source is hallucinated.

Both failures come from the same root cause: the scorer is evaluating text, not data.

---

## Current Flow

```
Agent generates response
  → Output gate receives response text
  → Scorer LLM reads text, judges quality features
  → "Does this look like it has sources?" (text-level guess)
  → Score → Accept/Modify/Reject
```

The scorer has NO access to the agent's memory, provenance records, or artifact store.

---

## Proposed Flow

```
Agent generates response
  → Output gate receives response text
  → Extract claim references from text (entities, URLs, statistics, named sources)
  → For each claim, query provenance:
    → Facts with matching keys + DirectObservation derivation?
    → Artifacts with matching URLs from researcher cycles?
    → CBR cases with matching domain/entity?
  → Build provenance report: sourced claims vs unsourced claims
  → Pass provenance report as context to the scorer LLM
  → Scorer judges with data-level evidence, not just text guessing
  → Score → Accept/Modify/Reject
```

The scorer now sees: "3 of 5 factual claims have verified provenance (fetched from URLs by the researcher agent). 2 claims have no provenance."

---

## Provenance Query

### What Counts as Sourced

A claim in the response is considered sourced if ANY of the following exist in memory:

| Evidence | Where | How Checked |
|---|---|---|
| Fact with `derivation: DirectObservation` and matching key | `memory/facts/` via Librarian | Key match or keyword overlap |
| Fact with `source_tool: "web_search"` or `"fetch_url"` or `"brave_*"` | `memory/facts/` via Librarian | Provenance field check |
| Artifact with a URL matching one cited in the response | `memory/artifacts/` via Librarian | URL string match |
| Artifact created by the researcher agent in the current session | `memory/artifacts/` via Librarian | `source_agent: "researcher"` and recent timestamp |
| CBR case with `category: DomainKnowledge` and matching domain | `memory/cbr/` via Librarian | Domain + entity overlap |
| Study-cycle narrative entry for a knowledge source | `memory/narrative/` via Librarian | `cycle_id` prefix `study:` with matching topic |

### What Counts as Unsourced

A claim is unsourced if:
- No matching fact, artifact, or case exists in memory
- The claim attributes data to a named source but no evidence of that source exists in the agent's history
- The claim presents a statistic or quote with no provenance trail

### Edge Cases

| Case | Treatment |
|---|---|
| Claim from operator input ("you told me X") | Sourced — `derivation: OperatorProvided` |
| Claim from the agent's own reasoning ("based on the pattern I've observed") | Sourced if backed by CBR cases; unsourced if pure synthesis |
| Claim with decayed confidence (<0.3) | Technically sourced but stale — flagged as `weak_provenance` |
| Claim from a federated peer | Sourced with `derivation: FederatedQuery` — lower confidence weight |
| Old claim (>90 days, no re-verification) | `weak_provenance` — the source existed but may be outdated |

---

## Implementation

### Claim Extraction

Before scoring, extract factual claims from the response. This is a lightweight LLM call (or a heuristic parser):

```gleam
pub type ClaimRef {
  ClaimRef(
    text: String,                      // The claim text
    entities: List(String),            // Named entities (Gartner, Dublin, etc.)
    urls: List(String),                // Any URLs cited
    statistics: List(String),          // Numbers, percentages, dates
  )
}

pub fn extract_claims(response_text: String) -> List(ClaimRef)
```

**Option A**: LLM call to extract claims (more accurate, costs tokens).
**Option B**: Regex/heuristic extraction (free, less accurate — look for URLs, quoted sources, "according to", percentage patterns).

Recommendation: Option B for the initial implementation. The provenance lookup is the valuable part, not perfect claim extraction.

### Provenance Lookup

For each extracted claim, query the Librarian:

```gleam
pub type ProvenanceCheck {
  ProvenanceCheck(
    claim: ClaimRef,
    status: ProvenanceStatus,
    evidence: List(ProvenanceEvidence),
  )
}

pub type ProvenanceStatus {
  Verified               // Strong provenance exists
  WeakProvenance         // Provenance exists but decayed or from lower-trust source
  Unsourced              // No provenance found
}

pub type ProvenanceEvidence {
  FactEvidence(key: String, derivation: FactDerivation, confidence: Float, age_days: Int)
  ArtifactEvidence(artifact_id: String, url: String, fetched_by: String)
  CaseEvidence(case_id: String, category: CbrCategory, utility: Float)
}
```

```gleam
pub fn check_provenance(
  claims: List(ClaimRef),
  librarian: Subject(LibrarianMessage),
  facts_dir: String,
) -> List(ProvenanceCheck)
```

The lookup uses existing Librarian queries:
- `QueryFact(key)` for fact matches
- `QueryArtifactsByCycle` for artifact matches
- `RetrieveCases` for CBR matches

### Scorer Context Enrichment

The provenance report is injected into the output gate's scorer prompt:

```
PROVENANCE REPORT FOR THIS RESPONSE:

Claims with verified provenance (3/5):
  - "Gartner projects 119% CAGR" → Fact: gartner_agent_cagr (confidence: 0.78, source: brave_web_search, 2 days old)
  - "Market valued at $7-15B" → Artifact: art-abc123 (URL: https://..., fetched by researcher)
  - "Harvey AI valued at $11B" → Fact: harvey_valuation (confidence: 0.85, source: web_search, 1 day old)

Claims without provenance (2/5):
  - "Fewer than 1 in 4 organisations have scaled agents" → No matching fact or artifact found
  - "BCG estimates 36% of AI value in underwriting" → No matching fact or artifact found

When scoring unsourced_claim: focus on the 2 unverified claims, not the 3 verified ones.
```

The scorer LLM now has data — not just text to guess from.

### Scoring Impact

With provenance context:
- A response where 5/5 claims have provenance → `unsourced_claim` magnitude 0 (fully sourced)
- A response where 3/5 claims have provenance → magnitude 1 (mostly sourced, minor gaps)
- A response where 0/5 claims have provenance → magnitude 2-3 (genuinely unsourced)

This replaces the current binary: "looks sourced" vs "doesn't look sourced."

---

## Data Already Available

Everything needed for provenance lookup is already built and in production:

| Data | Implementation | Status |
|---|---|---|
| `FactProvenance` on facts | `facts/types.gleam` | Implemented (Enhancement 2) |
| `derivation` field (DirectObservation, Synthesis, OperatorProvided) | `facts/types.gleam` | Implemented |
| `source_tool` on provenance | `facts/types.gleam` | Implemented |
| Artifact store with cycle linkage | `artifacts/log.gleam`, Librarian | Implemented |
| CBR cases with category and usage stats | `cbr/types.gleam` | Implemented |
| Confidence decay on facts | `dprime/decay.gleam` | Implemented |
| Librarian fact/artifact/case queries | `narrative/librarian.gleam` | Implemented |

The only new code is: claim extraction from text, provenance lookup orchestration, and scorer prompt enrichment. ~200 lines.

---

## Example

### Before (text-level, current)

```
Response: "According to Gartner, the agent market will grow at 119% CAGR..."

Scorer thinks: "I can't verify this Gartner claim exists. Flagging as unsourced."
Score: unsourced_claim = 2/3
Result: MODIFY (revise with citations)
```

### After (provenance-aware)

```
Response: "According to Gartner, the agent market will grow at 119% CAGR..."

Provenance lookup:
  - Fact "gartner_agent_cagr" exists
  - Derivation: DirectObservation
  - Source tool: brave_web_search
  - Source cycle: abc123 (researcher agent, 2 days ago)
  - Confidence: 0.78 (decayed from 0.85)

Scorer sees: "This claim has verified provenance — fetched from web by researcher agent."
Score: unsourced_claim = 0/3
Result: ACCEPT
```

---

## Configuration

```toml
[dprime.output_gate]
# Enable provenance-aware scoring (default: true when fact provenance is available)
# provenance_aware = true

# Minimum fact confidence for provenance to count as "verified" (default: 0.3)
# min_provenance_confidence = 0.3

# Claim extraction method: "heuristic" | "llm" (default: "heuristic")
# claim_extraction = "heuristic"

# Maximum age in days for provenance to count as "verified" vs "weak" (default: 30)
# max_provenance_age_days = 30
```

---

## Relationship to Other Specs

| Spec | Relationship |
|---|---|
| [D' Safety Overhaul](../roadmap/implemented/dprime-safety-overhaul.md) | Output gate is the evaluation point; provenance enriches its context |
| [D' Enhancements](../roadmap/implemented/dprime-enhancements.md) | Fact provenance (Enhancement 2) provides the data model |
| [CBR Retrieval System](../roadmap/implemented/cbr-retrieval-system.md) | CBR cases with category and usage stats as provenance evidence |
| [Prime Narrative Memory](../roadmap/implemented/prime-narrative-memory.md) | Artifact store and Librarian provide the query layer |
| [Knowledge Management](knowledge-management.md) | Study-cycle provenance for knowledge-sourced claims |
| [Remembrancer](remembrancer.md) | Restored confidence on re-verified facts feeds into provenance quality |
| [Web Research Tools](../roadmap/implemented/web-research-tools.md) | Researcher agent creates the artifacts and facts that provenance checks against |

---

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | Heuristic claim extraction (URLs, "according to", statistics) | Small |
| 2 | Provenance lookup (facts, artifacts, cases via Librarian) | Medium |
| 3 | Provenance report formatting for scorer prompt | Small |
| 4 | Wire into output gate evaluate function | Small |
| 5 | Weak provenance handling (decayed, old, federated) | Small |
| 6 | Optional LLM-based claim extraction (more accurate, higher cost) | Medium |

Phases 1-4 deliver the core capability. ~200 lines of new code. The data is already there.

---

## What This Enables

The output gate stops guessing and starts checking. A research report with properly fetched sources passes. A hallucinated report with fake URLs fails — because there's no artifact in memory proving those URLs were ever fetched.

This is the difference between "it looks right" and "we can prove it's right." For regulated industries, that's the difference between useful and deployable.
