//// Knowledge converter tests.
////
//// Two layers of test:
////
//// 1. Pure dispatch logic (extension_of, is_supported) — always run.
//// 2. End-to-end: actually invoke pdftotext on a fixture PDF. Gracefully
////    skips if the host binary isn't present so CI doesn't fail on a
////    machine without poppler-utils. Also exercises the
////    BinaryMissing error path for pandoc (which is unlikely to be
////    installed everywhere).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/string
import gleeunit/should
import knowledge/converter
import sandbox/podman_ffi as exec
import simplifile

// ---------------------------------------------------------------------------
// extension_of
// ---------------------------------------------------------------------------

pub fn extension_of_handles_common_extensions_test() {
  converter.extension_of("doc.pdf") |> should.equal("pdf")
  converter.extension_of("doc.PDF") |> should.equal("pdf")
  converter.extension_of("doc.MD") |> should.equal("md")
  converter.extension_of("notes.txt") |> should.equal("txt")
  converter.extension_of("report.html") |> should.equal("html")
  converter.extension_of("/path/to/doc.docx") |> should.equal("docx")
}

pub fn extension_of_no_extension_returns_empty_test() {
  converter.extension_of("README") |> should.equal("")
  converter.extension_of("") |> should.equal("")
}

pub fn extension_of_multiple_dots_uses_last_test() {
  // A file named like "v1.2.3.pdf" should resolve to "pdf".
  converter.extension_of("release.v1.2.3.pdf") |> should.equal("pdf")
}

// ---------------------------------------------------------------------------
// is_supported
// ---------------------------------------------------------------------------

pub fn is_supported_accepts_known_types_test() {
  converter.is_supported("doc.md") |> should.be_true
  converter.is_supported("doc.markdown") |> should.be_true
  converter.is_supported("doc.txt") |> should.be_true
  converter.is_supported("doc.pdf") |> should.be_true
  converter.is_supported("doc.html") |> should.be_true
  converter.is_supported("doc.htm") |> should.be_true
  converter.is_supported("doc.docx") |> should.be_true
  converter.is_supported("doc.epub") |> should.be_true
}

pub fn is_supported_rejects_unknown_types_test() {
  converter.is_supported("image.png") |> should.be_false
  converter.is_supported("archive.zip") |> should.be_false
  converter.is_supported("binary") |> should.be_false
  converter.is_supported("note.doc") |> should.be_false
  // .doc (legacy Word) deliberately excluded — pandoc doesn't reliably
  // convert it; operator should convert to .docx first.
}

// ---------------------------------------------------------------------------
// convert — markdown/txt passthrough
// ---------------------------------------------------------------------------

fn test_write(path: String, content: String) -> Nil {
  let _ = simplifile.write(path, content)
  Nil
}

pub fn convert_reads_markdown_as_is_test() {
  let path = "/tmp/springdrift_converter_test.md"
  let _ = simplifile.delete(path)
  test_write(path, "# Title\n\nParagraph.\n")

  case converter.convert(path) {
    Ok(content) -> {
      content |> string.contains("# Title") |> should.be_true
      content |> string.contains("Paragraph.") |> should.be_true
    }
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(path)
  Nil
}

pub fn convert_reads_txt_as_is_test() {
  let path = "/tmp/springdrift_converter_test.txt"
  let _ = simplifile.delete(path)
  test_write(path, "plain text file content\n")

  case converter.convert(path) {
    Ok(content) ->
      content |> string.contains("plain text file content") |> should.be_true
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(path)
  Nil
}

pub fn convert_rejects_unsupported_extension_test() {
  let path = "/tmp/springdrift_converter_test.png"
  let _ = simplifile.delete(path)
  test_write(path, "not really a png")

  case converter.convert(path) {
    Error(converter.UnsupportedExtension(extension:)) ->
      extension |> should.equal("png")
    _ -> should.fail()
  }

  let _ = simplifile.delete(path)
  Nil
}

// ---------------------------------------------------------------------------
// End-to-end: PDF conversion via pdftotext
// ---------------------------------------------------------------------------

pub fn convert_pdf_via_pdftotext_test() {
  // Skip if pdftotext isn't on PATH — don't fail CI on machines
  // without poppler-utils.
  case exec.which("pdftotext") {
    Error(_) -> Nil
    Ok(_) -> {
      // Fixture PDF ships in the repo under test/fixtures/sample.pdf.
      // Contains exactly: "Hello from Springdrift test fixture."
      let fixture = "test/fixtures/sample.pdf"
      case converter.convert(fixture) {
        Ok(content) ->
          content
          |> string.contains("Hello from Springdrift test fixture.")
          |> should.be_true
        Error(err) -> {
          echo err
          should.fail()
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// BinaryMissing error path
// ---------------------------------------------------------------------------

pub fn convert_html_reports_missing_binary_when_pandoc_absent_test() {
  // If pandoc IS on PATH this test just becomes a success path — still
  // valid, just exercises a different code path.
  let path = "/tmp/springdrift_converter_test.html"
  let _ = simplifile.delete(path)
  test_write(path, "<html><body><p>Hello</p></body></html>")

  case exec.which("pandoc"), converter.convert(path) {
    Error(_), Error(converter.BinaryMissing(binary:)) ->
      binary |> should.equal("pandoc")
    Ok(_), Ok(content) ->
      // pandoc is available — convert succeeded
      content |> string.contains("Hello") |> should.be_true
    _, _ -> should.fail()
  }

  let _ = simplifile.delete(path)
  Nil
}
