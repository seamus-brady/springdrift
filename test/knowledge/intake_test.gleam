//// Knowledge intake tests.
////
//// Two boundaries to cover:
////
//// 1. `deposit(intray, bytes, filename)` — the producer-facing
////    boundary. Tests cover sanitisation (path traversal, empty
////    name, last-component selection), directory auto-creation,
////    and that bytes land verbatim.
//// 2. `process(...)` — the consumer that drains the intray into
////    sources/. Tests cover unsupported-extension skip, markdown
////    happy path, and PDF end-to-end (skipped when pdftotext is
////    not on PATH so CI without poppler stays green).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/string
import gleeunit/should
import knowledge/intake
import sandbox/podman_ffi as exec
import simplifile

fn test_root(suffix: String) -> String {
  let root = "/tmp/springdrift_test_intake_" <> suffix
  let _ = simplifile.delete(root)
  let _ = simplifile.create_directory_all(root)
  let _ = simplifile.create_directory_all(root <> "/intray")
  let _ = simplifile.create_directory_all(root <> "/sources")
  let _ = simplifile.create_directory_all(root <> "/indexes")
  root
}

// ---------------------------------------------------------------------------
// deposit — producer-facing boundary
// ---------------------------------------------------------------------------

pub fn deposit_writes_bytes_to_intray_test() {
  let root = test_root("deposit_basic")
  let intray = root <> "/intray"
  let bytes = <<"hello":utf8>>

  let assert Ok(filename) = intake.deposit(intray, bytes, "note.txt")
  filename |> should.equal("note.txt")

  // Verify the bytes actually landed.
  let assert Ok(read_back) = simplifile.read_bits(intray <> "/" <> filename)
  read_back |> should.equal(bytes)

  let _ = simplifile.delete(root)
  Nil
}

pub fn deposit_creates_intray_dir_if_missing_test() {
  let root = test_root("deposit_mkdir")
  // Deliberately don't create the intray subdir.
  let intray = root <> "/intray"
  let _ = simplifile.delete(intray)

  let assert Ok(_) = intake.deposit(intray, <<"x":utf8>>, "x.txt")

  case simplifile.is_directory(intray) {
    Ok(True) -> Nil
    _ -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn deposit_strips_path_traversal_test() {
  // A malicious filename that tries to escape the intray must be
  // reduced to a basename. The "../" components get taken off (last
  // path component only); any residual ".." sequences in what
  // remains get replaced with underscores.
  let root = test_root("deposit_traversal")
  let intray = root <> "/intray"

  let assert Ok(filename) =
    intake.deposit(intray, <<"x":utf8>>, "../../../etc/passwd")
  filename |> should.equal("passwd")
  // File landed in the intray, not in /etc.
  case simplifile.read(intray <> "/passwd") {
    Ok(_) -> Nil
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn deposit_strips_dotdot_in_basename_test() {
  // The basename itself can contain ".." even after path stripping
  // (e.g. "..hidden" or "weird..name"). These get replaced with "_".
  let root = test_root("deposit_dotdot")
  let intray = root <> "/intray"

  let assert Ok(filename) =
    intake.deposit(intray, <<"x":utf8>>, "weird..name.txt")
  filename |> string.contains("..") |> should.be_false

  let _ = simplifile.delete(root)
  Nil
}

pub fn deposit_rejects_empty_filename_test() {
  let root = test_root("deposit_empty")
  let intray = root <> "/intray"

  case intake.deposit(intray, <<"x":utf8>>, "") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn deposit_rejects_path_only_filename_test() {
  // A filename of just "/" or "../" reduces to empty after
  // sanitisation, so it must be rejected.
  let root = test_root("deposit_pathonly")
  let intray = root <> "/intray"

  case intake.deposit(intray, <<"x":utf8>>, "/") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// process_with_summary — structured per-failure reporting
// ---------------------------------------------------------------------------

pub fn process_summary_empty_intray_test() {
  let root = test_root("summary_empty")
  let summary =
    intake.process_with_summary(
      root,
      root <> "/intray",
      root <> "/sources",
      root <> "/indexes",
    )
  summary.normalised |> should.equal(0)
  summary.failures |> should.equal([])
  let _ = simplifile.delete(root)
  Nil
}

pub fn process_summary_markdown_success_test() {
  let root = test_root("summary_md")
  let intray_dir = root <> "/intray"
  let _ = simplifile.write(intray_dir <> "/x.md", "# X\n\nContent.\n")

  let summary =
    intake.process_with_summary(
      root,
      intray_dir,
      root <> "/sources",
      root <> "/indexes",
    )
  summary.normalised |> should.equal(1)
  summary.failures |> should.equal([])

  let _ = simplifile.delete(root)
  Nil
}

pub fn format_failure_binary_missing_includes_install_hint_test() {
  // The whole point of splitting this variant out: the operator
  // gets an ACTIONABLE message ("install poppler-utils") rather than
  // a generic "couldn't process." Pin the contract — if someone
  // edits format_failure to drop the install hint, the test catches
  // it.
  let msg =
    intake.format_failure(intake.BinaryMissing(
      filename: "report.pdf",
      binary: "pdftotext",
    ))
  msg |> string.contains("pdftotext") |> should.be_true
  msg |> string.contains("not installed") |> should.be_true
  msg |> string.contains("apt install") |> should.be_true
}

pub fn format_failure_unsupported_extension_includes_action_test() {
  let msg =
    intake.format_failure(intake.UnsupportedExtension(
      filename: "data.xyz",
      extension: ".xyz",
    ))
  msg |> string.contains(".xyz") |> should.be_true
  msg |> string.contains("Convert to") |> should.be_true
}

// ---------------------------------------------------------------------------
// process — consumer that drains the intray into sources/
// ---------------------------------------------------------------------------

pub fn process_skips_unsupported_extensions_test() {
  let root = test_root("unsupported")
  let intray_dir = root <> "/intray"
  // Drop a file with an unsupported extension.
  let _ = simplifile.write(intray_dir <> "/image.png", "not really a png")

  let processed =
    intake.process(root, intray_dir, root <> "/sources", root <> "/indexes")
  processed |> should.equal(0)
  // File stays in the intray because it wasn't processable.
  case simplifile.read(intray_dir <> "/image.png") {
    Ok(_) -> Nil
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn process_handles_markdown_test() {
  let root = test_root("markdown")
  let intray_dir = root <> "/intray"
  let _ =
    simplifile.write(
      intray_dir <> "/hello.md",
      "# Hello\n\nThis is a test document.\n",
    )

  let processed =
    intake.process(root, intray_dir, root <> "/sources", root <> "/indexes")
  processed |> should.equal(1)

  // File was moved out of the intray.
  case simplifile.read(intray_dir <> "/hello.md") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
  // Normalised file lives in sources/intray/hello.md — domain is
  // "intray" (the staging origin).
  case simplifile.read(root <> "/sources/intray/hello.md") {
    Ok(content) ->
      content |> string.contains("This is a test document.") |> should.be_true
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn process_converts_pdf_end_to_end_test() {
  // Skip if pdftotext isn't on PATH.
  case exec.which("pdftotext") {
    Error(_) -> Nil
    Ok(_) -> {
      let root = test_root("pdf")
      let intray_dir = root <> "/intray"

      // Copy the fixture PDF into the test intray.
      let assert Ok(pdf_bytes) =
        simplifile.read_bits("test/fixtures/sample.pdf")
      let _ = simplifile.write_bits(intray_dir <> "/sample.pdf", pdf_bytes)

      let processed =
        intake.process(root, intray_dir, root <> "/sources", root <> "/indexes")
      processed |> should.equal(1)

      // The original PDF should no longer be in the intray (processed
      // successfully → deleted).
      case simplifile.read(intray_dir <> "/sample.pdf") {
        Error(_) -> Nil
        Ok(_) -> should.fail()
      }

      // The normalised markdown should live at sources/intray/sample.md
      // (slug strips the .pdf extension).
      case simplifile.read(root <> "/sources/intray/sample.md") {
        Ok(content) ->
          content
          |> string.contains("Hello from Springdrift test fixture.")
          |> should.be_true
        Error(_) -> should.fail()
      }

      // An index file should be written. Name is
      // `<doc_id>.json` so we don't know the exact name — just check
      // the dir has one file ending in .json.
      case simplifile.read_directory(root <> "/indexes") {
        Ok(files) -> {
          let json_count =
            list.filter(files, fn(f) { string.ends_with(f, ".json") })
            |> list.length
          json_count |> should.equal(1)
        }
        Error(_) -> should.fail()
      }

      let _ = simplifile.delete(root)
      Nil
    }
  }
}
