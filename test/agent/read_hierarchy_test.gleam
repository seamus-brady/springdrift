//// Phase 5 tests — read_hierarchy tool declaration is correctly wired
//// into the specialist tool set. End-to-end rendering (which requires a
//// running librarian + DAG state) is covered by scenario tests rather
//// than unit tests.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dag/types as dag_types
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import narrative/librarian
import simplifile
import tools/builtin

pub fn read_hierarchy_tool_in_agent_tools_test() {
  let names =
    builtin.agent_tools()
    |> list.map(fn(t) { t.name })
  names |> list.contains("read_hierarchy") |> should.be_true
}

pub fn read_hierarchy_not_required_for_orchestrator_test() {
  // The orchestrator sits at the top of hierarchies it creates — it
  // already knows what it dispatched. Only specialists need to see
  // sideways across peer delegations. `builtin.all()` includes the
  // cognitive-loop superset (human_input etc.) but not read_hierarchy;
  // that's fine.
  let cognitive_names =
    builtin.all()
    |> list.map(fn(t) { t.name })
  cognitive_names |> list.contains("request_human_input") |> should.be_true
}

pub fn read_hierarchy_tool_has_scope_enum_test() {
  let tool = builtin.read_hierarchy_tool()
  tool.name |> should.equal("read_hierarchy")
  // Look up the "scope" parameter and verify it's an enum with expected
  // values.
  case list.find(tool.parameters, fn(p) { p.0 == "scope" }) {
    Ok(#(_, schema)) -> {
      case schema.enum_values {
        Some(vals) -> {
          vals |> list.contains("siblings") |> should.be_true
          vals |> list.contains("ancestors") |> should.be_true
          vals |> list.contains("full") |> should.be_true
        }
        _ -> should.fail()
      }
      // scope is NOT in required_params (default is "siblings")
      tool.required_params |> list.contains("scope") |> should.be_false
    }
    Error(_) -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// End-to-end: index a small DAG in the librarian, then verify get_subtree
// returns it correctly. Sanity check for the whole Phase 5 query path.
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/springdrift_test_hierarchy_" <> suffix
  let _ = simplifile.delete(dir)
  let _ = simplifile.create_directory_all(dir)
  dir
}

fn make_node(
  cycle_id: String,
  parent_id: option.Option(String),
  node_type: dag_types.CycleNodeType,
) -> dag_types.CycleNode {
  dag_types.CycleNode(
    cycle_id: cycle_id,
    parent_id: parent_id,
    node_type: node_type,
    timestamp: "2026-04-24T10:00:00",
    outcome: dag_types.NodeSuccess,
    model: "test-model",
    complexity: "test",
    tool_calls: [],
    dprime_gates: [],
    tokens_in: 100,
    tokens_out: 50,
    duration_ms: 1000,
    agent_output: None,
    instance_name: "test",
    instance_id: "tst12345",
  )
}

pub fn get_subtree_returns_indexed_node_with_children_test() {
  let dir = test_dir("subtree")
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      dir <> "/planner",
      0,
      librarian.default_cbr_config(),
    )

  // Build a small DAG: cognitive → two agent children
  let parent = make_node("cyc-root", None, dag_types.CognitiveCycle)
  let child_a = make_node("cyc-a", Some("cyc-root"), dag_types.AgentCycle)
  let child_b = make_node("cyc-b", Some("cyc-root"), dag_types.AgentCycle)
  process.send(lib, librarian.IndexNode(node: parent))
  process.send(lib, librarian.IndexNode(node: child_a))
  process.send(lib, librarian.IndexNode(node: child_b))

  // Query parent's subtree — should contain both children.
  case librarian.get_subtree(lib, "cyc-root") {
    Ok(subtree) -> {
      subtree.root.cycle_id |> should.equal("cyc-root")
      list.length(subtree.children) |> should.equal(2)
    }
    Error(_) -> should.fail()
  }

  // Query one child — subtree is a leaf.
  case librarian.get_subtree(lib, "cyc-a") {
    Ok(subtree) -> {
      subtree.root.cycle_id |> should.equal("cyc-a")
      list.length(subtree.children) |> should.equal(0)
    }
    Error(_) -> should.fail()
  }

  // Query non-existent cycle — Error.
  case librarian.get_subtree(lib, "cyc-missing") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }

  process.send(lib, librarian.Shutdown)
  let _ = simplifile.delete(dir)
  Nil
}
