# CBR Self-Improvement and Metacognition Enhancements

**Status**: Planned, ready for implementation
**Date**: 2026-03-26
**Source**: Three-paper review — Memento (2508.16153), ACE (2510.04618), Dupoux/LeCun/Malik System M (2603.15381)
**Theoretical basis**: Sloman's H-CogAff meta-management layer

---

## Table of Contents

- [Academic References](#academic-references)
  - [Theoretical Foundation](#theoretical-foundation)
- [Enhancement 1: CBR Retrieval Tracking + Hit/Harm Counters](#enhancement-1-cbr-retrieval-tracking-hitharm-counters)
  - [Origin](#origin)
  - [Current State](#current-state)
  - [Proposed Change](#proposed-change)
  - [Implementation](#implementation)
- [Enhancement 2: K=4 Retrieval Cap](#enhancement-2-k4-retrieval-cap)
  - [Origin](#origin)
  - [Current State](#current-state)
  - [Proposed Change](#proposed-change)
  - [Implementation](#implementation)
- [Enhancement 3: CBR Case Categories](#enhancement-3-cbr-case-categories)
  - [Origin](#origin)
  - [Current State](#current-state)
  - [Proposed Change](#proposed-change)
  - [Implementation](#implementation)
- [Enhancement 4: Split Archivist into Reflector + Curator Phases](#enhancement-4-split-archivist-into-reflector-curator-phases)
  - [Origin](#origin)
  - [Current State](#current-state)
  - [Proposed Change](#proposed-change)
  - [Implementation](#implementation)
- [Enhancement 5: Budget-Triggered Housekeeping](#enhancement-5-budget-triggered-housekeeping)
  - [Origin](#origin)
  - [Current State](#current-state)
  - [Proposed Change](#proposed-change)
  - [Implementation](#implementation)
- [Enhancement 6: Canonical Meta-States in Sensorium](#enhancement-6-canonical-meta-states-in-sensorium)
  - [Origin](#origin)
  - [Current State](#current-state)
  - [Proposed Change](#proposed-change)
  - [Implementation](#implementation)
- [Implementation Priority](#implementation-priority)
- [What This Does NOT Include](#what-this-does-not-include)


## Academic References

| Paper | Authors | ArXiv | Key Contribution |
|---|---|---|---|
| **Memento** | Huichi Zhou et al. (UCL, Huawei Noah's Ark) | [2508.16153](https://arxiv.org/abs/2508.16153) | Learned case retrieval policy via soft Q-learning over episodic case bank; K=4 optimal; fast planner + smart executor |
| **ACE** (Agentic Context Engineering) | Zhang et al. (Stanford, SambaNova, UC Berkeley) | [2510.04618](https://arxiv.org/abs/2510.04618) | Incremental delta context updates; Reflector/Curator separation; hit/harm counters on context items; budget-triggered dedup |
| **System M** ("Why AI Systems Don't Learn") | Dupoux (FAIR/META), LeCun (NYU), Malik (UC Berkeley) | [2603.15381](https://arxiv.org/abs/2603.15381) | Three-system cognitive architecture (A/B/M); meta-controller operating on epistemic signals; Evo/Devo bilevel optimisation |

### Theoretical Foundation

These enhancements refine Springdrift's implementation of Sloman's H-CogAff architecture:

| Sloman Layer | Current Implementation | Enhancement |
|---|---|---|
| Reactive | D' deterministic pre-filter, reactive gate layer | Unchanged |
| Deliberative | D' LLM scorer, deliberative gate layer | Unchanged |
| Meta-management | Meta observer, forecaster, escalation criteria | Canonical epistemic signals, self-improving CBR retrieval |

---

## Enhancement 1: CBR Retrieval Tracking + Hit/Harm Counters

### Origin

- **Memento**: The retrieval policy over memory is itself a learnable policy. Tracking which retrievals led to good outcomes and biasing future retrieval is cheaper and more effective than fine-tuning.
- **ACE**: Attach `helpful_count` and `harmful_count` to each memory item. Use execution outcomes to update them. Prune high-harm, boost high-helpful.

### Current State

- `CbrCase` in `cbr/types.gleam` has `confidence` on the outcome but no usage tracking
- `cbr/bridge.gleam` retrieval uses a weighted sum of 5 signals (field score, index overlap, recency, domain match, embedding cosine)
- No feedback loop: cases are stored by the Archivist but never updated based on whether they helped
- Housekeeping prunes by age and confidence, not by actual utility

### Proposed Change

Add tracking fields to `CbrCase`:

```gleam
pub type CbrUsageStats {
  CbrUsageStats(
    retrieval_count: Int,           // Times retrieved by recall_cases
    retrieval_success_count: Int,   // Times the retrieving cycle succeeded
    helpful_count: Int,             // Explicit positive signal
    harmful_count: Int,             // Explicit negative signal
  )
}
```

Add `usage_stats: Option(CbrUsageStats)` to `CbrCase`. Optional for backward compatibility with legacy cases.

#### Feedback loop

1. When `recall_cases` returns cases, record their IDs in the cycle context
2. When the Archivist writes the cycle outcome, cross-reference retrieved case IDs
3. If cycle outcome is success → increment `retrieval_success_count` on each retrieved case
4. If cycle had tool failures or D' rejections → increment `harmful_count`
5. If cycle completed cleanly → increment `helpful_count`

#### Retrieval scoring

Blend a `utility_score` into the existing weighted sum:

```
utility_score = (retrieval_success_count + 1) / (retrieval_count + 2)  // Laplace smoothing
```

Add `cbr_utility_weight` to `RetrievalWeights` in `cbr/bridge.gleam`. Default 0.15 — redistributed from existing weights when utility data is available.

#### Housekeeping

- Cases with `harmful_count > helpful_count * 2` and `retrieval_count > 5` → candidates for deprecation
- Cases with `retrieval_count == 0` after 30 days → candidates for pruning (never useful enough to retrieve)

### Implementation

| File | Change |
|---|---|
| `src/cbr/types.gleam` | Add `CbrUsageStats` type, add `usage_stats: Option(CbrUsageStats)` to `CbrCase` |
| `src/cbr/log.gleam` | Encode/decode usage_stats (optional, backward compatible) |
| `src/cbr/bridge.gleam` | Add `utility_score` to retrieval weighted sum; add `cbr_utility_weight` to `RetrievalWeights` |
| `src/narrative/archivist.gleam` | After cycle outcome, update usage stats on retrieved cases |
| `src/narrative/housekeeping.gleam` | Use usage stats for pruning decisions |
| `src/agent/cognitive_state.gleam` | Track retrieved case IDs per cycle |
| `src/config.gleam` | Add `cbr_utility_weight: Option(Float)` |
| `test/cbr/usage_stats_test.gleam` | New test file |

**Effort**: ~150 lines new, ~80 lines modified
**Risk**: Low — usage_stats is optional, existing cases work unchanged

---

## Enhancement 2: K=4 Retrieval Cap

### Origin

**Memento**: Ablation shows performance peaks at K=4 retrieved cases. More causes context pollution — the LLM gets confused by too many examples.

### Current State

`cbr_max_results` in config defaults to 5 (max 20). The Curator injects all retrieved cases into the system prompt.

### Proposed Change

Change default from 5 to 4. Add a note in config documentation referencing the Memento finding.

### Implementation

| File | Change |
|---|---|
| `src/tools/memory.gleam` | Change `MemoryLimits` default `cbr_max_results` from 20 to 4 |
| `src/config.gleam` | Update default comment |
| `.springdrift/config.toml` | Update comment |
| `.springdrift_example/config.toml` | Update comment |

**Effort**: 5 minutes
**Risk**: None

---

## Enhancement 3: CBR Case Categories

### Origin

**ACE**: Organise playbook items into typed categories (strategies, code patterns, troubleshooting, pitfalls). Enables structured prompt assembly.

### Current State

`CbrCase` has `approach` and `pitfalls` as flat text fields. No type-level distinction between different kinds of knowledge.

### Proposed Change

Add a category enum:

```gleam
pub type CbrCategory {
  Strategy           // High-level approach that worked
  CodePattern        // Reusable code snippet or template
  Troubleshooting    // How to diagnose/fix a specific problem
  Pitfall            // What NOT to do — learned from failure
  DomainKnowledge    // Factual knowledge about a domain
}
```

Add `category: Option(CbrCategory)` to `CbrCase`. The Archivist assigns category based on the cycle outcome:
- Success with novel approach → `Strategy`
- Success involving code → `CodePattern`
- Failure with identified root cause → `Troubleshooting`
- Failure with identified mistake → `Pitfall`
- Pure research/factual → `DomainKnowledge`

The Curator can then assemble context by category — strategies first, then relevant patterns, then known pitfalls for the domain.

### Implementation

| File | Change |
|---|---|
| `src/cbr/types.gleam` | Add `CbrCategory` enum, add `category: Option(CbrCategory)` to `CbrCase` |
| `src/cbr/log.gleam` | Encode/decode category (optional, backward compatible) |
| `src/narrative/archivist.gleam` | Assign category during case generation |
| `src/narrative/curator.gleam` | Organise injected cases by category in system prompt |
| `test/cbr/category_test.gleam` | New test file |

**Effort**: ~80 lines new, ~40 lines modified
**Risk**: Low — category is optional

---

## Enhancement 4: Split Archivist into Reflector + Curator Phases

### Origin

**ACE**: Separating insight extraction from curation produces meaningfully better results. The Reflector asks "what went right/wrong?" The Curator decides "how to update the playbook." Ablation shows removing the Reflector drops performance significantly.

### Current State

The Archivist (`narrative/archivist.gleam`) makes a single LLM call that generates both a `NarrativeEntry` and a `CbrCase` from the cycle's context. It does insight extraction and structuring in one pass.

### Proposed Change

Split into two phases:

**Phase 1 — Reflection** (LLM call):
- Input: cycle context (messages, tool calls, outcomes, D' decisions)
- Output: raw insights — what worked, what failed, what was surprising, what to remember
- Prompt focuses on honest assessment, not formatting

**Phase 2 — Curation** (deterministic + optional LLM):
- Input: raw insights from Phase 1
- Output: structured `NarrativeEntry` + `CbrCase` with category, provenance, and usage stats initialised
- Can be mostly deterministic (template-based extraction from structured insights)
- Optional second LLM call for complex synthesis

The two-phase approach also makes the Archivist more testable — Phase 2 can be unit tested with fixed insight inputs.

### Implementation

| File | Change |
|---|---|
| `src/narrative/archivist.gleam` | Split `generate` into `reflect` (LLM call) and `curate` (structuring); update `spawn_archivist` to chain them |
| `src/xstructor/schemas.gleam` | New XSD schema for reflection output (insights structure) |
| `test/narrative/archivist_test.gleam` | Test curation phase independently |

**Effort**: ~200 lines new, ~100 lines modified
**Risk**: Medium — changes the Archivist's core flow. Both phases must complete for the fire-and-forget contract to hold. If Phase 1 succeeds but Phase 2 fails, the raw insights are lost. Mitigation: log Phase 1 output before starting Phase 2.

---

## Enhancement 5: Budget-Triggered Housekeeping

### Origin

**ACE**: Run dedup lazily — only when context exceeds a budget — rather than on a fixed schedule.

### Current State

Housekeeping runs on fixed timer ticks (short/medium/long) via the Housekeeper GenServer. CBR dedup runs on the long tick (~24h). The Curator enforces `preamble_budget_chars` by truncating low-priority slots.

### Proposed Change

Add a budget check to the Curator: when the assembled preamble exceeds `preamble_budget_chars` AND CBR cases are being truncated, send a `HousekeepingNeeded` message to the Housekeeper to trigger immediate dedup. This supplements (not replaces) the timer-based schedule.

### Implementation

| File | Change |
|---|---|
| `src/narrative/curator.gleam` | After `apply_preamble_budget`, if CBR content was truncated, send `HousekeepingNeeded` to Housekeeper |
| `src/narrative/housekeeping.gleam` | Add `HousekeepingNeeded` message handler that triggers CBR dedup |
| `src/agent/types.gleam` or housekeeper types | Add message variant |

**Effort**: ~30 lines
**Risk**: Low — additive, doesn't change existing schedule

---

## Enhancement 6: Canonical Meta-States in Sensorium

### Origin

**System M** (Dupoux/LeCun/Malik): The meta-controller should operate on a small set of well-defined epistemic signals. Replace ad-hoc vitals with principled metrics.

**Sloman**: Meta-management is the system reasoning about its own processing.

### Current State

The sensorium `<vitals>` section includes:
- `cycles_today` — count
- `agents_active` — count
- `agent_health` — last error text
- `last_failure` — from narrative
- `cycles_remaining` / `tokens_remaining` — budget

These are operational metrics, not epistemic signals. The system can count what it did but can't express how confident or uncertain it is.

### Proposed Change

Add three canonical meta-states to the sensorium:

**Uncertainty**: What proportion of recent CBR retrievals returned no matches? High uncertainty means the agent is in unfamiliar territory.

```
uncertainty = 1.0 - (cycles_with_cbr_hits / total_recent_cycles)
```

Derived from Librarian query over recent narrative entries cross-referenced with CBR retrieval logs.

**Prediction Error**: How often did tool calls fail or D' gates fire in the current session? High prediction error means the agent's expectations are misaligned with reality.

```
prediction_error = (tool_failures + dprime_modifications + dprime_rejections) / total_tool_calls
```

Derived from `cycle_tool_calls` and `dprime_decisions` on CognitiveState.

**Novelty**: How similar is the current query to the most recent narrative entries? Low similarity = high novelty.

```
novelty = 1.0 - max_similarity(current_input, recent_narrative_summaries)
```

Derived from keyword overlap with recent thread summaries. No embedding needed — simple Jaccard over keywords.

These appear in the sensorium as:

```xml
<vitals cycles_today="12" agents_active="5"
        uncertainty="0.3" prediction_error="0.1" novelty="0.7" />
```

The D' gates, escalation criteria, and forecaster can all read from these signals.

### Implementation

| File | Change |
|---|---|
| `src/narrative/curator.gleam` | Compute uncertainty, prediction_error, novelty during sensorium assembly; add as `<vitals>` attributes |
| `src/agent/cognitive_state.gleam` | Track `session_tool_failures`, `session_dprime_modifications`, `session_total_tool_calls` counters |
| `src/agent/cognitive.gleam` | Increment counters after tool execution and D' decisions |
| `src/agent/cognitive/escalation.gleam` | Optionally use meta-states for escalation decisions (future wiring) |
| `test/narrative/curator_meta_states_test.gleam` | New test file |

**Effort**: ~150 lines new, ~50 lines modified
**Risk**: Low — additive to the sensorium. Existing consumers ignore unknown attributes.

---

## Implementation Priority

| # | Enhancement | Effort | Value | Source |
|---|---|---|---|---|
| 1 | CBR retrieval tracking + hit/harm counters | Medium (~230 lines) | High — closes the feedback loop | Memento + ACE |
| 2 | K=4 retrieval cap | Trivial | Quick win | Memento |
| 3 | CBR case categories | Small (~120 lines) | Medium — structured context | ACE |
| 4 | Split Archivist into Reflector + Curator | Large (~300 lines) | High — better insight extraction | ACE |
| 5 | Budget-triggered housekeeping | Small (~30 lines) | Low-medium — efficiency | ACE |
| 6 | Canonical meta-states in sensorium | Medium (~200 lines) | High — principled metacognition | System M / Sloman |

**Recommended order**: 2 → 1 → 3 → 5 → 6 → 4

Start with the trivial win (K=4), then close the CBR feedback loop (retrieval tracking), add categories, wire budget-triggered dedup, add meta-states to the sensorium, and finally tackle the Archivist split as the largest change.

Enhancements 1-3 make the CBR system self-improving. Enhancement 6 makes the meta-management layer principled. Enhancement 4 improves memory quality. Enhancement 5 is an efficiency optimisation.

---

## What This Does NOT Include

- **Neural Q-learning for retrieval** (Memento): Requires gradient infrastructure (PyTorch/JAX) not available on BEAM. The empirical success-rate approach captures most of the value without it.
- **Full Evo/Devo bilevel optimisation** (System M): Requires many agent lifetimes to optimise. Interesting for research, not production.
- **Monolithic context rewriting** (explicitly avoided per ACE's warning): All updates remain append-only with delta patches.
- **Intent Graph pre-generation** (from Curragh's earlier CCA analysis): Over-engineered for an exploratory agent.
