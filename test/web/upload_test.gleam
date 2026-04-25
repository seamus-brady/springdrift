//// Web upload tests.
////
//// The HTTP layer (method check, header parsing, body reading,
//// response shaping) is a thin adapter that the existing test
//// stack can't drive without spinning up mist. What's testable —
//// and where the bugs would actually live — is the
//// deposit-then-process round-trip the handler performs. The
//// `deposit_and_process` helper is extracted from the handler for
//// exactly this purpose.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/string
import gleeunit/should
import sandbox/podman_ffi as exec
import simplifile
import web/gui as web_gui

fn test_root(suffix: String) -> String {
  let root = "/tmp/springdrift_test_upload_" <> suffix
  let _ = simplifile.delete(root)
  let _ = simplifile.create_directory_all(root)
  root
}

fn deposit(root: String, bytes: BitArray, filename: String) {
  web_gui.deposit_and_process(
    root,
    root <> "/intray",
    root <> "/sources",
    root <> "/indexes",
    bytes,
    filename,
  )
}

// ---------------------------------------------------------------------------
// deposit_and_process — happy paths
// ---------------------------------------------------------------------------

pub fn deposit_markdown_lands_and_processes_test() {
  // The dominant path: operator drops a markdown file, it lands
  // in the intray, the synchronous drain normalises it into
  // sources/intray/.
  let root = test_root("markdown_happy")
  let bytes = <<"# Hello\n\nFrom upload.\n":utf8>>

  let assert Ok(#(saved, summary)) = deposit(root, bytes, "memo.md")
  saved |> should.equal("memo.md")
  summary.normalised |> should.equal(1)
  summary.failures |> should.equal([])

  // File no longer in the intray (it was processed).
  case simplifile.read(root <> "/intray/memo.md") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
  // Normalised content lives in sources/intray/.
  case simplifile.read(root <> "/sources/intray/memo.md") {
    Ok(content) -> content |> string.contains("From upload.") |> should.be_true
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn deposit_pdf_lands_and_processes_test() {
  // PDF path requires pdftotext; skip if the binary isn't present so
  // CI without poppler stays green. Same skip pattern as the
  // attachments PDF test.
  case exec.which("pdftotext") {
    Error(_) -> Nil
    Ok(_) -> {
      let root = test_root("pdf_happy")
      let assert Ok(pdf_bytes) =
        simplifile.read_bits("test/fixtures/sample.pdf")

      let assert Ok(#(saved, summary)) =
        deposit(root, pdf_bytes, "research.pdf")
      saved |> should.equal("research.pdf")
      summary.normalised |> should.equal(1)

      // Normalised markdown is in sources/intray/research.md (slug
      // strips the .pdf extension).
      case simplifile.read(root <> "/sources/intray/research.md") {
        Ok(content) ->
          content
          |> string.contains("Hello from Springdrift test fixture.")
          |> should.be_true
        Error(_) -> should.fail()
      }

      let _ = simplifile.delete(root)
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// deposit_and_process — sad paths
// ---------------------------------------------------------------------------

pub fn deposit_unsupported_extension_lands_but_does_not_process_test() {
  // The intake boundary does NOT type-check on deposit — it accepts
  // any filename and writes the bytes. The processor downstream is
  // what decides what's converted. So uploading a PNG succeeds at
  // deposit, but processed=0 because the converter skips it. The
  // file stays in the intray for the operator to remove or the
  // converter to learn.
  let root = test_root("unsupported")
  let bytes = <<"binary png pretender":utf8>>

  let assert Ok(#(saved, summary)) = deposit(root, bytes, "image.png")
  saved |> should.equal("image.png")
  summary.normalised |> should.equal(0)
  // PNG isn't in the supported list; converter.is_supported filter
  // skips it BEFORE the per-file failure path runs, so failures stays
  // empty (no actionable error to surface — the file just sits there).
  summary.failures |> should.equal([])
  // File still sits in the intray.
  case simplifile.read(root <> "/intray/image.png") {
    Ok(_) -> Nil
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn deposit_rejects_empty_filename_test() {
  // Sanitisation in the boundary collapses "" / "/" / similar to
  // empty and rejects.
  let root = test_root("empty_name")
  case deposit(root, <<"x":utf8>>, "") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn deposit_strips_path_traversal_in_filename_test() {
  // Defense-in-depth: even a malicious uploader sending
  // "../../../etc/passwd" lands the file as "passwd" inside the
  // intray, never escaping it.
  let root = test_root("traversal")
  let assert Ok(#(saved, _)) =
    deposit(root, <<"x":utf8>>, "../../../etc/passwd")
  saved |> should.equal("passwd")

  // Confirm landed in intray, not in /etc.
  case simplifile.read(root <> "/intray/passwd") {
    Ok(_) -> Nil
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn deposit_multiple_files_each_become_a_source_test() {
  // Multiple uploads in sequence: each call's process() drains
  // whatever's currently in the intray. After two markdown deposits
  // the sources/intray/ directory holds both normalised files.
  let root = test_root("multi")
  let assert Ok(_) = deposit(root, <<"# One\n\nFirst.\n":utf8>>, "one.md")
  let assert Ok(_) = deposit(root, <<"# Two\n\nSecond.\n":utf8>>, "two.md")

  case simplifile.read_directory(root <> "/sources/intray") {
    Ok(files) -> list.length(files) |> should.equal(2)
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}
