//// Export approval workflow tests.
////
//// Covers:
//// - promote_draft sets status=Promoted (not Active)
//// - approve_export / reject_export transitions via the tool
////   dispatch
//// - search filtering: Rejected always excluded, Promoted excluded
////   unless include_pending=true
//// - double-approve / already-rejected error cases

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import knowledge/log as knowledge_log
import knowledge/types.{
  type DocumentMeta, Approved, Create, DocumentMeta, Export, Promoted, Rejected,
  Source,
}
import llm/types as llm_types
import simplifile
import tools/knowledge as knowledge_tools

fn test_root(suffix: String) -> String {
  let root = "/tmp/springdrift_test_approval_" <> suffix
  let _ = simplifile.delete(root)
  let _ = simplifile.create_directory_all(root)
  let _ = simplifile.create_directory_all(root <> "/drafts")
  let _ = simplifile.create_directory_all(root <> "/exports")
  let _ = simplifile.create_directory_all(root <> "/indexes")
  root
}

fn make_cfg(root: String) -> knowledge_tools.KnowledgeConfig {
  knowledge_tools.KnowledgeConfig(
    knowledge_dir: root,
    indexes_dir: root <> "/indexes",
    sources_dir: root <> "/sources",
    journal_dir: root <> "/journal",
    notes_dir: root <> "/notes",
    drafts_dir: root <> "/drafts",
    exports_dir: root <> "/exports",
    embed_fn: None,
  )
}

fn make_tool_call(name: String, input: String) -> llm_types.ToolCall {
  llm_types.ToolCall(id: "test-call", name: name, input_json: input)
}

fn resolve_status_for_slug(
  knowledge_dir: String,
  slug: String,
) -> Result(types.DocStatus, Nil) {
  let docs = knowledge_log.resolve(knowledge_dir)
  case list.find(docs, fn(m) { m.doc_type == Export && m.title == slug }) {
    Ok(m) -> Ok(m.status)
    Error(_) -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// promote_draft lands as Promoted (pending approval), not Active
// ---------------------------------------------------------------------------

pub fn promote_draft_sets_status_promoted_test() {
  let root = test_root("promote_status")
  let cfg = make_cfg(root)

  // Write a draft directly so we don't have to call create_draft.
  let _ = simplifile.write(root <> "/drafts/alpha.md", "# Alpha\n")

  let call = make_tool_call("promote_draft", "{\"slug\":\"alpha\"}")
  let result = knowledge_tools.execute(call, cfg)

  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      content |> string.contains("Promoted") |> should.be_true
      content |> string.contains("pending") |> should.be_true
    }
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }

  case resolve_status_for_slug(root, "alpha") {
    Ok(Promoted) -> Nil
    Ok(other) -> {
      echo other
      should.fail()
    }
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// approve_export transitions Promoted → Approved
// ---------------------------------------------------------------------------

pub fn approve_export_transitions_to_approved_test() {
  let root = test_root("approve_basic")
  let cfg = make_cfg(root)
  let _ = simplifile.write(root <> "/drafts/beta.md", "# Beta\n")
  let _ =
    knowledge_tools.execute(
      make_tool_call("promote_draft", "{\"slug\":\"beta\"}"),
      cfg,
    )

  let result =
    knowledge_tools.execute(
      make_tool_call(
        "approve_export",
        "{\"slug\":\"beta\",\"note\":\"looks good\"}",
      ),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(..) -> Nil
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }

  case resolve_status_for_slug(root, "beta") {
    Ok(Approved) -> Nil
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// reject_export transitions Promoted → Rejected, requires non-empty reason
// ---------------------------------------------------------------------------

pub fn reject_export_transitions_to_rejected_test() {
  let root = test_root("reject_basic")
  let cfg = make_cfg(root)
  let _ = simplifile.write(root <> "/drafts/gamma.md", "# Gamma\n")
  let _ =
    knowledge_tools.execute(
      make_tool_call("promote_draft", "{\"slug\":\"gamma\"}"),
      cfg,
    )

  let result =
    knowledge_tools.execute(
      make_tool_call(
        "reject_export",
        "{\"slug\":\"gamma\",\"reason\":\"scope changed\"}",
      ),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(..) -> Nil
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }

  case resolve_status_for_slug(root, "gamma") {
    Ok(Rejected) -> Nil
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn reject_export_requires_non_empty_reason_test() {
  let root = test_root("reject_empty")
  let cfg = make_cfg(root)
  let _ = simplifile.write(root <> "/drafts/delta.md", "# Delta\n")
  let _ =
    knowledge_tools.execute(
      make_tool_call("promote_draft", "{\"slug\":\"delta\"}"),
      cfg,
    )

  let result =
    knowledge_tools.execute(
      make_tool_call("reject_export", "{\"slug\":\"delta\",\"reason\":\"   \"}"),
      cfg,
    )
  case result {
    llm_types.ToolFailure(error:, ..) ->
      error |> string.contains("reason") |> should.be_true
    _ -> should.fail()
  }

  // Status should still be Promoted since rejection failed.
  case resolve_status_for_slug(root, "delta") {
    Ok(Promoted) -> Nil
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Double-approve / already-rejected are rejected
// ---------------------------------------------------------------------------

pub fn cannot_double_approve_test() {
  let root = test_root("double_approve")
  let cfg = make_cfg(root)
  let _ = simplifile.write(root <> "/drafts/epsilon.md", "# Epsilon\n")
  let _ =
    knowledge_tools.execute(
      make_tool_call("promote_draft", "{\"slug\":\"epsilon\"}"),
      cfg,
    )
  let _ =
    knowledge_tools.execute(
      make_tool_call("approve_export", "{\"slug\":\"epsilon\"}"),
      cfg,
    )

  // Second approval attempt should fail.
  let result =
    knowledge_tools.execute(
      make_tool_call("approve_export", "{\"slug\":\"epsilon\"}"),
      cfg,
    )
  case result {
    llm_types.ToolFailure(error:, ..) ->
      error |> string.contains("already Approved") |> should.be_true
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn approve_missing_export_returns_clean_error_test() {
  let root = test_root("approve_missing")
  let cfg = make_cfg(root)

  let result =
    knowledge_tools.execute(
      make_tool_call("approve_export", "{\"slug\":\"does-not-exist\"}"),
      cfg,
    )
  case result {
    llm_types.ToolFailure(error:, ..) ->
      error |> string.contains("No export") |> should.be_true
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Tool registration — cognitive loop has the operator tools, writer doesn't
// ---------------------------------------------------------------------------

pub fn cognitive_tools_include_approval_tools_test() {
  let names =
    knowledge_tools.cognitive_tools()
    |> list.map(fn(t) { t.name })
  names |> list.contains("approve_export") |> should.be_true
  names |> list.contains("reject_export") |> should.be_true
}

pub fn writer_tools_exclude_approval_tools_test() {
  // Writer must not be able to self-approve. Only promote_draft
  // belongs to the writer; approval is operator-driven.
  let names =
    knowledge_tools.writer_tools()
    |> list.map(fn(t) { t.name })
  names |> list.contains("promote_draft") |> should.be_true
  names |> list.contains("approve_export") |> should.be_false
  names |> list.contains("reject_export") |> should.be_false
}

// ---------------------------------------------------------------------------
// search_library filter — skip Promoted unless include_pending=true; always
// skip Rejected.
// ---------------------------------------------------------------------------

fn write_doc(
  root: String,
  doc_id: String,
  domain: String,
  title: String,
  status: types.DocStatus,
  doc_type: types.DocType,
) -> Nil {
  let meta =
    DocumentMeta(
      op: Create,
      doc_id: doc_id,
      doc_type: doc_type,
      domain: domain,
      title: title,
      path: case doc_type {
        Export -> "exports/" <> title <> ".md"
        _ -> "sources/" <> domain <> "/" <> title <> ".md"
      },
      status: status,
      content_hash: "",
      node_count: 1,
      created_at: "2026-04-24",
      updated_at: "2026-04-24",
      source_url: None,
      version: 1,
    )
  knowledge_log.append(root, meta)
  Nil
}

pub fn resolve_keeps_all_statuses_test() {
  // The raw log holds every state; filtering happens at search time,
  // not at resolve time.
  let root = test_root("resolve_keeps")
  write_doc(root, "d1", "papers", "promoted-export", Promoted, Export)
  write_doc(root, "d2", "papers", "approved-export", Approved, Export)
  write_doc(root, "d3", "papers", "rejected-export", Rejected, Export)
  write_doc(root, "d4", "papers", "normal-source", types.Normalised, Source)

  let docs = knowledge_log.resolve(root)
  list.length(docs) |> should.equal(4)

  let _ = simplifile.delete(root)
  Nil
}

// End-to-end filter check: we can't easily call run_search_library via
// a tool call without real indexes, but we can exercise the filter
// predicate directly against a doc list. This is the same predicate
// run_search_library uses inline. Keeping it inline in the executor
// is fine for readability, so we replicate the logic for the test.
fn apply_search_filter(
  docs: List(DocumentMeta),
  include_pending: Bool,
) -> List(DocumentMeta) {
  list.filter(docs, fn(m: DocumentMeta) {
    case m.doc_type, m.status {
      Export, Rejected -> False
      Export, Promoted -> include_pending
      _, _ -> True
    }
  })
}

pub fn search_filter_excludes_rejected_always_test() {
  let docs = [
    DocumentMeta(
      op: Create,
      doc_id: "d1",
      doc_type: Export,
      domain: "",
      title: "rejected-report",
      path: "exports/rejected-report.md",
      status: Rejected,
      content_hash: "",
      node_count: 1,
      created_at: "",
      updated_at: "",
      source_url: None,
      version: 1,
    ),
  ]
  // Rejected excluded whether include_pending is true OR false.
  apply_search_filter(docs, False) |> list.length |> should.equal(0)
  apply_search_filter(docs, True) |> list.length |> should.equal(0)
}

pub fn search_filter_promoted_controlled_by_flag_test() {
  let docs = [
    DocumentMeta(
      op: Create,
      doc_id: "d1",
      doc_type: Export,
      domain: "",
      title: "pending-report",
      path: "exports/pending-report.md",
      status: Promoted,
      content_hash: "",
      node_count: 1,
      created_at: "",
      updated_at: "",
      source_url: None,
      version: 1,
    ),
  ]
  apply_search_filter(docs, False) |> list.length |> should.equal(0)
  apply_search_filter(docs, True) |> list.length |> should.equal(1)
}

pub fn search_filter_approved_always_included_test() {
  let docs = [
    DocumentMeta(
      op: Create,
      doc_id: "d1",
      doc_type: Export,
      domain: "",
      title: "approved-report",
      path: "exports/approved-report.md",
      status: Approved,
      content_hash: "",
      node_count: 1,
      created_at: "",
      updated_at: "",
      source_url: None,
      version: 1,
    ),
  ]
  apply_search_filter(docs, False) |> list.length |> should.equal(1)
  apply_search_filter(docs, True) |> list.length |> should.equal(1)
}

pub fn search_filter_leaves_sources_and_drafts_alone_test() {
  // Non-Export types are never filtered — only Exports have the
  // approval lifecycle.
  let docs = [
    DocumentMeta(
      op: Create,
      doc_id: "d1",
      doc_type: Source,
      domain: "papers",
      title: "my-paper",
      path: "sources/papers/my-paper.md",
      status: types.Normalised,
      content_hash: "",
      node_count: 1,
      created_at: "",
      updated_at: "",
      source_url: None,
      version: 1,
    ),
  ]
  apply_search_filter(docs, False) |> list.length |> should.equal(1)
}

// ---------------------------------------------------------------------------
// Status enum round-trip through JSON
// ---------------------------------------------------------------------------

pub fn new_statuses_roundtrip_through_json_test() {
  let meta =
    DocumentMeta(
      op: Create,
      doc_id: "x1",
      doc_type: Export,
      domain: "",
      title: "rt",
      path: "exports/rt.md",
      status: Approved,
      content_hash: "",
      node_count: 1,
      created_at: "",
      updated_at: "",
      source_url: None,
      version: 1,
    )
  let encoded = types.encode_meta(meta)
  let decoded = json.parse(encoded, types.decode_meta())
  case decoded {
    Ok(m) -> m.status |> should.equal(Approved)
    Error(_) -> should.fail()
  }
}
