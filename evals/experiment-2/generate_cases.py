#!/usr/bin/env python3
"""
Experiment 2: Generate synthetic CBR case base.

800 cases across 4 domains × 5 subdomains each = 20 subdomains.
200 queries with known relevance (50 per domain).

Cases have realistic keyword distributions with controlled overlap and noise.
"""

import json
import random
import os

random.seed(42)  # Reproducible

OUTPUT_DIR = "evals/experiment-2/results"

# ---------------------------------------------------------------------------
# Domain definitions — 4 domains, 5 subdomains each
# ---------------------------------------------------------------------------

DOMAINS = {
    "property_market": {
        "subdomains": {
            "residential_rent": {
                "keywords": ["rent", "residential", "tenant", "lease", "apartment"],
                "entities": ["Dublin", "London", "Berlin", "Amsterdam", "Barcelona"],
            },
            "house_prices": {
                "keywords": ["house_prices", "index", "valuation", "mortgage", "sales"],
                "entities": ["CSO", "Land Registry", "Zillow", "Rightmove", "ESRI"],
            },
            "commercial": {
                "keywords": ["commercial", "office", "vacancy", "grade_a", "coworking"],
                "entities": ["CBRE", "JLL", "CoStar", "Savills", "Cushman"],
            },
            "development": {
                "keywords": ["planning", "zoning", "construction", "permits", "new_builds"],
                "entities": ["An Bord Pleanala", "Planning Authority", "RIAI", "CIF"],
            },
            "investment": {
                "keywords": ["yield", "reit", "investment", "cap_rate", "portfolio"],
                "entities": ["IRES", "Hibernia", "Green REIT", "Hines", "Kennedy Wilson"],
            },
        },
        "intents": ["research", "analysis", "report", "monitoring"],
        "tools": [["web_search"], ["web_search", "fetch_url"], ["web_search", "fetch_url"]],
        "agents": [["researcher"], ["researcher", "writer"], ["researcher", "coder"]],
    },
    "financial_analysis": {
        "subdomains": {
            "equity": {
                "keywords": ["equity", "stock", "earnings", "pe_ratio", "dividend"],
                "entities": ["AAPL", "MSFT", "NASDAQ", "NYSE", "S&P500"],
            },
            "fixed_income": {
                "keywords": ["bonds", "yield_curve", "treasury", "spread", "duration"],
                "entities": ["US Treasury", "Fed", "ECB", "Bloomberg", "Moody's"],
            },
            "crypto": {
                "keywords": ["crypto", "bitcoin", "defi", "tvl", "regulation"],
                "entities": ["BTC", "ETH", "SEC", "Binance", "Coinbase"],
            },
            "macro": {
                "keywords": ["gdp", "inflation", "employment", "central_bank", "rates"],
                "entities": ["IMF", "World Bank", "BLS", "Eurostat", "OECD"],
            },
            "commodities": {
                "keywords": ["oil", "gold", "futures", "supply", "opec"],
                "entities": ["WTI", "Brent", "COMEX", "OPEC", "LME"],
            },
        },
        "intents": ["analysis", "research", "report", "forecast"],
        "tools": [["web_search"], ["web_search", "fetch_url"], ["web_search", "fetch_url"]],
        "agents": [["researcher"], ["researcher", "coder"], ["researcher", "writer"]],
    },
    "legal_research": {
        "subdomains": {
            "contract": {
                "keywords": ["contract", "breach", "termination", "damages", "force_majeure"],
                "entities": ["High Court", "Commercial Court", "Supreme Court"],
            },
            "tort": {
                "keywords": ["tort", "negligence", "duty_of_care", "product_liability", "causation"],
                "entities": ["Supreme Court", "Court of Appeal", "CJEU"],
            },
            "ip": {
                "keywords": ["patent", "trademark", "copyright", "infringement", "fair_use"],
                "entities": ["EPO", "WIPO", "EUIPO", "CJEU", "USPTO"],
            },
            "regulatory": {
                "keywords": ["compliance", "gdpr", "data_protection", "sanctions", "aml"],
                "entities": ["DPC", "EDPB", "FCA", "SEC", "CBI"],
            },
            "employment": {
                "keywords": ["employment", "unfair_dismissal", "redundancy", "discrimination", "wrc"],
                "entities": ["WRC", "Labour Court", "EAT", "EHRC"],
            },
        },
        "intents": ["research", "analysis", "review", "advisory"],
        "tools": [["web_search"], ["web_search", "fetch_url"]],
        "agents": [["researcher"], ["researcher", "writer"]],
    },
    "technical_ops": {
        "subdomains": {
            "deployment": {
                "keywords": ["deployment", "docker", "kubernetes", "ci_cd", "rollback"],
                "entities": ["AWS", "GKE", "ECS", "ArgoCD", "GitHub Actions"],
            },
            "monitoring": {
                "keywords": ["monitoring", "latency", "errors", "alerting", "dashboards"],
                "entities": ["Grafana", "Prometheus", "Datadog", "PagerDuty", "Sentry"],
            },
            "incident": {
                "keywords": ["incident", "outage", "postmortem", "root_cause", "recovery"],
                "entities": ["Jira", "Confluence", "Statuspage", "OpsGenie"],
            },
            "database": {
                "keywords": ["database", "migration", "replication", "backup", "connection_pool"],
                "entities": ["PostgreSQL", "RDS", "MongoDB", "Redis", "ElasticSearch"],
            },
            "security": {
                "keywords": ["security", "vulnerability", "cve", "patching", "access_control"],
                "entities": ["Snyk", "Dependabot", "Vault", "IAM", "WAF"],
            },
        },
        "intents": ["troubleshooting", "analysis", "research", "report"],
        "tools": [["web_search"], ["web_search", "fetch_url"], ["web_search"]],
        "agents": [["coder"], ["researcher"], ["researcher", "coder"]],
    },
}

# Outcome distribution (realistic)
OUTCOMES = [
    ("success", 0.55),
    ("partial", 0.30),
    ("failure", 0.10),
    ("in_progress", 0.05),
]


def pick_outcome():
    r = random.random()
    cumulative = 0
    for status, prob in OUTCOMES:
        cumulative += prob
        if r <= cumulative:
            conf = random.uniform(0.3, 0.95) if status == "success" else random.uniform(0.2, 0.7)
            return status, round(conf, 2)
    return "success", 0.8


def generate_case(case_id, domain, subdomain, subconfig, domain_config, day):
    """Generate a single case with controlled keyword selection."""
    # Pick 3-4 keywords from subdomain (primary) + 0-1 from another subdomain (noise)
    primary_kw = random.sample(subconfig["keywords"], min(random.randint(3, 4), len(subconfig["keywords"])))
    noise_kw = []
    if random.random() < 0.2:  # 20% chance of cross-subdomain keyword
        other_subs = [s for s in DOMAINS[domain]["subdomains"] if s != subdomain]
        if other_subs:
            other = random.choice(other_subs)
            other_kws = DOMAINS[domain]["subdomains"][other]["keywords"]
            noise_kw = [random.choice(other_kws)]

    keywords = primary_kw + noise_kw

    # Pick 1-2 entities
    entities = random.sample(subconfig["entities"], min(random.randint(1, 2), len(subconfig["entities"])))

    intent = random.choice(domain_config["intents"])
    tools = random.choice(domain_config["tools"])
    agents = random.choice(domain_config["agents"])
    outcome_status, confidence = pick_outcome()

    timestamp = f"2026-03-{day:02d}T{random.randint(8,20):02d}:{random.randint(0,59):02d}:00Z"

    return {
        "case_id": case_id,
        "timestamp": timestamp,
        "schema_version": 2,
        "problem": {
            "user_input": f"{intent} {domain} {subdomain}",
            "intent": intent,
            "domain": domain,
            "entities": entities,
            "keywords": keywords,
            "query_complexity": random.choice(["simple", "complex"]),
        },
        "solution": {
            "approach": f"{intent} via {' + '.join(tools)}",
            "tools_used": tools,
            "agents_used": agents,
            "steps": [],
        },
        "outcome": {
            "status": outcome_status,
            "confidence": confidence,
            "assessment": "synthetic eval case",
            "pitfalls": [],
        },
        "source_narrative_id": case_id,
        "profile": None,
        "redacted": False,
        "category": None,
        "usage_stats": None,
    }


def generate_query(query_id, domain, subdomain, subconfig):
    """Generate a query targeting a specific subdomain."""
    keywords = random.sample(subconfig["keywords"], min(3, len(subconfig["keywords"])))
    entities = random.sample(subconfig["entities"], min(1, len(subconfig["entities"])))
    intent = random.choice(DOMAINS[domain]["intents"])

    return {
        "query_id": query_id,
        "domain": domain,
        "subdomain": subdomain,
        "intent": intent,
        "keywords": keywords,
        "entities": entities,
        "max_results": 4,
    }


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Generate 800 cases (40 per subdomain × 20 subdomains)
    cases = []
    case_num = 0
    for domain, domain_config in DOMAINS.items():
        for subdomain, subconfig in domain_config["subdomains"].items():
            for i in range(40):
                case_id = f"{domain[:3]}-{subdomain[:3]}-{case_num:04d}"
                day = 1 + (case_num % 28)  # Spread across 28 days
                cases.append(generate_case(case_id, domain, subdomain, subconfig, domain_config, day))
                case_num += 1

    print(f"Generated {len(cases)} cases across {len(DOMAINS)} domains")

    # Generate 200 queries (10 per subdomain × 20 subdomains)
    queries = []
    query_num = 0
    for domain, domain_config in DOMAINS.items():
        for subdomain, subconfig in domain_config["subdomains"].items():
            for i in range(10):
                qid = f"q-{domain[:3]}-{subdomain[:3]}-{query_num:04d}"
                queries.append(generate_query(qid, domain, subdomain, subconfig))
                query_num += 1

    print(f"Generated {len(queries)} queries")

    # Compute ground truth relevance
    # A case is relevant to a query if: same domain AND shares >= 2 keywords
    for q in queries:
        q_kw_set = set(q["keywords"])
        relevant = []
        for c in cases:
            if c["problem"]["domain"] == q["domain"]:
                c_kw_set = set(c["problem"]["keywords"])
                overlap = len(q_kw_set & c_kw_set)
                if overlap >= 2:
                    relevant.append(c["case_id"])
        q["relevant_ids"] = relevant

    avg_relevant = sum(len(q["relevant_ids"]) for q in queries) / len(queries)
    print(f"Average relevant cases per query: {avg_relevant:.1f}")

    # Save
    with open(os.path.join(OUTPUT_DIR, "cases.jsonl"), "w") as f:
        for c in cases:
            f.write(json.dumps(c) + "\n")

    with open(os.path.join(OUTPUT_DIR, "queries.jsonl"), "w") as f:
        for q in queries:
            f.write(json.dumps(q) + "\n")

    print(f"Written to {OUTPUT_DIR}/cases.jsonl and queries.jsonl")

    # Stats
    domain_counts = {}
    for c in cases:
        d = c["problem"]["domain"]
        domain_counts[d] = domain_counts.get(d, 0) + 1
    print("\nCases per domain:")
    for d, n in sorted(domain_counts.items()):
        print(f"  {d}: {n}")

    outcome_counts = {}
    for c in cases:
        s = c["outcome"]["status"]
        outcome_counts[s] = outcome_counts.get(s, 0) + 1
    print("\nOutcome distribution:")
    for s, n in sorted(outcome_counts.items(), key=lambda x: -x[1]):
        print(f"  {s}: {n} ({100*n/len(cases):.1f}%)")


if __name__ == "__main__":
    main()
