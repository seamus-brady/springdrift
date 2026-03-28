# Experiment 1 — Review

**Status:** Completed, not paper-ready. Methodology demonstration only.

## What's strong

The normative calculus eval is genuinely strong. Exhaustive verification over
the full input space (7,056 pairs) with zero violations is a mathematical
proof, not a sample. The axiom firing distribution and severity breakdown are
independently verifiable. This stands on its own.

## What's weak (CBR)

- **40 synthetic cases is toy-scale.** CBR papers typically evaluate on
  hundreds to thousands of cases. Memento uses 1000+. 40 is a unit test.
- **6 queries is not a sample size.** Can't compute confidence intervals on
  6 data points. Need 50+ minimum.
- **MRR = 1.0 everywhere is a red flag.** Means the dataset is too easy.
  A discriminative eval should have queries where configurations differ at
  rank 1.
- **Relevance judgments are hand-picked for hand-crafted cases.** Circular.
- **No external baseline.** No RAG comparison, no standard CBR system, no
  random retrieval with bootstrap CI.
- **"Index beats fusion" undermines the thesis.** The paper argues multi-signal
  fusion is better, but the data shows index-only (0.667) outperforms the
  full system (0.542). Honest explanation exists (recency/utility dilute when
  uninformative) but a reviewer will see "your system is worse than its
  component."

## What experiment-2 needs

1. Scale: 200+ cases per domain (800+ total)
2. Queries: 50+ per domain with varying difficulty
3. RAG baseline: embed + cosine, same P@K/MRR metrics
4. Utility signal: simulate usage stats, show learning curve
5. Statistical significance: bootstrap 95% CI on all metrics
