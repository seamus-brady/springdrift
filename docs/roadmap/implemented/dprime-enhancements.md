# D' Enhancements from Three-Paper Integration

**Status**: Specified, ready for implementation
**Date**: 2026-03-25
**Source**: Three-paper integration research by Curragh (Springdrift agent instance)

---

## Table of Contents

- [Academic References](#academic-references)
  - [Confidence Note](#confidence-note)
- [Enhancement 1: Confidence Decay on Facts and CBR Cases](#enhancement-1-confidence-decay-on-facts-and-cbr-cases)
  - [Origin](#origin)
  - [Current State in Springdrift](#current-state-in-springdrift)
  - [Proposed Change](#proposed-change)
  - [Implementation](#implementation)
- [Enhancement 2: Provenance Tags on Facts](#enhancement-2-provenance-tags-on-facts)
  - [Origin](#origin)
  - [Current State in Springdrift](#current-state-in-springdrift)
  - [Proposed Change](#proposed-change)
  - [Impact on D' Output Gate](#impact-on-d-output-gate)
  - [Implementation](#implementation)
- [Enhancement 3: Formalised Escalation Criteria](#enhancement-3-formalised-escalation-criteria)
  - [Origin](#origin)
  - [Current State in Springdrift](#current-state-in-springdrift)
  - [Proposed Change](#proposed-change)
  - [Implementation](#implementation)
- [Implementation Priority](#implementation-priority)
- [Validation Against Source Papers](#validation-against-source-papers)


## Academic References

| Paper | Authors | ArXiv | Key Contribution |
|---|---|---|---|
| **CCA** (Cognitive Control Architecture) | arXiv:2512.06716 | [2512.06716](https://arxiv.org/abs/2512.06716) | Intent Graph with Parameter Provenance Placeholders; 4-dimensional Adjudicator (semantic alignment, causal contribution, source provenance, inherent risk); 0.34% attack success rate at 86% utility |
| **SOFAI-LM** | IBM Research | arXiv:2508.17959 | [2508.17959](https://arxiv.org/abs/2508.17959) | S1/S2 metacognitive architecture; episodic memory with confidence decay; correctness functions C(y) and feedback F(y_t); stagnation detection with S1→S2 escalation |
| **Nowaczyk** (Agentic Architecture) | Nowaczyk et al. | arXiv:2512.09458 | [2512.09458](https://arxiv.org/abs/2512.09458) | BDI-style componentisation; explicit interface contracts; Verifier/Critic for pre-execution validation; versioned policies with rollback |

### Confidence Note

These papers were analysed via agent-retrieved summaries, not direct quote extraction (the researcher agent crashed during quote extraction). The design proposals below are novel synthesis informed by these papers, not positions endorsed by the papers themselves. ArXiv IDs verified 2026-03-25.

---

## Enhancement 1: Confidence Decay on Facts and CBR Cases

### Origin

SOFAI-LM's episodic memory model uses time-based confidence degradation. Information becomes less reliable as it ages — a fact verified yesterday is more trustworthy than one stored a month ago. The paper describes smooth decay rather than binary fresh/stale.

### Current State in Springdrift

- Facts (`facts/types.gleam`) have a `confidence: Float` field (0.0-1.0) set at write time, never updated
- CBR cases (`cbr/types.gleam`) have `confidence: Float` on the outcome, static after creation
- The Librarian replays facts and cases from JSONL without adjusting for age
- The CBR retrieval scorer (`cbr/bridge.gleam`) has a `recency` signal in its weighted fusion, but this is based on creation date ranking, not confidence adjustment
- The meta observer (`meta/log.gleam`) has `decay_days: 7` for observation history, but this is a hard cutoff, not smooth decay

### Proposed Change

Add a mathematical half-life decay function that adjusts confidence at query time:

```
confidence_t = confidence_0 * 2^(-age_days / half_life_days)
```

Where:
- `confidence_0` is the original confidence when the fact/case was stored
- `age_days` is days since creation
- `half_life_days` is configurable (default: 30 for facts, 60 for CBR cases)

The stored confidence is never mutated (append-only principle). Decay is applied at read time — when the Librarian returns facts or the CBR retriever scores cases.

### Implementation

**New file**: `src/dprime/decay.gleam` — pure function module

```gleam
/// Apply half-life confidence decay.
/// Returns the decayed confidence value at query time.
pub fn decay_confidence(
  original_confidence: Float,
  age_days: Int,
  half_life_days: Int,
) -> Float

/// Apply decay to a fact based on its timestamp and current date.
pub fn decay_fact(fact: MemoryFact, today: String, half_life: Int) -> MemoryFact
```

**Modified files**:

| File | Change |
|---|---|
| `src/narrative/librarian.gleam` | Apply `decay_confidence` when returning facts via `QueryFact`, `QueryFacts` |
| `src/cbr/bridge.gleam` | Apply `decay_confidence` to case outcome confidence during retrieval scoring |
| `src/config.gleam` | Add `fact_decay_half_life_days: Option(Int)` and `cbr_decay_half_life_days: Option(Int)` |
| `.springdrift/config.toml` | Add decay config under `[housekeeping]` |
| `.springdrift_example/config.toml` | Same |
| `test/dprime/decay_test.gleam` | Unit tests for decay function |

**Config**:

```toml
[housekeeping]
# Half-life in days for fact confidence decay (default: 30)
# fact_decay_half_life_days = 30

# Half-life in days for CBR case confidence decay (default: 60)
# cbr_decay_half_life_days = 60
```

**Effort**: ~50 lines of new code, ~30 lines of modifications. Small, bounded, high value.

**Impact on existing behaviour**: Facts and CBR cases returned by the Librarian will have lower effective confidence as they age. The output gate's unsourced_claim detection benefits indirectly — old facts with decayed confidence are less likely to be presented as high-confidence claims.

---

## Enhancement 2: Provenance Tags on Facts

### Origin

CCA's "Parameter Provenance Placeholders" enforce data-flow integrity by tracking which tool arguments trace to which sources. Every parameter in the Intent Graph carries metadata about its origin. The 4-dimensional Adjudicator includes "source provenance" as one of its scoring dimensions.

### Current State in Springdrift

- `memory_write` stores facts with key, value, scope, and confidence — no source tracking
- The output gate flags `unsourced_claim` by asking the LLM scorer to evaluate text quality — a heuristic, not a data-level check
- Cycle log entries have `cycle_id` but facts don't reference back to the cycle that created them
- The `MemoryFact` type has `supersedes: Option(String)` for tracking fact lineage but not source lineage

### Proposed Change

Add provenance metadata to facts:

```gleam
pub type FactProvenance {
  FactProvenance(
    /// Cycle that created this fact
    source_cycle_id: String,
    /// Tool that produced the data (e.g. "web_search", "fetch_url", "memory_write")
    source_tool: String,
    /// Agent that produced it (e.g. "cognitive", "researcher", "coder")
    source_agent: String,
    /// How the fact was derived
    derivation: FactDerivation,
  )
}

pub type FactDerivation {
  /// Directly observed from a tool result
  DirectObservation
  /// Inferred or synthesised from multiple sources
  Synthesis
  /// Stated by the user/operator
  OperatorProvided
  /// Unknown or legacy (no provenance available)
  Unknown
}
```

The `memory_write` tool gains an optional `provenance` parameter. When called from within the cognitive loop, the provenance is auto-populated from the current cycle context. Legacy facts without provenance get `derivation: Unknown`.

### Impact on D' Output Gate

The output gate can check provenance when evaluating `unsourced_claim`:

- Fact with `DirectObservation` from `fetch_url` → well-sourced
- Fact with `Synthesis` from `cognitive` → needs hedging
- Fact with `Unknown` provenance → flag as unsourced

This upgrades `unsourced_claim` detection from text-level heuristic (asking the LLM "does this look sourced?") to data-level verification (checking whether the underlying facts have traceable origins).

### Implementation

**Modified files**:

| File | Change |
|---|---|
| `src/facts/types.gleam` | Add `FactProvenance` and `FactDerivation` types; add `provenance: Option(FactProvenance)` to `MemoryFact` |
| `src/facts/log.gleam` | Encode/decode provenance in JSONL (optional field, backward compatible) |
| `src/tools/memory.gleam` | `memory_write` tool accepts optional provenance; auto-populate from cycle context when available |
| `src/narrative/librarian.gleam` | Index provenance metadata in ETS; support provenance-aware queries |
| `src/dprime/output_gate.gleam` | When evaluating `unsourced_claim`, query provenance for facts referenced in the report |
| `test/facts/provenance_test.gleam` | Unit tests |

**Backward compatibility**: `provenance` is `Option(FactProvenance)`. Legacy facts decode as `None`. No migration needed.

**Effort**: ~150 lines new code, ~80 lines modifications. Medium effort, high value for output quality.

---

## Enhancement 3: Formalised Escalation Criteria

### Origin

SOFAI-LM's S1→S2 escalation is governed by explicit criteria: the metacognitive governor evaluates `C(y)` (correctness) and `F(y_t)` (feedback), triggering escalation when the cheap solver stagnates or confidence drops below threshold. Stagnation is detected by monitoring solution quality across iterations.

### Current State in Springdrift

The system already has the signals but they're not wired into model selection:

| Signal | Source | Currently Used For |
|---|---|---|
| Query complexity | `query_complexity.gleam` | Initial model selection (Simple→haiku, Complex→opus) |
| Tool failures | Agent framework | Warning prefix on agent results |
| Stagnation detection | `dprime/meta.gleam` | Threshold tightening |
| Forecaster D' score | `planner/forecaster.gleam` | Sensory events suggesting replan |
| Meta observer signals | `meta/observer.gleam` | Interventions (cooldown, tighten, escalate) |
| Token budget | Scheduler runner | Job skipping |

Model fallback currently only triggers on API errors (500, 503, 529, timeout). There is no escalation based on task difficulty or agent performance.

### Proposed Change

Add structured escalation criteria that trigger model upgrade mid-cycle:

```gleam
pub type EscalationTrigger {
  /// Tool failures exceed threshold within a cycle
  ToolFailureEscalation(failure_count: Int, threshold: Int)
  /// D' score elevated across consecutive evaluations
  SafetyEscalation(avg_score: Float, threshold: Float)
  /// Agent hit max_turns without completing
  TurnExhaustionEscalation(agent: String, turns_used: Int, max_turns: Int)
  /// Token budget approaching limit
  BudgetEscalation(tokens_used: Int, budget: Int, threshold_pct: Float)
  /// Stagnation detected by meta-management
  StagnationEscalation(stall_count: Int)
}
```

When an escalation triggers:

1. The cognitive loop switches the current cycle's model from task_model to reasoning_model
2. The escalation is logged in the cycle log and visible in the D' Safety admin panel
3. The sensorium includes the escalation reason so the agent knows why it got a more powerful model

This is NOT about the initial classification (Simple/Complex) — that stays. This is about mid-cycle escalation when things go wrong with the cheap model.

### Implementation

**New file**: `src/agent/cognitive/escalation.gleam` — pure functions evaluating escalation criteria

```gleam
/// Check if any escalation criteria are met.
/// Returns Some(trigger) if escalation should happen, None otherwise.
pub fn check_escalation(
  tool_failure_count: Int,
  dprime_scores: List(Float),
  turn_count: Int,
  max_turns: Int,
  tokens_used: Int,
  token_budget: Int,
  config: EscalationConfig,
) -> Option(EscalationTrigger)
```

**Modified files**:

| File | Change |
|---|---|
| `src/agent/cognitive.gleam` | After tool execution failures or elevated D' scores, call `check_escalation`; if triggered, switch model for remainder of cycle |
| `src/agent/framework.gleam` | After agent turn exhaustion, report back to cognitive loop with escalation signal |
| `src/agent/cognitive_state.gleam` | Add `escalation_config: EscalationConfig` to RuntimeConfig |
| `src/config.gleam` | Add escalation config fields |
| `src/cycle_log.gleam` | Log escalation events |
| `src/web/html.gleam` | Show escalation events in D' Safety panel |
| `test/agent/escalation_test.gleam` | Unit tests |

**Config** (in `config.toml`):

```toml
[escalation]
# Enable mid-cycle model escalation (default: true)
# enabled = true

# Tool failures before escalation (default: 2)
# tool_failure_threshold = 2

# Average D' score threshold for safety escalation (default: 0.4)
# safety_score_threshold = 0.4

# Token budget percentage that triggers escalation (default: 0.8 = 80%)
# budget_threshold_pct = 0.8
```

**Effort**: ~100 lines new code, ~60 lines modifications. Medium effort, medium value. The signals already exist — this is wiring them into model selection.

**Risk**: Model switching mid-cycle means the conversation context was built by one model and continued by another. This is already handled by the model fallback path (which prepends `[model_x unavailable, used model_y]`). The same pattern works for escalation.

---

## Implementation Priority

| Enhancement | Effort | Value | Risk | Priority |
|---|---|---|---|---|
| 1. Confidence Decay | Small (~50 lines) | High — improves fact freshness | Low | First |
| 2. Provenance Tags | Medium (~230 lines) | High — upgrades output quality | Low | Second |
| 3. Escalation Criteria | Medium (~160 lines) | Medium — better model utilisation | Medium | Third |

All three are independent — they can be implemented in any order without dependencies between them. Each has its own test suite and config surface.

---

## Validation Against Source Papers

| Enhancement | Paper Source | What the Paper Proposes | What We Take | What We Skip |
|---|---|---|---|---|
| Confidence Decay | SOFAI-LM (2508.17959) | Episodic memory with S1/S2 feedback loops modifying confidence | Simple half-life decay at query time | Complex RL feedback on memory updates |
| Provenance Tags | CCA (2512.06716) | Full Intent Graph with Parameter Provenance Placeholders and pre-generated DAG | Source tagging on facts with derivation type | Pre-generated tool call DAGs, full provenance graph |
| Escalation Criteria | SOFAI-LM (2508.17959) | Metacognitive governor with C(y) correctness functions and stagnation detection | Structured triggers for model switching using existing signals | Domain-specific correctness functions, RL-trained governor |

In each case, we take the practical kernel and skip the academic machinery. The papers validate the principles; the implementation stays grounded in what Springdrift actually needs.
