#!/usr/bin/env python3
"""
Experiment 3: CBR with Embeddings vs RAG

Uses the same dataset as experiment-2 but adds embedding-aware CBR configs.
This is the fair comparison — CBR as Springdrift actually runs it, with
Ollama embeddings as a retrieval signal alongside deterministic signals.

Configurations:
  - rag_cosine: pure embedding cosine similarity (baseline)
  - cbr_no_embed: deterministic signals only (experiment-2 full_weighted)
  - cbr_with_embed: Springdrift default weights including embedding signal
  - cbr_embed_heavy: high embedding weight (ablation)
  - cbr_index_embed: index + embedding only (best deterministic + best semantic)
  - random: random retrieval (lower bound)
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
RESULTS_DIR = "evals/experiment-3/results"
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
        print(f"Embedding error: {e}", file=sys.stderr)
        return None


def embed_text(obj):
    parts = []
    p = obj.get("problem", obj)
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
# Retrieval systems
# ---------------------------------------------------------------------------

def rag_retrieve(query_vec, case_vecs, case_ids, k):
    scores = [(cid, cosine_similarity(query_vec, cvec))
              for cid, cvec in zip(case_ids, case_vecs)]
    scores.sort(key=lambda x: -x[1])
    return [cid for cid, _ in scores[:k]]


def random_retrieve(case_ids, k):
    return list(np.random.choice(case_ids, size=min(k, len(case_ids)), replace=False))


def cbr_field_score(query, case):
    qp, cp = query, case["problem"]
    intent_match = 1.0 if qp["intent"] == cp["intent"] else 0.0
    domain_match = 1.0 if qp["domain"] == cp["domain"] else 0.0
    q_kw, c_kw = set(qp["keywords"]), set(cp["keywords"])
    kw_j = len(q_kw & c_kw) / max(len(q_kw | c_kw), 1)
    q_ent, c_ent = set(qp["entities"]), set(cp["entities"])
    ent_j = len(q_ent & c_ent) / max(len(q_ent | c_ent), 1)
    return 0.3 * intent_match + 0.3 * domain_match + 0.25 * kw_j + 0.15 * ent_j


def cbr_index_score(query, case, token_index):
    q_tokens = set(query["keywords"] + query["entities"] + [query["domain"], query["intent"]])
    c_tokens = token_index.get(case["case_id"], set())
    return len(q_tokens & c_tokens) / max(len(q_tokens), 1)


def cbr_domain_score(query, case):
    return 1.0 if query["domain"] == case["problem"]["domain"] else 0.0


def cbr_recency_score(case, timestamp_ranks):
    return timestamp_ranks.get(case["timestamp"], 0.5)


def cbr_retrieve(query, cases, token_index, ts_ranks, k, weights,
                 query_vec=None, case_vecs_dict=None):
    """5-signal CBR retrieval: field, index, recency, domain, embedding."""
    w_f, w_i, w_r, w_d, w_e = weights
    scores = []
    for c in cases:
        f = cbr_field_score(query, c)
        i = cbr_index_score(query, c, token_index)
        r = cbr_recency_score(c, ts_ranks)
        d = cbr_domain_score(query, c)
        e = 0.0
        if w_e > 0 and query_vec is not None and case_vecs_dict is not None:
            cvec = case_vecs_dict.get(c["case_id"])
            if cvec is not None:
                e = max(0.0, cosine_similarity(query_vec, cvec))
        score = w_f * f + w_i * i + w_r * r + w_d * d + w_e * e
        scores.append((c["case_id"], score))
    scores.sort(key=lambda x: -x[1])
    return [cid for cid, _ in scores[:k]]


def build_token_index(cases):
    index = {}
    for c in cases:
        p = c["problem"]
        tokens = set(p["keywords"] + p["entities"] + [p["domain"], p["intent"]])
        index[c["case_id"]] = tokens
    return index


def build_timestamp_ranks(cases):
    timestamps = sorted(set(c["timestamp"] for c in cases))
    if len(timestamps) <= 1:
        return {ts: 0.5 for ts in timestamps}
    return {ts: i / (len(timestamps) - 1) for i, ts in enumerate(timestamps)}


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def precision_at_k(relevant, retrieved, k):
    hits = sum(1 for r in retrieved[:k] if r in relevant)
    return hits / k if k > 0 else 0.0


def recall_at_k(relevant, retrieved, k):
    if not relevant:
        return 0.0
    hits = sum(1 for r in retrieved[:k] if r in relevant)
    return hits / min(len(relevant), k)


def reciprocal_rank(relevant, retrieved):
    for i, r in enumerate(retrieved):
        if r in relevant:
            return 1.0 / (i + 1)
    return 0.0


def ndcg_at_k(relevant, retrieved, k):
    relevant_set = set(relevant)
    dcg = sum((1.0 if retrieved[i] in relevant_set else 0.0) / np.log2(i + 2)
              for i in range(min(k, len(retrieved))))
    idcg = sum(1.0 / np.log2(i + 2) for i in range(min(k, len(relevant))))
    return dcg / idcg if idcg > 0 else 0.0


def bootstrap_ci(values, n_boot=2000, ci=0.95):
    values = np.array(values)
    n = len(values)
    if n == 0:
        return 0.0, 0.0, 0.0
    boot_means = np.array([np.mean(np.random.choice(values, size=n, replace=True))
                           for _ in range(n_boot)])
    alpha = (1 - ci) / 2
    return np.mean(values), np.percentile(boot_means, 100 * alpha), np.percentile(boot_means, 100 * (1 - alpha))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    np.random.seed(42)
    os.makedirs(RESULTS_DIR, exist_ok=True)

    cases = load_jsonl(CASES_PATH)
    queries = load_jsonl(QUERIES_PATH)
    print(f"Loaded {len(cases)} cases, {len(queries)} queries")

    token_index = build_token_index(cases)
    ts_ranks = build_timestamp_ranks(cases)
    case_ids = [c["case_id"] for c in cases]

    # Embed everything
    print("\nEmbedding...")
    t0 = time.time()
    case_vecs = []
    case_vecs_dict = {}
    for i, c in enumerate(cases):
        vec = get_embedding(embed_text(c))
        if vec is None:
            vec = [0.0] * 768
        case_vecs.append(vec)
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

    # Configurations: (name, type, weights_or_none)
    # Weights: (field, index, recency, domain, embedding)
    configs = [
        ("random",              "random",  None),
        ("rag_cosine",          "rag",     None),
        ("cbr_no_embed",        "cbr",     (0.30, 0.20, 0.15, 0.15, 0.0)),     # No embedding
        ("cbr_with_embed",      "cbr",     (0.25, 0.15, 0.10, 0.15, 0.25)),    # Balanced with embed
        ("cbr_embed_heavy",     "cbr",     (0.10, 0.10, 0.05, 0.10, 0.55)),    # Embedding dominant
        ("cbr_index_embed",     "cbr",     (0.00, 0.30, 0.00, 0.00, 0.60)),    # Best deterministic + semantic
        ("cbr_springdrift",     "cbr",     (0.30, 0.20, 0.15, 0.15, 0.10)),    # Springdrift actual defaults
    ]

    all_results = {}
    for config_name, ctype, weights in configs:
        print(f"\n{config_name}...")
        per_query = []

        for qi, q in enumerate(queries):
            relevant = set(q["relevant_ids"])

            if ctype == "random":
                retrieved = random_retrieve(case_ids, K)
            elif ctype == "rag":
                retrieved = rag_retrieve(query_vecs[qi], case_vecs, case_ids, K)
            else:
                retrieved = cbr_retrieve(q, cases, token_index, ts_ranks, K, weights,
                                         query_vec=query_vecs[qi], case_vecs_dict=case_vecs_dict)

            per_query.append({
                "query_id": q["query_id"],
                "domain": q["domain"],
                "subdomain": q["subdomain"],
                "difficulty": q["difficulty"],
                "precision_at_k": precision_at_k(relevant, retrieved, K),
                "recall_at_k": recall_at_k(relevant, retrieved, K),
                "mrr": reciprocal_rank(relevant, retrieved),
                "ndcg_at_k": ndcg_at_k(list(relevant), retrieved, K),
                "retrieved": retrieved,
            })

        # Aggregate
        metrics = {}
        for m in ["precision_at_k", "mrr", "ndcg_at_k", "recall_at_k"]:
            vals = [r[m] for r in per_query]
            mean, lo, hi = bootstrap_ci(vals)
            metrics[m] = {"mean": float(mean), "ci_lo": float(lo), "ci_hi": float(hi)}

        all_results[config_name] = {"summary": {**metrics, "config": config_name,
                                                 "n_cases": len(cases), "n_queries": len(queries), "k": K},
                                     "per_query": per_query}

        p = metrics["precision_at_k"]
        m = metrics["mrr"]
        print(f"  P@{K}={p['mean']:.3f} [{p['ci_lo']:.3f},{p['ci_hi']:.3f}]  "
              f"MRR={m['mean']:.3f} [{m['ci_lo']:.3f},{m['ci_hi']:.3f}]")

    # Difficulty breakdown
    print("\n" + "=" * 80)
    print(f"{'Config':<25} {'Easy':>8} {'Medium':>8} {'Hard':>8} {'Overall':>8}")
    print("-" * 60)
    for config_name, _, _ in configs:
        pq = all_results[config_name]["per_query"]
        by_diff = defaultdict(list)
        for r in pq:
            by_diff[r["difficulty"]].append(r["precision_at_k"])
        overall = all_results[config_name]["summary"]["precision_at_k"]["mean"]
        e = np.mean(by_diff.get("easy", [0]))
        m = np.mean(by_diff.get("medium", [0]))
        h = np.mean(by_diff.get("hard", [0]))
        print(f"{config_name:<25} {e:>8.3f} {m:>8.3f} {h:>8.3f} {overall:>8.3f}")

    # Summary table
    print("\n" + "=" * 80)
    print("SUMMARY")
    print("=" * 80)
    print(f"\n{'Config':<25} {'P@4':>14} {'MRR':>14} {'nDCG@4':>14}")
    print("-" * 70)
    for config_name, _, _ in configs:
        s = all_results[config_name]["summary"]
        p, m, n = s["precision_at_k"], s["mrr"], s["ndcg_at_k"]
        print(f"{config_name:<25} "
              f"{p['mean']:.3f}[{p['ci_lo']:.3f},{p['ci_hi']:.3f}]  "
              f"{m['mean']:.3f}[{m['ci_lo']:.3f},{m['ci_hi']:.3f}]  "
              f"{n['mean']:.3f}[{n['ci_lo']:.3f},{n['ci_hi']:.3f}]")

    # Save
    output_path = os.path.join(RESULTS_DIR, "experiment3_results.json")
    def convert(obj):
        if isinstance(obj, (np.floating, np.float64)):
            return float(obj)
        if isinstance(obj, (np.integer, np.int64)):
            return int(obj)
        if isinstance(obj, np.ndarray):
            return obj.tolist()
        return obj

    with open(output_path, "w") as f:
        json.dump(all_results, f, indent=2, default=convert)

    csv_path = os.path.join(RESULTS_DIR, "summary.csv")
    with open(csv_path, "w") as f:
        f.write("config,p_at_k,p_ci_lo,p_ci_hi,mrr,mrr_ci_lo,mrr_ci_hi,ndcg,ndcg_ci_lo,ndcg_ci_hi\n")
        for config_name, _, _ in configs:
            s = all_results[config_name]["summary"]
            p, m, n = s["precision_at_k"], s["mrr"], s["ndcg_at_k"]
            f.write(f"{config_name},{p['mean']:.4f},{p['ci_lo']:.4f},{p['ci_hi']:.4f},"
                    f"{m['mean']:.4f},{m['ci_lo']:.4f},{m['ci_hi']:.4f},"
                    f"{n['mean']:.4f},{n['ci_lo']:.4f},{n['ci_hi']:.4f}\n")

    print(f"\nResults: {output_path}")
    print(f"CSV: {csv_path}")


if __name__ == "__main__":
    main()
