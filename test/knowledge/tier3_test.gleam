//// Tier 3 LLM reasoning retrieval tests.
////
//// Uses a fake reason_fn so these tests run without a real LLM. The
//// fake implements a deterministic policy: return a canned reply
//// containing known node IDs. Exercises:
////
//// - reason_over_documents returns nodes whose IDs appear in the
////   reason_fn reply
//// - gibberish / error replies yield empty results (no hallucination)
//// - the max_results cap is respected
//// - run_search_library auto-escalates when tiers 1/2 return nothing
////   AND reason_fn is set
//// - mode=reasoning skips tiers 1/2 and goes straight to tier 3

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import knowledge/indexer
import knowledge/log as knowledge_log
import knowledge/search
import knowledge/types.{
  type DocumentMeta, type TreeNode, Create, DocumentMeta, Normalised, Source,
}
import llm/adapters/mock
import llm/types as llm_types
import simplifile
import tools/knowledge as knowledge_tools

fn test_root(suffix: String) -> String {
  let root = "/tmp/springdrift_test_tier3_" <> suffix
  let _ = simplifile.delete(root)
  let _ = simplifile.create_directory_all(root)
  let _ = simplifile.create_directory_all(root <> "/indexes")
  root
}

fn make_cfg(
  root: String,
  reason_fn: option.Option(fn(String) -> Result(String, String)),
) -> knowledge_tools.KnowledgeConfig {
  knowledge_tools.KnowledgeConfig(
    knowledge_dir: root,
    indexes_dir: root <> "/indexes",
    sources_dir: root <> "/sources",
    journal_dir: root <> "/journal",
    notes_dir: root <> "/notes",
    drafts_dir: root <> "/drafts",
    exports_dir: root <> "/exports",
    embed_fn: None,
    reason_fn: reason_fn,
  )
}

/// Descend to the first leaf (no children) in a tree. The indexer
/// wraps content under a synthetic "Document" root; most tests want
/// the deepest section (e.g. H2 title), not the root or the H1.
fn first_leaf_id(node: TreeNode) -> String {
  case node.children {
    [] -> node.id
    [c, ..] -> first_leaf_id(c)
  }
}

fn index_sample_doc(
  root: String,
  doc_id: String,
  title: String,
  content: String,
) -> DocumentMeta {
  let idx = indexer.index_markdown(doc_id, content)
  indexer.save_index(root <> "/indexes", idx)
  let meta =
    DocumentMeta(
      op: Create,
      doc_id: doc_id,
      doc_type: Source,
      domain: "test",
      title: title,
      path: "sources/test/" <> doc_id <> ".md",
      status: Normalised,
      content_hash: "",
      node_count: idx.node_count,
      created_at: "2026-04-24",
      updated_at: "2026-04-24",
      source_url: None,
      version: 1,
    )
  knowledge_log.append(root, meta)
  meta
}

// ---------------------------------------------------------------------------
// reason_over_documents — direct unit tests
// ---------------------------------------------------------------------------

pub fn reason_picks_nodes_whose_ids_appear_in_reply_test() {
  let root = test_root("picks")
  let _ =
    index_sample_doc(
      root,
      "d1",
      "Project Plan",
      "# Project Plan\n\n## Phase One\nFoo.\n\n## Phase Two\nBar.\n",
    )

  // Load the index so we know a real node ID to return.
  let assert Ok(idx) = indexer.load_index(root <> "/indexes", "d1")
  let all_nodes = list.flat_map(idx.root.children, fn(n) { [n, ..n.children] })
  let assert [first_node, ..] = all_nodes
  let target_id = first_node.id

  // Fake reason_fn returns a reply mentioning the target node id.
  let fake_rf = fn(_prompt) {
    Ok("The most relevant section is " <> target_id <> "\n")
  }
  let docs = knowledge_log.resolve(root)

  let results =
    search.reason_over_documents("phase", docs, root <> "/indexes", fake_rf, 5)

  // Should return exactly the node with target_id.
  case results {
    [r] -> r.node_title |> should.equal(first_node.title)
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn reason_returns_empty_when_reply_is_gibberish_test() {
  let root = test_root("gibberish")
  let _ = index_sample_doc(root, "d1", "Doc", "# Doc\n\nContent.\n")

  // Reply doesn't mention any real node ID — must return nothing
  // rather than hallucinate.
  let fake_rf = fn(_prompt) { Ok("I have no idea, here is some prose.") }
  let docs = knowledge_log.resolve(root)

  let results =
    search.reason_over_documents(
      "anything",
      docs,
      root <> "/indexes",
      fake_rf,
      5,
    )
  results |> should.equal([])

  let _ = simplifile.delete(root)
  Nil
}

pub fn reason_returns_empty_when_reason_fn_errors_test() {
  let root = test_root("errors")
  let _ = index_sample_doc(root, "d1", "Doc", "# Doc\n\nContent.\n")

  let fake_rf = fn(_prompt) { Error("model unavailable") }
  let docs = knowledge_log.resolve(root)

  let results =
    search.reason_over_documents(
      "anything",
      docs,
      root <> "/indexes",
      fake_rf,
      5,
    )
  results |> should.equal([])

  let _ = simplifile.delete(root)
  Nil
}

pub fn reason_respects_max_results_cap_test() {
  let root = test_root("cap")
  let _ =
    index_sample_doc(
      root,
      "d1",
      "Multi",
      "# Multi\n\n## A\nAA\n\n## B\nBB\n\n## C\nCC\n\n## D\nDD\n",
    )

  // Load index to grab IDs of all leaf nodes.
  let assert Ok(idx) = indexer.load_index(root <> "/indexes", "d1")
  let leaves =
    idx.root.children
    |> list.flat_map(fn(c) { [c, ..c.children] })
  let all_ids = list.map(leaves, fn(n) { n.id })
  // Reply mentions every node id — reason_over_documents must still
  // honour max_results.
  let fake_rf = fn(_prompt) { Ok(string.join(all_ids, "\n")) }
  let docs = knowledge_log.resolve(root)

  let results =
    search.reason_over_documents(
      "anything",
      docs,
      root <> "/indexes",
      fake_rf,
      2,
    )
  list.length(results) |> should.equal(2)

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// run_search_library — integration via the tool dispatch
// ---------------------------------------------------------------------------

fn make_tool_call(input: String) -> llm_types.ToolCall {
  llm_types.ToolCall(id: "t", name: "search_library", input_json: input)
}

pub fn search_auto_escalates_to_tier3_when_keyword_empty_test() {
  let root = test_root("escalate")
  let _ =
    index_sample_doc(
      root,
      "d1",
      "Manual",
      "# Manual\n\n## Installation\nLong install steps here.\n",
    )

  // Fake reason_fn picks the deepest leaf node (should be
  // "Installation") so the result's node_title actually matches
  // what we assert below.
  let assert Ok(idx) = indexer.load_index(root <> "/indexes", "d1")
  let target_node_id = first_leaf_id(idx.root)
  let fake_rf = fn(_prompt) { Ok(target_node_id) }

  let cfg = make_cfg(root, Some(fake_rf))

  // Query with zero keyword or content overlap so keyword tier
  // definitely returns empty. Should escalate to tier 3.
  let result =
    knowledge_tools.execute(
      make_tool_call(
        "{\"query\":\"completely unrelated term xyzzy\",\"mode\":\"keyword\"}",
      ),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      // Tier 3 picked the Installation node — its content should
      // appear in the result.
      content |> string.contains("Installation") |> should.be_true
    }
    llm_types.ToolFailure(..) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn search_does_not_escalate_when_reason_fn_is_none_test() {
  let root = test_root("no_escalation")
  let _ = index_sample_doc(root, "d1", "Doc", "# Doc\n\nContent.\n")

  let cfg = make_cfg(root, None)

  // Zero-overlap query; no reason_fn; should return "No results found".
  let result =
    knowledge_tools.execute(
      make_tool_call("{\"query\":\"xyzzy-no-match\",\"mode\":\"keyword\"}"),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) ->
      content |> string.contains("No results") |> should.be_true
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn mode_reasoning_goes_straight_to_tier3_test() {
  let root = test_root("explicit")
  let _ =
    index_sample_doc(
      root,
      "d1",
      "Manual",
      "# Manual\n\n## Setup\nSetup steps.\n",
    )

  let assert Ok(idx) = indexer.load_index(root <> "/indexes", "d1")
  let target_node_id = first_leaf_id(idx.root)
  let fake_rf = fn(_prompt) { Ok(target_node_id) }
  let cfg = make_cfg(root, Some(fake_rf))

  // Query that WOULD match the keyword tier, but mode=reasoning
  // forces tier 3 anyway. Result should come from our fake_rf pick.
  let result =
    knowledge_tools.execute(
      make_tool_call("{\"query\":\"setup\",\"mode\":\"reasoning\"}"),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) ->
      content |> string.contains("Setup") |> should.be_true
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn mode_reasoning_with_no_reason_fn_falls_back_cleanly_test() {
  let root = test_root("reasoning_fallback")
  let _ =
    index_sample_doc(
      root,
      "d1",
      "Manual",
      "# Manual\n\n## Overview\nSome overview content.\n",
    )

  // mode=reasoning but no reason_fn configured — should fall back to
  // embedding/keyword so the caller gets something rather than an
  // opaque empty reply.
  let cfg = make_cfg(root, None)
  let result =
    knowledge_tools.execute(
      make_tool_call("{\"query\":\"overview\",\"mode\":\"reasoning\"}"),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) ->
      content |> string.contains("Overview") |> should.be_true
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// make_reason_fn — provider/model → closure
// ---------------------------------------------------------------------------

pub fn make_reason_fn_returns_response_text_test() {
  // Mock provider returns a fixed string. The closure should pass
  // through the provider's reply text unchanged.
  let provider = mock.provider_with_text("node-id-42 is the answer")
  let rf = search.make_reason_fn(provider, "test-model")
  case rf("any prompt") {
    Ok(text) -> text |> should.equal("node-id-42 is the answer")
    Error(_) -> should.fail()
  }
}

pub fn make_reason_fn_propagates_provider_errors_test() {
  // When the provider errors, the closure must return Error so
  // reason_over_documents can degrade to zero results gracefully.
  let provider = mock.provider_with_error("model unavailable")
  let rf = search.make_reason_fn(provider, "test-model")
  case rf("any prompt") {
    Error(reason) ->
      reason |> string.contains("model unavailable") |> should.be_true
    Ok(_) -> should.fail()
  }
}

pub fn make_reason_fn_integrates_with_reason_over_documents_test() {
  // End-to-end: a real KnowledgeConfig wired through make_reason_fn
  // and the mock provider should pick the leaf node whose ID the
  // mock returns. This validates the whole closure pipeline that
  // ships when an agent's executor builds the config.
  let root = test_root("reason_fn_integration")
  let _ =
    index_sample_doc(root, "d1", "Manual", "# Manual\n\n## Setup\nDetails.\n")
  let assert Ok(idx) = indexer.load_index(root <> "/indexes", "d1")
  let target_id = first_leaf_id(idx.root)
  let provider = mock.provider_with_text(target_id)
  let rf = search.make_reason_fn(provider, "test-model")
  let cfg = make_cfg(root, Some(rf))
  let result =
    knowledge_tools.execute(
      make_tool_call("{\"query\":\"setup\",\"mode\":\"reasoning\"}"),
      cfg,
    )
  case result {
    llm_types.ToolSuccess(content:, ..) ->
      content |> string.contains("Setup") |> should.be_true
    _ -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}
