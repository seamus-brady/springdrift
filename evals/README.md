# Springdrift Empirical Evaluations

## Experiments

### Experiment 1 (Preliminary)

Initial methodology demonstration. Small synthetic dataset (40 cases, 6 queries).
Normative calculus exhaustive completeness (7,056 pairs). Results too easy for
paper-quality metrics. See [experiment-1/REVIEW.md](experiment-1/REVIEW.md).

### Experiment 2: CBR vs RAG (Deterministic Signals Only)

800 cases, 200 queries at 3 difficulty levels. RAG baseline using Ollama
nomic-embed-text. Bootstrap 95% CIs.

**Key finding:** RAG outperforms deterministic-only CBR on ambiguous queries
(P@4=0.920 vs 0.620). CBR token overlap matches RAG on easy queries
(P@4=0.994 vs 0.988). See [experiment-2/REPORT.md](experiment-2/REPORT.md).

### Experiment 3: CBR with Embeddings vs RAG

Same dataset as experiment 2, but adds embedding-aware CBR configurations —
the fair comparison (CBR as Springdrift actually runs it).

**Key finding:** Hybrid CBR (index + embedding) outperforms pure RAG
(P@4=0.956 vs 0.920, non-overlapping 95% CIs). Best at every difficulty level.

| System | Easy | Medium | Hard | Overall P@4 | 95% CI |
|---|---|---|---|---|---|
| Random | 0.044 | 0.021 | 0.013 | 0.028 | [0.018, 0.040] |
| CBR no embedding | 0.872 | 0.588 | 0.317 | 0.620 | [0.575, 0.665] |
| RAG cosine | 0.988 | 0.954 | 0.796 | 0.920 | [0.895, 0.943] |
| **CBR index+embed** | **1.000** | **0.971** | **0.883** | **0.956** | **[0.936, 0.974]** |

Default retrieval weights tuned from these results. See
[experiment-3/REPORT.md](experiment-3/REPORT.md).

### Experiment 4: Deterministic Pre-Filter (D' Safety)

64-sample adversarial corpus: 23 known injections (direct, roleplay, boundary,
multi-step, indirect), 11 evasion variants (unicode confusables, whitespace,
zero-width chars, synonyms), 5 payload signatures (base64, XML, code fences),
25 adversarial-adjacent benign inputs.

**Key finding:** Precision 1.000, Recall 0.795, F1 0.886, FPR 0.000.

| Metric | Value |
|---|---|
| Precision | 1.000 |
| Recall | 0.795 |
| F1 | 0.886 |
| FPR | 0.000 |
| Accuracy | 0.875 |

Zero false positives on benign inputs that share vocabulary with injection
patterns ("ignore the error", "bypass the cache", "override the config",
"act as a reviewer"). Enhanced structural detector uses three layers:
normalisation (unicode confusables, whitespace collapse), weighted structural
scoring (boundary markers + imperative verbs + system targets + role-play
patterns), and payload signatures (base64, XML injection, code fences).

Remaining gaps: zero-width unicode (Python handling issue), multilingual
injections, some synonym substitutions. These are documented as known
limitations — the deterministic layer is a first line, not a complete defence.
Canary probes handle what deterministic rules miss.

### Experiment 5: Learning Curve + Confidence Decay

**Part A — Learning Curve:** Same dataset/embeddings as experiment 3.
Cases added incrementally (25 → 800), P@4 measured at each step.

| Case Base Size | P@4 | 95% CI | Queries |
|---|---|---|---|
| 25 | 0.864 | [0.727, 0.977] | 11 |
| 50 | 0.850 | [0.750, 0.950] | 20 |
| 100 | 0.891 | [0.820, 0.953] | 32 |
| 200 | 0.935 | [0.885, 0.975] | 50 |
| 400 | 0.948 | [0.920, 0.973] | 100 |
| 800 | 0.956 | [0.935, 0.974] | 200 |

+10.7% P@4 from 25 to 800 cases. Hard queries improve most: 0.750 → 0.883.
The system gets measurably better with scale.

**Part B — Confidence Decay Properties:** Mathematical verification of the
half-life formula. All 5 property tests pass: monotonic decrease, half-life
correctness (exact at all tested values), boundary conditions, sensitivity
to half-life parameter, curve data for 4 half-life values (181 points each).

### Normative Calculus Completeness (Experiment 1)

Exhaustive verification: 84 NPs × 84 NPs = 7,056 pairs. 100% coverage,
zero monotonicity violations, zero determinism violations, 8/8 rules fired,
8/8 floor rules correct, 2/2 priority tests passed. Mathematical proof,
not a statistical sample.

## Running

```bash
# Experiment 2: CBR vs RAG (deterministic only)
python3 evals/experiment-2/generate_cases_v2.py
python3 evals/experiment-2/run_eval.py

# Experiment 3: CBR with embeddings vs RAG
python3 evals/experiment-3/run_eval.py

# Experiment 4: Deterministic pre-filter
python3 evals/experiment-4/run_eval.py

# Experiment 5: Learning curve + decay
python3 evals/experiment-5/run_eval.py

# Normative calculus + CBR structured (Gleam)
gleam test
```

## Requirements

- Python 3.10+
- numpy, scipy, requests (`pip3 install numpy scipy requests`)
- Ollama running locally with nomic-embed-text model
- Gleam 1.9+ (for normative calculus and CBR Gleam harness evals)
