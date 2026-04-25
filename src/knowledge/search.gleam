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
import llm/provider as llm_provider
import llm/request
import llm/response

pub type SearchResult {
  SearchResult(
    doc_id: String,
    /// Filename-based stable slug derived from the document's source
    /// path (e.g. "inbox/sample" for sources/inbox/sample.md). More
    /// stable across sessions than doc_title, which is a human string
    /// that can change.
    doc_slug: String,
    doc_title: String,
    domain: String,
    node_title: String,
    /// Breadcrumb from the document root to this node, slash-separated
    /// (e.g. "EU Compliance / Article 6 / Subpoint 2"). Empty string
    /// for the document root itself.
    section_path: String,
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
  /// Tier 3 — LLM reasons over tree nodes. Used as a fallback when
  /// keyword and embedding both return nothing above threshold, or
  /// forced by passing mode=reasoning. Costs a model call.
  Reasoning
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
  // Walk the tree carrying a breadcrumb so each node knows its
  // position under the document root. Root itself is given an empty
  // path so citations for the whole-document case don't carry the
  // title twice (doc_title is already on the result).
  let nodes_with_paths = flatten_tree_with_path(idx.root, "")
  case mode {
    Keyword -> keyword_search(query, meta, nodes_with_paths)
    Embedding ->
      case embed_fn {
        Some(ef) -> embedding_search(query, meta, nodes_with_paths, ef)
        None -> keyword_search(query, meta, nodes_with_paths)
      }
    // Reasoning mode is dispatched at a higher level
    // (reason_over_documents in run_search_library). If it somehow
    // lands here, fall back to keyword so we don't silently drop
    // results — the caller should have routed it instead.
    Reasoning -> keyword_search(query, meta, nodes_with_paths)
  }
}

/// Walk a tree depth-first, emitting `(node, section_path)` pairs
/// where section_path is the slash-joined breadcrumb of ancestor
/// titles (empty string at the root). The root itself has an empty
/// path; its direct children have path = root.title; deeper children
/// extend it.
fn flatten_tree_with_path(
  node: TreeNode,
  parent_path: String,
) -> List(#(TreeNode, String)) {
  // Child path: extend parent's breadcrumb with this node's title,
  // but leave root's own path empty (parent_path == "" means we're
  // at the root, so children should start with just this node's
  // title rather than a leading " / ").
  let child_path = case parent_path {
    "" -> node.title
    _ -> parent_path <> " / " <> node.title
  }
  let children_paths =
    list.flat_map(node.children, fn(c) { flatten_tree_with_path(c, child_path) })
  [#(node, parent_path), ..children_paths]
}

fn doc_slug_from(meta: DocumentMeta) -> String {
  // path looks like "sources/<domain>/<slug>.md" or
  // "workspace/drafts/<slug>.md". Strip the prefix segments and
  // trailing .md so the slug is stable and human-readable.
  case string.split(meta.path, "/") {
    [] -> meta.doc_id
    parts ->
      case list.last(parts) {
        Ok(last) ->
          // Prefix with domain when present so two documents with the
          // same filename in different domains are distinguishable.
          case meta.domain {
            "" -> strip_md(last)
            domain -> domain <> "/" <> strip_md(last)
          }
        Error(_) -> meta.doc_id
      }
  }
}

fn strip_md(filename: String) -> String {
  case string.ends_with(filename, ".md") {
    True -> string.drop_end(filename, 3)
    False -> filename
  }
}

// ---------------------------------------------------------------------------
// Tier 1 — Keyword search
// ---------------------------------------------------------------------------

fn keyword_search(
  query: String,
  meta: DocumentMeta,
  nodes_with_paths: List(#(TreeNode, String)),
) -> List(SearchResult) {
  let terms =
    string.lowercase(query)
    |> string.split(" ")
    |> list.filter(fn(t) { string.length(t) > 2 })
  let slug = doc_slug_from(meta)

  list.filter_map(nodes_with_paths, fn(pair) {
    let #(node, section_path) = pair
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
          doc_slug: slug,
          doc_title: meta.title,
          domain: meta.domain,
          node_title: node.title,
          section_path: section_path,
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
  nodes_with_paths: List(#(TreeNode, String)),
  embed_fn: fn(String) -> Result(List(Float), String),
) -> List(SearchResult) {
  case embed_fn(query) {
    Error(_) -> keyword_search(query, meta, nodes_with_paths)
    Ok(query_vec) -> {
      let slug = doc_slug_from(meta)
      list.filter_map(nodes_with_paths, fn(pair) {
        let #(node, section_path) = pair
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
                  doc_slug: slug,
                  doc_title: meta.title,
                  domain: meta.domain,
                  node_title: node.title,
                  section_path: section_path,
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

/// Structured, machine-parseable citation. Format:
///
///   doc:<slug> §<section-path> L<start>-<end>
///
/// When a page number is known (e.g. from a PDF) it replaces the line
/// range: `doc:<slug> §<section-path> p.<N>`.
///
/// The slug is the stable identifier operators and agents should use
/// when referring back to a document — it doesn't change if the
/// human-readable title is edited, and it encodes the domain for
/// disambiguation. The section path carries the full breadcrumb so
/// deeply-nested sections remain findable.
pub fn format_citation(result: SearchResult) -> String {
  let section = case result.section_path {
    "" -> result.node_title
    path -> path
  }
  format_citation_from_parts(
    result.doc_slug,
    section,
    result.line_start,
    result.line_end,
    result.page,
  )
}

/// Citation builder taking bare parts. Lets `read_section` produce
/// the same format without constructing a SearchResult just to
/// throw it away.
pub fn format_citation_from_parts(
  doc_slug: String,
  section_or_path: String,
  line_start: Int,
  line_end: Int,
  page: Option(Int),
) -> String {
  let location = case page {
    Some(p) -> " p." <> int.to_string(p)
    None -> " L" <> int.to_string(line_start) <> "-" <> int.to_string(line_end)
  }
  "doc:" <> doc_slug <> " §" <> section_or_path <> location
}

/// Compute the slug for a DocumentMeta — exposed so tools outside of
/// search (e.g. `read_section`) can build citations consistently.
pub fn doc_slug_for(meta: DocumentMeta) -> String {
  doc_slug_from(meta)
}

// ---------------------------------------------------------------------------
// Tier 3 — LLM reasoning retrieval
// ---------------------------------------------------------------------------

/// Maximum nodes fed into the Tier 3 prompt. Caps prompt size (each
/// node line is ~250 chars worst case, so 100 nodes ≈ 25KB input) and
/// costs. If the library has more, we sort by title-length heuristic
/// and truncate to keep the prompt tractable.
pub const tier3_max_nodes: Int = 100

/// Tier 3 retrieval: when keyword + embedding return nothing, ask an
/// LLM to reason over the list of document sections and pick the
/// relevant ones. Cost-capped by `tier3_max_nodes` and by reason_fn
/// (the caller owns the model choice and max_tokens budget).
///
/// reason_fn takes a fully-formed prompt string and returns the model's
/// free-form text reply (or an error). The parser here picks node IDs
/// out of the reply by substring match against the known set, so a
/// malformed or hallucinated reply yields zero results rather than
/// garbage.
pub fn reason_over_documents(
  query: String,
  documents: List(DocumentMeta),
  indexes_dir: String,
  reason_fn: fn(String) -> Result(String, String),
  max_results: Int,
) -> List(SearchResult) {
  // Flatten all docs into (meta, node, section_path, node_id) tuples.
  // Cap to tier3_max_nodes up front — a huge library shouldn't pay for
  // every leaf in one prompt.
  let all_entries =
    list.flat_map(documents, fn(meta) {
      case indexer.load_index(indexes_dir, meta.doc_id) {
        Error(_) -> []
        Ok(idx) ->
          flatten_tree_with_path(idx.root, "")
          |> list.map(fn(pair) {
            let #(node, path) = pair
            #(meta, node, path)
          })
      }
    })
  let entries = list.take(all_entries, tier3_max_nodes)
  case entries {
    [] -> []
    _ -> {
      let prompt = build_tier3_prompt(query, entries)
      case reason_fn(prompt) {
        Error(_) -> []
        Ok(reply) -> {
          let picked_ids = parse_picked_ids(reply, entries)
          entries
          |> list.filter(fn(t) { list.contains(picked_ids, { t.1 }.id) })
          |> list.map(fn(t) {
            let #(meta, node, path) = t
            let slug = doc_slug_from(meta)
            SearchResult(
              doc_id: meta.doc_id,
              doc_slug: slug,
              doc_title: meta.title,
              domain: meta.domain,
              node_title: node.title,
              section_path: path,
              content: truncate(node.content, 500),
              depth: node.depth,
              line_start: node.source.line_start,
              line_end: node.source.line_end,
              page: node.source.page,
              // Score 0.5 is a placeholder — the LLM picked it, but
              // we don't have a numeric confidence. All reasoning
              // results score the same; the LLM's ordering in the
              // reply is preserved by the filter pass below.
              score: 0.5,
            )
          })
          |> list.take(max_results)
        }
      }
    }
  }
}

/// Default max_tokens for the Tier 3 reasoning reply. The reply is
/// just a list of node IDs (one per line), so this is small. Bigger
/// here just risks a chatty model padding with prose we'll discard.
pub const tier3_default_reply_tokens: Int = 512

/// Build a default `reason_fn` closure from a provider + model. Each
/// agent that owns the search_library tool can pass its own provider
/// and model in — the agent's working model is the natural choice for
/// "reason over my own library".
///
/// The returned closure is single-shot: builds a request, calls the
/// provider, returns the reply text or a stringified error. The
/// caller (`reason_over_documents`) treats Error as "no picks", so a
/// hung or failing provider degrades gracefully to zero results
/// rather than crashing the search.
pub fn make_reason_fn(
  provider: llm_provider.Provider,
  model: String,
) -> fn(String) -> Result(String, String) {
  fn(prompt: String) -> Result(String, String) {
    let req =
      request.new(model, tier3_default_reply_tokens)
      |> request.with_user_message(prompt)
    case provider.chat(req) {
      Error(e) -> Error(response.error_message(e))
      Ok(resp) -> Ok(response.text(resp))
    }
  }
}

fn build_tier3_prompt(
  query: String,
  entries: List(#(DocumentMeta, TreeNode, String)),
) -> String {
  let lines =
    list.index_map(entries, fn(t, i) {
      let #(_meta, node, path) = t
      let section = case path {
        "" -> node.title
        _ -> path <> " / " <> node.title
      }
      let preview = truncate(node.content, 200)
      int.to_string(i + 1)
      <> ". id="
      <> node.id
      <> " §"
      <> section
      <> "\n   "
      <> preview
    })
  "You are helping search a document library.\n\n"
  <> "Query: "
  <> query
  <> "\n\n"
  <> "Here are the sections available:\n\n"
  <> string.join(lines, "\n\n")
  <> "\n\n"
  <> "Return the IDs of sections relevant to the query, one per line, "
  <> "most relevant first. Use only IDs from the list above. If none "
  <> "are relevant, return an empty line."
}

/// Extract node IDs from the LLM reply by substring match against the
/// known set. Tolerates the LLM adding prose around the IDs.
fn parse_picked_ids(
  reply: String,
  entries: List(#(DocumentMeta, TreeNode, String)),
) -> List(String) {
  let known_ids = list.map(entries, fn(t) { { t.1 }.id })
  list.filter(known_ids, fn(id) { string.contains(reply, id) })
}

fn truncate(s: String, max: Int) -> String {
  case string.length(s) > max {
    True -> string.slice(s, 0, max) <> "..."
    False -> s
  }
}
