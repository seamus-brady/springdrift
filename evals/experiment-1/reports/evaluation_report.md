# Springdrift Empirical Evaluation Report

**Generated:** 2026-03-27T19:45:05

---

## 1. CBR Retrieval Quality — Signal Ablation

**Dataset:** 408 cases, 50 queries (leave-one-out)
**Relevance criterion:** Same domain
**Method:** For each query case, retrieve top-4 from remaining cases under different weight configurations. Measure Precision@4, Mean Reciprocal Rank, and Recall@4.

| Config | P@4 | MRR | R@4 |
|---|---|---|---|
| full_6signal | 0.485 | 0.400 | 0.673 |
| field_only | 0.350 | 0.347 | 0.485 |
| index_only | 0.235 | 0.287 | 0.340 |
| recency_only | 0.000 | 0.000 | 0.000 |
| domain_only | 0.545 | 0.670 | 0.735 |
| field_index | 0.350 | 0.345 | 0.487 |

Full 6-signal fusion improves P@4 by 38.6% over field-only baseline.
Domain match alone outperforms the fusion — suggesting domain is the dominant relevance dimension in this case base (single-agent, multi-domain workload).

## 2. Normative Calculus — Exhaustive Completeness

**Input space:** 84 NPs × 84 NPs = 7056 pairs
**Coverage:** 100%
**Unique rules fired:** 8/8
**Monotonicity violations:** 0
**Determinism violations:** 0

The normative calculus is total (produces a result for every possible input pair), deterministic (same inputs always produce the same output), and achieves full rule coverage (all 8 resolution rules fire on at least one input pair). Zero monotonicity violations confirm that conflict severity respects the level ordering.

## 3. Normative Floor Rules — Priority Ordering

**Tests passed:** 8/8
**Priority tests passed:** 2/2

All 8 floor rules produce the correct verdict for their designed trigger conditions. Priority ordering is correct — higher-priority floors always override lower-priority floors when both conditions are met.

---

## Methodology

All evaluations run against Springdrift's real libraries (Gleam, compiled to Erlang). CBR evaluation uses 408 cases from 17 days of agent operation. Normative calculus evaluation is exhaustive over the full input space (14 levels × 3 operators × 2 modalities = 84 NPs, all 7,056 pairs tested). No LLM calls are made during evaluation — all computations are deterministic.

**Reproducibility:** Run `gleam test` to regenerate all results. JSONL outputs in `evals/results/`, this report in `evals/reports/`.
