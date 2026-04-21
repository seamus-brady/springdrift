//// DAG store — operational telemetry per cognitive cycle.
////
//// Owns three ETS tables:
////   - dag_nodes      (set)  — cycle_id   → CycleNode (authoritative)
////   - dag_by_parent  (bag)  — parent_id  → CycleNode (traversal)
////   - dag_by_date    (bag)  — YYYY-MM-DD → CycleNode (day queries)
////
//// The set table holds the authoritative copy; bag tables are populated
//// once on index and are *not* updated on merges — day queries dedupe via
//// set lookup. Populated lazily from `cycle_log.load_cycles_for_date` when
//// a day has no in-memory entries.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cycle_log
import dag/types as dag_types
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import simplifile

pub type Table

@external(erlang, "store_ffi", "new_unique_table")
pub fn new_table(name: String, table_type: String) -> Table

@external(erlang, "store_ffi", "delete_table")
pub fn delete_table(table: Table) -> Nil

@external(erlang, "store_ffi", "insert")
pub fn insert(table: Table, key: String, value: dag_types.CycleNode) -> Nil

@external(erlang, "store_ffi", "lookup")
pub fn lookup(table: Table, key: String) -> Result(dag_types.CycleNode, Nil)

@external(erlang, "store_ffi", "lookup_bag")
pub fn lookup_bag(table: Table, key: String) -> List(dag_types.CycleNode)

@external(erlang, "store_ffi", "all_values")
pub fn all_values(table: Table) -> List(dag_types.CycleNode)

@external(erlang, "store_ffi", "delete_key")
pub fn delete_key(table: Table, key: String) -> Nil

// ---------------------------------------------------------------------------
// Indexing
// ---------------------------------------------------------------------------

/// Insert a node across all three tables: primary by cycle_id, parent edge,
/// and date bucket. Idempotent on the set table; bags may accumulate
/// duplicates which `query_day` deduplicates on read.
pub fn index_node(
  dag_nodes: Table,
  dag_by_parent: Table,
  dag_by_date: Table,
  node: dag_types.CycleNode,
) -> Nil {
  insert(dag_nodes, node.cycle_id, node)

  let parent_key = case node.parent_id {
    Some(pid) -> pid
    None -> "root"
  }
  insert(dag_by_parent, parent_key, node)

  let date_key = string.slice(node.timestamp, 0, 10)
  insert(dag_by_date, date_key, node)
  Nil
}

/// Merge an UpdateNode onto the existing set entry. Non-empty fields on the
/// incoming node replace the existing value; empty/zero fields are kept
/// from the existing record so callers can partial-update without losing
/// already-populated data. If no existing node, also seeds the bag tables.
pub fn apply_update(
  dag_nodes: Table,
  dag_by_parent: Table,
  dag_by_date: Table,
  node: dag_types.CycleNode,
) -> Nil {
  let merged = case lookup(dag_nodes, node.cycle_id) {
    Ok(existing) ->
      dag_types.CycleNode(
        ..existing,
        outcome: node.outcome,
        model: case node.model {
          "" -> existing.model
          m -> m
        },
        tokens_in: case node.tokens_in {
          0 -> existing.tokens_in
          t -> t
        },
        tokens_out: case node.tokens_out {
          0 -> existing.tokens_out
          t -> t
        },
        duration_ms: case node.duration_ms {
          0 -> existing.duration_ms
          d -> d
        },
        tool_calls: case node.tool_calls {
          [] -> existing.tool_calls
          tc -> tc
        },
        dprime_gates: case node.dprime_gates {
          [] -> existing.dprime_gates
          g -> g
        },
        agent_output: case node.agent_output {
          None -> existing.agent_output
          some -> some
        },
      )
    Error(_) -> {
      // New node — also index in bag tables so dag_by_date queries find it.
      let date_key = string.slice(node.timestamp, 0, 10)
      insert(dag_by_date, date_key, node)
      let parent_key = case node.parent_id {
        Some(pid) -> pid
        None -> "root"
      }
      insert(dag_by_parent, parent_key, node)
      node
    }
  }
  insert(dag_nodes, merged.cycle_id, merged)
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/// Return all nodes for a given `YYYY-MM-DD`. Lazy-loads from cycle log
/// files on first access. Deduplicates by cycle_id via the authoritative
/// set table.
pub fn query_day(
  dag_nodes: Table,
  dag_by_parent: Table,
  dag_by_date: Table,
  date: String,
) -> List(dag_types.CycleNode) {
  let results = lookup_bag(dag_by_date, date)
  case results {
    [] -> {
      let cycles = cycle_log.load_cycles_for_date(date)
      case cycles {
        [] -> []
        _ -> {
          let nodes = list.map(cycles, cycle_data_to_node)
          list.each(nodes, fn(n) {
            index_node(dag_nodes, dag_by_parent, dag_by_date, n)
          })
          nodes
        }
      }
    }
    found -> {
      let unique_ids = list.map(found, fn(n) { n.cycle_id }) |> list.unique()
      list.filter_map(unique_ids, fn(id) {
        case lookup(dag_nodes, id) {
          Ok(node) -> Ok(node)
          Error(_) -> Error(Nil)
        }
      })
    }
  }
}

/// Build a recursive subtree rooted at `root`, using the parent-edge bag.
pub fn build_subtree(
  dag_by_parent: Table,
  root: dag_types.CycleNode,
) -> dag_types.DagSubtree {
  let children = lookup_bag(dag_by_parent, root.cycle_id)
  let child_trees =
    list.map(children, fn(c) { build_subtree(dag_by_parent, c) })
  dag_types.DagSubtree(root:, children: child_trees)
}

/// Aggregate daily stats — cycle counts, token totals, tool-failure rate,
/// models used, gate decisions, per-agent failures.
pub fn day_stats(
  dag_nodes: Table,
  dag_by_parent: Table,
  dag_by_date: Table,
  date: String,
) -> dag_types.DayStats {
  let all = query_day(dag_nodes, dag_by_parent, dag_by_date, date)
  let success_count =
    list.count(all, fn(n) { n.outcome == dag_types.NodeSuccess })
  let partial_count =
    list.count(all, fn(n) { n.outcome == dag_types.NodePartial })
  let failure_count =
    list.count(all, fn(n) {
      case n.outcome {
        dag_types.NodeFailure(_) -> True
        _ -> False
      }
    })
  let total_tokens_in = list.fold(all, 0, fn(acc, n) { acc + n.tokens_in })
  let total_tokens_out = list.fold(all, 0, fn(acc, n) { acc + n.tokens_out })
  let total_duration_ms = list.fold(all, 0, fn(acc, n) { acc + n.duration_ms })

  let all_tools = list.flat_map(all, fn(n) { n.tool_calls })
  let total_tool_calls = list.length(all_tools)
  let failed_tool_calls = list.count(all_tools, fn(t) { !t.success })
  let tool_failure_rate = case total_tool_calls {
    0 -> 0.0
    n -> int.to_float(failed_tool_calls) /. int.to_float(n)
  }

  let models_used =
    list.map(all, fn(n) { n.model })
    |> list.unique()

  let gate_decisions = list.flat_map(all, fn(n) { n.dprime_gates })

  let agent_failures =
    list.filter_map(all, fn(n) {
      case n.node_type, n.outcome {
        dag_types.AgentCycle, dag_types.NodeFailure(reason:) ->
          Ok(dag_types.AgentFailureRecord(
            agent_model: n.model,
            reason:,
            cycle_id: n.cycle_id,
          ))
        _, _ -> Error(Nil)
      }
    })

  let total = list.length(all)
  let root_cycles = list.count(all, fn(n) { option.is_none(n.parent_id) })
  let agent_cycles = total - root_cycles

  dag_types.DayStats(
    date:,
    total_cycles: total,
    root_cycles:,
    agent_cycles:,
    success_count:,
    partial_count:,
    failure_count:,
    total_tokens_in:,
    total_tokens_out:,
    total_duration_ms:,
    tool_failure_rate:,
    models_used:,
    gate_decisions:,
    agent_failures:,
  )
}

/// Per-tool usage records for a day — total calls, success/failure counts,
/// deduped cycle_ids each tool fired in.
pub fn tool_activity(
  dag_nodes: Table,
  dag_by_parent: Table,
  dag_by_date: Table,
  date: String,
) -> List(dag_types.ToolActivityRecord) {
  let all = query_day(dag_nodes, dag_by_parent, dag_by_date, date)
  let triples =
    list.flat_map(all, fn(node) {
      list.map(node.tool_calls, fn(t) { #(t.name, t.success, node.cycle_id) })
    })
  let records_dict =
    list.fold(triples, dict.new(), fn(acc, triple) {
      let #(name, success, cycle_id) = triple
      case dict.get(acc, name) {
        Error(_) ->
          dict.insert(
            acc,
            name,
            dag_types.ToolActivityRecord(
              name:,
              total_calls: 1,
              success_count: case success {
                True -> 1
                False -> 0
              },
              failure_count: case success {
                True -> 0
                False -> 1
              },
              cycle_ids: [cycle_id],
            ),
          )
        Ok(rec) ->
          dict.insert(
            acc,
            name,
            dag_types.ToolActivityRecord(
              ..rec,
              total_calls: rec.total_calls + 1,
              success_count: rec.success_count
                + case success {
                  True -> 1
                  False -> 0
                },
              failure_count: rec.failure_count
                + case success {
                  True -> 0
                  False -> 1
                },
              cycle_ids: case list.contains(rec.cycle_ids, cycle_id) {
                True -> rec.cycle_ids
                False -> [cycle_id, ..rec.cycle_ids]
              },
            ),
          )
      }
    })
  dict.values(records_dict)
}

// ---------------------------------------------------------------------------
// Startup replay
// ---------------------------------------------------------------------------

/// Replay cycle-log JSONL files from disk into all three DAG tables.
pub fn replay_from_cycle_log(
  dag_nodes: Table,
  dag_by_parent: Table,
  dag_by_date: Table,
  max_files: Int,
) -> Nil {
  let dir = cycle_log.log_directory()
  case simplifile.read_directory(dir) {
    Error(_) -> Nil
    Ok(files) -> {
      let jsonl_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.sort(string.compare)

      let limited = limit_files(jsonl_files, max_files)

      list.each(limited, fn(f) {
        let date = string.drop_end(f, 6)
        let cycles = cycle_log.load_cycles_for_date(date)
        list.each(cycles, fn(c) {
          let node = cycle_data_to_node(c)
          index_node(dag_nodes, dag_by_parent, dag_by_date, node)
        })
      })
    }
  }
}

// ---------------------------------------------------------------------------
// Trim window
// ---------------------------------------------------------------------------

/// Drop nodes whose date is before `cutoff_date`. Bag entries are left as
/// orphans — `query_day` dedupes via the set, and the next replay skips
/// old files so the orphans are transient.
pub fn trim(dag_nodes: Table, cutoff_date: String) -> Int {
  let all = all_values(dag_nodes)
  let old_nodes =
    list.filter(all, fn(node) {
      string.compare(string.slice(node.timestamp, 0, 10), cutoff_date)
      == order.Lt
    })
  let count = list.length(old_nodes)
  list.each(old_nodes, fn(node) { delete_key(dag_nodes, node.cycle_id) })
  count
}

// ---------------------------------------------------------------------------
// Cycle log → node translation
// ---------------------------------------------------------------------------

fn cycle_data_to_node(c: cycle_log.CycleData) -> dag_types.CycleNode {
  let outcome = case c.response_text {
    "" -> dag_types.NodeFailure(reason: "no response")
    _ -> dag_types.NodeSuccess
  }
  let node_type = case c.parent_id {
    Some(_) -> dag_types.AgentCycle
    None -> dag_types.CognitiveCycle
  }
  let tool_calls = build_tool_summaries(c.tool_names, c.tool_successes, [])
  dag_types.CycleNode(
    cycle_id: c.cycle_id,
    parent_id: c.parent_id,
    node_type:,
    timestamp: c.timestamp,
    outcome:,
    model: c.model,
    complexity: option.unwrap(c.complexity, ""),
    tool_calls:,
    dprime_gates: [],
    tokens_in: c.input_tokens,
    tokens_out: c.output_tokens,
    duration_ms: 0,
    agent_output: None,
    instance_name: "",
    instance_id: "",
  )
}

/// Pair tool_call names with tool_result successes positionally.
fn build_tool_summaries(
  names: List(String),
  results: List(#(String, Bool)),
  acc: List(dag_types.ToolSummary),
) -> List(dag_types.ToolSummary) {
  case names {
    [] -> list.reverse(acc)
    [name, ..rest_names] -> {
      let #(success, rest_results) = case results {
        [#(_, s), ..rest] -> #(s, rest)
        [] -> #(True, [])
      }
      build_tool_summaries(rest_names, rest_results, [
        dag_types.ToolSummary(name:, success:, error: None),
        ..acc
      ])
    }
  }
}

fn limit_files(files: List(String), max_files: Int) -> List(String) {
  case max_files > 0 {
    True -> {
      let len = list.length(files)
      case len > max_files {
        True -> list.drop(files, len - max_files)
        False -> files
      }
    }
    False -> files
  }
}
