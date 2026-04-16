//// Markdown indexer — parses heading hierarchy into a tree of nodes.
//// Ported from Curragh's PageIndex Library prototype (April 5-6, 2026).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import knowledge/types.{
  type DocumentIndex, type TreeNode, DocumentIndex, SourceLocation, TreeNode,
}
import simplifile
import slog

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "sha256_hex")
fn sha256_hex(input: String) -> String

/// Index a markdown file into a tree structure.
pub fn index_markdown(doc_id: String, content: String) -> DocumentIndex {
  let lines = string.split(content, "\n")
  let root = build_tree(lines)
  let count = count_nodes(root)
  DocumentIndex(doc_id:, root:, node_count: count, indexed_at: get_datetime())
}

/// Save a document index to disk as JSON.
pub fn save_index(indexes_dir: String, idx: DocumentIndex) -> Nil {
  let _ = simplifile.create_directory_all(indexes_dir)
  let path = indexes_dir <> "/" <> idx.doc_id <> ".json"
  let content = types.encode_index(idx)
  case simplifile.write(path, content) {
    Ok(_) -> Nil
    Error(reason) ->
      slog.log_error(
        "indexer",
        "save_index",
        "Failed to write index: " <> string.inspect(reason),
        None,
      )
  }
}

/// Load a document index from disk.
pub fn load_index(
  indexes_dir: String,
  doc_id: String,
) -> Result(DocumentIndex, String) {
  let path = indexes_dir <> "/" <> doc_id <> ".json"
  case simplifile.read(path) {
    Error(_) -> Error("Index file not found: " <> path)
    Ok(content) ->
      case json.parse(content, types.decode_index()) {
        Ok(idx) -> Ok(idx)
        Error(_) -> Error("Failed to parse index: " <> path)
      }
  }
}

/// Compute content hash for change detection.
pub fn content_hash(content: String) -> String {
  sha256_hex(content)
}

/// Find a section by path (e.g. "3.2" or "introduction").
pub fn find_section(node: TreeNode, section_path: String) -> Option(TreeNode) {
  let target = string.lowercase(string.trim(section_path))
  find_section_recursive(node, target)
}

fn find_section_recursive(node: TreeNode, target: String) -> Option(TreeNode) {
  let title_lower = string.lowercase(node.title)
  case
    string.contains(title_lower, target)
    || string.starts_with(title_lower, target)
  {
    True -> option.Some(node)
    False ->
      list.find_map(node.children, fn(child) {
        case find_section_recursive(child, target) {
          option.Some(found) -> Ok(found)
          None -> Error(Nil)
        }
      })
      |> option.from_result
  }
}

/// Count all nodes in a tree.
pub fn count_nodes(node: TreeNode) -> Int {
  1 + list.fold(node.children, 0, fn(acc, child) { acc + count_nodes(child) })
}

// ---------------------------------------------------------------------------
// Tree builder — heading hierarchy → tree
// ---------------------------------------------------------------------------

type ParseState {
  ParseState(
    current_content: List(String),
    current_line_start: Int,
    stack: List(StackEntry),
    line_num: Int,
  )
}

type StackEntry {
  StackEntry(node: TreeNode, depth: Int)
}

fn build_tree(lines: List(String)) -> TreeNode {
  let root_id = generate_uuid()
  let state =
    ParseState(
      current_content: [],
      current_line_start: 1,
      stack: [
        StackEntry(
          node: TreeNode(
            id: root_id,
            title: "Document",
            content: "",
            depth: 0,
            source: SourceLocation(line_start: 1, line_end: 0, page: None),
            children: [],
          ),
          depth: 0,
        ),
      ],
      line_num: 1,
    )
  let final_state = list.fold(lines, state, process_line)
  let final_state2 = flush_content(final_state)
  collapse_stack(final_state2.stack)
}

fn process_line(state: ParseState, line: String) -> ParseState {
  let line_num = state.line_num + 1
  case parse_heading(line) {
    option.Some(#(depth, title)) -> {
      let flushed = flush_content(state)
      let node_id = generate_uuid()
      let new_node =
        TreeNode(
          id: node_id,
          title:,
          content: "",
          depth:,
          source: SourceLocation(
            line_start: line_num,
            line_end: line_num,
            page: None,
          ),
          children: [],
        )
      let new_stack = push_node(flushed.stack, new_node, depth)
      ParseState(
        current_content: [],
        current_line_start: line_num + 1,
        stack: new_stack,
        line_num:,
      )
    }
    None ->
      ParseState(
        ..state,
        current_content: list.append(state.current_content, [line]),
        line_num:,
      )
  }
}

fn flush_content(state: ParseState) -> ParseState {
  case state.current_content {
    [] -> state
    lines -> {
      let text = string.trim(string.join(lines, "\n"))
      case text {
        "" -> ParseState(..state, current_content: [])
        _ -> {
          let new_stack = case state.stack {
            [StackEntry(node: top, depth: d), ..rest] -> {
              let updated =
                TreeNode(
                  ..top,
                  content: case top.content {
                    "" -> text
                    existing -> existing <> "\n\n" <> text
                  },
                  source: SourceLocation(..top.source, line_end: state.line_num),
                )
              [StackEntry(node: updated, depth: d), ..rest]
            }
            [] -> state.stack
          }
          ParseState(..state, current_content: [], stack: new_stack)
        }
      }
    }
  }
}

fn push_node(
  stack: List(StackEntry),
  node: TreeNode,
  depth: Int,
) -> List(StackEntry) {
  case stack {
    [] -> [StackEntry(node:, depth:)]
    [top, ..] if depth <= top.depth -> {
      let collapsed = collapse_one(stack)
      push_node(collapsed, node, depth)
    }
    _ -> [StackEntry(node:, depth:), ..stack]
  }
}

fn collapse_one(stack: List(StackEntry)) -> List(StackEntry) {
  case stack {
    [child_entry, parent_entry, ..rest] -> {
      let updated_parent =
        TreeNode(
          ..parent_entry.node,
          children: list.append(parent_entry.node.children, [child_entry.node]),
          source: SourceLocation(
            ..parent_entry.node.source,
            line_end: int.max(
              parent_entry.node.source.line_end,
              child_entry.node.source.line_end,
            ),
          ),
        )
      [StackEntry(node: updated_parent, depth: parent_entry.depth), ..rest]
    }
    _ -> stack
  }
}

fn collapse_stack(stack: List(StackEntry)) -> TreeNode {
  case stack {
    [single] -> single.node
    [_, _, ..] -> collapse_stack(collapse_one(stack))
    [] ->
      TreeNode(
        id: "empty",
        title: "Empty",
        content: "",
        depth: 0,
        source: SourceLocation(line_start: 0, line_end: 0, page: None),
        children: [],
      )
  }
}

fn parse_heading(line: String) -> Option(#(Int, String)) {
  let trimmed = string.trim(line)
  case trimmed {
    "# " <> rest -> option.Some(#(1, string.trim(rest)))
    "## " <> rest -> option.Some(#(2, string.trim(rest)))
    "### " <> rest -> option.Some(#(3, string.trim(rest)))
    "#### " <> rest -> option.Some(#(4, string.trim(rest)))
    "##### " <> rest -> option.Some(#(5, string.trim(rest)))
    "###### " <> rest -> option.Some(#(6, string.trim(rest)))
    _ -> None
  }
}
