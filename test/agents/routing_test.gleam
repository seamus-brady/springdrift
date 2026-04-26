//// Routing-coverage tests for agent executors.
////
//// The bug class: an agent declares a tool in its `spec(...)` tool list,
//// but the executor's `case call.name { ... }` doesn't have a branch for
//// it. The LLM emits a tool_use, the dispatcher falls through to
//// `builtin.execute(...)`, which doesn't know the name, and returns
//// "Unknown tool: <name>" — or, on the cognitive loop, drops the
//// tool_use entirely and lands the user on a half-finished cycle.
////
//// This test asserts that every tool name an agent's spec exposes to the
//// LLM is claimed by some routing branch. Each agent's `routes_tool(name)`
//// predicate documents its routing surface; the test iterates each agent's
//// tool list and asserts the predicate holds for every name. If a tool is
//// added without registering a branch, the test fails with the offending
//// name.
////
//// Caught — and now prevents — three real bugs:
////  1. read_skill on the cog loop fell through dispatch_tool_calls and
////     was silently dropped (preamble text replied, tool_use orphaned).
////  2. researcher executor only matched 4 hardcoded knowledge-tool names;
////     PR #162's document_info / list_sections / read_section_by_id /
////     read_range had no branch and returned "Unknown tool".
////  3. writer executor only matched create/update/promote_draft;
////     read_draft and export_pdf returned "Unknown tool".

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agents/researcher
import agents/writer
import gleam/list
import gleeunit/should
import llm/types as llm_types
import tools/artifacts
import tools/brave
import tools/builtin
import tools/jina
import tools/kagi
import tools/knowledge as knowledge_tools
import tools/web

// ---------------------------------------------------------------------------
// Researcher
// ---------------------------------------------------------------------------

/// Build the full researcher tool list as `spec(...)` would assemble
/// it. Mirrors the `list.flatten` in researcher.spec — without
/// requiring a real Provider / Librarian Subject / etc. just to read
/// tool names.
fn researcher_tool_names(kagi_enabled: Bool) -> List(String) {
  let kagi_tools = case kagi_enabled {
    True -> kagi.all()
    False -> []
  }
  [
    knowledge_tools.researcher_tools(),
    brave.all(),
    jina.all(),
    web.all(),
    kagi_tools,
    artifacts.all(),
    builtin.agent_tools(),
  ]
  |> list.flatten
  |> list.map(fn(t: llm_types.Tool) { t.name })
}

pub fn researcher_no_orphan_tools_kagi_off_test() {
  let names = researcher_tool_names(False)
  list.each(names, fn(n) {
    case researcher.routes_tool(n) {
      True -> Nil
      False -> {
        echo "Orphan tool in researcher (kagi off): " <> n
        should.fail()
      }
    }
  })
}

pub fn researcher_no_orphan_tools_kagi_on_test() {
  let names = researcher_tool_names(True)
  list.each(names, fn(n) {
    case researcher.routes_tool(n) {
      True -> Nil
      False -> {
        echo "Orphan tool in researcher (kagi on): " <> n
        should.fail()
      }
    }
  })
}

pub fn researcher_routes_new_document_library_tools_test() {
  // Targeted regression guard for PR #162: the four new tools must
  // route, otherwise calling them returns "Unknown tool" and the
  // researcher silently fails — exactly the bug this branch fixes.
  researcher.routes_tool("document_info") |> should.be_true
  researcher.routes_tool("list_sections") |> should.be_true
  researcher.routes_tool("read_section_by_id") |> should.be_true
  researcher.routes_tool("read_range") |> should.be_true
}

pub fn researcher_does_not_route_unknown_test() {
  // Sanity check the predicate isn't accidentally returning True
  // for everything (which would mask the bug).
  researcher.routes_tool("definitely_not_a_real_tool") |> should.be_false
}

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

fn writer_tool_names() -> List(String) {
  [
    knowledge_tools.writer_tools(),
    artifacts.all(),
    builtin.agent_tools(),
  ]
  |> list.flatten
  |> list.map(fn(t: llm_types.Tool) { t.name })
}

pub fn writer_no_orphan_tools_test() {
  let names = writer_tool_names()
  list.each(names, fn(n) {
    case writer.routes_tool(n) {
      True -> Nil
      False -> {
        echo "Orphan tool in writer: " <> n
        should.fail()
      }
    }
  })
}

pub fn writer_routes_read_draft_and_export_pdf_test() {
  // Targeted regression guard: read_draft and export_pdf shipped in
  // writer_tools() but the previous executor only matched
  // create/update/promote.
  writer.routes_tool("read_draft") |> should.be_true
  writer.routes_tool("export_pdf") |> should.be_true
}

// ---------------------------------------------------------------------------
// Cognitive loop builtin tools
// ---------------------------------------------------------------------------

pub fn cog_loop_read_skill_is_partitioned_test() {
  // The cog loop's dispatch_tool_calls partitions calls into buckets
  // (memory / planner / knowledge / learning_goal / strategy /
  // captures / cog_builtin) and dispatches each bucket. read_skill
  // must be in is_cog_builtin_tool — without it, read_skill falls
  // through to dispatch_agent_calls, which sees no agent_/team_
  // prefix and silently drops the tool_use.
  builtin.is_cog_builtin_tool("read_skill") |> should.be_true
}

pub fn cog_loop_builtin_predicate_does_not_overmatch_test() {
  // Sanity check.
  builtin.is_cog_builtin_tool("not_a_tool") |> should.be_false
  // request_human_input is a cog-loop tool too, but it's handled by
  // a separate early branch in dispatch_tool_calls (it pauses the
  // loop on a question rather than running synchronously). It must
  // NOT be in is_cog_builtin_tool or it would get incorrectly
  // routed through handle_memory_tools.
  builtin.is_cog_builtin_tool("request_human_input") |> should.be_false
}

pub fn read_skill_executes_via_builtin_test() {
  // End-to-end smoke test for the executor side — confirms that once
  // the partition routes read_skill into builtin.execute, the call
  // actually returns something other than "Unknown tool". Uses an
  // empty skills_dirs list which makes the read fail, but with a
  // path-not-found error rather than the unknown-tool error.
  let call =
    llm_types.ToolCall(
      id: "t",
      name: "read_skill",
      input_json: "{\"path\":\"some-skill\"}",
    )
  let result = builtin.execute(call, [])
  case result {
    llm_types.ToolFailure(error:, ..) -> {
      // The error message must NOT be the "Unknown tool" one. Any
      // other failure (file not found, path validation, etc.) is
      // proof the dispatcher routed read_skill to a real branch.
      let is_unknown_tool_error = case error {
        e -> {
          let lower = e
          lower
          |> should.not_equal("Unknown tool: read_skill")
        }
      }
      is_unknown_tool_error
    }
    llm_types.ToolSuccess(..) -> Nil
  }
}
