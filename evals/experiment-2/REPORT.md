# Experiment 2: CBR vs RAG Retrieval — Full Evaluation

## Setup

**Case base:** 800 synthetic cases, 4 domains × 5 subdomains × 40 cases each.
Each case has structured metadata: intent, domain, keywords (2-6 terms drawn
from core, specific, and shared vocabulary pools), entities, tools, agents,
outcome, and confidence.

**Queries:** 200 queries at three difficulty levels:
- **Easy (80):** 3 core subdomain keywords, 1 entity. Avg 29.6 relevant cases.
- **Medium (60):** 2 core + 2 shared-pool keywords, 1 entity. Avg 18.3 relevant.
- **Hard (60):** 1 core + 4 shared-pool keywords, no entities. Avg 12.9 relevant.

**Ground truth:** A case is relevant to a query if same domain AND ≥2 keyword overlap.

**Systems under test:**
- **RAG:** Ollama nomic-embed-text (768-dim), cosine similarity, top-K retrieval
- **CBR full:** Springdrift 4-signal weighted fusion (field=0.30, index=0.20,
  recency=0.15, domain=0.15). Embedding and utility signals excluded (require
  runtime state).
- **CBR index only:** Inverted index token overlap
- **CBR field only:** Weighted field scoring (intent + domain + keyword jaccard +
  entity jaccard)
- **CBR field+index+domain:** Combined deterministic signals (0.35/0.30/0.35)

**Metrics:** P@4, MRR, nDCG@4, R@4. Bootstrap 95% CI (1000 resamples). K=4
following Zhou et al. (2025) finding that K>4 causes context pollution.

## Results

### Table 1: Overall Retrieval Quality (N=800 cases, 200 queries, K=4)

| System | P@4 | 95% CI | MRR | 95% CI | nDCG@4 | R@4 |
|---|---|---|---|---|---|---|
| **RAG (cosine)** | **0.920** | [0.895, 0.944] | **0.978** | [0.960, 0.993] | **0.931** | **0.922** |
| CBR index only | 0.921 | [0.897, 0.944] | 0.975 | [0.954, 0.993] | 0.935 | 0.922 |
| CBR field+index+domain | 0.761 | [0.719, 0.799] | 0.942 | [0.911, 0.970] | 0.796 | 0.761 |
| CBR field only | 0.705 | [0.662, 0.749] | 0.889 | [0.850, 0.923] | 0.736 | 0.705 |
| CBR full (4 signal) | 0.620 | [0.574, 0.664] | 0.852 | [0.809, 0.896] | 0.656 | 0.620 |

### Table 2: Precision@4 by Query Difficulty

| System | Easy (N=80) | Medium (N=60) | Hard (N=60) |
|---|---|---|---|
| **RAG (cosine)** | 0.988 | **0.954** | **0.796** |
| CBR index only | **0.994** | 0.938 | 0.808 |
| CBR field+index+domain | 0.894 | 0.692 | 0.654 |
| CBR field only | 0.825 | 0.600 | 0.650 |
| CBR full (4 signal) | 0.872 | 0.588 | 0.317 |

### Table 3: Precision@4 by Domain (Full Weighted CBR)

| Domain | P@4 | 95% CI |
|---|---|---|
| Legal research | 0.660 | [0.570, 0.745] |
| Technical ops | 0.640 | [0.550, 0.725] |
| Property market | 0.595 | [0.500, 0.685] |
| Financial analysis | 0.585 | [0.495, 0.670] |

## Analysis

### RAG outperforms multi-signal CBR fusion

RAG (cosine similarity over nomic-embed-text embeddings) achieves P@4=0.920,
significantly outperforming the CBR full weighted fusion (P@4=0.620). The
confidence intervals do not overlap (RAG: [0.895, 0.944], CBR full: [0.574,
0.664]), confirming this is a statistically significant difference.

The key finding: **semantic embeddings capture cross-vocabulary similarity
that token overlap and field matching cannot**. When a query uses shared pool
terms ("analysis", "risk", "trend") that appear across multiple subdomains,
the embedding model correctly maps them to the right semantic neighbourhood.
The deterministic CBR signals treat these as exact-match tokens and produce
false positives from other subdomains.

### CBR index matches RAG on easy queries

On easy queries (core subdomain keywords), CBR index-only (P@4=0.994) slightly
outperforms RAG (0.988). When the query vocabulary is distinct and domain-
specific, token overlap is a perfect signal — it's both fast and accurate.
The embedding model adds no value here.

### Hard queries reveal the gap

On hard queries (mostly shared vocabulary), the full CBR fusion collapses to
P@4=0.317. RAG degrades gracefully to 0.796. The recency signal in CBR full
is the primary culprit — it injects noise that is uncorrelated with relevance,
diluting the useful signals on ambiguous queries.

Notably, CBR index-only (0.808) matches RAG on hard queries. The field score
(which weights intent match at 0.30) is the weak signal — intent classification
is too coarse to discriminate within a domain.

### Implications for Springdrift

1. **The embedding signal matters.** Springdrift's CBR system includes an
   optional embedding signal (via Ollama). This evaluation confirms it should
   not be optional — it is the dominant retrieval signal for ambiguous queries.

2. **Recency should be query-adaptive.** A fixed 0.15 weight on recency
   dilutes precision on hard queries. Recency should only contribute when the
   query is time-sensitive (detectable from keywords like "latest", "recent",
   "current").

3. **The utility signal is untested but potentially valuable.** Cases with
   proven utility (high retrieval success count) should be boosted. This is
   the Memento paper's central thesis — the retrieval policy itself is
   learnable. Springdrift implements the utility signal but it needs
   accumulated operational data to evaluate.

4. **Hybrid CBR+embedding is the target.** The optimal system would use
   inverted index for recall (it's fast and catches easy queries perfectly)
   and embedding similarity for ranking (it handles ambiguity). The current
   weighted sum conflates these two roles.

## Reproducibility

```bash
# Generate dataset
python3 evals/experiment-2/generate_cases_v2.py

# Run evaluation (requires Ollama with nomic-embed-text)
python3 evals/experiment-2/run_eval.py
```

Seed: 42 (both generation and bootstrap). Results in `evals/experiment-2/results/`.
