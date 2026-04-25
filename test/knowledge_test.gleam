import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import knowledge/indexer
import knowledge/log as knowledge_log
import knowledge/types.{
  type DocumentMeta, Active, Create, Delete, DocumentMeta, Draft, Journal,
  Normalised, Note, Pending, Source, UpdateStatus,
}
import simplifile

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

// ---------------------------------------------------------------------------
// Indexer tests
// ---------------------------------------------------------------------------

pub fn index_simple_markdown_test() {
  let content =
    "# Introduction

This is the intro.

## Background

Some background text.

### Prior Work

Details about prior work.

## Methods

Description of methods."

  let idx = indexer.index_markdown("test-doc", content)
  idx.doc_id |> should.equal("test-doc")
  idx.node_count |> should.not_equal(0)
  idx.root.title |> should.equal("Document")
  // Should have children for the top-level headings
  list.length(idx.root.children) |> should.equal(1)
  // The H1 "Introduction" should exist
  let assert [intro] = idx.root.children
  intro.title |> should.equal("Introduction")
  intro.depth |> should.equal(1)
}

pub fn index_nested_headings_test() {
  let content =
    "# Chapter 1

Intro text.

## Section 1.1

Section content.

## Section 1.2

More content.

### Subsection 1.2.1

Sub content.

# Chapter 2

Chapter 2 text."

  let idx = indexer.index_markdown("nested", content)
  // Root should have 2 children (Chapter 1 and Chapter 2)
  list.length(idx.root.children) |> should.equal(2)
  let assert [ch1, ch2] = idx.root.children
  ch1.title |> should.equal("Chapter 1")
  ch2.title |> should.equal("Chapter 2")
  // Chapter 1 should have 2 sections
  list.length(ch1.children) |> should.equal(2)
  let assert [s11, s12] = ch1.children
  s11.title |> should.equal("Section 1.1")
  s12.title |> should.equal("Section 1.2")
  // Section 1.2 should have 1 subsection
  list.length(s12.children) |> should.equal(1)
}

pub fn index_empty_content_test() {
  let idx = indexer.index_markdown("empty", "")
  idx.node_count |> should.equal(1)
  idx.root.children |> should.equal([])
}

pub fn index_no_headings_test() {
  let content = "Just plain text\nwith multiple lines\nno headings at all."
  let idx = indexer.index_markdown("plain", content)
  idx.node_count |> should.equal(1)
  idx.root.children |> should.equal([])
  string.contains(idx.root.content, "Just plain text") |> should.be_true
}

pub fn index_content_attached_to_sections_test() {
  let content =
    "# Title

Title content here.

## Section

Section content here."

  let idx = indexer.index_markdown("content", content)
  let assert [title] = idx.root.children
  string.contains(title.content, "Title content here") |> should.be_true
  let assert [section] = title.children
  string.contains(section.content, "Section content here") |> should.be_true
}

pub fn find_section_by_title_test() {
  let content =
    "# Doc

## Introduction

Intro text.

## Methods

Methods text."

  let idx = indexer.index_markdown("find", content)
  let result = indexer.find_section(idx.root, "methods")
  case result {
    Some(node) -> node.title |> should.equal("Methods")
    None -> should.fail()
  }
}

pub fn find_section_not_found_test() {
  let idx = indexer.index_markdown("empty", "# Just a title")
  let result = indexer.find_section(idx.root, "nonexistent section xyz")
  result |> should.equal(None)
}

pub fn count_nodes_test() {
  let content =
    "# A

## B

### C

## D"

  let idx = indexer.index_markdown("count", content)
  // root + A + B + C + D = 5
  idx.node_count |> should.equal(5)
}

pub fn index_roundtrip_json_test() {
  let content = "# Test\n\nSome content.\n\n## Sub\n\nMore."
  let idx = indexer.index_markdown("roundtrip", content)
  let encoded = types.encode_index(idx)
  let decoded = json.parse(encoded, types.decode_index())
  case decoded {
    Ok(restored) -> {
      restored.doc_id |> should.equal("roundtrip")
      restored.node_count |> should.equal(idx.node_count)
      restored.root.title |> should.equal("Document")
    }
    Error(_) -> should.fail()
  }
}

pub fn index_save_load_test() {
  let dir = "/tmp/springdrift_test_indexes_" <> generate_uuid()
  let _ = simplifile.create_directory_all(dir)
  let content = "# Paper Title\n\n## Abstract\n\nSummary here."
  let idx = indexer.index_markdown("paper-1", content)
  indexer.save_index(dir, idx)
  case indexer.load_index(dir, "paper-1") {
    Ok(loaded) -> {
      loaded.doc_id |> should.equal("paper-1")
      loaded.node_count |> should.equal(idx.node_count)
    }
    Error(_) -> should.fail()
  }
  let _ = simplifile.delete(dir)
  Nil
}

// ---------------------------------------------------------------------------
// Log tests
// ---------------------------------------------------------------------------

fn make_meta(
  op: types.DocOp,
  doc_id: String,
  doc_type: types.DocType,
  status: types.DocStatus,
) -> DocumentMeta {
  DocumentMeta(
    op:,
    doc_id:,
    doc_type:,
    domain: "test",
    title: "Test Doc",
    path: "sources/test/doc.md",
    status:,
    content_hash: "abc123",
    node_count: 0,
    created_at: "2026-04-16T00:00:00Z",
    updated_at: "2026-04-16T00:00:00Z",
    source_url: None,
    version: 1,
  )
}

pub fn log_append_and_read_test() {
  let dir = "/tmp/springdrift_test_knowledge_" <> generate_uuid()
  let _ = simplifile.create_directory_all(dir)
  let meta = make_meta(Create, "doc-1", Source, Pending)
  knowledge_log.append(dir, meta)
  let entries = knowledge_log.read_all(dir)
  list.length(entries) |> should.equal(1)
  let assert [first] = entries
  first.doc_id |> should.equal("doc-1")
  let _ = simplifile.delete(dir)
  Nil
}

pub fn log_resolve_last_op_wins_test() {
  let ops = [
    make_meta(Create, "doc-1", Source, Pending),
    make_meta(UpdateStatus, "doc-1", Source, Normalised),
    make_meta(Create, "doc-2", Note, Active),
  ]
  let resolved = knowledge_log.resolve_ops(ops)
  list.length(resolved) |> should.equal(2)
  let doc1 = list.find(resolved, fn(m) { m.doc_id == "doc-1" })
  case doc1 {
    Ok(m) -> m.status |> should.equal(Normalised)
    Error(_) -> should.fail()
  }
}

pub fn log_resolve_delete_removes_test() {
  let ops = [
    make_meta(Create, "doc-1", Source, Pending),
    make_meta(Delete, "doc-1", Source, Pending),
  ]
  let resolved = knowledge_log.resolve_ops(ops)
  list.length(resolved) |> should.equal(0)
}

pub fn log_read_empty_dir_test() {
  let entries = knowledge_log.read_all("/tmp/nonexistent_" <> generate_uuid())
  list.length(entries) |> should.equal(0)
}

pub fn meta_json_roundtrip_test() {
  let meta = make_meta(Create, "rt-1", Journal, Active)
  let encoded = types.encode_meta(meta)
  let decoded = json.parse(encoded, types.decode_meta())
  case decoded {
    Ok(m) -> {
      m.doc_id |> should.equal("rt-1")
      m.doc_type |> should.equal(Journal)
      m.status |> should.equal(Active)
    }
    Error(_) -> should.fail()
  }
}

pub fn meta_with_source_url_roundtrip_test() {
  let meta =
    DocumentMeta(
      ..make_meta(Create, "url-1", Source, Normalised),
      source_url: Some("https://arxiv.org/abs/1234"),
    )
  let encoded = types.encode_meta(meta)
  let decoded = json.parse(encoded, types.decode_meta())
  case decoded {
    Ok(m) -> m.source_url |> should.equal(Some("https://arxiv.org/abs/1234"))
    Error(_) -> should.fail()
  }
}

pub fn doc_type_roundtrip_test() {
  [Source, Journal, Note, Draft, types.Export, types.Consolidation]
  |> list.each(fn(t) {
    let s = types.doc_type_to_string(t)
    let result = types.doc_type_from_string(s)
    result |> should.equal(Ok(t))
  })
}

pub fn doc_status_roundtrip_test() {
  [
    Pending,
    Normalised,
    types.Studied,
    types.Promoted,
    types.Stale,
    Active,
    types.Final,
    types.Delivered,
  ]
  |> list.each(fn(s) {
    let str = types.doc_status_to_string(s)
    let result = types.doc_status_from_string(str)
    result |> should.equal(Ok(s))
  })
}

// ---------------------------------------------------------------------------
// Search tests
// ---------------------------------------------------------------------------

import knowledge/search

pub fn keyword_search_finds_match_test() {
  let dir = "/tmp/springdrift_test_search_" <> generate_uuid()
  let _ = simplifile.create_directory_all(dir <> "/indexes")
  let content =
    "# Machine Learning\n\n## Neural Networks\n\nDeep learning uses neural networks.\n\n## Decision Trees\n\nRandom forests use decision trees."
  let idx = indexer.index_markdown("ml-paper", content)
  indexer.save_index(dir <> "/indexes", idx)
  let meta =
    DocumentMeta(
      ..make_meta(Create, "ml-paper", Source, Normalised),
      title: "ML Paper",
      domain: "research",
    )
  let results =
    search.search(
      "neural networks",
      [meta],
      dir <> "/indexes",
      search.Keyword,
      5,
      None,
      None,
      None,
    )
  { results != [] } |> should.be_true
  let assert [first, ..] = results
  string.contains(first.content, "neural") |> should.be_true
  let _ = simplifile.delete(dir)
  Nil
}

pub fn keyword_search_no_match_test() {
  let dir = "/tmp/springdrift_test_search2_" <> generate_uuid()
  let _ = simplifile.create_directory_all(dir <> "/indexes")
  let content = "# Cooking\n\n## Pasta\n\nBoil water and add spaghetti."
  let idx = indexer.index_markdown("cooking", content)
  indexer.save_index(dir <> "/indexes", idx)
  let meta =
    DocumentMeta(
      ..make_meta(Create, "cooking", Source, Normalised),
      title: "Cooking",
      domain: "food",
    )
  let results =
    search.search(
      "quantum physics",
      [meta],
      dir <> "/indexes",
      search.Keyword,
      5,
      None,
      None,
      None,
    )
  list.length(results) |> should.equal(0)
  let _ = simplifile.delete(dir)
  Nil
}

pub fn search_domain_filter_test() {
  let dir = "/tmp/springdrift_test_search3_" <> generate_uuid()
  let _ = simplifile.create_directory_all(dir <> "/indexes")
  let idx1 = indexer.index_markdown("doc1", "# Legal\n\nContract law.")
  indexer.save_index(dir <> "/indexes", idx1)
  let idx2 = indexer.index_markdown("doc2", "# Science\n\nContract analysis.")
  indexer.save_index(dir <> "/indexes", idx2)
  let meta1 =
    DocumentMeta(
      ..make_meta(Create, "doc1", Source, Normalised),
      title: "Legal Doc",
      domain: "legal",
    )
  let meta2 =
    DocumentMeta(
      ..make_meta(Create, "doc2", Source, Normalised),
      title: "Science Doc",
      domain: "science",
    )
  let results =
    search.search(
      "contract",
      [meta1, meta2],
      dir <> "/indexes",
      search.Keyword,
      5,
      Some("legal"),
      None,
      None,
    )
  list.length(results) |> should.equal(1)
  let assert [r] = results
  r.domain |> should.equal("legal")
  let _ = simplifile.delete(dir)
  Nil
}

pub fn format_citation_test() {
  let result =
    search.SearchResult(
      doc_id: "abc",
      doc_slug: "cbr/aamodt-plaza-1994",
      doc_title: "Aamodt & Plaza 1994",
      domain: "cbr",
      node_title: "Similarity Assessment",
      section_path: "Introduction / Similarity Assessment",
      content: "Some content",
      depth: 2,
      line_start: 145,
      line_end: 178,
      page: None,
      score: 0.85,
    )
  let citation = search.format_citation(result)
  // Structured form: doc:<slug> §<section-path> L<a>-<b>
  string.contains(citation, "doc:cbr/aamodt-plaza-1994") |> should.be_true
  string.contains(citation, "§Introduction / Similarity Assessment")
  |> should.be_true
  string.contains(citation, "L145-178") |> should.be_true
}

pub fn format_citation_uses_page_for_pdf_test() {
  let result =
    search.SearchResult(
      doc_id: "abc",
      doc_slug: "papers/eu-ai-act",
      doc_title: "EU AI Act",
      domain: "papers",
      node_title: "Article 6",
      section_path: "Title III / High-Risk Systems / Article 6",
      content: "content",
      depth: 3,
      line_start: 1,
      line_end: 1,
      page: Some(42),
      score: 0.9,
    )
  let citation = search.format_citation(result)
  // When page is known, it replaces the line range.
  string.contains(citation, "p.42") |> should.be_true
  string.contains(citation, "L1") |> should.be_false
}

pub fn format_citation_falls_back_to_node_title_when_no_path_test() {
  // Root-level sections have section_path = "" — citation should still
  // carry a usable section label (the node's own title).
  let result =
    search.SearchResult(
      doc_id: "abc",
      doc_slug: "inbox/notes",
      doc_title: "Notes",
      domain: "inbox",
      node_title: "Overview",
      section_path: "",
      content: "c",
      depth: 0,
      line_start: 1,
      line_end: 10,
      page: None,
      score: 0.5,
    )
  let citation = search.format_citation(result)
  string.contains(citation, "§Overview") |> should.be_true
}

pub fn format_citation_from_parts_matches_structured_form_test() {
  let citation =
    search.format_citation_from_parts(
      "inbox/sample",
      "Introduction / Key Findings",
      10,
      25,
      None,
    )
  citation
  |> should.equal("doc:inbox/sample §Introduction / Key Findings L10-25")
}

// End-to-end: index a nested-heading document, write its index to disk,
// search it, and verify the returned SearchResult carries a well-formed
// citation with the section breadcrumb.
pub fn search_populates_citation_end_to_end_test() {
  let dir = "/tmp/springdrift_test_citation_e2e"
  let _ = simplifile.delete(dir)
  let _ = simplifile.create_directory_all(dir)

  let doc_id = "cite-test"
  let content =
    "# Project Plan\n"
    <> "\n"
    <> "## Phase One\n"
    <> "### Scope\n"
    <> "The phase one scope covers initial data collection.\n"
    <> "### Timeline\n"
    <> "Six weeks from kickoff.\n"
    <> "## Phase Two\n"
    <> "Expansion and validation.\n"

  let idx = indexer.index_markdown(doc_id, content)
  indexer.save_index(dir, idx)

  let meta =
    DocumentMeta(
      op: Create,
      doc_id: doc_id,
      doc_type: Source,
      domain: "inbox",
      title: "Project Plan",
      path: "sources/inbox/project-plan.md",
      status: Normalised,
      content_hash: "",
      node_count: idx.node_count,
      created_at: "2026-04-24",
      updated_at: "2026-04-24",
      source_url: None,
      version: 1,
    )

  // Search for "scope" — should hit the "Scope" subsection under
  // "Phase One", which has a breadcrumb of
  // "Project Plan / Phase One / Scope".
  let results =
    search.search("scope", [meta], dir, search.Keyword, 5, None, None, None)

  // At least one result should land on the Scope node.
  case list.find(results, fn(r) { r.node_title == "Scope" }) {
    Ok(r) -> {
      r.doc_slug |> should.equal("inbox/project-plan")
      // Breadcrumb from root: "Project Plan / Phase One"
      // (node's own title gets appended by format_citation).
      r.section_path |> string.contains("Phase One") |> should.be_true
      let citation = search.format_citation(r)
      citation |> string.contains("doc:inbox/project-plan") |> should.be_true
      citation |> string.contains("§") |> should.be_true
    }
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(dir)
  Nil
}

// ---------------------------------------------------------------------------
// Workspace tests
// ---------------------------------------------------------------------------

import knowledge/workspace

pub fn journal_write_and_read_test() {
  let dir = "/tmp/springdrift_test_journal_" <> generate_uuid()
  workspace.write_journal(dir, "Today I learned about trees.")
  |> should.be_ok
  let content = workspace.read_journal_today(dir)
  string.contains(content, "Today I learned") |> should.be_true
  let _ = simplifile.delete(dir)
  Nil
}

pub fn note_write_read_list_test() {
  let dir = "/tmp/springdrift_test_notes_" <> generate_uuid()
  workspace.write_note(dir, "open-questions", "1. Why?\n2. How?")
  |> should.be_ok
  workspace.read_note(dir, "open-questions") |> should.be_ok
  let notes = workspace.list_notes(dir)
  list.length(notes) |> should.equal(1)
  let _ = simplifile.delete(dir)
  Nil
}

pub fn note_update_replaces_content_test() {
  let dir = "/tmp/springdrift_test_notes2_" <> generate_uuid()
  workspace.write_note(dir, "todo", "Original") |> should.be_ok
  workspace.write_note(dir, "todo", "Updated") |> should.be_ok
  let assert Ok(content) = workspace.read_note(dir, "todo")
  content |> should.equal("Updated")
  let _ = simplifile.delete(dir)
  Nil
}

pub fn note_not_found_test() {
  let dir = "/tmp/springdrift_test_notes3_" <> generate_uuid()
  workspace.read_note(dir, "nonexistent") |> should.be_error
}

// ---------------------------------------------------------------------------
// Intake tests
// ---------------------------------------------------------------------------

import knowledge/intake

pub fn intake_process_markdown_test() {
  let base = "/tmp/springdrift_test_intake_" <> generate_uuid()
  let intray_dir = base <> "/intray"
  let sources_dir = base <> "/sources"
  let indexes_dir = base <> "/indexes"
  let _ = simplifile.create_directory_all(intray_dir)
  let _ = simplifile.write(intray_dir <> "/test-doc.md", "# Test\n\nContent.")
  let count = intake.process(base, intray_dir, sources_dir, indexes_dir)
  count |> should.equal(1)
  case simplifile.read_directory(intray_dir) {
    Ok(files) -> list.length(files) |> should.equal(0)
    Error(_) -> Nil
  }
  let docs = knowledge_log.read_all(base)
  list.length(docs) |> should.equal(1)
  let _ = simplifile.delete(base)
  Nil
}

pub fn intake_skip_non_markdown_test() {
  let base = "/tmp/springdrift_test_intake2_" <> generate_uuid()
  let intray_dir = base <> "/intray"
  let _ = simplifile.create_directory_all(intray_dir)
  let _ = simplifile.write(intray_dir <> "/image.png", "binary data")
  let count =
    intake.process(base, intray_dir, base <> "/sources", base <> "/indexes")
  count |> should.equal(0)
  let _ = simplifile.delete(base)
  Nil
}

pub fn intake_empty_dir_test() {
  let base = "/tmp/springdrift_test_intake3_" <> generate_uuid()
  let count =
    intake.process(
      base,
      base <> "/intray",
      base <> "/sources",
      base <> "/indexes",
    )
  count |> should.equal(0)
}

pub fn draft_create_and_read_test() {
  let dir = "/tmp/springdrift_test_drafts_" <> generate_uuid()
  workspace.write_draft(dir, "q2-report", "# Q2 Analysis\n\nDraft.")
  |> should.be_ok
  let assert Ok(content) = workspace.read_draft(dir, "q2-report")
  string.contains(content, "Q2 Analysis") |> should.be_true
  let drafts = workspace.list_drafts(dir)
  list.length(drafts) |> should.equal(1)
  let _ = simplifile.delete(dir)
  Nil
}
