//// Skill-proposal pattern detection over CBR cases.
////
//// Implements the algorithm from `skills-management.md` §Pattern Detection:
//// cluster cases by `(category, domain)`, then qualify each cluster against
//// six criteria (size, tool overlap, agent overlap, domain coherence,
//// utility floor, novelty against existing skills). Qualifying clusters
//// produce a `SkillProposal`.
////
//// All functions are pure — no I/O, no side effects. The Remembrancer's
//// proposal tool is the only caller; it owns the wiring to disk.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/types as cbr_types
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import skills.{type SkillMeta}
import skills/proposal.{type SkillProposal, SkillProposal, Unknown}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub type PatternConfig {
  PatternConfig(
    /// Minimum cases needed in a cluster to qualify (spec default: 5).
    min_cases: Int,
    /// Mean confidence × Laplace utility must reach this floor
    /// (spec default: 0.70).
    min_utility: Float,
    /// Pairwise Jaccard on tools_used, averaged over the cluster
    /// (spec default: 0.50).
    tool_overlap_threshold: Float,
    /// Pairwise Jaccard on agents_used, averaged over the cluster
    /// (spec default: 0.50).
    agent_overlap_threshold: Float,
    /// Body-keyword Jaccard against existing Active skills above which a
    /// proposal is treated as "update existing" rather than novel
    /// (spec default: 0.40 — used by the dedup check, not implemented in
    /// this module yet).
    novelty_threshold: Float,
  )
}

pub fn default_config() -> PatternConfig {
  PatternConfig(
    min_cases: 5,
    min_utility: 0.7,
    tool_overlap_threshold: 0.5,
    agent_overlap_threshold: 0.5,
    novelty_threshold: 0.4,
  )
}

// ---------------------------------------------------------------------------
// Cluster type — internal to pattern detection
// ---------------------------------------------------------------------------

pub type Cluster {
  Cluster(
    category: String,
    domain: String,
    cases: List(cbr_types.CbrCase),
    common_tools: List(String),
    common_agents: List(String),
    common_keywords: List(String),
    avg_confidence: Float,
    avg_utility: Float,
  )
}

// ---------------------------------------------------------------------------
// Public entry — find clusters
// ---------------------------------------------------------------------------

/// Group `cases` by `(category, domain)` and return only groups that
/// satisfy every qualifying criterion. The caller decides what to do with
/// the surviving clusters; typically `clusters_to_proposals` next.
pub fn find_clusters(
  cases: List(cbr_types.CbrCase),
  config: PatternConfig,
) -> List(Cluster) {
  cases
  |> group_by_category_domain
  |> dict.values
  |> list.filter_map(fn(group) { qualify_cluster(group, config) })
}

/// Convert qualifying clusters to proposals, filtered against existing
/// Active skills (novelty check). Returns one proposal per qualifying
/// cluster that doesn't duplicate an existing skill.
pub fn clusters_to_proposals(
  clusters: List(Cluster),
  existing_skills: List(SkillMeta),
  proposed_at: String,
  proposed_by: String,
) -> List(SkillProposal) {
  list.filter_map(clusters, fn(c) {
    case is_novel(c, existing_skills) {
      False -> Error(Nil)
      True -> Ok(cluster_to_proposal(c, proposed_at, proposed_by))
    }
  })
}

// ---------------------------------------------------------------------------
// Grouping
// ---------------------------------------------------------------------------

fn group_by_category_domain(
  cases: List(cbr_types.CbrCase),
) -> dict.Dict(#(String, String), List(cbr_types.CbrCase)) {
  list.fold(cases, dict.new(), fn(acc, c) {
    let cat = case c.category {
      Some(cat) -> category_to_string(cat)
      None -> "uncategorised"
    }
    let key = #(cat, c.problem.domain)
    case dict.get(acc, key) {
      Ok(existing) -> dict.insert(acc, key, [c, ..existing])
      Error(_) -> dict.insert(acc, key, [c])
    }
  })
}

fn category_to_string(cat: cbr_types.CbrCategory) -> String {
  case cat {
    cbr_types.Strategy -> "strategy"
    cbr_types.CodePattern -> "code_pattern"
    cbr_types.Troubleshooting -> "troubleshooting"
    cbr_types.Pitfall -> "pitfall"
    cbr_types.DomainKnowledge -> "domain_knowledge"
  }
}

// ---------------------------------------------------------------------------
// Qualification
// ---------------------------------------------------------------------------

fn qualify_cluster(
  cases: List(cbr_types.CbrCase),
  config: PatternConfig,
) -> Result(Cluster, Nil) {
  // Reverse so the cluster's case order matches read order
  let cases = list.reverse(cases)
  let n = list.length(cases)
  case n < config.min_cases {
    True -> Error(Nil)
    False -> {
      let tool_overlap =
        avg_pairwise_jaccard(cases, fn(c) { c.solution.tools_used })
      let agent_overlap =
        avg_pairwise_jaccard(cases, fn(c) { c.solution.agents_used })
      case
        tool_overlap >=. config.tool_overlap_threshold,
        agent_overlap >=. config.agent_overlap_threshold,
        domain_coherent(cases)
      {
        True, True, True -> {
          let avg_conf = mean_confidence(cases)
          let avg_util = mean_utility(cases)
          let utility_score = avg_conf *. avg_util
          case utility_score >=. config.min_utility {
            False -> Error(Nil)
            True -> {
              let first = case cases {
                [c, ..] -> c
                [] -> empty_case()
              }
              let cat = case first.category {
                Some(cat) -> category_to_string(cat)
                None -> "uncategorised"
              }
              Ok(Cluster(
                category: cat,
                domain: first.problem.domain,
                cases: cases,
                common_tools: shared_elements(cases, fn(c) {
                  c.solution.tools_used
                }),
                common_agents: shared_elements(cases, fn(c) {
                  c.solution.agents_used
                }),
                common_keywords: shared_elements(cases, fn(c) {
                  c.problem.keywords
                }),
                avg_confidence: avg_conf,
                avg_utility: avg_util,
              ))
            }
          }
        }
        _, _, _ -> Error(Nil)
      }
    }
  }
}

fn empty_case() -> cbr_types.CbrCase {
  cbr_types.CbrCase(
    case_id: "",
    timestamp: "",
    schema_version: 1,
    problem: cbr_types.CbrProblem(
      user_input: "",
      intent: "",
      domain: "",
      entities: [],
      keywords: [],
      query_complexity: "",
    ),
    solution: cbr_types.CbrSolution(
      approach: "",
      agents_used: [],
      tools_used: [],
      steps: [],
    ),
    outcome: cbr_types.CbrOutcome(
      status: "",
      confidence: 0.0,
      assessment: "",
      pitfalls: [],
    ),
    source_narrative_id: "",
    profile: None,
    redacted: False,
    category: None,
    usage_stats: None,
    strategy_id: None,
  )
}

// Domain coherence: all cases share the same problem.domain (already true
// by virtue of grouping) OR share at least 2 keywords across the cluster.
fn domain_coherent(cases: List(cbr_types.CbrCase)) -> Bool {
  let domains =
    cases
    |> list.map(fn(c) { c.problem.domain })
    |> list.unique
  case list.length(domains) {
    1 -> True
    _ -> {
      let shared = shared_elements(cases, fn(c) { c.problem.keywords })
      list.length(shared) >= 2
    }
  }
}

// ---------------------------------------------------------------------------
// Cluster → Proposal
// ---------------------------------------------------------------------------

fn cluster_to_proposal(
  cluster: Cluster,
  proposed_at: String,
  proposed_by: String,
) -> SkillProposal {
  let proposal_id = make_proposal_id(cluster, proposed_at)
  let name = derive_name(cluster)
  let description = derive_description(cluster)
  let body = derive_body(cluster)
  let agents = case cluster.common_agents {
    [] -> ["cognitive"]
    agents -> agents
  }
  let contexts = case cluster.domain {
    "" -> []
    d -> [d]
  }
  let case_ids = list.map(cluster.cases, fn(c) { c.case_id })
  let confidence = cluster.avg_confidence *. cluster.avg_utility
  SkillProposal(
    proposal_id: proposal_id,
    name: name,
    description: description,
    body: body,
    agents: agents,
    contexts: contexts,
    source_cases: case_ids,
    confidence: confidence,
    proposed_by: proposed_by,
    proposed_at: proposed_at,
    conflict: Unknown,
  )
}

fn make_proposal_id(cluster: Cluster, proposed_at: String) -> String {
  let cat_slug = slugify(cluster.category)
  let dom_slug = case cluster.domain {
    "" -> "general"
    d -> slugify(d)
  }
  let stamp = string.replace(proposed_at, ":", "")
  cat_slug <> "-" <> dom_slug <> "-" <> stamp
}

fn derive_name(cluster: Cluster) -> String {
  let cat = string.replace(cluster.category, "_", " ")
  let dom = case cluster.domain {
    "" -> ""
    d -> " for " <> d
  }
  capitalise(cat) <> " pattern" <> dom
}

fn derive_description(cluster: Cluster) -> String {
  "Auto-derived "
  <> string.replace(cluster.category, "_", " ")
  <> " pattern from "
  <> int.to_string(list.length(cluster.cases))
  <> " CBR cases (avg confidence "
  <> float_to_pct(cluster.avg_confidence)
  <> ", utility "
  <> float_to_pct(cluster.avg_utility)
  <> ")."
}

/// First-cut body. Hand-coded template that the operator (or a later LLM
/// pass) can refine. The spec example body is prose; producing prose
/// requires an LLM call. PR-D / a follow-up can replace this with an
/// XStructor-validated body generation. For now the proposal body is
/// honest about what we know structurally.
fn derive_body(cluster: Cluster) -> String {
  let header =
    "## "
    <> derive_name(cluster)
    <> "\n\nDerived from "
    <> int.to_string(list.length(cluster.cases))
    <> " "
    <> cluster.category
    <> " cases."

  let tools_section = case cluster.common_tools {
    [] -> ""
    tools ->
      "\n\n### Tools commonly used\n\n"
      <> string.join(list.map(tools, fn(t) { "- " <> t }), "\n")
  }

  let agents_section = case cluster.common_agents {
    [] -> ""
    agents ->
      "\n\n### Agents commonly involved\n\n"
      <> string.join(list.map(agents, fn(a) { "- " <> a }), "\n")
  }

  let keywords_section = case cluster.common_keywords {
    [] -> ""
    kws ->
      "\n\n### Recurring keywords\n\n"
      <> string.join(list.map(kws, fn(k) { "- " <> k }), "\n")
  }

  let evidence =
    "\n\n### Evidence (CBR cases)\n\n"
    <> string.join(list.map(cluster.cases, fn(c) { "- " <> c.case_id }), "\n")

  header <> tools_section <> agents_section <> keywords_section <> evidence
}

// ---------------------------------------------------------------------------
// Novelty check
// ---------------------------------------------------------------------------

/// A cluster is novel when no existing Active skill is scoped to the same
/// agents AND the same domain context. This is the structural variant of
/// the spec's "no existing Active or Experimental skill scoped to the
/// same agents+domain" criterion. The body-keyword Jaccard dedup
/// (treating high overlap as "update existing") is left for the conflict
/// classifier in PR-D.
pub fn is_novel(cluster: Cluster, existing: List(SkillMeta)) -> Bool {
  let cluster_agents = case cluster.common_agents {
    [] -> ["cognitive"]
    a -> a
  }
  let collides =
    list.any(existing, fn(s) {
      same_agent_scope(s.agents, cluster_agents)
      && same_domain_scope(s.contexts, cluster.domain)
    })
  !collides
}

fn same_agent_scope(
  skill_agents: List(String),
  cluster_agents: List(String),
) -> Bool {
  // Treat empty + ["all"] as universal scope (matches anything).
  case skill_agents {
    [] -> True
    ["all"] -> True
    _ -> list.any(cluster_agents, fn(a) { list.contains(skill_agents, a) })
  }
}

fn same_domain_scope(
  skill_contexts: List(String),
  cluster_domain: String,
) -> Bool {
  case skill_contexts {
    [] -> True
    contexts ->
      list.contains(contexts, cluster_domain) || list.contains(contexts, "all")
  }
}

// ---------------------------------------------------------------------------
// Helpers — Jaccard, mean confidence/utility, shared elements
// ---------------------------------------------------------------------------

/// Average pairwise Jaccard similarity over a `selector` field across all
/// pairs in `cases`. Returns 1.0 when there's a single case (vacuous true)
/// and 0.0 for an empty list.
fn avg_pairwise_jaccard(
  cases: List(cbr_types.CbrCase),
  selector: fn(cbr_types.CbrCase) -> List(String),
) -> Float {
  let sets = list.map(cases, selector)
  let n = list.length(sets)
  case n {
    0 | 1 -> 1.0
    _ -> {
      let pairs = pairs_of(sets)
      let total =
        list.fold(pairs, 0.0, fn(acc, pair) { acc +. jaccard(pair.0, pair.1) })
      let count = int.to_float(list.length(pairs))
      case count {
        0.0 -> 0.0
        _ -> total /. count
      }
    }
  }
}

fn pairs_of(items: List(a)) -> List(#(a, a)) {
  case items {
    [] -> []
    [_] -> []
    [head, ..rest] -> {
      let with_head = list.map(rest, fn(x) { #(head, x) })
      list.append(with_head, pairs_of(rest))
    }
  }
}

fn jaccard(a: List(String), b: List(String)) -> Float {
  let a_set = list.unique(a)
  let b_set = list.unique(b)
  let intersection_size =
    list.fold(a_set, 0, fn(acc, x) {
      case list.contains(b_set, x) {
        True -> acc + 1
        False -> acc
      }
    })
  let union_size = list.length(a_set) + list.length(b_set) - intersection_size
  case union_size {
    0 -> 1.0
    _ -> int.to_float(intersection_size) /. int.to_float(union_size)
  }
}

fn mean_confidence(cases: List(cbr_types.CbrCase)) -> Float {
  case cases {
    [] -> 0.0
    _ -> {
      let total =
        list.fold(cases, 0.0, fn(acc, c) { acc +. c.outcome.confidence })
      total /. int.to_float(list.length(cases))
    }
  }
}

fn mean_utility(cases: List(cbr_types.CbrCase)) -> Float {
  case cases {
    [] -> 0.0
    _ -> {
      let total =
        list.fold(cases, 0.0, fn(acc, c) {
          acc +. cbr_types.utility_score(c.usage_stats)
        })
      total /. int.to_float(list.length(cases))
    }
  }
}

/// Items that appear in EVERY case's selected list. Used for "common tools",
/// "common agents", "common keywords" in the cluster summary and proposal
/// body.
fn shared_elements(
  cases: List(cbr_types.CbrCase),
  selector: fn(cbr_types.CbrCase) -> List(String),
) -> List(String) {
  case cases {
    [] -> []
    [first, ..rest] -> {
      let initial = list.unique(selector(first))
      list.fold(rest, initial, fn(acc, c) {
        let next = list.unique(selector(c))
        list.filter(acc, fn(x) { list.contains(next, x) })
      })
    }
  }
}

// ---------------------------------------------------------------------------
// Stringy helpers
// ---------------------------------------------------------------------------

fn slugify(s: String) -> String {
  s
  |> string.lowercase
  |> string.replace(" ", "-")
  |> string.replace("_", "-")
}

fn capitalise(s: String) -> String {
  case string.to_graphemes(s) {
    [] -> s
    [first, ..rest] -> string.uppercase(first) <> string.concat(rest)
  }
}

fn float_to_pct(f: Float) -> String {
  let n = float.round(f *. 100.0)
  int.to_string(n) <> "%"
}
