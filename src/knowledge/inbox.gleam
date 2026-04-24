//// Knowledge inbox — normalise uploaded files to markdown sources.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import knowledge/converter
import knowledge/indexer
import knowledge/log as knowledge_log
import knowledge/types
import simplifile
import slog

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "sha256_hex")
fn sha256_hex(input: String) -> String

/// Process all pending files in the inbox directory.
/// Returns number of files processed.
pub fn process_inbox(
  knowledge_dir: String,
  inbox_dir: String,
  sources_dir: String,
  indexes_dir: String,
) -> Int {
  let _ = simplifile.create_directory_all(inbox_dir)
  case simplifile.read_directory(inbox_dir) {
    Error(_) -> 0
    Ok(files) -> {
      // Supported inputs: markdown, text, PDF, HTML, docx, epub.
      // Everything else is skipped (operator can see it sitting in
      // the inbox and remove it).
      let processable = list.filter(files, fn(f) { converter.is_supported(f) })
      list.fold(processable, 0, fn(count, filename) {
        case
          process_file(
            knowledge_dir,
            inbox_dir,
            sources_dir,
            indexes_dir,
            filename,
          )
        {
          Ok(_) -> count + 1
          Error(_) -> count
        }
      })
    }
  }
}

fn process_file(
  knowledge_dir: String,
  inbox_dir: String,
  sources_dir: String,
  indexes_dir: String,
  filename: String,
) -> Result(String, String) {
  let source_path = inbox_dir <> "/" <> filename
  // Route through the converter — markdown/txt read as-is, others shell
  // out to pdftotext / pandoc. Errors leave the file in the inbox so
  // the operator can see it and investigate.
  case converter.convert(source_path) {
    Error(converter.UnsupportedExtension(extension:)) ->
      Error("Unsupported extension '" <> extension <> "' on " <> filename)
    Error(converter.BinaryMissing(binary:)) ->
      Error(
        "Converter binary missing: "
        <> binary
        <> " (install it on the host to process "
        <> filename
        <> ")",
      )
    Error(converter.ConversionFailed(reason:)) ->
      Error("Failed to convert " <> filename <> ": " <> reason)
    Ok(content) -> {
      let slug = derive_slug(filename)
      let domain = "inbox"
      let title = derive_title(filename, content)
      let doc_id = generate_uuid()

      let dest_dir = sources_dir <> "/" <> domain
      let _ = simplifile.create_directory_all(dest_dir)
      let dest_path = dest_dir <> "/" <> slug <> ".md"

      case simplifile.write(dest_path, content) {
        Error(reason) ->
          Error("Failed to write source: " <> string.inspect(reason))
        Ok(_) -> {
          let idx = indexer.index_markdown(doc_id, content)
          indexer.save_index(indexes_dir, idx)

          let meta =
            types.DocumentMeta(
              op: types.Create,
              doc_id:,
              doc_type: types.Source,
              domain:,
              title:,
              path: "sources/" <> domain <> "/" <> slug <> ".md",
              status: types.Normalised,
              content_hash: sha256_hex(content),
              node_count: idx.node_count,
              created_at: get_datetime(),
              updated_at: get_datetime(),
              source_url: None,
              version: 1,
            )
          knowledge_log.append(knowledge_dir, meta)

          case simplifile.delete(source_path) {
            Ok(_) -> Nil
            Error(_) ->
              slog.warn(
                "inbox",
                "process_file",
                "Failed to remove processed file: " <> filename,
                Some(doc_id),
              )
          }

          slog.info(
            "inbox",
            "process_file",
            "Normalised: "
              <> filename
              <> " → "
              <> slug
              <> " ("
              <> string.inspect(idx.node_count)
              <> " sections)",
            Some(doc_id),
          )
          Ok(doc_id)
        }
      }
    }
  }
}

fn strip_extension(filename: String) -> String {
  filename
  |> string.replace(".markdown", "")
  |> string.replace(".md", "")
  |> string.replace(".txt", "")
  |> string.replace(".pdf", "")
  |> string.replace(".html", "")
  |> string.replace(".htm", "")
  |> string.replace(".docx", "")
  |> string.replace(".epub", "")
}

fn derive_slug(filename: String) -> String {
  filename
  |> strip_extension
  |> string.lowercase
  |> string.replace(" ", "-")
  |> string.replace("_", "-")
}

fn derive_title(filename: String, content: String) -> String {
  case string.split(content, "\n") {
    [first, ..] ->
      case string.starts_with(string.trim(first), "# ") {
        True -> string.trim(string.drop_start(string.trim(first), 2))
        False ->
          filename
          |> strip_extension
          |> string.replace("-", " ")
          |> string.replace("_", " ")
      }
    [] -> strip_extension(filename)
  }
}

/// List files currently in the inbox.
pub fn list_pending(inbox_dir: String) -> List(String) {
  case simplifile.read_directory(inbox_dir) {
    Ok(files) -> files
    Error(_) -> []
  }
}
