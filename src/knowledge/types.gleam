//// Knowledge document types — metadata, tree nodes, operations.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// Document types and status
// ---------------------------------------------------------------------------

pub type DocType {
  Source
  Journal
  Note
  Draft
  Export
  Consolidation
}

pub type DocStatus {
  Pending
  Normalised
  Studied
  /// A draft that has been promoted to an export. Awaiting operator
  /// review. Not yet citeable by default (search filters these out
  /// unless include_pending=true is passed).
  Promoted
  Stale
  Active
  Final
  Delivered
  /// Operator has reviewed and approved the export. Citeable, canonical.
  Approved
  /// Operator has rejected the export. Not citeable; reason is
  /// recorded in the log entry's title/slog at rejection time and
  /// can be retrieved via list_documents.
  Rejected
}

pub fn doc_type_to_string(t: DocType) -> String {
  case t {
    Source -> "source"
    Journal -> "journal"
    Note -> "note"
    Draft -> "draft"
    Export -> "export"
    Consolidation -> "consolidation"
  }
}

pub fn doc_type_from_string(s: String) -> Result(DocType, Nil) {
  case s {
    "source" -> Ok(Source)
    "journal" -> Ok(Journal)
    "note" -> Ok(Note)
    "draft" -> Ok(Draft)
    "export" -> Ok(Export)
    "consolidation" -> Ok(Consolidation)
    _ -> Error(Nil)
  }
}

pub fn doc_status_to_string(s: DocStatus) -> String {
  case s {
    Pending -> "pending"
    Normalised -> "normalised"
    Studied -> "studied"
    Promoted -> "promoted"
    Stale -> "stale"
    Active -> "active"
    Final -> "final"
    Delivered -> "delivered"
    Approved -> "approved"
    Rejected -> "rejected"
  }
}

pub fn doc_status_from_string(s: String) -> Result(DocStatus, Nil) {
  case s {
    "pending" -> Ok(Pending)
    "normalised" -> Ok(Normalised)
    "studied" -> Ok(Studied)
    "promoted" -> Ok(Promoted)
    "stale" -> Ok(Stale)
    "active" -> Ok(Active)
    "final" -> Ok(Final)
    "delivered" -> Ok(Delivered)
    "approved" -> Ok(Approved)
    "rejected" -> Ok(Rejected)
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Document metadata (stored in index.jsonl)
// ---------------------------------------------------------------------------

pub type DocOp {
  Create
  UpdateStatus
  UpdateContent
  Delete
}

pub type DocumentMeta {
  DocumentMeta(
    op: DocOp,
    doc_id: String,
    doc_type: DocType,
    domain: String,
    title: String,
    path: String,
    status: DocStatus,
    content_hash: String,
    node_count: Int,
    created_at: String,
    updated_at: String,
    source_url: Option(String),
    version: Int,
  )
}

// ---------------------------------------------------------------------------
// Tree index nodes (stored in indexes/{doc-id}.json)
// ---------------------------------------------------------------------------

pub type SourceLocation {
  SourceLocation(line_start: Int, line_end: Int, page: Option(Int))
}

pub type TreeNode {
  TreeNode(
    id: String,
    title: String,
    content: String,
    depth: Int,
    source: SourceLocation,
    children: List(TreeNode),
  )
}

pub type DocumentIndex {
  DocumentIndex(
    doc_id: String,
    root: TreeNode,
    node_count: Int,
    indexed_at: String,
  )
}

// ---------------------------------------------------------------------------
// JSON encoding
// ---------------------------------------------------------------------------

fn op_to_string(op: DocOp) -> String {
  case op {
    Create -> "create"
    UpdateStatus -> "update_status"
    UpdateContent -> "update_content"
    Delete -> "delete"
  }
}

pub fn encode_meta(meta: DocumentMeta) -> String {
  json.to_string(
    json.object([
      #("op", json.string(op_to_string(meta.op))),
      #("doc_id", json.string(meta.doc_id)),
      #("doc_type", json.string(doc_type_to_string(meta.doc_type))),
      #("domain", json.string(meta.domain)),
      #("title", json.string(meta.title)),
      #("path", json.string(meta.path)),
      #("status", json.string(doc_status_to_string(meta.status))),
      #("content_hash", json.string(meta.content_hash)),
      #("node_count", json.int(meta.node_count)),
      #("created_at", json.string(meta.created_at)),
      #("updated_at", json.string(meta.updated_at)),
      #("source_url", case meta.source_url {
        Some(url) -> json.string(url)
        None -> json.null()
      }),
      #("version", json.int(meta.version)),
    ]),
  )
}

pub fn encode_tree_node(node: TreeNode) -> json.Json {
  json.object([
    #("id", json.string(node.id)),
    #("title", json.string(node.title)),
    #("content", json.string(node.content)),
    #("depth", json.int(node.depth)),
    #(
      "source",
      json.object([
        #("line_start", json.int(node.source.line_start)),
        #("line_end", json.int(node.source.line_end)),
        #("page", case node.source.page {
          Some(p) -> json.int(p)
          None -> json.null()
        }),
      ]),
    ),
    #(
      "children",
      json.preprocessed_array(list.map(node.children, encode_tree_node)),
    ),
  ])
}

pub fn encode_index(idx: DocumentIndex) -> String {
  json.to_string(
    json.object([
      #("doc_id", json.string(idx.doc_id)),
      #("root", encode_tree_node(idx.root)),
      #("node_count", json.int(idx.node_count)),
      #("indexed_at", json.string(idx.indexed_at)),
    ]),
  )
}

// ---------------------------------------------------------------------------
// JSON decoding
// ---------------------------------------------------------------------------

fn op_from_string(s: String) -> Result(DocOp, Nil) {
  case s {
    "create" -> Ok(Create)
    "update_status" -> Ok(UpdateStatus)
    "update_content" -> Ok(UpdateContent)
    "delete" -> Ok(Delete)
    _ -> Error(Nil)
  }
}

fn decode_op() -> decode.Decoder(DocOp) {
  use s <- decode.then(decode.string)
  case op_from_string(s) {
    Ok(op) -> decode.success(op)
    Error(_) -> decode.failure(Create, "DocOp")
  }
}

fn decode_doc_type() -> decode.Decoder(DocType) {
  use s <- decode.then(decode.string)
  case doc_type_from_string(s) {
    Ok(t) -> decode.success(t)
    Error(_) -> decode.failure(Source, "DocType")
  }
}

fn decode_doc_status() -> decode.Decoder(DocStatus) {
  use s <- decode.then(decode.string)
  case doc_status_from_string(s) {
    Ok(s) -> decode.success(s)
    Error(_) -> decode.failure(Pending, "DocStatus")
  }
}

pub fn decode_meta() -> decode.Decoder(DocumentMeta) {
  use op <- decode.field("op", decode_op())
  use doc_id <- decode.field("doc_id", decode.string)
  use doc_type <- decode.field("doc_type", decode_doc_type())
  use domain <- decode.optional_field("domain", "", decode.string)
  use title <- decode.field("title", decode.string)
  use path <- decode.field("path", decode.string)
  use status <- decode.field("status", decode_doc_status())
  use content_hash <- decode.optional_field("content_hash", "", decode.string)
  use node_count <- decode.optional_field("node_count", 0, decode.int)
  use created_at <- decode.field("created_at", decode.string)
  use updated_at <- decode.optional_field("updated_at", "", decode.string)
  use source_url <- decode.optional_field(
    "source_url",
    None,
    decode.optional(decode.string),
  )
  use version <- decode.optional_field("version", 1, decode.int)
  decode.success(DocumentMeta(
    op:,
    doc_id:,
    doc_type:,
    domain:,
    title:,
    path:,
    status:,
    content_hash:,
    node_count:,
    created_at:,
    updated_at:,
    source_url:,
    version:,
  ))
}

fn decode_source_location() -> decode.Decoder(SourceLocation) {
  use line_start <- decode.optional_field("line_start", 0, decode.int)
  use line_end <- decode.optional_field("line_end", 0, decode.int)
  use page <- decode.optional_field("page", None, decode.optional(decode.int))
  decode.success(SourceLocation(line_start:, line_end:, page:))
}

pub fn decode_tree_node() -> decode.Decoder(TreeNode) {
  use id <- decode.field("id", decode.string)
  use title <- decode.optional_field("title", "", decode.string)
  use content <- decode.optional_field("content", "", decode.string)
  use depth <- decode.optional_field("depth", 0, decode.int)
  use source <- decode.optional_field(
    "source",
    SourceLocation(0, 0, None),
    decode_source_location(),
  )
  use children <- decode.optional_field(
    "children",
    [],
    decode.list(decode_tree_node()),
  )
  decode.success(TreeNode(id:, title:, content:, depth:, source:, children:))
}

pub fn decode_index() -> decode.Decoder(DocumentIndex) {
  use doc_id <- decode.field("doc_id", decode.string)
  use root <- decode.field("root", decode_tree_node())
  use node_count <- decode.optional_field("node_count", 0, decode.int)
  use indexed_at <- decode.optional_field("indexed_at", "", decode.string)
  decode.success(DocumentIndex(doc_id:, root:, node_count:, indexed_at:))
}
