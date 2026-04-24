//// Inbox end-to-end test — drops a real PDF into a temporary inbox
//// directory, runs `process_inbox`, verifies the file ends up
//// normalised into `sources/` as markdown with a tree index written
//// alongside.
////
//// Skips gracefully when pdftotext isn't on PATH so CI doesn't fail
//// on machines without poppler-utils.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/string
import gleeunit/should
import knowledge/inbox
import sandbox/podman_ffi as exec
import simplifile

fn test_root(suffix: String) -> String {
  let root = "/tmp/springdrift_test_inbox_" <> suffix
  let _ = simplifile.delete(root)
  let _ = simplifile.create_directory_all(root)
  let _ = simplifile.create_directory_all(root <> "/inbox")
  let _ = simplifile.create_directory_all(root <> "/sources")
  let _ = simplifile.create_directory_all(root <> "/indexes")
  root
}

pub fn process_inbox_skips_unsupported_extensions_test() {
  let root = test_root("unsupported")
  let inbox_dir = root <> "/inbox"
  // Drop a file with an unsupported extension.
  let _ = simplifile.write(inbox_dir <> "/image.png", "not really a png")

  let processed =
    inbox.process_inbox(root, inbox_dir, root <> "/sources", root <> "/indexes")
  processed |> should.equal(0)
  // File stays in inbox because it wasn't processable.
  case simplifile.read(inbox_dir <> "/image.png") {
    Ok(_) -> Nil
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn process_inbox_handles_markdown_test() {
  let root = test_root("markdown")
  let inbox_dir = root <> "/inbox"
  let _ =
    simplifile.write(
      inbox_dir <> "/hello.md",
      "# Hello\n\nThis is a test document.\n",
    )

  let processed =
    inbox.process_inbox(root, inbox_dir, root <> "/sources", root <> "/indexes")
  processed |> should.equal(1)

  // File was moved out of inbox.
  case simplifile.read(inbox_dir <> "/hello.md") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
  // Normalised file lives in sources/inbox/hello.md — slug has no
  // extension; domain is "inbox".
  case simplifile.read(root <> "/sources/inbox/hello.md") {
    Ok(content) ->
      content |> string.contains("This is a test document.") |> should.be_true
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn process_inbox_converts_pdf_end_to_end_test() {
  // Skip if pdftotext isn't on PATH.
  case exec.which("pdftotext") {
    Error(_) -> Nil
    Ok(_) -> {
      let root = test_root("pdf")
      let inbox_dir = root <> "/inbox"

      // Copy the fixture PDF into the test inbox.
      let assert Ok(pdf_bytes) =
        simplifile.read_bits("test/fixtures/sample.pdf")
      let _ = simplifile.write_bits(inbox_dir <> "/sample.pdf", pdf_bytes)

      let processed =
        inbox.process_inbox(
          root,
          inbox_dir,
          root <> "/sources",
          root <> "/indexes",
        )
      processed |> should.equal(1)

      // The original PDF should no longer be in the inbox (processed
      // successfully → deleted).
      case simplifile.read(inbox_dir <> "/sample.pdf") {
        Error(_) -> Nil
        Ok(_) -> should.fail()
      }

      // The normalised markdown should live at sources/inbox/sample.md
      // (slug strips the .pdf extension).
      case simplifile.read(root <> "/sources/inbox/sample.md") {
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
