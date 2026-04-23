# CBR Graph Projection — Relational Index over the Case Library

**Status**: Planned (design 2026-04-23)
**Priority**: Medium — augments CBR retrieval; earns value only if an ablation eval shows measurable lift
**Effort**: Medium (~500 LOC MVP, plus eval harness)

## Problem

Springdrift's CBR retrieval ranks past cases by a weighted fusion of six
signals (field score, inverted-index overlap, recency, domain match,
optional embedding cosine, utility). This works — experiment-3 validated
it — but the retrieval is structurally blind:

1. **Cases are isolated.** The retrieval sees each case as a point in
   similarity space. It has no awareness that two cases involved the
   same sub-agent, or that a cluster of failures shares a tool, or that
   the current query touches an entity with a bad outcome history.
2. **Multi-hop questions don't surface.** "What do I know about
   `agent:coder` that's related to `tool:run_code` failures?" requires a
   traversal pattern the current index can't answer.
3. **Outcome history per entity is invisible at retrieval time.** A
   case retrieved by similarity may have involved a system whose last
   20 cases all ended in `Failure`. The ranker doesn't know; the agent
   acts on the case as if it were sound.

## Proposed solution

Add a **projected graph layer** over the existing CBR JSONL store. The
graph is never the source of truth — it's a derived, rebuildable index
that lives alongside the Librarian's existing ETS projections.

- Entities and relationships are extracted by the Archivist during
  Phase 2 curation and stored as a new field on each CbrCase.
- On each case write, a projection step upserts nodes and edges into
  ETS graph tables owned by the Librarian.
- At retrieval time, the standard vector/keyword search produces a
  candidate set; the graph enriches it with entity co-occurrence and
  outcome stats; a re-rank stage blends the signals.
- At startup, the graph rebuilds from JSONL replay — same pattern as
  narrative/CBR/facts/artifacts today.

## Why this fits Springdrift

The pattern is identical to existing projections:

| Existing | This addition |
|---|---|
| Narrative JSONL → ETS narrative indexes | CBR JSONL → ETS graph tables |
| Archivist writes narrative + CBR | Archivist also emits graph-ready entities |
| Librarian owns the ETS projection | Librarian owns the graph projection |
| Rebuild on startup from JSONL | Same rebuild path, same guarantees |

No new subsystem. No new writer. No new source of truth.

## Prior art

CBR + graph hybrids go back decades in the CBR research literature
(conceptual graphs as case indexes, memory-organisation-packet models).
Commercial products (Mem0, Zep/Graphiti, Cognee) layer graphs onto
vector stores but none of them treat cases as outcome-tagged records —
they store facts and entities. The CBR piece with explicit
success/failure/partial outcomes is the genuinely differentiated move.
This design is conservative: known research pattern, minor architectural
extension, Springdrift-specific outcome integration.

## Architecture

### One process, one writer

The graph lives on the Librarian. Not a separate GraphProjector actor.
Splitting graph projection into its own process recreates exactly the
synchronisation problem the "graph-as-projection" model is designed to
avoid — two stores disagreeing about state. The Librarian already
projects narrative / CBR / facts / artifacts / captures into ETS.
Graph tables are the sixth projection under the same owner.

### ETS tables

Two new tables alongside existing ones:

- **`cbr_graph_nodes`** — `set` type, keyed on `node_id`. Node records
  carry `node_type` (`case`, `agent`, `tool`, `domain`, `failure`,
  `cycle`), `created_at`, `last_seen_at`, and a small metadata map
  (e.g. outcome aggregates for entity nodes).
- **`cbr_graph_edges`** — `bag` type, allowing multiple edges between
  the same pair. Records carry `from_id`, `edge_type`
  (`involved`, `linked_to`, `co_occurs_with`), `to_id`, `weight`,
  `last_seen_at`.

Named with the `cbr_graph_` prefix to match existing ETS naming.

### CbrCase schema extension

Add one field:

```gleam
pub type CbrCase {
  CbrCase(
    // existing fields...
    entities: List(String),
  )
}
```

Entities are extracted by the Archivist during Phase 2 curation in the
existing structured-output path. Identifiers use a `type:name` convention
(`agent:coder`, `tool:run_code`, `failure:talking_not_coding`,
`domain:delegation`). The extraction is a dedicated XStructor field on
the curation schema — one LLM call, same call that already exists.

### Projection on write

```
Archivist writes CbrCase to cbr/log.jsonl
        │
        ├──► Librarian receives IndexCase (existing path)
        │        │
        │        ├──► Updates existing CBR ETS + CaseBase (existing)
        │        └──► NEW: updates graph tables
        │               ├── upsert case node
        │               ├── upsert entity nodes
        │               ├── increment involved edges (case → entity)
        │               ├── increment co_occurs_with edges (entity ↔ entity)
        │               └── accumulate outcome aggregates on entity nodes
```

No new message variant to the Librarian — the existing `IndexCase`
message gains graph-projection as part of its handler body. Keeps the
actor message surface small.

### Co-occurrence pruning

Co-occurrence edges grow quadratically in per-case entity count. A case
with 6 entities generates 15 edges. Over 10k cases at that density,
that's 150k edges. ETS handles it, but without discipline the graph
accumulates hub nodes (ubiquitous entities that co-occur with
everything) that distort traversal.

Two mitigations, both configurable:

1. **Minimum weight for traversal.** `cbr_graph_cooccur_min_weight`
   (default 3) — edges below this aren't considered in enrichment.
   Still stored; just filtered.
2. **Hub suppression.** Entity nodes with degree > `cbr_graph_hub_degree`
   (default 500) are flagged as hubs. Traversal skips them for
   co-occurrence expansion. Useful for generic entities like
   `agent:cognitive` that touch everything.

### Retrieval enrichment

The existing retrieval path in `cbr/bridge.gleam` gains one step:

```gleam
pub fn retrieve(query: CbrQuery) -> List(ScoredCase) {
  // existing: vector + field + index fusion
  let candidates = existing_retrieve(query, k: 10)

  // new: graph enrichment
  let query_entities = extract_entities_from_query(query)
  let graph_ctx = graph_lookup(query_entities)

  candidates
  |> rerank_with_graph(graph_ctx)
  |> list.take(query.k)  // existing K cap (default 4)
}
```

**Re-rank blends two signals:**

- **Entity overlap boost** — small positive on cases that share
  entities with the query. Magnitude tunable.
- **Outcome history penalty** — negative signal scaled by the failure
  rate of the case's dominant entities in their aggregated history.
  A case that involves `system:x` which has 80% failure rate over its
  last 20 cases is deranked.

These are the only two new signals in MVP. More (temporal decay on
weights, linked-case chains, cluster centrality) are deferred until
MVP data shows them to be worth the complexity.

## Impact on invariants

**Immutability** — preserved. The graph is projected from JSONL; the
JSONL is never mutated; only the Archivist writes. The writer set
doesn't grow.

**Auditability** — preserved. Every graph node and edge is derivable
from a specific case or set of cases. A `rebuild_graph()` function
can reconstruct the graph from scratch, proving no hidden state.
Provenance of any graph assertion is a cycle_id pointer.

**Performance** — ETS lookups are µs-level. The rebuild cost is
bounded by the CBR library size; at 10k cases it completes in a few
seconds at startup.

**Existing retrieval fusion weights** — must be re-tuned. The current
weight balance was validated in experiment-3. Adding a graph signal
means the old balance may no longer be optimal. A new ablation (below)
is mandatory before shipping.

## What this is explicitly NOT

- **Not a replacement for CBR retrieval.** The vector/keyword retrieval
  stays as the candidate generator. The graph is a re-rank and enrichment
  layer, not a primary search mechanism.
- **Not a separate actor process.** Graph lives on the Librarian.
- **Not a sensorium block (yet).** The sensorium is already crowded;
  adding graph-derived health signals before the retrieval value is
  proven is premature.
- **Not an authority-calibration input.** The graph is descriptive
  (shows what happened), never prescriptive (never auto-adjusts
  standing instructions, normative thresholds, or delegation rules).
  Surfacing patterns to the operator is fine; letting the graph tune
  agent behaviour is not.
- **Not a drift detector (yet).** Drift via edge-weight trends is
  deferred to Phase 2. Raw edge weights increase with activity, not
  drift; turning this into a signal requires rate-of-change analysis
  that warrants its own design iteration.
- **Not a novelty / escalation source (yet).** "Unseen entity
  combinations trigger consultation" is in the literature but its
  integration with Springdrift's existing authority model needs
  dedicated design work.

## Required: evaluation plan

**MVP does not ship without an ablation.** Entity extraction quality is
the hidden cost of this design. Without a before/after comparison,
graph enrichment is faith-based augmentation.

### Dataset

A held-out set of 50–100 cases with hand-labelled "correct retrieval"
for each query. Labels identify which stored cases a good retrieval
should return for a given query — the ground truth the existing
retrieval should approximate.

### Metrics

Compare three retrieval configurations on the held-out set:

- **A** — existing retrieval (no graph)
- **B** — existing + entity-overlap boost
- **C** — existing + entity-overlap boost + outcome-history penalty

For each, measure:

- **P@4** — precision of the top-4 results (matches Memento K cap)
- **MRR** — mean reciprocal rank of the first correct hit
- **Outcome-weighted relevance** — does the retrieval prefer cases
  with `Success` outcomes when outcomes are ambiguous otherwise?

### Acceptance criteria

- P@4 of C must exceed P@4 of A by a margin larger than held-out
  variance (95% CI, non-overlapping). Otherwise the graph isn't earning
  its keep.
- Entity-extraction quality on a second held-out sample must be ≥ 80%
  (correct identification of the agent-facing entities a human reviewer
  would expect).

If either criterion fails, ship with `cbr_graph_projection_enabled =
false` as default, land the JSONL schema change alone, and revisit once
extraction quality improves.

## Configuration

| Field | Default | Purpose |
|---|---|---|
| `cbr_graph_projection_enabled` | True after passing eval; False until then | Master switch |
| `cbr_graph_cooccur_min_weight` | 3 | Minimum edge weight for co-occurrence traversal |
| `cbr_graph_hub_degree` | 500 | Entity-node degree threshold above which a node is suppressed from co-occurrence expansion |
| `cbr_graph_entity_overlap_boost` | 0.15 | Reranker: score boost when candidate shares entities with query |
| `cbr_graph_outcome_penalty_max` | 0.20 | Reranker: maximum score penalty for cases whose entities have a history of failure outcomes |

Weights live in config so ablation variants can be A/B tested without
rebuilds.

## Implementation phases

| # | Name | LOC | Gated by |
|---|---|---|---|
| **1** | **MVP — projection + retrieval enrichment + eval** | ~500 | — |
| 2 | Drift detection (edge-weight rate-of-change, surfaced via meta observer) | ~300 | Phase 1 + empirical justification |
| 3 | Novelty / anomaly signal (unfamiliar entity combinations) | ~250 | Phase 2 + operator sign-off on behaviour changes |
| 4 | Sensorium block (compact graph-health line in `<vitals>` or similar) | ~150 | Phases 1–3 shipped and valued |

**MVP scope (Phase 1):**

- CbrCase schema extension (`entities: List(String)`)
- Archivist Phase 2 extracts entities via XStructor
- Librarian gains graph ETS tables + projection on IndexCase
- Rebuild replay at Librarian startup
- Two new retrieval signals in `cbr/bridge.gleam` reranker
- Config fields + defaults
- Ablation eval harness (script + held-out dataset + report)
- Go/no-go decision from eval before flipping the default on

## Risks and open questions

- **Entity extraction quality.** Load-bearing. If the Archivist's
  extraction is noisy, the graph noise-amplifies at retrieval time.
  Mitigation: extraction quality is part of the acceptance criteria;
  a schema-constrained XStructor field helps stability.
- **Retrieval weight retuning.** Existing fusion was tuned empirically.
  Adding two signals means the balance changes. The eval harness
  quantifies this rather than guessing.
- **Co-occurrence explosion.** Handled by weight pruning and hub
  suppression, but these are defaults that may need adjustment on real
  data. Worth checking graph size + degree distribution after a week
  of real operation.
- **Cold start.** A fresh agent has sparse case base, sparser graph.
  Enrichment signal is weak until enough cases accumulate. Ship with
  the enrichment signal weighted modestly; let weights grow with the
  graph's maturity (later work).
- **Who labels the eval dataset.** Operator-authored labels are the
  gold standard. Semi-automated labels (e.g. cases sharing thread IDs
  or domains) are a practical shortcut for the first eval but
  introduce their own bias. Be explicit about which is used.
- **Graph backend choice.** ETS is right for MVP (fits existing
  pattern, no new dependency). At scale — say, 100k+ cases with
  frequent traversal-heavy queries — Kuzu via FFI becomes worth
  evaluating. Not before.

## What this enables

- **Retrieval aware of structural similarity**, not just surface
  textual similarity. Two cases with different wording but shared
  entities can both surface for the same query.
- **Outcome-aware reranking**, so the agent doesn't recycle cases
  whose entities have a failure history.
- **Post-mortem traversal** — once the graph exists, "show me
  everything that touched `tool:run_code` this month with outcomes" is
  a graph query, not a JSONL grep. Supports observer forensics
  directly.
- **Foundation for later phases** (drift, anomaly, sensorium health)
  that earn value once retrieval augmentation proves itself.

What's *not* claimed: that this will automatically make the agent
smarter. Graph enrichment is only as good as the entities extracted
and the weights tuned. The eval harness exists precisely to keep us
honest about when the graph earns its keep and when it's just overhead.

## Relationship to other planned work

- **Deputies (shipped)** — deputies brief specialist agents with
  relevant CBR cases. If the graph improves retrieval quality, deputy
  briefings improve by the same margin. No direct dependency either
  way.
- **Captures (shipped)** — independent. Captures are operator-facing
  commitment tracking; graph projection is retrieval-facing.
- **Remembrancer (shipped)** — the Remembrancer's `mine_patterns`
  output is a natural consumer of graph cluster data. Once the graph
  exists, `mine_patterns` could use it directly rather than recomputing
  structural-field Jaccard on every run. Deferred integration.
- **Meta-learning Phase D (affect-performance correlation)** — entity
  nodes in the graph are a natural grouping for affect correlation
  queries. Could feed one another once both are proven.

## Open questions for the user

1. **Which entity types to include in MVP?** The design proposes six
   (`agent`, `tool`, `domain`, `failure`, `cycle`, `case`). Starting
   smaller — three or four — reduces extraction risk. Preferred
   starting set?
2. **Eval dataset source?** Hand-label 50 queries, or use existing
   narrative thread IDs as a proxy for semi-automated labels?
3. **Default on or off after eval passes?** Cautious would be off
   with explicit opt-in; consistent with the "if it shipped, it runs"
   principle is on by default.
