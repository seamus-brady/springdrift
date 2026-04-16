//// Knowledge log — append-only JSONL persistence for document metadata.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import knowledge/types.{type DocumentMeta}
import simplifile
import slog

pub fn append(knowledge_dir: String, meta: DocumentMeta) -> Nil {
  let path = knowledge_dir <> "/index.jsonl"
  let line = types.encode_meta(meta) <> "\n"
  let _ = simplifile.create_directory_all(knowledge_dir)
  case simplifile.append(path, line) {
    Ok(_) -> Nil
    Error(reason) ->
      slog.log_error(
        "knowledge_log",
        "append",
        "Failed to write index.jsonl: " <> string.inspect(reason),
        option.None,
      )
  }
}

pub fn read_all(knowledge_dir: String) -> List(DocumentMeta) {
  let path = knowledge_dir <> "/index.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) ->
      string.split(content, "\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.filter_map(fn(line) { json.parse(line, types.decode_meta()) })
  }
}

/// Replay the log and resolve to current state (last op per doc_id wins).
pub fn resolve(knowledge_dir: String) -> List(DocumentMeta) {
  let all = read_all(knowledge_dir)
  resolve_ops(all)
}

pub fn resolve_ops(ops: List(DocumentMeta)) -> List(DocumentMeta) {
  let grouped = list.group(ops, fn(meta) { meta.doc_id })
  dict.values(grouped)
  |> list.flat_map(fn(entries) {
    case list.first(entries) {
      Ok(latest) ->
        case latest.op {
          types.Delete -> []
          _ -> [latest]
        }
      Error(_) -> []
    }
  })
}
