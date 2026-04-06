//// CycleTree — hierarchical view of narrative entries via parent_cycle_id.
////
//// Builds a tree structure from flat narrative entries, linking each
//// cycle to its parent. Useful for visualising delegation chains.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import narrative/types.{type NarrativeEntry}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type CycleNode {
  CycleNode(entry: NarrativeEntry, children: List(CycleNode))
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Build a forest of CycleNodes from a flat list of entries.
/// Root nodes are entries with no parent_cycle_id.
pub fn build(entries: List(NarrativeEntry)) -> List(CycleNode) {
  // Index entries by cycle_id
  let by_id =
    list.fold(entries, dict.new(), fn(acc, e) {
      dict.insert(acc, e.cycle_id, e)
    })

  // Group children by parent_cycle_id
  let children_of =
    list.fold(entries, dict.new(), fn(acc, e) {
      case e.parent_cycle_id {
        Some(pid) -> {
          let existing = case dict.get(acc, pid) {
            Ok(kids) -> kids
            Error(_) -> []
          }
          dict.insert(acc, pid, [e.cycle_id, ..existing])
        }
        None -> acc
      }
    })

  // Find roots (no parent, or parent not in the set)
  let roots =
    list.filter(entries, fn(e) {
      case e.parent_cycle_id {
        None -> True
        Some(pid) -> !dict.has_key(by_id, pid)
      }
    })

  // Build tree recursively
  list.map(roots, fn(root) { build_node(root, children_of, by_id) })
}

/// Flatten a CycleNode tree back to a list (pre-order traversal).
pub fn flatten(nodes: List(CycleNode)) -> List(NarrativeEntry) {
  list.flat_map(nodes, fn(node) { [node.entry, ..flatten(node.children)] })
}

/// Get the depth of a cycle in the tree.
pub fn depth(node: CycleNode) -> Int {
  case node.children {
    [] -> 0
    kids ->
      1
      + list.fold(kids, 0, fn(acc, child) {
        let d = depth(child)
        case d > acc {
          True -> d
          False -> acc
        }
      })
  }
}

/// Find a specific cycle by ID in the forest.
pub fn find(nodes: List(CycleNode), cycle_id: String) -> Option(CycleNode) {
  case nodes {
    [] -> None
    [node, ..rest] ->
      case node.entry.cycle_id == cycle_id {
        True -> Some(node)
        False ->
          case find(node.children, cycle_id) {
            Some(found) -> Some(found)
            None -> find(rest, cycle_id)
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn build_node(
  entry: NarrativeEntry,
  children_of: Dict(String, List(String)),
  by_id: Dict(String, NarrativeEntry),
) -> CycleNode {
  let child_ids = case dict.get(children_of, entry.cycle_id) {
    Ok(ids) -> list.reverse(ids)
    Error(_) -> []
  }
  let children =
    list.filter_map(child_ids, fn(cid) {
      case dict.get(by_id, cid) {
        Ok(child_entry) -> Ok(build_node(child_entry, children_of, by_id))
        Error(_) -> Error(Nil)
      }
    })
  CycleNode(entry:, children:)
}
