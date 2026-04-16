//// Knowledge search — three-tier retrieval over document indexes.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import knowledge/indexer
import knowledge/types.{type DocumentIndex, type DocumentMeta, type TreeNode}

pub type SearchResult {
  SearchResult(
    doc_id: String,
    doc_title: String,
    domain: String,
    node_title: String,
    content: String,
    depth: Int,
    line_start: Int,
    line_end: Int,
    page: Option(Int),
    score: Float,
  )
}

pub type SearchMode {
  Keyword
  Embedding
}

pub fn search(
  query: String,
  documents: List(DocumentMeta),
  indexes_dir: String,
  mode: SearchMode,
  max_results: Int,
  domain_filter: Option(String),
  type_filter: Option(types.DocType),
  embed_fn: Option(fn(String) -> Result(List(Float), String)),
) -> List(SearchResult) {
  let filtered = case domain_filter {
    Some(d) -> list.filter(documents, fn(m) { m.domain == d })
    None -> documents
  }
  let filtered2 = case type_filter {
    Some(t) -> list.filter(filtered, fn(m) { m.doc_type == t })
    None -> filtered
  }

  let all_results =
    list.flat_map(filtered2, fn(meta) {
      case indexer.load_index(indexes_dir, meta.doc_id) {
        Error(_) -> []
        Ok(idx) -> search_index(query, meta, idx, mode, embed_fn)
      }
    })

  all_results
  |> list.sort(fn(a, b) { float.compare(b.score, a.score) })
  |> list.take(max_results)
}

fn search_index(
  query: String,
  meta: DocumentMeta,
  idx: DocumentIndex,
  mode: SearchMode,
  embed_fn: Option(fn(String) -> Result(List(Float), String)),
) -> List(SearchResult) {
  let nodes = flatten_tree(idx.root)
  case mode {
    Keyword -> keyword_search(query, meta, nodes)
    Embedding ->
      case embed_fn {
        Some(ef) -> embedding_search(query, meta, nodes, ef)
        None -> keyword_search(query, meta, nodes)
      }
  }
}

fn flatten_tree(node: TreeNode) -> List(TreeNode) {
  [node, ..list.flat_map(node.children, flatten_tree)]
}

// ---------------------------------------------------------------------------
// Tier 1 — Keyword search
// ---------------------------------------------------------------------------

fn keyword_search(
  query: String,
  meta: DocumentMeta,
  nodes: List(TreeNode),
) -> List(SearchResult) {
  let terms =
    string.lowercase(query)
    |> string.split(" ")
    |> list.filter(fn(t) { string.length(t) > 2 })

  list.filter_map(nodes, fn(node) {
    let title_lower = string.lowercase(node.title)
    let content_lower = string.lowercase(node.content)
    let matches =
      list.count(terms, fn(term) {
        string.contains(title_lower, term)
        || string.contains(content_lower, term)
      })
    case matches > 0 {
      False -> Error(Nil)
      True -> {
        let title_bonus = case
          list.any(terms, fn(t) { string.contains(title_lower, t) })
        {
          True -> 0.5
          False -> 0.0
        }
        let score =
          int.to_float(matches)
          /. int.to_float(int.max(1, list.length(terms)))
          +. title_bonus
        Ok(SearchResult(
          doc_id: meta.doc_id,
          doc_title: meta.title,
          domain: meta.domain,
          node_title: node.title,
          content: truncate(node.content, 500),
          depth: node.depth,
          line_start: node.source.line_start,
          line_end: node.source.line_end,
          page: node.source.page,
          score:,
        ))
      }
    }
  })
}

// ---------------------------------------------------------------------------
// Tier 2 — Embedding search
// ---------------------------------------------------------------------------

fn embedding_search(
  query: String,
  meta: DocumentMeta,
  nodes: List(TreeNode),
  embed_fn: fn(String) -> Result(List(Float), String),
) -> List(SearchResult) {
  case embed_fn(query) {
    Error(_) -> keyword_search(query, meta, nodes)
    Ok(query_vec) ->
      list.filter_map(nodes, fn(node) {
        let text = node.title <> " " <> truncate(node.content, 200)
        case embed_fn(text) {
          Error(_) -> Error(Nil)
          Ok(node_vec) -> {
            let score = cosine_similarity(query_vec, node_vec)
            case score >. 0.3 {
              False -> Error(Nil)
              True ->
                Ok(SearchResult(
                  doc_id: meta.doc_id,
                  doc_title: meta.title,
                  domain: meta.domain,
                  node_title: node.title,
                  content: truncate(node.content, 500),
                  depth: node.depth,
                  line_start: node.source.line_start,
                  line_end: node.source.line_end,
                  page: node.source.page,
                  score:,
                ))
            }
          }
        }
      })
  }
}

fn cosine_similarity(a: List(Float), b: List(Float)) -> Float {
  let pairs = list.zip(a, b)
  let dot = list.fold(pairs, 0.0, fn(acc, pair) { acc +. pair.0 *. pair.1 })
  let mag_a =
    list.fold(a, 0.0, fn(acc, x) { acc +. x *. x })
    |> float_sqrt
  let mag_b =
    list.fold(b, 0.0, fn(acc, x) { acc +. x *. x })
    |> float_sqrt
  case mag_a *. mag_b {
    0.0 -> 0.0
    denom -> dot /. denom
  }
}

@external(erlang, "math", "sqrt")
fn float_sqrt(x: Float) -> Float

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

pub fn format_result(result: SearchResult) -> String {
  let location = case result.page {
    Some(p) -> "p." <> int.to_string(p)
    None ->
      "lines "
      <> int.to_string(result.line_start)
      <> "-"
      <> int.to_string(result.line_end)
  }
  result.domain
  <> " / "
  <> result.doc_title
  <> " / "
  <> result.node_title
  <> " ("
  <> location
  <> ")\n"
  <> result.content
}

pub fn format_citation(result: SearchResult) -> String {
  let location = case result.page {
    Some(p) -> ", p." <> int.to_string(p)
    None ->
      ", lines "
      <> int.to_string(result.line_start)
      <> "-"
      <> int.to_string(result.line_end)
  }
  "[" <> result.doc_title <> ", §" <> result.node_title <> location <> "]"
}

fn truncate(s: String, max: Int) -> String {
  case string.length(s) > max {
    True -> string.slice(s, 0, max) <> "..."
    False -> s
  }
}
