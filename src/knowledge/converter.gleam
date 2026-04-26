//// Converter — normalise non-markdown source files into markdown the
//// tree indexer can eat.
////
//// Extension-based dispatch:
////   .md / .txt   → no conversion (read as-is)
////   .pdf         → unpdf markdown (https://github.com/iyulab/unpdf)
////   .html / .htm → pandoc
////   .docx        → pandoc
////   .epub        → pandoc
////
//// PDF backend rationale: `pdftotext -layout` produced a flat text
//// dump with no heading markers, so the indexer's tree-builder had
//// nothing to attach sections to. unpdf detects headings from PDF
//// font sizes and emits real `#` / `##` ATX markers, which the tree
//// builder uses to populate a navigable section tree.
////
//// The converter shells out to the host binaries listed above. They are
//// deterministic file-format converters, not agent-written code, so
//// running them on the host (rather than through the sandbox) is
//// appropriate. Arguments are passed as a list — no shell interpolation —
//// so malicious filenames cannot break out.
////
//// When a required binary is not on PATH, `convert` returns
//// `BinaryMissing` with the binary name so the caller can surface a
//// clean error instead of a shell failure.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/string
import sandbox/podman_ffi as exec
import simplifile

/// Default timeout for any converter invocation. Generous enough for
/// hundreds-of-pages PDFs; bounded so a runaway converter can't stall
/// the inbox processing loop forever.
pub const default_timeout_ms: Int = 30_000

pub type ConverterError {
  /// File extension isn't in the supported set. Carries the extension
  /// (no leading dot) so the caller can log it.
  UnsupportedExtension(extension: String)
  /// Required host binary (e.g. "unpdf", "pandoc") is not on PATH.
  BinaryMissing(binary: String)
  /// Binary ran but exited non-zero, or the file could not be read, or
  /// the output was empty.
  ConversionFailed(reason: String)
}

/// Convert the file at `path` to markdown content. Dispatches by
/// extension. For markdown/text inputs this reads the file directly.
/// For others, it shells out to the appropriate host converter.
pub fn convert(path: String) -> Result(String, ConverterError) {
  case extension_of(path) {
    "md" | "markdown" | "txt" -> read_file(path)
    "pdf" -> run_unpdf(path)
    "html" | "htm" -> run_pandoc(path, "html")
    "docx" -> run_pandoc(path, "docx")
    "epub" -> run_pandoc(path, "epub")
    other -> Error(UnsupportedExtension(extension: other))
  }
}

/// True if `path` has an extension the converter knows how to process.
/// Useful for filtering inbox directory contents without actually
/// invoking the converter.
pub fn is_supported(path: String) -> Bool {
  case extension_of(path) {
    "md" | "markdown" | "txt" | "pdf" | "html" | "htm" | "docx" | "epub" -> True
    _ -> False
  }
}

/// The lowercased extension of `path` (no leading dot). Returns "" if
/// there is no extension.
pub fn extension_of(path: String) -> String {
  case string.split(path, ".") {
    [] | [_] -> ""
    parts ->
      parts
      |> list_last
      |> string.lowercase
  }
}

fn list_last(xs: List(String)) -> String {
  case xs {
    [] -> ""
    [x] -> x
    [_, ..rest] -> list_last(rest)
  }
}

// ---------------------------------------------------------------------------
// Per-format converters
// ---------------------------------------------------------------------------

fn read_file(path: String) -> Result(String, ConverterError) {
  case simplifile.read(path) {
    Ok(content) -> Ok(content)
    Error(reason) ->
      Error(ConversionFailed(reason: "read failed: " <> string.inspect(reason)))
  }
}

fn run_unpdf(path: String) -> Result(String, ConverterError) {
  use _ <- require_binary("unpdf")
  // `markdown <file>` writes structured markdown to stdout when no
  // `-o` is supplied. unpdf detects headings from PDF font sizes and
  // emits real `#` / `##` markers — the structural fidelity the tree
  // indexer needs.
  case exec.run_cmd("unpdf", ["markdown", path], default_timeout_ms) {
    Ok(result) ->
      case result.exit_code, string.trim(result.stdout) {
        0, "" ->
          Error(ConversionFailed(
            reason: "unpdf produced no output for " <> path,
          ))
        0, stdout -> Ok(stdout)
        code, _ ->
          Error(ConversionFailed(
            reason: "unpdf exited "
            <> int_to_string(code)
            <> ": "
            <> string.slice(result.stderr, 0, 500),
          ))
      }
    Error(reason) -> Error(ConversionFailed(reason: reason))
  }
}

fn run_pandoc(
  path: String,
  from_format: String,
) -> Result(String, ConverterError) {
  use _ <- require_binary("pandoc")
  case
    exec.run_cmd(
      "pandoc",
      ["-f", from_format, "-t", "gfm", "--wrap=none", path],
      default_timeout_ms,
    )
  {
    Ok(result) ->
      case result.exit_code, string.trim(result.stdout) {
        0, "" ->
          Error(ConversionFailed(
            reason: "pandoc produced no output for " <> path,
          ))
        0, stdout -> Ok(stdout)
        code, _ ->
          Error(ConversionFailed(
            reason: "pandoc exited "
            <> int_to_string(code)
            <> ": "
            <> string.slice(result.stderr, 0, 500),
          ))
      }
    Error(reason) -> Error(ConversionFailed(reason: reason))
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn require_binary(
  name: String,
  k: fn(Nil) -> Result(String, ConverterError),
) -> Result(String, ConverterError) {
  case exec.which(name) {
    Ok(_) -> k(Nil)
    Error(_) -> Error(BinaryMissing(binary: name))
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String
