#!/usr/bin/env python3
"""
Experiment 5: CBR Learning Curve + Confidence Decay Properties

Two evaluations:

Part A — Learning Curve:
  Add cases incrementally (50, 100, 200, 400, 600, 800) and measure
  retrieval quality at each step. Demonstrates the system improves with
  scale. Uses the same dataset and embeddings as experiment 3.

Part B — Confidence Decay Properties:
  Verify the half-life decay formula: confidence_t = confidence_0 * 2^(-age/half_life).
  Show monotonic decrease, boundary correctness, configurable half-life.
"""

import json
import os
import sys
import time
import requests
import numpy as np
from collections import defaultdict

CASES_PATH = "evals/experiment-2/results/cases.jsonl"
QUERIES_PATH = "evals/experiment-2/results/queries.jsonl"
RESULTS_DIR = "evals/experiment-5/results"
OLLAMA_URL = "http://localhost:11434/api/embeddings"
EMBED_MODEL = "nomic-embed-text"
K = 4


def load_jsonl(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def get_embedding(text, cache={}):
    if text in cache:
        return cache[text]
    try:
        resp = requests.post(OLLAMA_URL, json={"model": EMBED_MODEL, "prompt": text}, timeout=30)
        resp.raise_for_status()
        vec = resp.json()["embedding"]
        cache[text] = vec
        return vec
    except Exception as e:
        return None


def embed_text(obj):
    p = obj.get("problem", obj)
    parts = [p.get("intent", ""), p.get("domain", "")]
    parts.extend(p.get("keywords", []))
    parts.extend(p.get("entities", []))
    return " ".join(parts)


def cosine_similarity(a, b):
    a, b = np.array(a), np.array(b)
    dot = np.dot(a, b)
    norm = np.linalg.norm(a) * np.linalg.norm(b)
    return dot / norm if norm > 0 else 0.0


# ---------------------------------------------------------------------------
# Retrieval (index + embedding, best config from experiment 3)
# ---------------------------------------------------------------------------

def build_token_index(cases):
    index = {}
    for c in cases:
        p = c["problem"]
        tokens = set(p["keywords"] + p["entities"] + [p["domain"], p["intent"]])
        index[c["case_id"]] = tokens
    return index


def retrieve(query, cases, token_index, case_vecs_dict, query_vec, k=4):
    """Index + embedding retrieval (experiment 3 best config: 0.30 index, 0.60 embed)."""
    w_index, w_embed = 0.30, 0.60
    q_tokens = set(query["keywords"] + query["entities"] + [query["domain"], query["intent"]])

    scores = []
    for c in cases:
        c_tokens = token_index.get(c["case_id"], set())
        idx_score = len(q_tokens & c_tokens) / max(len(q_tokens), 1)

        embed_score = 0.0
        cvec = case_vecs_dict.get(c["case_id"])
        if cvec is not None and query_vec is not None:
            embed_score = max(0.0, cosine_similarity(query_vec, cvec))

        score = w_index * idx_score + w_embed * embed_score
        scores.append((c["case_id"], score))

    scores.sort(key=lambda x: -x[1])
    return [cid for cid, _ in scores[:k]]


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def precision_at_k(relevant, retrieved, k):
    hits = sum(1 for r in retrieved[:k] if r in relevant)
    return hits / k if k > 0 else 0.0


def reciprocal_rank(relevant, retrieved):
    for i, r in enumerate(retrieved):
        if r in relevant:
            return 1.0 / (i + 1)
    return 0.0


def bootstrap_ci(values, n_boot=2000, ci=0.95):
    values = np.array(values)
    n = len(values)
    if n == 0:
        return 0.0, 0.0, 0.0
    boot_means = np.array([np.mean(np.random.choice(values, size=n, replace=True))
                           for _ in range(n_boot)])
    alpha = (1 - ci) / 2
    return float(np.mean(values)), float(np.percentile(boot_means, 100 * alpha)), float(np.percentile(boot_means, 100 * (1 - alpha)))


# ---------------------------------------------------------------------------
# Part A: Learning Curve
# ---------------------------------------------------------------------------

def run_learning_curve(cases, queries, case_vecs_dict, query_vecs):
    print("=" * 70)
    print("PART A: CBR LEARNING CURVE")
    print("=" * 70)

    # Case base sizes to test
    sizes = [25, 50, 100, 200, 400, 600, 800]
    # Ensure we don't exceed available cases
    sizes = [s for s in sizes if s <= len(cases)]

    results = []
    print(f"\n{'Size':>6} {'P@4':>10} {'95% CI':>18} {'MRR':>10} {'95% CI':>18}")
    print("-" * 65)

    for size in sizes:
        # Take first N cases (chronological order)
        subset = cases[:size]
        token_index = build_token_index(subset)
        subset_ids = set(c["case_id"] for c in subset)

        p_vals = []
        mrr_vals = []

        for qi, q in enumerate(queries):
            # Recompute relevant IDs for this subset
            relevant = set(q["relevant_ids"]) & subset_ids
            if not relevant:
                continue

            retrieved = retrieve(q, subset, token_index, case_vecs_dict,
                                query_vecs[qi], K)
            p = precision_at_k(relevant, retrieved, K)
            mrr = reciprocal_rank(relevant, retrieved)
            p_vals.append(p)
            mrr_vals.append(mrr)

        p_mean, p_lo, p_hi = bootstrap_ci(p_vals)
        mrr_mean, mrr_lo, mrr_hi = bootstrap_ci(mrr_vals)

        results.append({
            "case_base_size": size,
            "n_queries_with_relevant": len(p_vals),
            "precision_at_k": {"mean": p_mean, "ci_lo": p_lo, "ci_hi": p_hi},
            "mrr": {"mean": mrr_mean, "ci_lo": mrr_lo, "ci_hi": mrr_hi},
        })

        print(f"{size:>6} {p_mean:>10.3f} [{p_lo:.3f}, {p_hi:.3f}]  "
              f"{mrr_mean:>10.3f} [{mrr_lo:.3f}, {mrr_hi:.3f}]  "
              f"(n={len(p_vals)})")

    # Check monotonicity
    p_means = [r["precision_at_k"]["mean"] for r in results]
    is_monotonic = all(p_means[i] <= p_means[i+1] for i in range(len(p_means)-1))
    improvement = (p_means[-1] - p_means[0]) / max(p_means[0], 0.001) * 100

    print(f"\nMonotonic improvement: {'Yes' if is_monotonic else 'No'}")
    print(f"P@4 improvement from {sizes[0]} to {sizes[-1]} cases: +{improvement:.1f}%")

    # By difficulty at different sizes
    print(f"\nP@4 by difficulty at selected sizes:")
    print(f"{'Size':>6} {'Easy':>8} {'Medium':>8} {'Hard':>8}")
    print("-" * 35)
    for size in [50, 200, 800]:
        if size > len(cases):
            continue
        subset = cases[:size]
        token_index = build_token_index(subset)
        subset_ids = set(c["case_id"] for c in subset)

        by_diff = defaultdict(list)
        for qi, q in enumerate(queries):
            relevant = set(q["relevant_ids"]) & subset_ids
            if not relevant:
                continue
            retrieved = retrieve(q, subset, token_index, case_vecs_dict,
                                query_vecs[qi], K)
            p = precision_at_k(relevant, retrieved, K)
            by_diff[q["difficulty"]].append(p)

        e = np.mean(by_diff.get("easy", [0]))
        m = np.mean(by_diff.get("medium", [0]))
        h = np.mean(by_diff.get("hard", [0]))
        print(f"{size:>6} {e:>8.3f} {m:>8.3f} {h:>8.3f}")

    return results


# ---------------------------------------------------------------------------
# Part B: Confidence Decay Properties
# ---------------------------------------------------------------------------

def run_decay_eval():
    print("\n" + "=" * 70)
    print("PART B: CONFIDENCE DECAY PROPERTIES")
    print("=" * 70)

    # Half-life formula: confidence_t = confidence_0 * 2^(-age_days / half_life_days)
    def decay(confidence_0, age_days, half_life_days):
        if half_life_days <= 0:
            return confidence_0
        return confidence_0 * (2.0 ** (-age_days / half_life_days))

    results = []

    # Test 1: Monotonic decrease
    print("\n1. Monotonic decrease (half_life=30, confidence_0=0.9):")
    ages = [0, 1, 7, 14, 30, 60, 90, 180, 365]
    vals = []
    for age in ages:
        d = decay(0.9, age, 30)
        vals.append(d)
        print(f"   age={age:>3}d  confidence={d:.4f}")

    is_mono = all(vals[i] >= vals[i+1] for i in range(len(vals)-1))
    print(f"   Monotonic: {is_mono}")
    results.append({"test": "monotonic_decrease", "pass": is_mono, "values": list(zip(ages, vals))})

    # Test 2: Half-life correctness — at exactly half_life days, confidence halves
    print("\n2. Half-life correctness:")
    half_lives = [7, 14, 30, 60, 90]
    all_correct = True
    for hl in half_lives:
        c0 = 0.8
        c_at_hl = decay(c0, hl, hl)
        expected = c0 / 2
        correct = abs(c_at_hl - expected) < 0.0001
        all_correct = all_correct and correct
        print(f"   HL={hl:>2}d: c0={c0} → c({hl}d)={c_at_hl:.4f} (expected {expected:.4f}) {'✓' if correct else '✗'}")
    results.append({"test": "half_life_correctness", "pass": all_correct})

    # Test 3: Boundary conditions
    print("\n3. Boundary conditions:")
    tests = [
        ("age=0", decay(0.9, 0, 30), 0.9),
        ("confidence=0", decay(0.0, 30, 30), 0.0),
        ("confidence=1", decay(1.0, 30, 30), 0.5),
        ("very old (365d)", decay(0.9, 365, 30), None),  # Just check > 0
    ]
    boundaries_pass = True
    for name, actual, expected in tests:
        if expected is not None:
            correct = abs(actual - expected) < 0.0001
            print(f"   {name}: {actual:.6f} (expected {expected}) {'✓' if correct else '✗'}")
        else:
            correct = actual > 0 and actual < 0.001
            print(f"   {name}: {actual:.6f} (expected ≈0) {'✓' if correct else '✗'}")
        boundaries_pass = boundaries_pass and correct
    results.append({"test": "boundary_conditions", "pass": boundaries_pass})

    # Test 4: Different half-lives produce different decay rates
    print("\n4. Half-life sensitivity:")
    print(f"   {'Age':>6} {'HL=7':>8} {'HL=30':>8} {'HL=60':>8} {'HL=90':>8}")
    print("   " + "-" * 40)
    for age in [7, 30, 60]:
        vals = [decay(0.9, age, hl) for hl in [7, 30, 60, 90]]
        print(f"   {age:>4}d  " + "  ".join(f"{v:>8.4f}" for v in vals))
        # Longer half-life should mean higher confidence
        assert all(vals[i] <= vals[i+1] for i in range(len(vals)-1))
    results.append({"test": "half_life_sensitivity", "pass": True})

    # Test 5: Decay curve data for plotting
    print("\n5. Decay curves (for plotting):")
    curve_data = {}
    for hl in [7, 30, 60, 90]:
        points = [(age, decay(0.9, age, hl)) for age in range(0, 181)]
        curve_data[f"hl_{hl}"] = points
        print(f"   HL={hl}d: {len(points)} points, final={points[-1][1]:.4f}")

    all_pass = all(r["pass"] for r in results)
    print(f"\nAll decay tests pass: {all_pass}")

    return results, curve_data


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    np.random.seed(42)
    os.makedirs(RESULTS_DIR, exist_ok=True)

    cases = load_jsonl(CASES_PATH)
    queries = load_jsonl(QUERIES_PATH)
    print(f"Loaded {len(cases)} cases, {len(queries)} queries")

    # Embed everything
    print("\nEmbedding...")
    t0 = time.time()
    case_vecs_dict = {}
    for i, c in enumerate(cases):
        vec = get_embedding(embed_text(c))
        if vec is None:
            vec = [0.0] * 768
        case_vecs_dict[c["case_id"]] = vec
        if (i + 1) % 200 == 0:
            print(f"  {i+1}/{len(cases)}...")

    query_vecs = []
    for q in queries:
        vec = get_embedding(embed_text(q))
        if vec is None:
            vec = [0.0] * 768
        query_vecs.append(vec)
    print(f"Embedding done: {time.time()-t0:.1f}s")

    # Part A: Learning Curve
    lc_results = run_learning_curve(cases, queries, case_vecs_dict, query_vecs)

    # Part B: Confidence Decay
    decay_results, curve_data = run_decay_eval()

    # Save results
    output = {
        "learning_curve": lc_results,
        "decay_tests": decay_results,
        "decay_curves": {k: [(a, round(v, 6)) for a, v in pts]
                         for k, pts in curve_data.items()},
    }

    def convert(obj):
        if isinstance(obj, (np.floating, np.float64)):
            return float(obj)
        if isinstance(obj, (np.integer, np.int64)):
            return int(obj)
        if isinstance(obj, np.ndarray):
            return obj.tolist()
        return obj

    output_path = os.path.join(RESULTS_DIR, "experiment5_results.json")
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2, default=convert)

    # CSV for learning curve
    csv_path = os.path.join(RESULTS_DIR, "learning_curve.csv")
    with open(csv_path, "w") as f:
        f.write("case_base_size,n_queries,p_at_4,p_ci_lo,p_ci_hi,mrr,mrr_ci_lo,mrr_ci_hi\n")
        for r in lc_results:
            p, m = r["precision_at_k"], r["mrr"]
            f.write(f"{r['case_base_size']},{r['n_queries_with_relevant']},"
                    f"{p['mean']:.4f},{p['ci_lo']:.4f},{p['ci_hi']:.4f},"
                    f"{m['mean']:.4f},{m['ci_lo']:.4f},{m['ci_hi']:.4f}\n")

    print(f"\nResults: {output_path}")
    print(f"Learning curve CSV: {csv_path}")


if __name__ == "__main__":
    main()
