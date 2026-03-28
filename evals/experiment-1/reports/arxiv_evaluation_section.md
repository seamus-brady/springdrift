# Empirical Evaluation

## Experimental Setup

All evaluations run against Springdrift's production libraries compiled from
Gleam to Erlang/OTP. No LLM calls are made during evaluation — all tested
components are deterministic. Experiments are fully reproducible via
`gleam test` from the project root.

The system under test comprises three subsystems: (1) a Case-Based Reasoning
retrieval engine with 6-signal weighted fusion, (2) a normative calculus for
ethical conflict resolution based on Becker's *A New Stoicism* (1998), and
(3) a D' discrepancy scoring engine based on Beach's Image Theory (2010) and
Sloman's H-CogAff architecture (2001).

---

## Evaluation 1: CBR Retrieval Quality — Signal Ablation

### Method

We construct a synthetic case base of 40 cases uniformly distributed across
four domains (property market, financial analysis, legal research, technical
operations), with 10 cases per domain. Each case has structured metadata:
intent classification, domain label, keyword set, named entities, solution
approach, tools used, agent roster, outcome status, and confidence score.
Timestamps span 10 days to provide temporal variation.

Six queries are constructed with known relevant case sets (3–5 relevant cases
per query), enabling precise measurement of retrieval quality. Relevance is
defined by domain + keyword overlap against manually curated ground truth.

We evaluate four weight configurations via ablation:

| Configuration | Field | Index | Recency | Domain | Embedding | Utility |
|---|---|---|---|---|---|---|
| Full weighted | 0.30 | 0.20 | 0.15 | 0.15 | 0.10 | 0.10 |
| Field only | 1.00 | 0 | 0 | 0 | 0 | 0 |
| Index only | 0 | 1.00 | 0 | 0 | 0 | 0 |
| Field + Index + Domain | 0.40 | 0.30 | 0 | 0.30 | 0 | 0 |

Embeddings and utility scoring are excluded from this evaluation as they
require runtime state (Ollama server and accumulated usage statistics
respectively). The evaluation tests the deterministic retrieval signals.

### Metrics

Standard information retrieval metrics following Aamodt & Plaza (1994):

- **Precision@K** (P@K): proportion of top-K retrieved cases that are relevant
- **Mean Reciprocal Rank** (MRR): 1/rank of first relevant result, averaged across queries
- **Recall@K** (R@K): proportion of relevant cases appearing in top-K results

### Results

**Table 1: CBR Retrieval Signal Ablation (N=40 cases, 6 queries, K=4)**

| Configuration | P@4 | MRR | Per-query P@4 range |
|---|---|---|---|
| Index only | **0.667** | 1.000 | 0.500 – 0.750 |
| Field + Index + Domain | 0.583 | 1.000 | 0.250 – 0.750 |
| Full weighted (6 signals) | 0.542 | 1.000 | 0.250 – 0.750 |
| Field only | 0.500 | 1.000 | 0.250 – 0.750 |

**Table 2: Per-Query Precision@4 by Configuration**

| Query | Relevant | full_weighted | field_only | index_only | field_index_domain |
|---|---|---|---|---|---|
| dublin_rent | 5 | 0.500 | 0.750 | 0.750 | 0.750 |
| bond_analysis | 3 | 0.500 | 0.250 | 0.500 | 0.500 |
| contract_law | 3 | 0.750 | 0.750 | 0.750 | 0.750 |
| deployment_troubleshoot | 3 | 0.250 | 0.250 | 0.750 | 0.250 |
| crypto_regulation | 3 | 0.500 | 0.250 | 0.500 | 0.500 |
| ip_law | 3 | 0.750 | 0.750 | 0.750 | 0.750 |

### Analysis

MRR = 1.000 across all configurations indicates that the first retrieved case
is always relevant — the system reliably ranks a correct case at position 1
regardless of signal weighting. This is a strong result for a domain-partitioned
case base.

The inverted index signal achieves the highest P@4 (0.667) on this dataset
because the synthetic cases have clean, distinct keyword vocabularies per
subdomain. The full weighted fusion (0.542) scores lower because recency and
utility signals carry no discriminative information in this controlled setting
(all cases span 10 days, no usage statistics accumulated).

The deployment troubleshooting query (P@4 = 0.250 for most configurations,
0.750 for index-only) reveals a signal interaction: the field scoring weights
intent match heavily, and "troubleshooting" as an intent is shared across
multiple technical cases with different keywords. The inverted index correctly
discriminates by keyword overlap ("deployment", "docker") while field scoring
conflates all troubleshooting cases.

Cross-domain contamination is low: the `bond_analysis` query under index-only
retrieves one property case (`prop-05`, which contains the keyword "yield" —
shared with financial analysis). This is correct behaviour: the inverted index
finds genuine lexical overlap.

### Limitations

This evaluation uses a small, uniformly distributed synthetic dataset. The
K=4 retrieval cap (following Zhou et al., 2025) means precision is measured
on a small set. Semantic embedding and utility scoring signals are not tested
(they require runtime infrastructure). A production evaluation with
accumulated usage statistics and Ollama embeddings would be needed to assess
the full 6-signal fusion.

---

## Evaluation 2: Normative Calculus — Exhaustive Completeness

### Method

The normative calculus operates on pairs of Normative Propositions (NPs),
each defined by a level (14-tier hierarchy), operator (Required, Ought,
Indifferent), and modality (Possible, Impossible). We generate the complete
input space: 14 × 3 × 2 = 84 unique NPs, and test all 84 × 84 = 7,056
ordered pairs through the `calculus.resolve` function.

For each pair we record: the conflict severity (NoConflict, Coordinate,
Superordinate, Absolute), the resolution (SystemWins, CoordinateConflict,
NoConflictResolution), and the rule that fired (one of 8 named rules
corresponding to Becker's axioms 6.2–6.7 plus three structural rules).

We verify four properties:

1. **Totality**: every input pair produces a result (no unhandled cases)
2. **Determinism**: same inputs always produce the same output
3. **Rule coverage**: every rule fires on at least one input pair
4. **Severity monotonicity**: conflict severity respects the level ordering

### Results

**Table 3: Normative Calculus Completeness**

| Property | Result |
|---|---|
| Input space | 84 NPs × 84 NPs = 7,056 pairs |
| Coverage | 100% (all pairs tested) |
| Totality | Verified (7,056/7,056 produce results) |
| Determinism violations | 0 |
| Monotonicity violations | 0 |
| Unique rules fired | 8/8 |

**Table 4: Axiom/Rule Firing Distribution**

| Rule | Count | % | Becker Reference |
|---|---|---|---|
| axiom_6.6_futility | 3,528 | 50.0 | §6.6: Impossible modality is inert |
| axiom_6.7_indifference | 1,176 | 16.7 | §6.7: Indifferent operator carries no weight |
| user_level_dominant | 1,092 | 15.5 | (structural: user level > system level) |
| axiom_6.3_moral_priority | 1,040 | 14.7 | §6.3: Higher level dominates |
| user_operator_dominant | 84 | 1.2 | (structural: user operator > system operator) |
| axiom_6.2_absolute_prohibition | 56 | 0.8 | §6.2: EthicalMoral + Required is categorical |
| equal_weight_coordinate | 54 | 0.8 | (structural: same level + same operator) |
| axiom_6.4_moral_rank | 26 | 0.4 | §6.4: Same level, stronger operator dominates |

**Table 5: Conflict Severity Distribution**

| Severity | Count | % |
|---|---|---|
| NoConflict | 5,880 | 83.3 |
| Superordinate | 1,066 | 15.1 |
| Absolute | 56 | 0.8 |
| Coordinate | 54 | 0.8 |

### Analysis

The calculus is total and deterministic over its entire input space — a
mathematical guarantee, not a statistical sample. Axiom 6.6 (Futility)
dominates at 50% because exactly half the NPs have Impossible modality, and
the futility pre-processor fires before any other rule. This is by design:
impossible propositions are normatively inert (Becker §6.6).

The 83.3% NoConflict rate reflects the asymmetry of the resolution rules:
when the user-side NP has a higher level or stronger operator than the
system-side NP, there is no conflict from the system's perspective. Only
when the system NP is at least as strong as the user NP does a conflict
arise (16.7% of pairs).

Absolute severity (0.8%) fires exclusively on pairs where the system NP is
EthicalMoral + Required — the categorical prohibition (Becker §6.2). This
is the agent's hard refusal boundary.

---

## Evaluation 3: Normative Floor Rules — Priority Ordering

### Method

The normative judgement layer maps conflict results + D' scores to a
FlourishingVerdict (Flourishing, Constrained, Prohibited) via 8 floor rules
in priority order. We construct test cases that trigger each floor rule in
isolation and verify: (a) each floor produces the correct verdict, and (b)
higher-priority floors override lower-priority floors when both conditions
are met.

### Results

**Table 6: Floor Rule Correctness**

| Floor | Trigger Condition | Expected Verdict | Result |
|---|---|---|---|
| 1 | Absolute severity | Prohibited | PASS |
| 2 | Superordinate at Legal+ | Prohibited | PASS |
| 3 | D' ≥ reject threshold | Prohibited | PASS |
| 4 | Catastrophic + Superordinate | Constrained | PASS |
| 5 | 2+ Coordinate conflicts | Constrained | PASS |
| 6 | D' ≥ modify threshold | Constrained | PASS |
| 7 | Superordinate at mid levels | Constrained | PASS |
| 8 | Default | Flourishing | PASS |

**Table 7: Priority Override Tests**

| Test | Conditions | Winner | Result |
|---|---|---|---|
| Floor 1 vs Floor 3 | Absolute + D' ≥ reject | Floor 1 | PASS |
| Floor 2 vs Floor 6 | Superordinate at Legal + D' ≥ modify | Floor 2 | PASS |

All 8 floor rules and 2 priority tests pass (10/10). Floors 3 and 6
preserve backward compatibility with the existing D' threshold-based
decisions, ensuring the normative layer is strictly additive.

---

## Data Availability

All evaluation code, synthetic datasets, and raw results are included in the
repository under `test/eval/` (Gleam harnesses) and `evals/` (results as
JSONL, analysis scripts, generated reports). Evaluations are reproducible
via `gleam test` with no external dependencies.

**Raw data files:**
- `evals/results/cbr_structured.jsonl` — per-query retrieval results
- `evals/results/cbr_retrieval.jsonl` — operational data ablation
- `evals/results/normative_completeness.jsonl` — 7,056-pair resolution data
- `evals/results/normative_floors.jsonl` — floor rule test results

---

## References

- Aamodt, A., & Plaza, E. (1994). Case-based reasoning: Foundational issues,
  methodological variations, and system approaches. *AI Communications*, 7(1), 39-59.
- Beach, L. R. (2010). *The Psychology of Narrative Thought*. Xlibris.
- Becker, L. C. (1998). *A New Stoicism*. Princeton University Press.
- Sloman, A. (2001). Beyond shallow models of emotion. *Cognitive Processing*, 2(1), 177-198.
- Zhou, H. et al. (2025). Memento: Leveraging episodic memory for LLM agents.
  arXiv:2508.16153.
- Zhang, Z. et al. (2025). ACE: Agentic context engineering. arXiv:2510.04618.
- Dupoux, E., LeCun, Y., & Malik, J. (2026). System M: Why AI systems don't
  learn. arXiv:2603.15381.
