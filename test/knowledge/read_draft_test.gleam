//// Tests for the read_draft tool — the missing piece of the writer's
//// revise-existing-draft workflow. Writer had create/update/promote
//// but no read-my-own-draft, which meant any "revise" request was
//// blind.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import llm/types as llm_types
import simplifile
import tools/knowledge as knowledge_tools

fn test_root(suffix: String) -> String {
  let root = "/tmp/springdrift_test_readdraft_" <> suffix
  let _ = simplifile.delete(root)
  let _ = simplifile.create_directory_all(root)
  let _ = simplifile.create_directory_all(root <> "/drafts")
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

fn call(name: String, input: String) -> llm_types.ToolCall {
  llm_types.ToolCall(id: "t", name: name, input_json: input)
}

pub fn read_draft_returns_content_test() {
  let root = test_root("basic")
  let cfg = make_cfg(root)
  // Create via the tool so we exercise the full path, not just the
  // underlying workspace function.
  let _ =
    knowledge_tools.execute(
      call(
        "create_draft",
        "{\"slug\":\"report\",\"content\":\"# Title\\n\\nBody.\"}",
      ),
      cfg,
    )

  let result =
    knowledge_tools.execute(call("read_draft", "{\"slug\":\"report\"}"), cfg)

  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      content |> string.contains("# Title") |> should.be_true
      content |> string.contains("Body.") |> should.be_true
    }
    llm_types.ToolFailure(..) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn read_draft_missing_returns_clean_error_test() {
  let root = test_root("missing")
  let cfg = make_cfg(root)

  let result =
    knowledge_tools.execute(call("read_draft", "{\"slug\":\"nope\"}"), cfg)

  case result {
    llm_types.ToolFailure(error:, ..) ->
      error |> string.contains("not found") |> should.be_true
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn read_draft_requires_slug_test() {
  let root = test_root("noslug")
  let cfg = make_cfg(root)

  let result = knowledge_tools.execute(call("read_draft", "{}"), cfg)

  case result {
    llm_types.ToolFailure(error:, ..) ->
      error |> string.contains("Missing slug") |> should.be_true
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Full revise flow — read_draft → produce revision → update_draft
// Simulates what the writer would do when handed a draft_slug ref.
// ---------------------------------------------------------------------------

pub fn revise_flow_preserves_unchanged_content_test() {
  let root = test_root("revise_flow")
  let cfg = make_cfg(root)

  // Initial draft: two sections.
  let initial = "# Report\n\n## Findings\n\nA, B, C.\n\n## Next Steps\n\nTBD.\n"
  let _ =
    knowledge_tools.execute(
      call(
        "create_draft",
        "{\"slug\":\"quarterly\",\"content\":\""
          <> escape_json(initial)
          <> "\"}",
      ),
      cfg,
    )

  // Simulate the writer's revise flow: read, then write back with
  // updated "Next Steps" but unchanged Findings.
  let read_result =
    knowledge_tools.execute(call("read_draft", "{\"slug\":\"quarterly\"}"), cfg)
  case read_result {
    llm_types.ToolSuccess(content:, ..) -> {
      content |> string.contains("A, B, C") |> should.be_true
    }
    _ -> should.fail()
  }

  let revised =
    "# Report\n\n## Findings\n\nA, B, C.\n\n## Next Steps\n\nPublish by Friday.\n"
  let _ =
    knowledge_tools.execute(
      call(
        "update_draft",
        "{\"slug\":\"quarterly\",\"content\":\""
          <> escape_json(revised)
          <> "\"}",
      ),
      cfg,
    )

  // Read again — must contain new Next Steps and unchanged Findings.
  case
    knowledge_tools.execute(call("read_draft", "{\"slug\":\"quarterly\"}"), cfg)
  {
    llm_types.ToolSuccess(content:, ..) -> {
      content |> string.contains("Publish by Friday") |> should.be_true
      content |> string.contains("A, B, C") |> should.be_true
    }
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

fn escape_json(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
}

// ---------------------------------------------------------------------------
// Tool registration
// ---------------------------------------------------------------------------

pub fn writer_tools_include_read_draft_test() {
  let names =
    knowledge_tools.writer_tools()
    |> list.map(fn(t) { t.name })
  names |> list.contains("read_draft") |> should.be_true
  names |> list.contains("create_draft") |> should.be_true
  names |> list.contains("update_draft") |> should.be_true
  names |> list.contains("promote_draft") |> should.be_true
}
