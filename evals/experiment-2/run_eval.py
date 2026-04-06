#!/usr/bin/env python3
"""
Experiment 2: CBR vs RAG Retrieval Evaluation

Loads 800 synthetic cases and 200 queries with ground truth relevance.
Runs two retrieval systems:
  1. CBR — Springdrift's weighted multi-signal fusion (via Gleam FFI test)
  2. RAG — Ollama nomic-embed-text cosine similarity baseline

Computes P@K, MRR, nDCG@K with bootstrap 95% confidence intervals.
"""

import json
import os
import sys
import time
import requests
import numpy as np
from collections import defaultdict

RESULTS_DIR = "evals/experiment-2/results"
OLLAMA_URL = "http://localhost:11434/api/embeddings"
EMBED_MODEL = "nomic-embed-text"
K = 4  # Retrieval depth (Memento: K=4 optimal)


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_jsonl(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


# ---------------------------------------------------------------------------
# Embedding via Ollama
# ---------------------------------------------------------------------------

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
        print(f"Embedding error: {e}", file=sys.stderr)
        return None


def embed_text(case_or_query):
    """Build a text representation for embedding."""
    parts = []
    if isinstance(case_or_query, dict):
        p = case_or_query.get("problem", case_or_query)
        parts.append(p.get("intent", ""))
        parts.append(p.get("domain", ""))
        parts.extend(p.get("keywords", []))
        parts.extend(p.get("entities", []))
    return " ".join(parts)


def cosine_similarity(a, b):
    a, b = np.array(a), np.array(b)
    dot = np.dot(a, b)
    norm = np.linalg.norm(a) * np.linalg.norm(b)
    return dot / norm if norm > 0 else 0.0


# ---------------------------------------------------------------------------
# RAG retrieval — pure cosine similarity
# ---------------------------------------------------------------------------

def rag_retrieve(query_vec, case_vecs, case_ids, k):
    """Retrieve top-k cases by cosine similarity."""
    scores = []
    for cid, cvec in zip(case_ids, case_vecs):
        sim = cosine_similarity(query_vec, cvec)
        scores.append((cid, sim))
    scores.sort(key=lambda x: -x[1])
    return [cid for cid, _ in scores[:k]]


# ---------------------------------------------------------------------------
# CBR retrieval — simulate Springdrift's weighted fusion in Python
# ---------------------------------------------------------------------------

def cbr_field_score(query, case):
    """Weighted field scoring: intent match + domain match + keyword jaccard + entity jaccard."""
    qp = query
    cp = case["problem"]

    intent_match = 1.0 if qp["intent"] == cp["intent"] else 0.0
    domain_match = 1.0 if qp["domain"] == cp["domain"] else 0.0

    q_kw = set(qp["keywords"])
    c_kw = set(cp["keywords"])
    kw_jaccard = len(q_kw & c_kw) / max(len(q_kw | c_kw), 1)

    q_ent = set(qp["entities"])
    c_ent = set(cp["entities"])
    ent_jaccard = len(q_ent & c_ent) / max(len(q_ent | c_ent), 1)

    # Weighted sum (matches Springdrift bridge.gleam weighted_field_score)
    return 0.3 * intent_match + 0.3 * domain_match + 0.25 * kw_jaccard + 0.15 * ent_jaccard


def cbr_index_score(query, case, all_tokens_by_case):
    """Inverted index overlap score."""
    q_tokens = set(query["keywords"] + query["entities"] + [query["domain"], query["intent"]])
    c_tokens = all_tokens_by_case.get(case["case_id"], set())
    if not q_tokens:
        return 0.0
    return len(q_tokens & c_tokens) / len(q_tokens)


def cbr_domain_score(query, case):
    return 1.0 if query["domain"] == case["problem"]["domain"] else 0.0


def cbr_recency_score(case, all_cases):
    """Rank by timestamp (newer = higher)."""
    # Normalize: most recent = 1.0, oldest = 0.0
    timestamps = sorted(set(c["timestamp"] for c in all_cases))
    if len(timestamps) <= 1:
        return 0.5
    idx = timestamps.index(case["timestamp"]) if case["timestamp"] in timestamps else 0
    return idx / (len(timestamps) - 1)


def cbr_retrieve(query, cases, token_index, k, weights):
    """CBR retrieval with configurable weights."""
    w_field, w_index, w_recency, w_domain = weights
    scores = []
    for c in cases:
        f = cbr_field_score(query, c)
        i = cbr_index_score(query, c, token_index)
        r = cbr_recency_score(c, cases)
        d = cbr_domain_score(query, c)
        score = w_field * f + w_index * i + w_recency * r + w_domain * d
        scores.append((c["case_id"], score))
    scores.sort(key=lambda x: -x[1])
    return [cid for cid, _ in scores[:k]]


def build_token_index(cases):
    """Build inverted index tokens per case."""
    index = {}
    for c in cases:
        p = c["problem"]
        tokens = set(p["keywords"] + p["entities"] + [p["domain"], p["intent"]])
        index[c["case_id"]] = tokens
    return index


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def precision_at_k(relevant, retrieved, k):
    top_k = retrieved[:k]
    hits = sum(1 for r in top_k if r in relevant)
    return hits / k if k > 0 else 0.0


def recall_at_k(relevant, retrieved, k):
    if not relevant:
        return 0.0
    top_k = retrieved[:k]
    hits = sum(1 for r in top_k if r in relevant)
    return hits / min(len(relevant), k)


def reciprocal_rank(relevant, retrieved):
    for i, r in enumerate(retrieved):
        if r in relevant:
            return 1.0 / (i + 1)
    return 0.0


def ndcg_at_k(relevant, retrieved, k):
    """Normalized Discounted Cumulative Gain."""
    relevant_set = set(relevant)
    dcg = sum(
        (1.0 if retrieved[i] in relevant_set else 0.0) / np.log2(i + 2)
        for i in range(min(k, len(retrieved)))
    )
    # Ideal DCG: all relevant items at top
    ideal_k = min(k, len(relevant))
    idcg = sum(1.0 / np.log2(i + 2) for i in range(ideal_k))
    return dcg / idcg if idcg > 0 else 0.0


def bootstrap_ci(values, n_boot=1000, ci=0.95):
    """Bootstrap confidence interval."""
    values = np.array(values)
    n = len(values)
    if n == 0:
        return 0.0, 0.0, 0.0
    boot_means = np.array([
        np.mean(np.random.choice(values, size=n, replace=True))
        for _ in range(n_boot)
    ])
    alpha = (1 - ci) / 2
    lo = np.percentile(boot_means, 100 * alpha)
    hi = np.percentile(boot_means, 100 * (1 - alpha))
    return np.mean(values), lo, hi


# ---------------------------------------------------------------------------
# Main evaluation
# ---------------------------------------------------------------------------

def main():
    np.random.seed(42)

    cases = load_jsonl(os.path.join(RESULTS_DIR, "cases.jsonl"))
    queries = load_jsonl(os.path.join(RESULTS_DIR, "queries.jsonl"))
    print(f"Loaded {len(cases)} cases, {len(queries)} queries")

    # Build token index for CBR
    token_index = build_token_index(cases)

    # --- Phase 1: Embed all cases and queries for RAG baseline ---
    print("\nEmbedding cases for RAG baseline...")
    t0 = time.time()
    case_texts = [embed_text(c) for c in cases]
    case_vecs = []
    for i, text in enumerate(case_texts):
        vec = get_embedding(text)
        if vec is None:
            print(f"Failed to embed case {i}, using zero vector")
            vec = [0.0] * 768
        case_vecs.append(vec)
        if (i + 1) % 100 == 0:
            print(f"  Embedded {i+1}/{len(cases)} cases...")

    query_vecs = []
    for q in queries:
        text = embed_text(q)
        vec = get_embedding(text)
        if vec is None:
            vec = [0.0] * 768
        query_vecs.append(vec)
    embed_time = time.time() - t0
    print(f"Embedding complete: {embed_time:.1f}s ({len(cases)+len(queries)} texts)")

    case_ids = [c["case_id"] for c in cases]

    # --- Phase 2: Run retrieval for each system ---
    configs = {
        "rag_cosine": None,  # RAG baseline
        "cbr_full": (0.30, 0.20, 0.15, 0.15),  # Springdrift default (sans embedding/utility)
        "cbr_field_only": (1.0, 0.0, 0.0, 0.0),
        "cbr_index_only": (0.0, 1.0, 0.0, 0.0),
        "cbr_field_index_domain": (0.35, 0.30, 0.0, 0.35),
    }

    all_results = {}
    for config_name, weights in configs.items():
        print(f"\nRunning {config_name}...")
        per_query = []

        for qi, q in enumerate(queries):
            relevant = set(q["relevant_ids"])

            if config_name == "rag_cosine":
                retrieved = rag_retrieve(query_vecs[qi], case_vecs, case_ids, K)
            else:
                retrieved = cbr_retrieve(q, cases, token_index, K, weights)

            p = precision_at_k(relevant, retrieved, K)
            r = recall_at_k(relevant, retrieved, K)
            mrr = reciprocal_rank(relevant, retrieved)
            ndcg = ndcg_at_k(list(relevant), retrieved, K)

            per_query.append({
                "query_id": q["query_id"],
                "domain": q["domain"],
                "subdomain": q["subdomain"],
                "precision_at_k": p,
                "recall_at_k": r,
                "mrr": mrr,
                "ndcg_at_k": ndcg,
                "retrieved": retrieved,
            })

        # Aggregate with bootstrap CI
        p_vals = [r["precision_at_k"] for r in per_query]
        mrr_vals = [r["mrr"] for r in per_query]
        ndcg_vals = [r["ndcg_at_k"] for r in per_query]
        recall_vals = [r["recall_at_k"] for r in per_query]

        p_mean, p_lo, p_hi = bootstrap_ci(p_vals)
        mrr_mean, mrr_lo, mrr_hi = bootstrap_ci(mrr_vals)
        ndcg_mean, ndcg_lo, ndcg_hi = bootstrap_ci(ndcg_vals)
        recall_mean, recall_lo, recall_hi = bootstrap_ci(recall_vals)

        summary = {
            "config": config_name,
            "n_cases": len(cases),
            "n_queries": len(queries),
            "k": K,
            "precision_at_k": {"mean": p_mean, "ci_lo": p_lo, "ci_hi": p_hi},
            "mrr": {"mean": mrr_mean, "ci_lo": mrr_lo, "ci_hi": mrr_hi},
            "ndcg_at_k": {"mean": ndcg_mean, "ci_lo": ndcg_lo, "ci_hi": ndcg_hi},
            "recall_at_k": {"mean": recall_mean, "ci_lo": recall_lo, "ci_hi": recall_hi},
        }

        all_results[config_name] = {"summary": summary, "per_query": per_query}

        print(f"  P@{K}={p_mean:.3f} [{p_lo:.3f}, {p_hi:.3f}]  "
              f"MRR={mrr_mean:.3f} [{mrr_lo:.3f}, {mrr_hi:.3f}]  "
              f"nDCG@{K}={ndcg_mean:.3f}  "
              f"R@{K}={recall_mean:.3f}")

    # --- Phase 3: Per-domain breakdown ---
    print("\n" + "=" * 80)
    print("PER-DOMAIN BREAKDOWN")
    print("=" * 80)
    for config_name in configs:
        print(f"\n{config_name}:")
        per_query = all_results[config_name]["per_query"]
        domain_metrics = defaultdict(list)
        for r in per_query:
            domain_metrics[r["domain"]].append(r["precision_at_k"])
        for domain in sorted(domain_metrics):
            vals = domain_metrics[domain]
            mean, lo, hi = bootstrap_ci(vals)
            print(f"  {domain:<25} P@{K}={mean:.3f} [{lo:.3f}, {hi:.3f}] (n={len(vals)})")

    # --- Phase 4: Save results ---
    print("\n" + "=" * 80)
    print("SUMMARY TABLE")
    print("=" * 80)
    print(f"\n{'Config':<25} {'P@'+str(K):>12} {'MRR':>12} {'nDCG@'+str(K):>12} {'R@'+str(K):>12}")
    print("-" * 75)
    for config_name in configs:
        s = all_results[config_name]["summary"]
        p = s["precision_at_k"]
        m = s["mrr"]
        n = s["ndcg_at_k"]
        r = s["recall_at_k"]
        print(f"{config_name:<25} "
              f"{p['mean']:.3f}±{(p['ci_hi']-p['ci_lo'])/2:.3f}  "
              f"{m['mean']:.3f}±{(m['ci_hi']-m['ci_lo'])/2:.3f}  "
              f"{n['mean']:.3f}±{(n['ci_hi']-n['ci_lo'])/2:.3f}  "
              f"{r['mean']:.3f}±{(r['ci_hi']-r['ci_lo'])/2:.3f}")

    # Save full results
    output_path = os.path.join(RESULTS_DIR, "experiment2_results.json")
    with open(output_path, "w") as f:
        # Convert numpy types for JSON serialization
        def convert(obj):
            if isinstance(obj, np.floating):
                return float(obj)
            if isinstance(obj, np.integer):
                return int(obj)
            if isinstance(obj, np.ndarray):
                return obj.tolist()
            return obj

        clean = {}
        for k, v in all_results.items():
            clean[k] = {
                "summary": json.loads(json.dumps(v["summary"], default=convert)),
                "per_query": json.loads(json.dumps(v["per_query"], default=convert)),
            }
        json.dump(clean, f, indent=2, default=convert)
    print(f"\nFull results: {output_path}")

    # Save CSV summary
    csv_path = os.path.join(RESULTS_DIR, "summary.csv")
    with open(csv_path, "w") as f:
        f.write("config,n_cases,n_queries,k,p_at_k,p_at_k_ci_lo,p_at_k_ci_hi,"
                "mrr,mrr_ci_lo,mrr_ci_hi,ndcg_at_k,ndcg_ci_lo,ndcg_ci_hi,"
                "recall_at_k,recall_ci_lo,recall_ci_hi\n")
        for config_name in configs:
            s = all_results[config_name]["summary"]
            p, m, n, r = s["precision_at_k"], s["mrr"], s["ndcg_at_k"], s["recall_at_k"]
            f.write(f"{config_name},{s['n_cases']},{s['n_queries']},{s['k']},"
                    f"{p['mean']:.4f},{p['ci_lo']:.4f},{p['ci_hi']:.4f},"
                    f"{m['mean']:.4f},{m['ci_lo']:.4f},{m['ci_hi']:.4f},"
                    f"{n['mean']:.4f},{n['ci_lo']:.4f},{n['ci_hi']:.4f},"
                    f"{r['mean']:.4f},{r['ci_lo']:.4f},{r['ci_hi']:.4f}\n")
    print(f"CSV summary: {csv_path}")


if __name__ == "__main__":
    main()
