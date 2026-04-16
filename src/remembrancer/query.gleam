//// Remembrancer query engine — filtering and aggregation over raw JSONL data.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/types as cbr_types
import facts/types as facts_types
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/order
import gleam/string
import narrative/types as narrative_types

// ---------------------------------------------------------------------------
// Narrative search
// ---------------------------------------------------------------------------

/// Search narrative entries by keyword across summaries and keywords fields.
pub fn search_entries(
  entries: List(narrative_types.NarrativeEntry),
  query: String,
) -> List(narrative_types.NarrativeEntry) {
  let terms =
    string.lowercase(query)
    |> string.split(" ")
    |> list.filter(fn(t) { string.length(t) > 2 })
  list.filter(entries, fn(entry) {
    let summary_lower = string.lowercase(entry.summary)
    let keywords_lower =
      list.map(entry.keywords, string.lowercase)
      |> string.join(" ")
    list.any(terms, fn(term) {
      string.contains(summary_lower, term)
      || string.contains(keywords_lower, term)
    })
  })
}

// ---------------------------------------------------------------------------
// Fact archaeology
// ---------------------------------------------------------------------------

/// Find all versions of a fact key across all files.
pub fn trace_fact_key(
  all_facts: List(facts_types.MemoryFact),
  key: String,
) -> List(facts_types.MemoryFact) {
  let key_lower = string.lowercase(key)
  list.filter(all_facts, fn(fact) { string.lowercase(fact.key) == key_lower })
}

/// Find facts with keys similar to the given key.
pub fn find_related_facts(
  all_facts: List(facts_types.MemoryFact),
  key: String,
) -> List(facts_types.MemoryFact) {
  let key_lower = string.lowercase(key)
  let key_parts = string.split(key_lower, "_")
  list.filter(all_facts, fn(fact) {
    let fact_key_lower = string.lowercase(fact.key)
    fact_key_lower != key_lower
    && list.any(key_parts, fn(part) {
      string.length(part) > 2 && string.contains(fact_key_lower, part)
    })
  })
  |> list.unique
}

// ---------------------------------------------------------------------------
// CBR pattern mining
// ---------------------------------------------------------------------------

pub type CaseCluster {
  CaseCluster(
    domain: String,
    keywords: List(String),
    cases: List(String),
    avg_confidence: Float,
  )
}

/// Find clusters of similar cases by keyword overlap within a domain.
pub fn cluster_cases(
  cases: List(cbr_types.CbrCase),
  min_cluster_size: Int,
) -> List(CaseCluster) {
  let by_domain = list.group(cases, fn(c) { c.problem.domain })
  dict.values(by_domain)
  |> list.flat_map(fn(domain_cases) {
    let domain = case domain_cases {
      [first, ..] -> first.problem.domain
      [] -> ""
    }
    let keyword_groups =
      list.group(
        list.flat_map(domain_cases, fn(c) {
          list.map(c.problem.keywords, fn(kw) { #(kw, c.case_id) })
        }),
        fn(pair) { pair.0 },
      )
    dict.values(keyword_groups)
    |> list.filter_map(fn(pairs) {
      let case_ids = list.map(pairs, fn(p) { p.1 }) |> list.unique
      case list.length(case_ids) >= min_cluster_size {
        False -> Error(Nil)
        True -> {
          let keyword = case pairs {
            [#(kw, _), ..] -> kw
            [] -> ""
          }
          let matching =
            list.filter(domain_cases, fn(c) {
              list.contains(case_ids, c.case_id)
            })
          let avg_conf = case matching {
            [] -> 0.0
            ms -> {
              let sum =
                list.fold(ms, 0.0, fn(acc, c) { acc +. c.outcome.confidence })
              sum /. int.to_float(list.length(ms))
            }
          }
          Ok(CaseCluster(
            domain:,
            keywords: [keyword],
            cases: case_ids,
            avg_confidence: avg_conf,
          ))
        }
      }
    })
  })
}

// ---------------------------------------------------------------------------
// Thread resurrection
// ---------------------------------------------------------------------------

pub type DormantThread {
  DormantThread(
    thread_name: String,
    last_active: String,
    domains: List(String),
    keywords: List(String),
    entry_count: Int,
  )
}

/// Find threads with no activity since a given date (ISO 8601 string).
pub fn find_dormant_threads(
  entries: List(narrative_types.NarrativeEntry),
  dormant_since: String,
) -> List(DormantThread) {
  let by_thread =
    list.group(entries, fn(e) {
      case e.thread {
        option.Some(t) -> t.thread_id
        option.None -> "unthreaded"
      }
    })
  dict.to_list(by_thread)
  |> list.filter_map(fn(pair) {
    let #(thread_id, thread_entries) = pair
    case thread_id == "unthreaded" {
      True -> Error(Nil)
      False -> {
        let sorted =
          list.sort(thread_entries, fn(a, b) {
            string.compare(b.timestamp, a.timestamp)
          })
        case sorted {
          [latest, ..] -> {
            case string.compare(latest.timestamp, dormant_since) {
              order.Lt -> {
                let all_domains =
                  list.map(thread_entries, fn(e) { e.intent.domain })
                  |> list.unique
                let all_keywords =
                  list.flat_map(thread_entries, fn(e) { e.keywords })
                  |> list.unique
                  |> list.take(10)
                let thread_name = case latest.thread {
                  option.Some(t) -> t.thread_name
                  option.None -> thread_id
                }
                Ok(DormantThread(
                  thread_name:,
                  last_active: latest.timestamp,
                  domains: all_domains,
                  keywords: all_keywords,
                  entry_count: list.length(thread_entries),
                ))
              }
              _ -> Error(Nil)
            }
          }
          [] -> Error(Nil)
        }
      }
    }
  })
}

// ---------------------------------------------------------------------------
// Cross-reference
// ---------------------------------------------------------------------------

pub type CrossReference {
  CrossReference(
    topic: String,
    narrative_hits: Int,
    case_hits: Int,
    fact_hits: Int,
    domains: List(String),
    date_range: #(String, String),
  )
}

/// Cross-reference a topic across all memory stores.
pub fn cross_reference(
  topic: String,
  entries: List(narrative_types.NarrativeEntry),
  cases: List(cbr_types.CbrCase),
  facts: List(facts_types.MemoryFact),
) -> CrossReference {
  let topic_lower = string.lowercase(topic)
  let matching_entries =
    list.filter(entries, fn(e) {
      string.contains(string.lowercase(e.summary), topic_lower)
      || list.any(e.keywords, fn(k) {
        string.contains(string.lowercase(k), topic_lower)
      })
    })
  let matching_cases =
    list.filter(cases, fn(c) {
      string.contains(string.lowercase(c.problem.intent), topic_lower)
      || list.any(c.problem.keywords, fn(k) {
        string.contains(string.lowercase(k), topic_lower)
      })
    })
  let matching_facts =
    list.filter(facts, fn(f) {
      string.contains(string.lowercase(f.key), topic_lower)
      || string.contains(string.lowercase(f.value), topic_lower)
    })
  let all_domains =
    list.map(matching_entries, fn(e) { e.intent.domain })
    |> list.append(list.map(matching_cases, fn(c) { c.problem.domain }))
    |> list.unique
  let timestamps =
    list.map(matching_entries, fn(e) { e.timestamp })
    |> list.sort(string.compare)
  let date_range = case timestamps {
    [first, ..] -> #(first, result_unwrap(list.last(timestamps), first))
    [] -> #("", "")
  }
  CrossReference(
    topic:,
    narrative_hits: list.length(matching_entries),
    case_hits: list.length(matching_cases),
    fact_hits: list.length(matching_facts),
    domains: all_domains,
    date_range:,
  )
}

fn result_unwrap(r: Result(a, b), default: a) -> a {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

pub fn format_cross_reference(xref: CrossReference) -> String {
  "Cross-reference: \""
  <> xref.topic
  <> "\"\n  Narrative: "
  <> int.to_string(xref.narrative_hits)
  <> " entries\n  CBR: "
  <> int.to_string(xref.case_hits)
  <> " cases\n  Facts: "
  <> int.to_string(xref.fact_hits)
  <> " matches\n  Domains: "
  <> string.join(xref.domains, ", ")
  <> "\n  Date range: "
  <> xref.date_range.0
  <> " to "
  <> xref.date_range.1
}

pub fn format_dormant_thread(dt: DormantThread) -> String {
  dt.thread_name
  <> " (last active: "
  <> dt.last_active
  <> ", "
  <> int.to_string(dt.entry_count)
  <> " entries)\n  Domains: "
  <> string.join(dt.domains, ", ")
  <> "\n  Keywords: "
  <> string.join(dt.keywords, ", ")
}

pub fn format_cluster(cluster: CaseCluster) -> String {
  cluster.domain
  <> " — "
  <> string.join(cluster.keywords, ", ")
  <> " ("
  <> int.to_string(list.length(cluster.cases))
  <> " cases, avg confidence: "
  <> float.to_string(cluster.avg_confidence)
  <> ")"
}
