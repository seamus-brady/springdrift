#!/usr/bin/env python3
"""
Experiment 2v2: Generate harder synthetic CBR case base.

Key changes from v1:
- Shared vocabulary across subdomains (realistic overlap)
- Three query difficulty levels: Easy, Medium, Hard
- Cross-domain noise terms
- More varied keyword selection
"""

import json
import random
import os

random.seed(42)

OUTPUT_DIR = "evals/experiment-2/results"

# ---------------------------------------------------------------------------
# Shared vocabulary pools — terms that appear across multiple subdomains
# ---------------------------------------------------------------------------

SHARED_TERMS = {
    "analysis": ["trend", "forecast", "comparison", "benchmark", "quarterly", "annual"],
    "risk": ["risk", "volatility", "exposure", "hedging", "downside", "stress_test"],
    "compliance": ["compliance", "regulation", "reporting", "audit", "standards"],
    "data": ["data", "metrics", "dashboard", "tracking", "historical", "time_series"],
    "market": ["market", "supply", "demand", "pricing", "competitive", "growth"],
}

DOMAINS = {
    "property_market": {
        "subdomains": {
            "residential_rent": {
                "core_kw": ["rent", "residential", "tenant", "lease"],
                "specific_kw": ["apartment", "studio", "furnished", "unfurnished", "letting"],
                "entities": ["Dublin", "London", "Berlin", "Amsterdam", "Barcelona", "Paris", "Vienna"],
                "shared_pools": ["analysis", "market", "data"],
            },
            "house_prices": {
                "core_kw": ["house_prices", "index", "valuation", "mortgage"],
                "specific_kw": ["sales", "asking_price", "closing_price", "stamp_duty", "first_time_buyer"],
                "entities": ["CSO", "Land Registry", "Zillow", "Rightmove", "ESRI", "Daft.ie"],
                "shared_pools": ["analysis", "market", "data"],
            },
            "commercial": {
                "core_kw": ["commercial", "office", "vacancy", "grade_a"],
                "specific_kw": ["coworking", "fitout", "break_clause", "service_charge", "prime_location"],
                "entities": ["CBRE", "JLL", "CoStar", "Savills", "Cushman", "Knight Frank"],
                "shared_pools": ["market", "analysis", "risk"],
            },
            "development": {
                "core_kw": ["planning", "zoning", "construction", "permits"],
                "specific_kw": ["new_builds", "sdz", "land_bank", "brownfield", "density"],
                "entities": ["An Bord Pleanala", "Planning Authority", "RIAI", "CIF", "SCSI"],
                "shared_pools": ["compliance", "data"],
            },
            "investment": {
                "core_kw": ["yield", "reit", "investment", "cap_rate"],
                "specific_kw": ["portfolio", "leverage", "noi", "irr", "exit_strategy"],
                "entities": ["IRES", "Hibernia", "Green REIT", "Hines", "Kennedy Wilson", "Greystar"],
                "shared_pools": ["risk", "analysis", "market"],
            },
        },
        "intents": ["research", "analysis", "report", "monitoring", "comparison"],
    },
    "financial_analysis": {
        "subdomains": {
            "equity": {
                "core_kw": ["equity", "stock", "earnings", "pe_ratio"],
                "specific_kw": ["dividend", "buyback", "eps", "guidance", "sector_rotation"],
                "entities": ["AAPL", "MSFT", "NASDAQ", "NYSE", "S&P500", "Tesla"],
                "shared_pools": ["analysis", "risk", "market"],
            },
            "fixed_income": {
                "core_kw": ["bonds", "yield_curve", "treasury", "spread"],
                "specific_kw": ["duration", "convexity", "coupon", "maturity", "issuance"],
                "entities": ["US Treasury", "Fed", "ECB", "Bloomberg", "Moody's", "Fitch"],
                "shared_pools": ["risk", "analysis", "data"],
            },
            "crypto": {
                "core_kw": ["crypto", "bitcoin", "defi", "tvl"],
                "specific_kw": ["staking", "liquidity", "nft", "layer2", "bridge"],
                "entities": ["BTC", "ETH", "SEC", "Binance", "Coinbase", "Uniswap"],
                "shared_pools": ["risk", "compliance", "market"],
            },
            "macro": {
                "core_kw": ["gdp", "inflation", "employment", "central_bank"],
                "specific_kw": ["rates", "monetary_policy", "fiscal", "trade_balance", "pmi"],
                "entities": ["IMF", "World Bank", "BLS", "Eurostat", "OECD", "Fed"],
                "shared_pools": ["analysis", "data", "market"],
            },
            "commodities": {
                "core_kw": ["oil", "gold", "futures", "supply"],
                "specific_kw": ["opec", "contango", "backwardation", "spot_price", "inventories"],
                "entities": ["WTI", "Brent", "COMEX", "OPEC", "LME", "ICE"],
                "shared_pools": ["market", "risk", "analysis"],
            },
        },
        "intents": ["analysis", "research", "report", "forecast", "comparison"],
    },
    "legal_research": {
        "subdomains": {
            "contract": {
                "core_kw": ["contract", "breach", "termination", "damages"],
                "specific_kw": ["force_majeure", "indemnity", "warranty", "limitation_of_liability"],
                "entities": ["High Court", "Commercial Court", "Supreme Court", "Circuit Court"],
                "shared_pools": ["compliance", "risk"],
            },
            "tort": {
                "core_kw": ["tort", "negligence", "duty_of_care", "product_liability"],
                "specific_kw": ["causation", "foreseeability", "contributory", "vicarious", "nuisance"],
                "entities": ["Supreme Court", "Court of Appeal", "CJEU", "ECHR"],
                "shared_pools": ["risk", "compliance"],
            },
            "ip": {
                "core_kw": ["patent", "trademark", "copyright", "infringement"],
                "specific_kw": ["fair_use", "licensing", "prior_art", "distinctiveness", "trade_secret"],
                "entities": ["EPO", "WIPO", "EUIPO", "CJEU", "USPTO", "UKIPO"],
                "shared_pools": ["compliance", "market"],
            },
            "regulatory": {
                "core_kw": ["gdpr", "data_protection", "sanctions", "aml"],
                "specific_kw": ["dpia", "consent", "right_to_erasure", "breach_notification", "processing"],
                "entities": ["DPC", "EDPB", "FCA", "SEC", "CBI", "ICO"],
                "shared_pools": ["compliance", "risk", "data"],
            },
            "employment": {
                "core_kw": ["employment", "unfair_dismissal", "redundancy", "discrimination"],
                "specific_kw": ["wrc", "transfer_of_undertakings", "whistleblower", "protected_disclosure"],
                "entities": ["WRC", "Labour Court", "EAT", "EHRC", "Workplace Relations"],
                "shared_pools": ["compliance", "risk"],
            },
        },
        "intents": ["research", "analysis", "review", "advisory", "comparison"],
    },
    "technical_ops": {
        "subdomains": {
            "deployment": {
                "core_kw": ["deployment", "docker", "kubernetes", "ci_cd"],
                "specific_kw": ["rollback", "canary", "blue_green", "helm", "manifest"],
                "entities": ["AWS", "GKE", "ECS", "ArgoCD", "GitHub Actions", "Jenkins"],
                "shared_pools": ["data", "compliance"],
            },
            "monitoring": {
                "core_kw": ["monitoring", "latency", "errors", "alerting"],
                "specific_kw": ["dashboards", "slo", "sli", "apdex", "percentile"],
                "entities": ["Grafana", "Prometheus", "Datadog", "PagerDuty", "Sentry", "New Relic"],
                "shared_pools": ["data", "analysis"],
            },
            "incident": {
                "core_kw": ["incident", "outage", "postmortem", "root_cause"],
                "specific_kw": ["recovery", "rto", "rpo", "escalation", "war_room"],
                "entities": ["Jira", "Confluence", "Statuspage", "OpsGenie", "Slack"],
                "shared_pools": ["risk", "compliance"],
            },
            "database": {
                "core_kw": ["database", "migration", "replication", "backup"],
                "specific_kw": ["connection_pool", "sharding", "indexing", "vacuum", "wal"],
                "entities": ["PostgreSQL", "RDS", "MongoDB", "Redis", "ElasticSearch", "DynamoDB"],
                "shared_pools": ["data", "risk"],
            },
            "security": {
                "core_kw": ["security", "vulnerability", "cve", "patching"],
                "specific_kw": ["access_control", "penetration_test", "encryption", "zero_trust", "soc2"],
                "entities": ["Snyk", "Dependabot", "Vault", "IAM", "WAF", "CrowdStrike"],
                "shared_pools": ["compliance", "risk"],
            },
        },
        "intents": ["troubleshooting", "analysis", "research", "report", "comparison"],
    },
}

OUTCOMES = [("success", 0.55), ("partial", 0.30), ("failure", 0.10), ("in_progress", 0.05)]


def pick_outcome():
    r = random.random()
    cumulative = 0
    for status, prob in OUTCOMES:
        cumulative += prob
        if r <= cumulative:
            conf = random.uniform(0.4, 0.95) if status == "success" else random.uniform(0.2, 0.6)
            return status, round(conf, 2)
    return "success", 0.8


def pick_keywords(subconfig, domain_config):
    """Pick keywords with shared vocabulary noise."""
    # 2-3 core keywords (always from this subdomain)
    n_core = random.randint(2, min(3, len(subconfig["core_kw"])))
    kws = random.sample(subconfig["core_kw"], n_core)

    # 0-2 specific keywords
    n_specific = random.randint(0, min(2, len(subconfig["specific_kw"])))
    kws += random.sample(subconfig["specific_kw"], n_specific)

    # 1-2 shared pool keywords (creates cross-subdomain overlap)
    for pool_name in random.sample(subconfig["shared_pools"], min(random.randint(1, 2), len(subconfig["shared_pools"]))):
        pool = SHARED_TERMS[pool_name]
        kws.append(random.choice(pool))

    return kws


def generate_case(case_id, domain, subdomain, subconfig, domain_config, day):
    keywords = pick_keywords(subconfig, domain_config)
    entities = random.sample(subconfig["entities"], min(random.randint(1, 3), len(subconfig["entities"])))
    intent = random.choice(domain_config["intents"])
    outcome_status, confidence = pick_outcome()
    timestamp = f"2026-03-{day:02d}T{random.randint(8,20):02d}:{random.randint(0,59):02d}:00Z"

    return {
        "case_id": case_id,
        "timestamp": timestamp,
        "schema_version": 2,
        "problem": {
            "user_input": f"{intent} {domain} {subdomain} {' '.join(keywords[:3])}",
            "intent": intent,
            "domain": domain,
            "entities": entities,
            "keywords": keywords,
            "query_complexity": random.choice(["simple", "complex"]),
        },
        "solution": {
            "approach": f"{intent} via web tools",
            "tools_used": ["web_search", "fetch_url"] if random.random() > 0.3 else ["web_search"],
            "agents_used": ["researcher"] if random.random() > 0.3 else ["researcher", "coder"],
            "steps": [],
        },
        "outcome": {
            "status": outcome_status,
            "confidence": confidence,
            "assessment": "synthetic",
            "pitfalls": [],
        },
        "source_narrative_id": case_id,
        "profile": None,
        "redacted": False,
        "category": None,
        "usage_stats": None,
    }


def generate_queries(cases, n_per_subdomain=10):
    """Generate queries at three difficulty levels."""
    queries = []
    qnum = 0

    for domain, domain_config in DOMAINS.items():
        for subdomain, subconfig in domain_config["subdomains"].items():
            subdomain_cases = [c for c in cases
                               if c["problem"]["domain"] == domain
                               and subdomain in c["case_id"]]

            for i in range(n_per_subdomain):
                qid = f"q-{qnum:04d}"

                if i < 4:
                    # EASY: use core keywords only (strong signal)
                    difficulty = "easy"
                    kws = random.sample(subconfig["core_kw"], min(3, len(subconfig["core_kw"])))
                    ents = random.sample(subconfig["entities"], 1)
                elif i < 7:
                    # MEDIUM: mix of core + shared pool (ambiguous)
                    difficulty = "medium"
                    kws = random.sample(subconfig["core_kw"], min(2, len(subconfig["core_kw"])))
                    pool = random.choice(subconfig["shared_pools"])
                    kws += random.sample(SHARED_TERMS[pool], min(2, len(SHARED_TERMS[pool])))
                    ents = random.sample(subconfig["entities"], 1)
                else:
                    # HARD: mostly shared vocabulary, minimal core signal
                    difficulty = "hard"
                    kws = [random.choice(subconfig["core_kw"])]
                    for pool_name in random.sample(subconfig["shared_pools"],
                                                    min(2, len(subconfig["shared_pools"]))):
                        kws += random.sample(SHARED_TERMS[pool_name], 2)
                    ents = []

                intent = random.choice(domain_config["intents"])

                # Compute ground truth: same domain + keyword overlap >= 2
                q_kw_set = set(kws)
                relevant = []
                for c in cases:
                    if c["problem"]["domain"] == domain:
                        c_kw_set = set(c["problem"]["keywords"])
                        overlap = len(q_kw_set & c_kw_set)
                        if overlap >= 2:
                            relevant.append(c["case_id"])

                queries.append({
                    "query_id": qid,
                    "domain": domain,
                    "subdomain": subdomain,
                    "difficulty": difficulty,
                    "intent": intent,
                    "keywords": kws,
                    "entities": ents,
                    "max_results": 4,
                    "relevant_ids": relevant,
                })
                qnum += 1

    return queries


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    cases = []
    case_num = 0
    for domain, domain_config in DOMAINS.items():
        for subdomain, subconfig in domain_config["subdomains"].items():
            for i in range(40):
                case_id = f"{domain[:3]}-{subdomain[:3]}-{case_num:04d}"
                day = 1 + (case_num % 28)
                cases.append(generate_case(case_id, domain, subdomain, subconfig, domain_config, day))
                case_num += 1

    print(f"Generated {len(cases)} cases")

    queries = generate_queries(cases, n_per_subdomain=10)
    print(f"Generated {len(queries)} queries")

    # Stats
    difficulties = {}
    for q in queries:
        d = q["difficulty"]
        difficulties[d] = difficulties.get(d, 0) + 1
    print(f"Difficulty distribution: {difficulties}")

    avg_rel = sum(len(q["relevant_ids"]) for q in queries) / len(queries)
    print(f"Average relevant per query: {avg_rel:.1f}")

    by_diff = {}
    for q in queries:
        d = q["difficulty"]
        by_diff.setdefault(d, []).append(len(q["relevant_ids"]))
    for d in ["easy", "medium", "hard"]:
        vals = by_diff.get(d, [])
        print(f"  {d}: avg relevant = {sum(vals)/len(vals):.1f}, min={min(vals)}, max={max(vals)}")

    with open(os.path.join(OUTPUT_DIR, "cases.jsonl"), "w") as f:
        for c in cases:
            f.write(json.dumps(c) + "\n")
    with open(os.path.join(OUTPUT_DIR, "queries.jsonl"), "w") as f:
        for q in queries:
            f.write(json.dumps(q) + "\n")
    print(f"\nWritten to {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
