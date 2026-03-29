# Empirical Evaluation Plan

**Status**: Planned — requires runtime data collection (1-2 weeks of agent operation)
**Date**: 2026-03-26
**Prerequisites**: Stable D' system, CBR self-improvement running, meta-states in sensorium

---

## Table of Contents

- [Overview](#overview)
- [Data Collection Infrastructure](#data-collection-infrastructure)
  - [Session Logger](#session-logger)
  - [Replay Tool](#replay-tool)
  - [CLI Command](#cli-command)
- [Evaluation 1: D' Safety Gate Accuracy](#evaluation-1-d-safety-gate-accuracy)
  - [Goal](#goal)
  - [Method](#method)
  - [Implementation](#implementation)
- [Evaluation 2: CBR Self-Improvement Over Time](#evaluation-2-cbr-self-improvement-over-time)
  - [Goal](#goal)
  - [Method](#method)
  - [Implementation](#implementation)
- [Evaluation 3: Output Gate Quality Detection](#evaluation-3-output-gate-quality-detection)
  - [Goal](#goal)
  - [Method](#method)
  - [Implementation](#implementation)
- [Evaluation 4: Confidence Decay Impact on Output Quality](#evaluation-4-confidence-decay-impact-on-output-quality)
  - [Goal](#goal)
  - [Method](#method)
  - [Implementation](#implementation)
- [Evaluation 5: Deterministic Pre-Filter Cost Savings](#evaluation-5-deterministic-pre-filter-cost-savings)
  - [Goal](#goal)
  - [Method](#method)
  - [Implementation](#implementation)
- [Evaluation 6: Archivist Split Quality](#evaluation-6-archivist-split-quality)
  - [Goal](#goal)
  - [Method](#method)
  - [Implementation](#implementation)
- [Evaluation 7: Meta-State Correlation with Task Outcomes](#evaluation-7-meta-state-correlation-with-task-outcomes)
  - [Goal](#goal)
  - [Method](#method)
  - [Implementation](#implementation)
- [Data Collection Timeline](#data-collection-timeline)
- [Output Format](#output-format)
- [New Files Required](#new-files-required)
- [Relationship to Existing Eval Tests](#relationship-to-existing-eval-tests)
- [References](#references)


## Overview

Springdrift has 1310 unit/correctness tests covering component mechanics. This plan describes the empirical evaluation needed to produce paper-quality metrics: baseline comparisons, real-workload data, and statistical significance on standard benchmarks.

The evaluation measures seven capabilities across three categories: safety (D' gates), learning (CBR self-improvement, confidence decay), and metacognition (meta-states, escalation).

---

## Data Collection Infrastructure

### Session Logger

All evaluations depend on rich session data. Springdrift already logs extensively:

| Data Source | Location | Contents |
|---|---|---|
| Cycle log | `.springdrift/memory/cycle-log/YYYY-MM-DD.jsonl` | Every LLM call, tool call, tool result, D' evaluation per cycle |
| Narrative | `.springdrift/memory/narrative/YYYY-MM-DD.jsonl` | Per-cycle summaries with intent, outcome, entities, delegation steps |
| CBR cases | `.springdrift/memory/cbr/cases.jsonl` | Problem-solution-outcome patterns with usage stats |
| Facts | `.springdrift/memory/facts/YYYY-MM-DD-facts.jsonl` | Key-value facts with provenance and confidence |
| D' audit | `.springdrift/memory/dprime/YYYY-MM-DD-audit.jsonl` | Every gate decision with scores, features, explanations |
| Meta observer | `.springdrift/memory/meta/YYYY-MM-DD-meta.jsonl` | Post-cycle meta observations, false positive annotations |
| System logs | `.springdrift/logs/YYYY-MM-DD.jsonl` | All system events with timestamps |

**New requirement**: Add an evaluation replay tool that reads these logs and computes metrics offline. This avoids instrumenting the live system.

### Replay Tool

New module: `src/eval/replay.gleam`

```gleam
/// Load all cycle data for a date range.
pub fn load_cycles(from: String, to: String) -> List(CycleRecord)

/// Load all D' decisions for a date range.
pub fn load_dprime_decisions(from: String, to: String) -> List(DprimeRecord)

/// Load CBR usage stats evolution over time.
pub fn load_cbr_usage_timeline(from: String, to: String) -> List(CbrSnapshot)

/// Load meta-state values over time.
pub fn load_meta_state_timeline(from: String, to: String) -> List(MetaStateSnapshot)
```

Types:

```gleam
pub type CycleRecord {
  CycleRecord(
    cycle_id: String,
    timestamp: String,
    user_input: String,
    model: String,
    tools_used: List(String),
    tool_failures: Int,
    outcome: String,           // "success" | "failure" | "partial"
    tokens_in: Int,
    tokens_out: Int,
    duration_ms: Int,
    dprime_decisions: List(DprimeRecord),
    retrieved_case_ids: List(String),
    escalated: Bool,
  )
}

pub type DprimeRecord {
  DprimeRecord(
    gate: String,              // "input" | "tool" | "output" | "deterministic"
    decision: String,          // "accept" | "modify" | "reject" | "block" | "escalate"
    score: Float,
    features_fired: List(String),
    was_deterministic: Bool,
  )
}

pub type CbrSnapshot {
  CbrSnapshot(
    case_id: String,
    timestamp: String,
    retrieval_count: Int,
    retrieval_success_count: Int,
    helpful_count: Int,
    harmful_count: Int,
    utility_score: Float,
    category: String,
  )
}

pub type MetaStateSnapshot {
  MetaStateSnapshot(
    cycle_id: String,
    timestamp: String,
    uncertainty: Float,
    prediction_error: Float,
    novelty: Float,
    cycle_outcome: String,
  )
}
```

### CLI Command

```sh
gleam run -- --eval <evaluation_name> --from 2026-03-20 --to 2026-03-27
```

Runs the specified evaluation and outputs results to stdout and `.springdrift/eval/`.

---

## Evaluation 1: D' Safety Gate Accuracy

### Goal

Measure precision, recall, and F1 of the D' safety system on a standard adversarial benchmark, compared to a no-safety baseline.

### Method

**Dataset**: Combine three sources:
1. **TensorTrust prompt injection dataset** — ~1,200 labelled prompt injection attempts with ground-truth labels (injection/benign). Publicly available at [tensortrust.ai](https://tensortrust.ai).
2. **HackAPrompt dataset** — ~600 adversarial prompts from the HackAPrompt competition, labelled by attack type.
3. **Springdrift organic data** — extract all inputs from Springdrift's cycle logs that triggered D' decisions, manually label a sample of 200 as true-positive/false-positive/false-negative.

**Procedure**:
1. For each input in the dataset, run through:
   - Deterministic pre-filter only (`deterministic.check_input`)
   - Full D' input gate (deterministic + LLM scorer) using the current dprime.json config
2. Record: ground truth label, deterministic decision, full gate decision, score, features fired
3. Compute metrics separately for deterministic-only and full pipeline

**Metrics**:

| Metric | Formula | What It Shows |
|---|---|---|
| Precision | TP / (TP + FP) | Of inputs blocked, how many were actually harmful |
| Recall | TP / (TP + FN) | Of harmful inputs, how many were caught |
| F1 | 2 * P * R / (P + R) | Harmonic mean of precision and recall |
| False Positive Rate | FP / (FP + TN) | Benign inputs incorrectly blocked |
| Latency (P50, P95) | ms per evaluation | Cost of safety evaluation |
| LLM Calls Saved | deterministic blocks / total evaluations | Efficiency of the deterministic layer |

**Baselines**:
- No safety system (all inputs accepted) — recall 0%, precision undefined
- Deterministic only — expected high precision, lower recall
- LLM scorer only (no deterministic) — expected balanced but slower
- Full pipeline (deterministic + LLM) — expected best F1

**Statistical method**: Bootstrap 95% confidence intervals on all metrics (1000 resamples).

### Implementation

```gleam
/// Run safety evaluation on a labelled dataset.
pub fn eval_safety_accuracy(
  dataset: List(#(String, Bool)),  // (input, is_harmful)
  config: DeterministicConfig,
  dprime_state: DprimeState,
  provider: Provider,
  model: String,
) -> SafetyEvalResult

pub type SafetyEvalResult {
  SafetyEvalResult(
    total: Int,
    true_positives: Int,
    false_positives: Int,
    true_negatives: Int,
    false_negatives: Int,
    precision: Float,
    recall: Float,
    f1: Float,
    false_positive_rate: Float,
    avg_latency_ms: Float,
    p95_latency_ms: Float,
    deterministic_blocks: Int,
    llm_calls_saved_pct: Float,
  )
}
```

**File**: `src/eval/safety_accuracy.gleam`
**Test**: `test/eval/safety_accuracy_eval_test.gleam` (runs on synthetic mini-dataset for CI; full dataset run via CLI)

---

## Evaluation 2: CBR Self-Improvement Over Time

### Goal

Demonstrate that retrieval quality improves as usage stats accumulate, measured by retrieval precision@4 and cycle success rate.

### Method

**Dataset**: Springdrift's own operational logs from 1-2 weeks of use.

**Procedure**:
1. Load CBR usage stats timeline from JSONL logs
2. Partition cycles into 5 time bins (days 1-3, 4-6, 7-9, 10-12, 13-15)
3. For each bin, compute:
   - **Retrieval precision@4**: Of the 4 cases retrieved per query, how many had `retrieval_success_count > 0` at the time of retrieval (i.e., previously helped)?
   - **Cycle success rate**: Proportion of cycles in the bin where the outcome was "success"
   - **Average utility score**: Mean utility score of retrieved cases in the bin
   - **Case bank size**: Total cases available

**Expected result**: Retrieval precision@4 and average utility score should increase monotonically across bins as the system accumulates success/failure data.

**Baselines**:
- Random retrieval (shuffle case IDs, pick 4) — expected ~50% precision
- Cosine-only retrieval (utility_weight = 0) — the pre-enhancement baseline
- Utility-weighted retrieval (utility_weight = 0.15) — the current system

**Statistical method**: Paired t-test between bins for monotonic improvement. Spearman rank correlation between utility score and cycle success rate.

### Implementation

```gleam
pub fn eval_cbr_improvement(
  cycles: List(CycleRecord),
  cbr_snapshots: List(CbrSnapshot),
  bin_size_days: Int,
) -> CbrImprovementResult

pub type CbrImprovementResult {
  CbrImprovementResult(
    bins: List(CbrBin),
    precision_trend: List(Float),      // Precision@4 per bin
    success_rate_trend: List(Float),   // Cycle success rate per bin
    utility_score_trend: List(Float),  // Mean utility score per bin
    spearman_rho: Float,              // Correlation between utility and success
    is_monotonically_improving: Bool,  // True if each bin >= previous
  )
}

pub type CbrBin {
  CbrBin(
    label: String,
    cycle_count: Int,
    retrieval_precision: Float,
    success_rate: Float,
    avg_utility_score: Float,
    case_bank_size: Int,
  )
}
```

**File**: `src/eval/cbr_improvement.gleam`
**Test**: `test/eval/cbr_improvement_eval_test.gleam`

---

## Evaluation 3: Output Gate Quality Detection

### Goal

Measure the output gate's ability to detect genuine quality issues vs false positives on real agent output.

### Method

**Dataset**: Extract 100 agent responses from Springdrift's cycle logs:
- 50 where the output gate scored ACCEPT (score < 0.4)
- 50 where the output gate scored MODIFY or REJECT (score >= 0.4)

**Human annotation**: Manually label each response on three dimensions (0-3 scale):
- `unsourced_claim`: Does the response make factual claims without evidence?
- `certainty_overstatement`: Does the response present uncertain information as definitive?
- `accuracy`: Does the response contain verifiably false or misleading claims?

**Procedure**:
1. Compare D' output gate scores with human ratings
2. Compute correlation between D' score and human rating per dimension
3. Compute agreement on the binary ACCEPT/MODIFY threshold

**Metrics**:

| Metric | What It Shows |
|---|---|
| Pearson correlation (per dimension) | How well D' scores track human judgment |
| Cohen's kappa (binary) | Agreement on accept/flag decision |
| Precision at modify threshold | Of responses flagged, how many have real issues |
| Recall at modify threshold | Of responses with real issues, how many were flagged |

**Baselines**:
- Random scoring — expected correlation ~0, kappa ~0
- Length-based heuristic (longer = more likely to have issues) — expected weak correlation
- D' output gate — expected moderate-to-strong correlation

### Implementation

```gleam
pub type OutputQualityAnnotation {
  OutputQualityAnnotation(
    cycle_id: String,
    response_text: String,
    dprime_score: Float,
    dprime_decision: String,
    human_unsourced: Int,       // 0-3
    human_certainty: Int,       // 0-3
    human_accuracy: Int,        // 0-3
  )
}

pub fn eval_output_quality(
  annotations: List(OutputQualityAnnotation),
) -> OutputQualityResult

pub type OutputQualityResult {
  OutputQualityResult(
    n: Int,
    pearson_unsourced: Float,
    pearson_certainty: Float,
    pearson_accuracy: Float,
    cohens_kappa: Float,
    precision_at_threshold: Float,
    recall_at_threshold: Float,
  )
}
```

**File**: `src/eval/output_quality.gleam`
**Annotation file format**: JSONL in `.springdrift/eval/output_quality_annotations.jsonl`
**Note**: This evaluation requires human annotation. The tool extracts responses and D' scores; a human fills in the ratings.

---

## Evaluation 4: Confidence Decay Impact on Output Quality

### Goal

Demonstrate that time-based confidence decay reduces unsourced_claim flags by encouraging appropriate hedging for old facts.

### Method

**Procedure**:
1. Run Springdrift for 2 weeks to accumulate facts at various ages
2. Extract all cycles where the agent referenced stored facts in its response
3. For each cycle, record:
   - Ages of facts referenced
   - Effective (decayed) confidence of those facts
   - Output gate `unsourced_claim` score
   - Whether the agent used hedging language ("based on records from...", "approximately", "as of...")

**A/B comparison**: Replay the same queries through the system with:
- Decay enabled (half_life = 30 days) — the treatment
- Decay disabled (half_life = 0) — the control

**Metrics**:

| Metric | What It Shows |
|---|---|
| Correlation: fact age → hedging frequency | Does the agent hedge more for older facts? |
| Correlation: decayed confidence → output gate score | Do low-confidence facts produce higher quality flags? |
| Unsourced_claim score: decay on vs off | Does decay reduce false certainty? |
| Hedging language frequency: decay on vs off | Does the agent naturally adjust its language? |

**Statistical method**: Wilcoxon signed-rank test for paired comparisons (same queries, decay on vs off).

### Implementation

```gleam
pub type FactReferenceRecord {
  FactReferenceRecord(
    cycle_id: String,
    fact_key: String,
    fact_age_days: Int,
    original_confidence: Float,
    decayed_confidence: Float,
    output_unsourced_score: Float,
    has_hedging_language: Bool,
  )
}

pub fn eval_decay_impact(
  records_with_decay: List(FactReferenceRecord),
  records_without_decay: List(FactReferenceRecord),
) -> DecayImpactResult

pub type DecayImpactResult {
  DecayImpactResult(
    n_pairs: Int,
    age_hedging_correlation: Float,
    confidence_unsourced_correlation: Float,
    mean_unsourced_with_decay: Float,
    mean_unsourced_without_decay: Float,
    hedging_rate_with_decay: Float,
    hedging_rate_without_decay: Float,
    wilcoxon_p_value: Float,
  )
}
```

**File**: `src/eval/decay_impact.gleam`
**Note**: Hedging language detection is heuristic — regex for phrases like "based on", "approximately", "as of", "according to records", "not re-verified".

---

## Evaluation 5: Deterministic Pre-Filter Cost Savings

### Goal

Quantify the latency and token cost savings from the deterministic pre-filter layer.

### Method

**Dataset**: All D' evaluations from 2 weeks of Springdrift operation.

**Procedure**:
1. From the D' audit log, extract every gate evaluation
2. Classify each as: deterministic-blocked, deterministic-escalated, deterministic-passed (then LLM-evaluated)
3. For LLM-evaluated gates, record latency and token usage
4. Compute counterfactual: what would the cost be if every evaluation required an LLM call?

**Metrics**:

| Metric | Formula | What It Shows |
|---|---|---|
| Block rate | deterministic_blocks / total_evaluations | % of evaluations that never need an LLM |
| Escalation rate | deterministic_escalations / total_evaluations | % enriched before LLM |
| LLM calls saved | deterministic_blocks / total_evaluations | Direct cost saving |
| Latency saved (ms) | blocked * avg_llm_latency | Time saved |
| Tokens saved | blocked * avg_tokens_per_eval | Token cost saving |
| Safety accuracy delta | F1(with_deterministic) - F1(without) | Whether deterministic changes accuracy |

**Expected result**: The deterministic layer saves 20-40% of LLM calls on typical workloads (most inputs are benign and pass through, but adversarial inputs are caught early). Latency savings are proportional. Safety accuracy should be neutral or slightly improved (deterministic catches what LLM would catch, plus some that LLM might miss due to scoring noise).

### Implementation

```gleam
pub fn eval_deterministic_savings(
  decisions: List(DprimeRecord),
  avg_llm_latency_ms: Float,
  avg_tokens_per_eval: Int,
) -> DeterministicSavingsResult

pub type DeterministicSavingsResult {
  DeterministicSavingsResult(
    total_evaluations: Int,
    deterministic_blocks: Int,
    deterministic_escalations: Int,
    llm_evaluations: Int,
    block_rate: Float,
    escalation_rate: Float,
    llm_calls_saved_pct: Float,
    latency_saved_ms: Float,
    tokens_saved: Int,
  )
}
```

**File**: `src/eval/deterministic_savings.gleam`

---

## Evaluation 6: Archivist Split Quality

### Goal

Demonstrate that the two-phase Reflector/Curator pipeline produces higher-quality narrative entries and CBR cases than the single-call approach.

### Method

**Procedure**:
1. Run Springdrift for 1 week with the two-phase pipeline (treatment)
2. Collect all narrative entries and CBR cases produced
3. For a control: replay the same cycle contexts through the single-call fallback path (`generate_single_call`) and collect its output
4. Human-rate both sets on:
   - **Completeness**: Does the entry capture all important aspects of the cycle? (1-5)
   - **Accuracy**: Are the claims in the entry verifiable from the cycle context? (1-5)
   - **Usefulness**: Would retrieving this entry help a future similar task? (1-5)
   - **Category correctness**: Is the assigned CbrCategory correct? (correct/incorrect)

**Metrics**:

| Metric | What It Shows |
|---|---|
| Mean completeness (treatment vs control) | Two-phase captures more detail |
| Mean accuracy (treatment vs control) | Two-phase makes fewer false claims |
| Mean usefulness (treatment vs control) | Two-phase produces more actionable cases |
| Category accuracy | Deterministic assignment correctness |
| Fallback rate | How often Phase 1 or 2 failed, triggering fallback |

**Statistical method**: Paired Wilcoxon signed-rank test (same cycle context, two methods). 95% confidence intervals.

### Implementation

```gleam
pub type ArchivistQualityAnnotation {
  ArchivistQualityAnnotation(
    cycle_id: String,
    method: String,                // "two_phase" | "single_call"
    completeness: Int,             // 1-5
    accuracy: Int,                 // 1-5
    usefulness: Int,               // 1-5
    category_correct: Bool,
  )
}

pub fn eval_archivist_quality(
  annotations: List(ArchivistQualityAnnotation),
) -> ArchivistQualityResult

pub type ArchivistQualityResult {
  ArchivistQualityResult(
    n_pairs: Int,
    mean_completeness_two_phase: Float,
    mean_completeness_single_call: Float,
    mean_accuracy_two_phase: Float,
    mean_accuracy_single_call: Float,
    mean_usefulness_two_phase: Float,
    mean_usefulness_single_call: Float,
    category_accuracy: Float,
    fallback_rate: Float,
    wilcoxon_p_completeness: Float,
    wilcoxon_p_accuracy: Float,
    wilcoxon_p_usefulness: Float,
  )
}
```

**File**: `src/eval/archivist_quality.gleam`
**Note**: Requires human annotation. The replay tool generates paired outputs; a human rates them blind (without knowing which method produced which output).

---

## Evaluation 7: Meta-State Correlation with Task Outcomes

### Goal

Demonstrate that the three canonical meta-states (uncertainty, prediction_error, novelty) are predictive of task difficulty and outcome.

### Method

**Dataset**: All cycles from 2 weeks of operation with meta-state values and outcomes.

**Procedure**:
1. Extract meta-state values at cycle start and cycle outcome at cycle end
2. Compute correlations between each meta-state and:
   - Cycle success/failure (binary)
   - Number of tool calls needed
   - D' gate scores during the cycle
   - Whether escalation triggered
3. Compute predictive power: can meta-states at cycle start predict cycle outcome?

**Metrics**:

| Metric | What It Shows |
|---|---|
| Point-biserial correlation: uncertainty → success | High uncertainty predicts failure |
| Spearman correlation: prediction_error → tool_call_count | High error → more tool calls needed |
| Spearman correlation: novelty → cycle_duration | Novel tasks take longer |
| ROC AUC: meta-states → cycle outcome | Predictive power of meta-states as a set |
| Escalation prediction: did high meta-states predict escalation? | Meta-states identify when the cheap model isn't enough |

**Baselines**:
- Random meta-states — expected AUC ~0.5
- Single meta-state (uncertainty only) — expected AUC 0.55-0.65
- All three meta-states combined — expected AUC 0.65-0.80

**Statistical method**: Bootstrap 95% CI on correlations. Logistic regression for ROC AUC with 5-fold cross-validation.

### Implementation

```gleam
pub type MetaStateOutcomeRecord {
  MetaStateOutcomeRecord(
    cycle_id: String,
    uncertainty: Float,
    prediction_error: Float,
    novelty: Float,
    outcome_success: Bool,
    tool_call_count: Int,
    cycle_duration_ms: Int,
    dprime_max_score: Float,
    escalated: Bool,
  )
}

pub fn eval_meta_state_correlation(
  records: List(MetaStateOutcomeRecord),
) -> MetaStateCorrelationResult

pub type MetaStateCorrelationResult {
  MetaStateCorrelationResult(
    n: Int,
    correlation_uncertainty_success: Float,
    correlation_prediction_error_tool_calls: Float,
    correlation_novelty_duration: Float,
    auc_uncertainty_only: Float,
    auc_all_three: Float,
    escalation_prediction_accuracy: Float,
  )
}
```

**File**: `src/eval/meta_state_correlation.gleam`
**Note**: ROC AUC computation requires logistic regression. This can be implemented as a simple online gradient descent in Gleam, or shelled out to a Python script for the evaluation.

---

## Data Collection Timeline

| Week | Activity |
|---|---|
| 1 | Run Springdrift normally with all enhancements enabled. Collect logs. |
| 2 | Continue operation. Begin human annotation for Evaluations 3 and 6. |
| 3 | Run evaluations 1-7. Compute metrics. Identify weak points. |
| 4 | Tune thresholds and rules based on evaluation results. Re-run. |

---

## Output Format

Each evaluation produces:
- A JSON results file in `.springdrift/eval/<evaluation_name>/results.json`
- A human-readable summary printed to stdout
- Raw data in `.springdrift/eval/<evaluation_name>/data.jsonl`

Example summary:

```
=== Evaluation 1: D' Safety Gate Accuracy ===
Dataset: TensorTrust (1,200 samples) + HackAPrompt (600) + Organic (200)
Total: 2,000 samples

                    Precision  Recall  F1     FPR
Deterministic only: 0.98       0.42    0.59   0.01
LLM scorer only:    0.87       0.91    0.89   0.08
Full pipeline:      0.95       0.93    0.94   0.03

Deterministic layer saves 38% of LLM calls (760/2000)
Mean latency: 2ms (deterministic) vs 1,850ms (LLM scorer)
```

---

## New Files Required

| File | Purpose |
|---|---|
| `src/eval/replay.gleam` | Log replay and data extraction |
| `src/eval/safety_accuracy.gleam` | Evaluation 1: safety gate P/R/F1 |
| `src/eval/cbr_improvement.gleam` | Evaluation 2: CBR self-improvement over time |
| `src/eval/output_quality.gleam` | Evaluation 3: output gate vs human judgment |
| `src/eval/decay_impact.gleam` | Evaluation 4: confidence decay A/B comparison |
| `src/eval/deterministic_savings.gleam` | Evaluation 5: cost/latency savings |
| `src/eval/archivist_quality.gleam` | Evaluation 6: two-phase vs single-call quality |
| `src/eval/meta_state_correlation.gleam` | Evaluation 7: meta-state predictive power |

---

## Relationship to Existing Eval Tests

The current `test/eval/` tests (73 tests, all passing) verify component correctness with synthetic data. The evaluations described here use real operational data and produce the metrics needed for a paper or investor deck.

The existing tests remain as fast CI checks. The evaluations here are run manually via CLI after sufficient data has been collected.

---

## References

| Paper | Relevance to Evaluation |
|---|---|
| Memento (2508.16153) | CBR self-improvement evaluation method (Section 5.2: continual learning curve) |
| ACE (2510.04618) | Archivist split evaluation method (Section 5: ablation of Reflector vs monolithic) |
| System M (2603.15381) | Meta-state evaluation framing (Table C.1: epistemic signal taxonomy) |
| TensorTrust (2311.01011) | Standard prompt injection benchmark dataset |
| HackAPrompt (2311.16119) | Adversarial prompt competition dataset |
| Sloman H-CogAff | Theoretical framework for meta-management layer evaluation |
