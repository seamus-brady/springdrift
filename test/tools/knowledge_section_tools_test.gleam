//// Tests for the document-library section tools that replaced the
//// naive `read_section` substring-match: `document_info`,
//// `list_sections`, `read_section_by_id`, and `read_range`.
////
//// Test strategy: seed a real knowledge directory on /tmp with a
//// markdown source, an index JSON, and an index.jsonl entry — then
//// drive `knowledge_tools.execute` end-to-end. Covers structured
//// docs, flat docs, and the bounds checking on `read_range`.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{None}
import gleam/string
import gleeunit/should
import knowledge/indexer
import knowledge/log as knowledge_log
import knowledge/types
import llm/types as llm_types
import simplifile
import tools/knowledge as knowledge_tools

fn test_root(suffix: String) -> String {
  let root = "/tmp/springdrift_test_section_tools_" <> suffix
  let _ = simplifile.delete(root)
  let _ = simplifile.create_directory_all(root)
  let _ = simplifile.create_directory_all(root <> "/sources/test")
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
    reason_fn: None,
  )
}

fn make_call(name: String, input: String) -> llm_types.ToolCall {
  llm_types.ToolCall(id: "t", name: name, input_json: input)
}

/// Seed a fully-formed document in the knowledge dir: markdown source,
/// JSON index, and an `index.jsonl` entry. Returns the doc_id.
fn seed_document(
  root: String,
  doc_id: String,
  title: String,
  content: String,
) -> String {
  let path = "sources/test/" <> doc_id <> ".md"
  let _ = simplifile.write(root <> "/" <> path, content)

  let idx = indexer.index_markdown(doc_id, content)
  indexer.save_index(root <> "/indexes", idx)

  let meta =
    types.DocumentMeta(
      op: types.Create,
      doc_id: doc_id,
      doc_type: types.Source,
      domain: "test",
      title: title,
      path: path,
      status: types.Normalised,
      content_hash: "h",
      node_count: idx.node_count,
      created_at: "2026-04-26T00:00:00",
      updated_at: "2026-04-26T00:00:00",
      source_url: None,
      version: 1,
    )
  knowledge_log.append(root, meta)
  doc_id
}

// A small but real structured document — three chapters, two with
// subsections. Used by the structured-doc tests below.
const structured_doc_content: String = "# Test Book

Front matter paragraph.

## Chapter 1: Beginning

Chapter 1 body text.

### Section 1.1

Section 1.1 body.

### Section 1.2

Section 1.2 body.

## Chapter 2: Middle

Chapter 2 body text.

## Chapter 3: End

Chapter 3 body text.
"

// ---------------------------------------------------------------------------
// document_info
// ---------------------------------------------------------------------------

pub fn document_info_returns_metadata_for_structured_doc_test() {
  let root = test_root("doc_info_structured")
  let cfg = make_cfg(root)
  let _ =
    seed_document(root, "doc-structured", "Test Book", structured_doc_content)

  let result =
    knowledge_tools.execute(
      make_call("document_info", "{\"doc_id\":\"doc-structured\"}"),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      content |> string.contains("Test Book") |> should.be_true
      content |> string.contains("structured: true") |> should.be_true
      // Source has 22 lines (incl. blanks); just check >0.
      content |> string.contains("total_lines:") |> should.be_true
      content |> string.contains("top_level_sections:") |> should.be_true
    }
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn document_info_marks_flat_doc_as_unstructured_test() {
  let root = test_root("doc_info_flat")
  let cfg = make_cfg(root)
  // No headings at all — just paragraphs.
  let flat_content =
    "First paragraph of a memo.

Second paragraph of the same memo.

Third paragraph.
"
  let _ = seed_document(root, "doc-flat", "Memo", flat_content)

  let result =
    knowledge_tools.execute(
      make_call("document_info", "{\"doc_id\":\"doc-flat\"}"),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) ->
      content |> string.contains("structured: false") |> should.be_true
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn document_info_errors_on_unknown_doc_id_test() {
  let root = test_root("doc_info_missing")
  let cfg = make_cfg(root)
  // Don't seed anything — empty knowledge dir.
  let result =
    knowledge_tools.execute(
      make_call("document_info", "{\"doc_id\":\"nope\"}"),
      cfg,
    )
  case result {
    llm_types.ToolFailure(error:, ..) ->
      error |> string.contains("not found") |> should.be_true
    _ -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// list_sections
// ---------------------------------------------------------------------------

pub fn list_sections_returns_full_tree_for_structured_doc_test() {
  let root = test_root("list_structured")
  let cfg = make_cfg(root)
  let _ = seed_document(root, "doc-list", "Test Book", structured_doc_content)

  let result =
    knowledge_tools.execute(
      make_call("list_sections", "{\"doc_id\":\"doc-list\"}"),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      content |> string.contains("Test Book") |> should.be_true
      content |> string.contains("Chapter 1: Beginning") |> should.be_true
      content |> string.contains("Section 1.1") |> should.be_true
      content |> string.contains("Section 1.2") |> should.be_true
      content |> string.contains("Chapter 2: Middle") |> should.be_true
      content |> string.contains("Chapter 3: End") |> should.be_true
      // Each entry should carry an id= and L<n>-<n> span.
      content |> string.contains("id=") |> should.be_true
      content |> string.contains("L") |> should.be_true
    }
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn list_sections_respects_max_depth_test() {
  let root = test_root("list_depth")
  let cfg = make_cfg(root)
  let _ = seed_document(root, "doc-depth", "Test Book", structured_doc_content)

  let result =
    knowledge_tools.execute(
      make_call("list_sections", "{\"doc_id\":\"doc-depth\",\"max_depth\":2}"),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      // Chapter 1 (depth 2) is in.
      content |> string.contains("Chapter 1: Beginning") |> should.be_true
      // Section 1.1 (depth 3) is NOT.
      content |> string.contains("Section 1.1") |> should.be_false
    }
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn list_sections_signals_no_sections_for_flat_doc_test() {
  let root = test_root("list_flat")
  let cfg = make_cfg(root)
  let _ = seed_document(root, "doc-flat-list", "Flat", "Just a paragraph.\n")

  let result =
    knowledge_tools.execute(
      make_call("list_sections", "{\"doc_id\":\"doc-flat-list\"}"),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      // Tells the agent to switch tools rather than handing back an
      // empty list with no guidance.
      content |> string.contains("read_range") |> should.be_true
    }
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }
  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// read_section_by_id
// ---------------------------------------------------------------------------

pub fn read_section_by_id_returns_content_for_valid_id_test() {
  // Round-trip: list_sections gives us the IDs, then read_section_by_id
  // should resolve one of them back to its content. This is the only
  // intended way to use the tool — exact id, no fuzzy matching.
  let root = test_root("read_by_id_roundtrip")
  let cfg = make_cfg(root)
  let _ = seed_document(root, "doc-rt", "Test Book", structured_doc_content)

  let assert Ok(idx) = indexer.load_index(root <> "/indexes", "doc-rt")
  // Pick the first child of root (Test Book), then its first child
  // (Chapter 1: Beginning).
  let assert [book, ..] = idx.root.children
  let assert [ch1, ..] = book.children
  let ch1_id = ch1.id

  let result =
    knowledge_tools.execute(
      make_call(
        "read_section_by_id",
        "{\"doc_id\":\"doc-rt\",\"section_id\":\"" <> ch1_id <> "\"}",
      ),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      content |> string.contains("Chapter 1: Beginning") |> should.be_true
      content |> string.contains("Citation:") |> should.be_true
    }
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn read_section_by_id_errors_on_unknown_id_test() {
  let root = test_root("read_by_id_bad")
  let cfg = make_cfg(root)
  let _ = seed_document(root, "doc-bad", "Test Book", structured_doc_content)

  let result =
    knowledge_tools.execute(
      make_call(
        "read_section_by_id",
        "{\"doc_id\":\"doc-bad\",\"section_id\":\"not-a-real-uuid\"}",
      ),
      cfg,
    )
  case result {
    llm_types.ToolFailure(error:, ..) -> {
      error |> string.contains("not found") |> should.be_true
      // The error must hint at list_sections so the LLM knows the
      // recovery path. This is the whole point — exact-id-or-error,
      // with a clear next step instead of a silent wrong answer.
      error |> string.contains("list_sections") |> should.be_true
    }
    _ -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// read_range
// ---------------------------------------------------------------------------

pub fn read_range_returns_requested_lines_test() {
  let root = test_root("range_basic")
  let cfg = make_cfg(root)
  // Predictable per-line content so the slice is verifiable.
  let content = "line1\nline2\nline3\nline4\nline5\n"
  let _ = seed_document(root, "doc-range", "Range Test", content)

  let result =
    knowledge_tools.execute(
      make_call(
        "read_range",
        "{\"doc_id\":\"doc-range\",\"start_line\":2,\"end_line\":4}",
      ),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      content |> string.contains("line2") |> should.be_true
      content |> string.contains("line3") |> should.be_true
      content |> string.contains("line4") |> should.be_true
      content |> string.contains("line1") |> should.be_false
      content |> string.contains("line5") |> should.be_false
      content |> string.contains("Citation:") |> should.be_true
      content |> string.contains("L2-4") |> should.be_true
    }
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn read_range_clamps_end_line_to_document_length_test() {
  // Asking for past the end shouldn't error — clamp to total. This
  // matters for agents that don't bother calling document_info first
  // and just guess a generous range. The citation should reflect the
  // clamped end so the agent can see what it actually got.
  let root = test_root("range_clamp")
  let cfg = make_cfg(root)
  let content = "line1\nline2\nline3\n"
  let _ = seed_document(root, "doc-clamp", "Clamp Test", content)

  let result =
    knowledge_tools.execute(
      make_call(
        "read_range",
        "{\"doc_id\":\"doc-clamp\",\"start_line\":1,\"end_line\":9999}",
      ),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) ->
      content |> string.contains("line1") |> should.be_true
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn read_range_clamps_start_line_to_one_test() {
  // start_line 0 or negative → clamp to 1. Same rationale as the
  // end-clamp test: don't punish the agent for an off-by-one.
  let root = test_root("range_start_clamp")
  let cfg = make_cfg(root)
  let _ = seed_document(root, "doc-sc", "SC", "a\nb\nc\n")

  let result =
    knowledge_tools.execute(
      make_call(
        "read_range",
        "{\"doc_id\":\"doc-sc\",\"start_line\":0,\"end_line\":2}",
      ),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) ->
      content |> string.contains("a") |> should.be_true
    _ -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn read_range_rejects_inverted_range_test() {
  // start > end after clamping is a real caller error — return so the
  // LLM can correct rather than silently hand back nothing.
  let root = test_root("range_inverted")
  let cfg = make_cfg(root)
  let _ = seed_document(root, "doc-inv", "Inv", "a\nb\nc\n")

  let result =
    knowledge_tools.execute(
      make_call(
        "read_range",
        "{\"doc_id\":\"doc-inv\",\"start_line\":5,\"end_line\":2}",
      ),
      cfg,
    )
  case result {
    llm_types.ToolFailure(error:, ..) ->
      error |> string.contains("before start_line") |> should.be_true
    _ -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn read_range_rejects_oversized_request_test() {
  // The 2000-line cap is a load-bearing safety guard — confirm the
  // agent gets a clear "chunk into multiple calls" hint instead of a
  // 50000-line context flood.
  let root = test_root("range_oversize")
  let cfg = make_cfg(root)
  // Generate a doc with > 2000 lines.
  let many_lines = string.repeat("x\n", 2500)
  let _ = seed_document(root, "doc-big", "Big", many_lines)

  let result =
    knowledge_tools.execute(
      make_call(
        "read_range",
        "{\"doc_id\":\"doc-big\",\"start_line\":1,\"end_line\":2500}",
      ),
      cfg,
    )
  case result {
    llm_types.ToolFailure(error:, ..) -> {
      error |> string.contains("exceeds") |> should.be_true
      error |> string.contains("Chunk") |> should.be_true
    }
    _ -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn read_range_works_on_flat_doc_test() {
  // The whole point of read_range over read_section_by_id: it works on
  // unstructured docs that have no section tree to address.
  let root = test_root("range_flat")
  let cfg = make_cfg(root)
  let _ = seed_document(root, "doc-flat-r", "Flat", "alpha\nbeta\ngamma\n")

  let result =
    knowledge_tools.execute(
      make_call(
        "read_range",
        "{\"doc_id\":\"doc-flat-r\",\"start_line\":1,\"end_line\":2}",
      ),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      content |> string.contains("alpha") |> should.be_true
      content |> string.contains("beta") |> should.be_true
      content |> string.contains("gamma") |> should.be_false
    }
    _ -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// is_knowledge_tool — name registration
// ---------------------------------------------------------------------------

pub fn new_tool_names_are_recognised_test() {
  // Regression guard: if any of these are missing from
  // is_knowledge_tool, the dispatcher won't route to them.
  knowledge_tools.is_knowledge_tool("document_info") |> should.be_true
  knowledge_tools.is_knowledge_tool("list_sections") |> should.be_true
  knowledge_tools.is_knowledge_tool("read_section_by_id") |> should.be_true
  knowledge_tools.is_knowledge_tool("read_range") |> should.be_true
  // The old name should NOT be in the supported set anymore.
  knowledge_tools.is_knowledge_tool("read_section") |> should.be_false
}
