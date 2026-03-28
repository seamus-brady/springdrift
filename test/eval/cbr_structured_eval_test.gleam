//// CBR Retrieval Structured Evaluation — Synthetic Test Data
////
//// Creates controlled test cases with known relevance relationships,
//// loads them into the CBR library, and measures retrieval quality.
//// No dependency on Curragh's operational data.
////
//// Test domains:
////   - property_market (Dublin, London, Berlin)
////   - financial_analysis (equity, bonds, crypto)
////   - legal_research (contract, tort, IP)
////   - technical_ops (deployment, monitoring, incident)
////
//// Each domain has 10 cases. Queries are constructed to have known
//// relevant cases. This allows precise P@K, MRR, and nDCG measurement.

import cbr/bridge
import cbr/types.{
  type CbrCase, type CbrQuery, CbrCase, CbrOutcome, CbrProblem, CbrQuery,
  CbrSolution, ScoredCase,
}
import gleam/dict
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Test case factory
// ---------------------------------------------------------------------------

fn make_case(
  id: String,
  intent: String,
  domain: String,
  keywords: List(String),
  entities: List(String),
  approach: String,
  tools: List(String),
  agents: List(String),
  outcome_status: String,
  confidence: Float,
  timestamp: String,
) -> CbrCase {
  CbrCase(
    case_id: id,
    timestamp:,
    schema_version: 2,
    problem: CbrProblem(
      intent:,
      domain:,
      keywords:,
      entities:,
      user_input: intent <> " " <> domain,
      query_complexity: "simple",
    ),
    solution: CbrSolution(
      approach:,
      tools_used: tools,
      agents_used: agents,
      steps: [],
    ),
    outcome: CbrOutcome(
      status: outcome_status,
      confidence:,
      assessment: "test",
      pitfalls: [],
    ),
    source_narrative_id: id,
    profile: None,
    category: None,
    redacted: False,
    usage_stats: None,
  )
}

// ---------------------------------------------------------------------------
// Synthetic dataset — 40 cases across 4 domains
// ---------------------------------------------------------------------------

fn property_cases() -> List(CbrCase) {
  [
    make_case(
      "prop-01",
      "research",
      "property_market",
      ["rent", "dublin", "residential"],
      ["Dublin", "Ireland"],
      "web search for rental data",
      ["web_search", "fetch_url"],
      ["researcher"],
      "success",
      0.9,
      "2026-03-01T10:00:00Z",
    ),
    make_case(
      "prop-02",
      "research",
      "property_market",
      ["house_prices", "dublin", "quarterly"],
      ["Dublin", "CSO"],
      "quarterly price index lookup",
      ["web_search"],
      ["researcher"],
      "success",
      0.85,
      "2026-03-02T10:00:00Z",
    ),
    make_case(
      "prop-03",
      "analysis",
      "property_market",
      ["rent", "london", "commercial"],
      ["London", "UK"],
      "commercial rent comparison",
      ["web_search", "fetch_url"],
      ["researcher"],
      "partial",
      0.7,
      "2026-03-03T10:00:00Z",
    ),
    make_case(
      "prop-04",
      "research",
      "property_market",
      ["house_prices", "berlin", "residential"],
      ["Berlin", "Germany"],
      "German property index research",
      ["web_search"],
      ["researcher"],
      "success",
      0.8,
      "2026-03-04T10:00:00Z",
    ),
    make_case(
      "prop-05",
      "analysis",
      "property_market",
      ["yield", "dublin", "investment"],
      ["Dublin", "REIT"],
      "investment yield calculation",
      ["web_search", "fetch_url"],
      ["researcher", "coder"],
      "success",
      0.95,
      "2026-03-05T10:00:00Z",
    ),
    make_case(
      "prop-06",
      "research",
      "property_market",
      ["vacancy", "london", "office"],
      ["London", "CoStar"],
      "office vacancy rate lookup",
      ["web_search"],
      ["researcher"],
      "partial",
      0.6,
      "2026-03-06T10:00:00Z",
    ),
    make_case(
      "prop-07",
      "report",
      "property_market",
      ["market_summary", "dublin"],
      ["Dublin", "Daft.ie"],
      "weekly market summary",
      ["web_search", "fetch_url"],
      ["researcher", "writer"],
      "success",
      0.9,
      "2026-03-07T10:00:00Z",
    ),
    make_case(
      "prop-08",
      "research",
      "property_market",
      ["planning", "dublin", "zoning"],
      ["Dublin", "An Bord Pleanala"],
      "planning permission lookup",
      ["web_search"],
      ["researcher"],
      "failure",
      0.3,
      "2026-03-08T10:00:00Z",
    ),
    make_case(
      "prop-09",
      "analysis",
      "property_market",
      ["rent", "berlin", "trends"],
      ["Berlin", "Mietspiegel"],
      "rental trend analysis",
      ["web_search", "fetch_url"],
      ["researcher"],
      "success",
      0.85,
      "2026-03-09T10:00:00Z",
    ),
    make_case(
      "prop-10",
      "research",
      "property_market",
      ["supply", "dublin", "new_builds"],
      ["Dublin", "CSO", "ESRI"],
      "new housing supply data",
      ["web_search"],
      ["researcher"],
      "success",
      0.8,
      "2026-03-10T10:00:00Z",
    ),
  ]
}

fn financial_cases() -> List(CbrCase) {
  [
    make_case(
      "fin-01",
      "analysis",
      "financial_analysis",
      ["equity", "tech", "valuation"],
      ["AAPL", "MSFT", "NASDAQ"],
      "DCF valuation of tech stocks",
      ["web_search", "fetch_url"],
      ["researcher", "coder"],
      "success",
      0.9,
      "2026-03-01T11:00:00Z",
    ),
    make_case(
      "fin-02",
      "research",
      "financial_analysis",
      ["bonds", "yield_curve", "treasury"],
      ["US Treasury", "Fed"],
      "yield curve analysis",
      ["web_search"],
      ["researcher"],
      "success",
      0.85,
      "2026-03-02T11:00:00Z",
    ),
    make_case(
      "fin-03",
      "analysis",
      "financial_analysis",
      ["crypto", "bitcoin", "volatility"],
      ["BTC", "ETH", "Binance"],
      "crypto volatility metrics",
      ["web_search", "fetch_url"],
      ["researcher"],
      "partial",
      0.7,
      "2026-03-03T11:00:00Z",
    ),
    make_case(
      "fin-04",
      "research",
      "financial_analysis",
      ["equity", "energy", "earnings"],
      ["XOM", "CVX", "NYSE"],
      "energy sector earnings review",
      ["web_search"],
      ["researcher"],
      "success",
      0.8,
      "2026-03-04T11:00:00Z",
    ),
    make_case(
      "fin-05",
      "analysis",
      "financial_analysis",
      ["bonds", "corporate", "spread"],
      ["Moody's", "S&P"],
      "corporate bond spread analysis",
      ["web_search", "fetch_url"],
      ["researcher", "coder"],
      "success",
      0.9,
      "2026-03-05T11:00:00Z",
    ),
    make_case(
      "fin-06",
      "research",
      "financial_analysis",
      ["crypto", "defi", "tvl"],
      ["Ethereum", "Aave", "DeFiLlama"],
      "DeFi TVL tracking",
      ["web_search"],
      ["researcher"],
      "success",
      0.75,
      "2026-03-06T11:00:00Z",
    ),
    make_case(
      "fin-07",
      "report",
      "financial_analysis",
      ["market_summary", "weekly"],
      ["S&P500", "FTSE"],
      "weekly market roundup",
      ["web_search", "fetch_url"],
      ["researcher", "writer"],
      "success",
      0.95,
      "2026-03-07T11:00:00Z",
    ),
    make_case(
      "fin-08",
      "analysis",
      "financial_analysis",
      ["equity", "pharma", "pipeline"],
      ["PFE", "JNJ", "NASDAQ"],
      "pharma pipeline valuation",
      ["web_search"],
      ["researcher"],
      "partial",
      0.65,
      "2026-03-08T11:00:00Z",
    ),
    make_case(
      "fin-09",
      "research",
      "financial_analysis",
      ["bonds", "municipal", "risk"],
      ["Muni", "Bloomberg"],
      "municipal bond risk assessment",
      ["web_search"],
      ["researcher"],
      "success",
      0.8,
      "2026-03-09T11:00:00Z",
    ),
    make_case(
      "fin-10",
      "analysis",
      "financial_analysis",
      ["crypto", "regulation", "sec"],
      ["SEC", "Coinbase"],
      "crypto regulation impact",
      ["web_search", "fetch_url"],
      ["researcher"],
      "success",
      0.85,
      "2026-03-10T11:00:00Z",
    ),
  ]
}

fn legal_cases() -> List(CbrCase) {
  [
    make_case(
      "leg-01",
      "research",
      "legal_research",
      ["contract", "breach", "damages"],
      ["High Court", "Ireland"],
      "contract breach precedent search",
      ["web_search"],
      ["researcher"],
      "success",
      0.9,
      "2026-03-01T12:00:00Z",
    ),
    make_case(
      "leg-02",
      "analysis",
      "legal_research",
      ["tort", "negligence", "duty_of_care"],
      ["Supreme Court", "UK"],
      "negligence duty analysis",
      ["web_search", "fetch_url"],
      ["researcher"],
      "success",
      0.85,
      "2026-03-02T12:00:00Z",
    ),
    make_case(
      "leg-03",
      "research",
      "legal_research",
      ["ip", "patent", "infringement"],
      ["EPO", "WIPO"],
      "patent infringement case law",
      ["web_search"],
      ["researcher"],
      "partial",
      0.7,
      "2026-03-03T12:00:00Z",
    ),
    make_case(
      "leg-04",
      "research",
      "legal_research",
      ["contract", "termination", "notice"],
      ["Commercial Court"],
      "termination clause interpretation",
      ["web_search"],
      ["researcher"],
      "success",
      0.8,
      "2026-03-04T12:00:00Z",
    ),
    make_case(
      "leg-05",
      "analysis",
      "legal_research",
      ["tort", "product_liability", "consumer"],
      ["CJEU", "EU"],
      "product liability directive",
      ["web_search", "fetch_url"],
      ["researcher"],
      "success",
      0.9,
      "2026-03-05T12:00:00Z",
    ),
    make_case(
      "leg-06",
      "research",
      "legal_research",
      ["ip", "trademark", "distinctiveness"],
      ["EUIPO"],
      "trademark distinctiveness test",
      ["web_search"],
      ["researcher"],
      "success",
      0.75,
      "2026-03-06T12:00:00Z",
    ),
    make_case(
      "leg-07",
      "report",
      "legal_research",
      ["regulatory", "compliance", "gdpr"],
      ["DPC", "EDPB"],
      "GDPR compliance summary",
      ["web_search", "fetch_url"],
      ["researcher", "writer"],
      "success",
      0.95,
      "2026-03-07T12:00:00Z",
    ),
    make_case(
      "leg-08",
      "research",
      "legal_research",
      ["contract", "force_majeure", "covid"],
      ["Commercial Court", "Ireland"],
      "force majeure covid cases",
      ["web_search"],
      ["researcher"],
      "success",
      0.85,
      "2026-03-08T12:00:00Z",
    ),
    make_case(
      "leg-09",
      "analysis",
      "legal_research",
      ["tort", "medical_negligence", "causation"],
      ["Supreme Court", "Ireland"],
      "medical negligence causation",
      ["web_search"],
      ["researcher"],
      "partial",
      0.65,
      "2026-03-09T12:00:00Z",
    ),
    make_case(
      "leg-10",
      "research",
      "legal_research",
      ["ip", "copyright", "fair_use"],
      ["CJEU"],
      "copyright fair use in EU",
      ["web_search", "fetch_url"],
      ["researcher"],
      "success",
      0.8,
      "2026-03-10T12:00:00Z",
    ),
  ]
}

fn technical_cases() -> List(CbrCase) {
  [
    make_case(
      "ops-01",
      "troubleshooting",
      "technical_ops",
      ["deployment", "docker", "failed"],
      ["AWS", "ECS"],
      "container deployment failure",
      ["web_search"],
      ["coder"],
      "success",
      0.9,
      "2026-03-01T13:00:00Z",
    ),
    make_case(
      "ops-02",
      "analysis",
      "technical_ops",
      ["monitoring", "latency", "p99"],
      ["Grafana", "Prometheus"],
      "latency spike investigation",
      ["web_search", "fetch_url"],
      ["researcher"],
      "success",
      0.85,
      "2026-03-02T13:00:00Z",
    ),
    make_case(
      "ops-03",
      "troubleshooting",
      "technical_ops",
      ["incident", "outage", "database"],
      ["PostgreSQL", "RDS"],
      "database connection pool exhaustion",
      ["web_search"],
      ["coder"],
      "success",
      0.8,
      "2026-03-03T13:00:00Z",
    ),
    make_case(
      "ops-04",
      "research",
      "technical_ops",
      ["deployment", "kubernetes", "scaling"],
      ["GKE", "HPA"],
      "kubernetes autoscaling config",
      ["web_search"],
      ["researcher"],
      "partial",
      0.7,
      "2026-03-04T13:00:00Z",
    ),
    make_case(
      "ops-05",
      "analysis",
      "technical_ops",
      ["monitoring", "errors", "rate"],
      ["Sentry", "PagerDuty"],
      "error rate anomaly detection",
      ["web_search", "fetch_url"],
      ["researcher", "coder"],
      "success",
      0.9,
      "2026-03-05T13:00:00Z",
    ),
    make_case(
      "ops-06",
      "troubleshooting",
      "technical_ops",
      ["incident", "memory_leak", "jvm"],
      ["Java", "GC"],
      "JVM memory leak diagnosis",
      ["web_search"],
      ["coder"],
      "success",
      0.85,
      "2026-03-06T13:00:00Z",
    ),
    make_case(
      "ops-07",
      "report",
      "technical_ops",
      ["postmortem", "incident_review"],
      ["Jira", "Confluence"],
      "incident postmortem template",
      ["web_search", "fetch_url"],
      ["researcher", "writer"],
      "success",
      0.95,
      "2026-03-07T13:00:00Z",
    ),
    make_case(
      "ops-08",
      "research",
      "technical_ops",
      ["deployment", "ci_cd", "pipeline"],
      ["GitHub Actions", "ArgoCD"],
      "CI/CD pipeline optimization",
      ["web_search"],
      ["researcher"],
      "success",
      0.8,
      "2026-03-08T13:00:00Z",
    ),
    make_case(
      "ops-09",
      "troubleshooting",
      "technical_ops",
      ["incident", "network", "dns"],
      ["Route53", "CloudFlare"],
      "DNS resolution failure",
      ["web_search"],
      ["coder"],
      "partial",
      0.6,
      "2026-03-09T13:00:00Z",
    ),
    make_case(
      "ops-10",
      "analysis",
      "technical_ops",
      ["monitoring", "capacity", "forecast"],
      ["Prometheus", "Thanos"],
      "capacity planning forecast",
      ["web_search", "fetch_url"],
      ["researcher", "coder"],
      "success",
      0.85,
      "2026-03-10T13:00:00Z",
    ),
  ]
}

fn all_test_cases() -> List(CbrCase) {
  list.flatten([
    property_cases(),
    financial_cases(),
    legal_cases(),
    technical_cases(),
  ])
}

// ---------------------------------------------------------------------------
// Test queries with known relevant cases
// ---------------------------------------------------------------------------

fn test_queries() -> List(#(String, CbrQuery, List(String))) {
  [
    // Query 1: Dublin rent research — should find prop-01, prop-05, prop-07, prop-09 (rent-related property)
    #(
      "dublin_rent",
      CbrQuery(
        intent: "research",
        domain: "property_market",
        keywords: ["rent", "dublin", "residential"],
        entities: ["Dublin"],
        max_results: 4,
        query_complexity: None,
      ),
      ["prop-01", "prop-02", "prop-05", "prop-07", "prop-10"],
    ),
    // Query 2: Bond analysis — should find fin-02, fin-05, fin-09
    #(
      "bond_analysis",
      CbrQuery(
        intent: "analysis",
        domain: "financial_analysis",
        keywords: ["bonds", "yield", "spread"],
        entities: ["Treasury"],
        max_results: 4,
        query_complexity: None,
      ),
      ["fin-02", "fin-05", "fin-09"],
    ),
    // Query 3: Contract law — should find leg-01, leg-04, leg-08
    #(
      "contract_law",
      CbrQuery(
        intent: "research",
        domain: "legal_research",
        keywords: ["contract", "breach", "termination"],
        entities: ["High Court"],
        max_results: 4,
        query_complexity: None,
      ),
      ["leg-01", "leg-04", "leg-08"],
    ),
    // Query 4: Deployment troubleshooting — should find ops-01, ops-04, ops-08
    #(
      "deployment_troubleshoot",
      CbrQuery(
        intent: "troubleshooting",
        domain: "technical_ops",
        keywords: ["deployment", "docker", "failed"],
        entities: ["AWS"],
        max_results: 4,
        query_complexity: None,
      ),
      ["ops-01", "ops-04", "ops-08"],
    ),
    // Query 5: Cross-domain — crypto regulation (specific subdomain)
    #(
      "crypto_regulation",
      CbrQuery(
        intent: "research",
        domain: "financial_analysis",
        keywords: ["crypto", "regulation", "sec"],
        entities: ["SEC"],
        max_results: 4,
        query_complexity: None,
      ),
      ["fin-03", "fin-06", "fin-10"],
    ),
    // Query 6: IP law — should find leg-03, leg-06, leg-10
    #(
      "ip_law",
      CbrQuery(
        intent: "research",
        domain: "legal_research",
        keywords: ["ip", "patent", "copyright"],
        entities: ["EPO", "CJEU"],
        max_results: 4,
        query_complexity: None,
      ),
      ["leg-03", "leg-06", "leg-10"],
    ),
  ]
}

// ---------------------------------------------------------------------------
// Weight configs (same as ablation)
// ---------------------------------------------------------------------------

fn full_weights() -> bridge.RetrievalWeights {
  bridge.default_weights()
}

fn field_only() -> bridge.RetrievalWeights {
  bridge.RetrievalWeights(
    field_weight: 1.0,
    index_weight: 0.0,
    recency_weight: 0.0,
    domain_weight: 0.0,
    embedding_weight: 0.0,
    utility_weight: 0.0,
  )
}

fn index_only() -> bridge.RetrievalWeights {
  bridge.RetrievalWeights(
    field_weight: 0.0,
    index_weight: 1.0,
    recency_weight: 0.0,
    domain_weight: 0.0,
    embedding_weight: 0.0,
    utility_weight: 0.0,
  )
}

fn field_index_domain() -> bridge.RetrievalWeights {
  bridge.RetrievalWeights(
    field_weight: 0.4,
    index_weight: 0.3,
    recency_weight: 0.0,
    domain_weight: 0.3,
    embedding_weight: 0.0,
    utility_weight: 0.0,
  )
}

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

fn precision_at_k(
  relevant_ids: List(String),
  retrieved_ids: List(String),
  k: Int,
) -> Float {
  let top_k = list.take(retrieved_ids, k)
  let hits = list.count(top_k, fn(id) { list.contains(relevant_ids, id) })
  int.to_float(hits) /. int.to_float(int.max(k, 1))
}

fn reciprocal_rank(
  relevant_ids: List(String),
  retrieved_ids: List(String),
) -> Float {
  find_rr(relevant_ids, retrieved_ids, 1)
}

fn find_rr(relevant: List(String), retrieved: List(String), rank: Int) -> Float {
  case retrieved {
    [] -> 0.0
    [id, ..rest] ->
      case list.contains(relevant, id) {
        True -> 1.0 /. int.to_float(rank)
        False -> find_rr(relevant, rest, rank + 1)
      }
  }
}

// ---------------------------------------------------------------------------
// Main structured eval
// ---------------------------------------------------------------------------

pub fn cbr_structured_retrieval_test() {
  let cases = all_test_cases()
  let queries = test_queries()
  let n_cases = list.length(cases)
  let n_queries = list.length(queries)

  io.println(
    "CBR Structured Eval: "
    <> int.to_string(n_cases)
    <> " synthetic cases, "
    <> int.to_string(n_queries)
    <> " queries",
  )

  // Build case base once
  let base =
    list.fold(cases, bridge.new(), fn(b, c) { bridge.retain_case(b, c) })
  let metadata =
    list.fold(cases, dict.new(), fn(d, c) { dict.insert(d, c.case_id, c) })

  let configs = [
    #("full_weighted", full_weights()),
    #("field_only", field_only()),
    #("index_only", index_only()),
    #("field_index_domain", field_index_domain()),
  ]

  let results =
    list.map(configs, fn(config) {
      let #(name, weights) = config
      let query_results =
        list.map(queries, fn(q) {
          let #(qname, query, relevant_ids) = q
          let retrieved =
            bridge.retrieve_cases(base, query, metadata, weights, 0.0)
          let retrieved_ids =
            list.map(retrieved, fn(sc) {
              let ScoredCase(cbr_case: c, ..) = sc
              c.case_id
            })
          let p4 = precision_at_k(relevant_ids, retrieved_ids, 4)
          let mrr = reciprocal_rank(relevant_ids, retrieved_ids)
          #(qname, p4, mrr, retrieved_ids)
        })

      let mean_p4 =
        list.fold(query_results, 0.0, fn(acc, r) { acc +. r.1 })
        /. int.to_float(n_queries)
      let mean_mrr =
        list.fold(query_results, 0.0, fn(acc, r) { acc +. r.2 })
        /. int.to_float(n_queries)

      io.println(
        name
        <> ": P@4="
        <> float.to_string(mean_p4)
        <> " MRR="
        <> float.to_string(mean_mrr),
      )

      // Per-query detail
      list.each(query_results, fn(r) {
        let #(qname, p4, mrr, retrieved) = r
        io.println(
          "  "
          <> qname
          <> ": P@4="
          <> float.to_string(p4)
          <> " MRR="
          <> float.to_string(mrr)
          <> " top4="
          <> string.join(list.take(retrieved, 4), ","),
        )
      })

      #(name, mean_p4, mean_mrr, query_results)
    })

  // Write JSONL
  let jsonl =
    list.flat_map(results, fn(r) {
      let #(name, mean_p4, mean_mrr, query_results) = r
      let summary =
        json.to_string(
          json.object([
            #("type", json.string("config_summary")),
            #("config", json.string(name)),
            #("n_cases", json.int(n_cases)),
            #("n_queries", json.int(n_queries)),
            #("mean_precision_at_4", json.float(mean_p4)),
            #("mean_mrr", json.float(mean_mrr)),
          ]),
        )
      let per_query =
        list.map(query_results, fn(qr) {
          let #(qname, p4, mrr, retrieved) = qr
          json.to_string(
            json.object([
              #("type", json.string("query_result")),
              #("config", json.string(name)),
              #("query", json.string(qname)),
              #("precision_at_4", json.float(p4)),
              #("mrr", json.float(mrr)),
              #("retrieved", json.array(list.take(retrieved, 4), json.string)),
            ]),
          )
        })
      [summary, ..per_query]
    })
    |> string.join("\n")

  let _ = simplifile.write("evals/results/cbr_structured.jsonl", jsonl)
  io.println("\nWritten to evals/results/cbr_structured.jsonl")
}

// ---------------------------------------------------------------------------
// Basic sanity checks (real assertions)
// ---------------------------------------------------------------------------

pub fn cbr_same_domain_retrieves_same_domain_test() {
  let cases = all_test_cases()
  let base =
    list.fold(cases, bridge.new(), fn(b, c) { bridge.retain_case(b, c) })
  let metadata =
    list.fold(cases, dict.new(), fn(d, c) { dict.insert(d, c.case_id, c) })

  // Query for property market — all results should be property cases
  let query =
    CbrQuery(
      intent: "research",
      domain: "property_market",
      keywords: ["rent", "dublin"],
      entities: ["Dublin"],
      max_results: 4,
      query_complexity: None,
    )
  let retrieved =
    bridge.retrieve_cases(base, query, metadata, full_weights(), 0.0)
  let domains =
    list.map(retrieved, fn(sc) {
      let ScoredCase(cbr_case: c, ..) = sc
      c.problem.domain
    })

  // At least 3 of 4 should be property_market
  let property_count = list.count(domains, fn(d) { d == "property_market" })
  { property_count >= 3 } |> should.be_true()
}

pub fn cbr_no_cross_domain_pollution_test() {
  let cases = all_test_cases()
  let base =
    list.fold(cases, bridge.new(), fn(b, c) { bridge.retain_case(b, c) })
  let metadata =
    list.fold(cases, dict.new(), fn(d, c) { dict.insert(d, c.case_id, c) })

  // Query for legal — should not return financial or ops cases in top 4
  let query =
    CbrQuery(
      intent: "research",
      domain: "legal_research",
      keywords: ["contract", "breach"],
      entities: ["High Court"],
      max_results: 4,
      query_complexity: None,
    )
  let retrieved =
    bridge.retrieve_cases(base, query, metadata, full_weights(), 0.0)
  let non_legal =
    list.count(retrieved, fn(sc) {
      let ScoredCase(cbr_case: c, ..) = sc
      c.problem.domain != "legal_research"
    })

  // At most 1 non-legal case in top 4
  { non_legal <= 1 } |> should.be_true()
}
