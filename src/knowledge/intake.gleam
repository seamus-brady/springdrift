//// Knowledge intake — the boundary that owns the intray directory.
////
//// Two responsibilities, both about the intray:
////
//// 1. `deposit(bytes, filename)` — entry point that producers
////    (comms attachment poller, web upload) call to land bytes in
////    the intray. Owns directory creation, filename safety, and
////    the actual write. Producers must not write to the intray
////    directly.
////
//// 2. `process(...)` — consumer that turns whatever sits in the
////    intray into normalised entries under `sources/`. Routes each
////    file through the converter (markdown / PDF / HTML / docx /
////    epub → markdown), assigns slug + title, indexes the tree,
////    appends a DocumentMeta to the knowledge log, and removes the
////    raw file. Files that fail conversion stay in the intray so
////    the operator can investigate.
////
//// The intray path itself is owned by `paths.knowledge_intray_dir()`.

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

// ---------------------------------------------------------------------------
// deposit — the producer-facing boundary
// ---------------------------------------------------------------------------

/// Deposit bytes in the intray under a sanitised filename. The
/// caller chooses the suggested filename (its own naming policy —
/// e.g. comms uses a `<msg_id>--<original>` pattern for traceability)
/// and `deposit` applies one more pass of safety:
///
/// - takes the last path component only (defends against
///   `/etc/passwd` / `..\..\windows`)
/// - strips backslashes and `..` sequences
/// - rejects an empty result
///
/// `intray_dir` is taken explicitly rather than read from `paths`
/// so tests can drive the boundary against a temp directory.
/// Production callers pass `paths.knowledge_intray_dir()`.
///
/// On success, returns the final filename written (relative to the
/// intray, not absolute) so the caller can log it.
pub fn deposit(
  intray_dir: String,
  bytes: BitArray,
  suggested_filename: String,
) -> Result(String, String) {
  case sanitise_filename(suggested_filename) {
    Error(reason) -> Error(reason)
    Ok(safe_name) -> {
      let _ = simplifile.create_directory_all(intray_dir)
      let dest_path = intray_dir <> "/" <> safe_name
      case simplifile.write_bits(dest_path, bytes) {
        Ok(_) -> Ok(safe_name)
        Error(reason) ->
          Error("Failed to write to intray: " <> string.inspect(reason))
      }
    }
  }
}

/// Sanitise an externally-supplied filename for safe placement in
/// the intray. Strips path components, `..` sequences, and
/// backslashes. Returns Error when nothing usable remains.
fn sanitise_filename(filename: String) -> Result(String, String) {
  let basename = case string.split(filename, "/") {
    [] -> ""
    parts -> {
      let assert Ok(last) = list.last(parts)
      last
    }
  }
  let clean =
    basename
    |> string.replace("\\", "_")
    |> string.replace("..", "_")
    |> string.trim
  case clean {
    "" -> Error("Empty filename after sanitisation")
    _ -> Ok(clean)
  }
}

// ---------------------------------------------------------------------------
// process — the consumer that drains the intray into sources/
// ---------------------------------------------------------------------------

/// Process all pending files in the intray directory.
/// Returns number of files successfully normalised.
pub fn process(
  knowledge_dir: String,
  intray_dir: String,
  sources_dir: String,
  indexes_dir: String,
) -> Int {
  let _ = simplifile.create_directory_all(intray_dir)
  case simplifile.read_directory(intray_dir) {
    Error(_) -> 0
    Ok(files) -> {
      // Supported inputs: markdown, text, PDF, HTML, docx, epub.
      // Everything else is skipped (operator can see it sitting in
      // the intray and remove it).
      let processable = list.filter(files, fn(f) { converter.is_supported(f) })
      list.fold(processable, 0, fn(count, filename) {
        case
          process_file(
            knowledge_dir,
            intray_dir,
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
  intray_dir: String,
  sources_dir: String,
  indexes_dir: String,
  filename: String,
) -> Result(String, String) {
  let source_path = intray_dir <> "/" <> filename
  // Route through the converter — markdown/txt read as-is, others shell
  // out to pdftotext / pandoc. Errors leave the file in the intray so
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
      let domain = "intray"
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
                "knowledge/intake",
                "process_file",
                "Failed to remove processed file: " <> filename,
                Some(doc_id),
              )
          }

          slog.info(
            "knowledge/intake",
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

/// List files currently in the intray.
pub fn list_pending(intray_dir: String) -> List(String) {
  case simplifile.read_directory(intray_dir) {
    Ok(files) -> files
    Error(_) -> []
  }
}
