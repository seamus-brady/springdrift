import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import narrative/cycle_tree
import narrative/types.{
  type NarrativeEntry, Conversation, Entities, Intent, Metrics, Narrative,
  NarrativeEntry, Outcome, Success,
}

fn make_entry(cycle_id: String, parent: option.Option(String)) -> NarrativeEntry {
  NarrativeEntry(
    schema_version: 1,
    cycle_id:,
    parent_cycle_id: parent,
    timestamp: "2026-03-06T12:00:00Z",
    entry_type: Narrative,
    summary: "Entry " <> cycle_id,
    intent: Intent(classification: Conversation, description: "", domain: ""),
    outcome: Outcome(status: Success, confidence: 1.0, assessment: ""),
    delegation_chain: [],
    decisions: [],
    keywords: [],
    topics: [],
    entities: Entities(
      locations: [],
      organisations: [],
      data_points: [],
      temporal_references: [],
    ),
    sources: [],
    thread: None,
    metrics: Metrics(
      total_duration_ms: 0,
      input_tokens: 0,
      output_tokens: 0,
      thinking_tokens: 0,
      tool_calls: 0,
      agent_delegations: 0,
      dprime_evaluations: 0,
      model_used: "",
    ),
    observations: [],
  )
}

// ---------------------------------------------------------------------------
// build
// ---------------------------------------------------------------------------

pub fn build_empty_test() {
  cycle_tree.build([])
  |> should.equal([])
}

pub fn build_single_root_test() {
  let e = make_entry("root", None)
  let nodes = cycle_tree.build([e])
  list.length(nodes) |> should.equal(1)
  let assert [node] = nodes
  node.entry.cycle_id |> should.equal("root")
  node.children |> should.equal([])
}

pub fn build_parent_child_test() {
  let parent = make_entry("p1", None)
  let child = make_entry("c1", Some("p1"))
  let nodes = cycle_tree.build([parent, child])

  list.length(nodes) |> should.equal(1)
  let assert [root] = nodes
  root.entry.cycle_id |> should.equal("p1")
  list.length(root.children) |> should.equal(1)
  let assert [child_node] = root.children
  child_node.entry.cycle_id |> should.equal("c1")
}

pub fn build_multiple_children_test() {
  let parent = make_entry("p1", None)
  let c1 = make_entry("c1", Some("p1"))
  let c2 = make_entry("c2", Some("p1"))
  let nodes = cycle_tree.build([parent, c1, c2])

  let assert [root] = nodes
  list.length(root.children) |> should.equal(2)
}

pub fn build_deep_nesting_test() {
  let root = make_entry("r", None)
  let mid = make_entry("m", Some("r"))
  let leaf = make_entry("l", Some("m"))
  let nodes = cycle_tree.build([root, mid, leaf])

  let assert [root_node] = nodes
  let assert [mid_node] = root_node.children
  let assert [leaf_node] = mid_node.children
  leaf_node.entry.cycle_id |> should.equal("l")
  leaf_node.children |> should.equal([])
}

pub fn build_multiple_roots_test() {
  let r1 = make_entry("r1", None)
  let r2 = make_entry("r2", None)
  let c1 = make_entry("c1", Some("r1"))
  let nodes = cycle_tree.build([r1, r2, c1])

  list.length(nodes) |> should.equal(2)
}

pub fn build_orphan_becomes_root_test() {
  // Child whose parent is not in the set becomes a root
  let orphan = make_entry("orphan", Some("nonexistent"))
  let nodes = cycle_tree.build([orphan])

  list.length(nodes) |> should.equal(1)
  let assert [node] = nodes
  node.entry.cycle_id |> should.equal("orphan")
}

// ---------------------------------------------------------------------------
// flatten
// ---------------------------------------------------------------------------

pub fn flatten_preserves_order_test() {
  let root = make_entry("r", None)
  let c1 = make_entry("c1", Some("r"))
  let c2 = make_entry("c2", Some("r"))
  let nodes = cycle_tree.build([root, c1, c2])
  let flat = cycle_tree.flatten(nodes)

  list.length(flat) |> should.equal(3)
  let assert [first, ..] = flat
  first.cycle_id |> should.equal("r")
}

// ---------------------------------------------------------------------------
// depth
// ---------------------------------------------------------------------------

pub fn depth_leaf_test() {
  let e = make_entry("leaf", None)
  let nodes = cycle_tree.build([e])
  let assert [node] = nodes
  cycle_tree.depth(node) |> should.equal(0)
}

pub fn depth_nested_test() {
  let root = make_entry("r", None)
  let mid = make_entry("m", Some("r"))
  let leaf = make_entry("l", Some("m"))
  let nodes = cycle_tree.build([root, mid, leaf])
  let assert [node] = nodes
  cycle_tree.depth(node) |> should.equal(2)
}

// ---------------------------------------------------------------------------
// find
// ---------------------------------------------------------------------------

pub fn find_existing_test() {
  let root = make_entry("r", None)
  let child = make_entry("c1", Some("r"))
  let nodes = cycle_tree.build([root, child])

  case cycle_tree.find(nodes, "c1") {
    Some(node) -> node.entry.cycle_id |> should.equal("c1")
    None -> should.fail()
  }
}

pub fn find_missing_test() {
  let root = make_entry("r", None)
  let nodes = cycle_tree.build([root])
  cycle_tree.find(nodes, "nonexistent") |> should.equal(None)
}
