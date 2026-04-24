//// Email-attachment inbound pipeline tests.
////
//// HTTP-bound parts (download_attachment) need a live AgentMail
//// inbox to test, so they're not covered here. What IS testable:
////
//// - Filename construction is collision-resistant and safe against
////   path-traversal characters in the original filename.
//// - write_attachment_to_inbox writes bytes to disk, creates the
////   inbox dir if needed, returns the final filename.
//// - The full PR 1 → PR 6 chain: an attachment lands in
////   knowledge/inbox/, the existing inbox.process_inbox picks it
////   up via PR 1's converter and turns it into a normalised source.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import comms/poller
import gleam/list
import gleam/string
import gleeunit/should
import knowledge/inbox
import sandbox/podman_ffi as exec
import simplifile

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/springdrift_test_attachments_" <> suffix
  let _ = simplifile.delete(dir)
  let _ = simplifile.create_directory_all(dir)
  dir
}

// ---------------------------------------------------------------------------
// build_inbox_filename
// ---------------------------------------------------------------------------

pub fn build_inbox_filename_includes_message_prefix_test() {
  poller.build_inbox_filename("msg-abcdef123456-rest-of-id", "report.pdf")
  |> should.equal("msg-abcdef12--report.pdf")
}

pub fn build_inbox_filename_two_messages_same_filename_dont_collide_test() {
  let a = poller.build_inbox_filename("aaaaaaaaaaaa-rest", "report.pdf")
  let b = poller.build_inbox_filename("bbbbbbbbbbbb-rest", "report.pdf")
  a |> should.not_equal(b)
}

pub fn build_inbox_filename_strips_path_traversal_chars_test() {
  // A malicious filename trying to escape the inbox dir should be
  // sanitised — slashes, backslashes, "..", and spaces all replaced.
  let result = poller.build_inbox_filename("msg-x", "../../../etc/passwd")
  result |> string.contains("/") |> should.be_false
  result |> string.contains("..") |> should.be_false
}

pub fn build_inbox_filename_preserves_extension_test() {
  // Critical: the converter dispatches by extension. If the
  // sanitiser ate the .pdf, conversion would silently fail.
  poller.build_inbox_filename("msg-x", "research paper.pdf")
  |> string.ends_with(".pdf")
  |> should.be_true
}

// ---------------------------------------------------------------------------
// write_attachment_to_inbox
// ---------------------------------------------------------------------------

pub fn write_attachment_creates_dir_and_writes_bytes_test() {
  let dir = test_dir("write_basic")
  // Delete the dir to verify auto-creation.
  let _ = simplifile.delete(dir)

  let bytes = <<"hello world":utf8>>
  let result =
    poller.write_attachment_to_inbox(dir, "msg-12345abcdef", "note.txt", bytes)
  case result {
    Ok(filename) -> {
      // File exists at the expected path.
      case simplifile.read_bits(dir <> "/" <> filename) {
        Ok(read_back) -> read_back |> should.equal(bytes)
        Error(_) -> should.fail()
      }
    }
    Error(reason) -> {
      echo reason
      should.fail()
    }
  }

  let _ = simplifile.delete(dir)
  Nil
}

// ---------------------------------------------------------------------------
// End-to-end: PR 6 + PR 1 chain
// "Attachment lands in knowledge inbox → inbox.process_inbox normalises it"
// ---------------------------------------------------------------------------

pub fn attachment_then_inbox_processing_round_trip_test() {
  let root = test_dir("e2e_chain")
  let inbox_dir = root <> "/inbox"

  // Step 1: simulate the poller writing an attachment to the inbox.
  // We use a markdown attachment so PR 1's converter doesn't need
  // pdftotext / pandoc to be installed for this test to run on CI.
  let bytes = <<"# Attached\n\nFrom email.\n":utf8>>
  let assert Ok(saved_filename) =
    poller.write_attachment_to_inbox(
      inbox_dir,
      "msg-emailtest123",
      "memo.md",
      bytes,
    )
  saved_filename |> string.ends_with(".md") |> should.be_true

  // Step 2: run the existing inbox processor over that directory.
  // It should pick up our written file and convert/normalise it.
  let processed =
    inbox.process_inbox(root, inbox_dir, root <> "/sources", root <> "/indexes")
  processed |> should.equal(1)

  // Step 3: verify the file moved out of inbox into sources/.
  case simplifile.read_directory(inbox_dir) {
    Ok(files) ->
      list.filter(files, fn(f) { string.ends_with(f, ".md") })
      |> list.length
      |> should.equal(0)
    Error(_) -> should.fail()
  }

  // Step 4: verify the normalised content is in sources/inbox/.
  case simplifile.read_directory(root <> "/sources/inbox") {
    Ok(files) -> {
      list.length(files) |> should.equal(1)
    }
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

// PDF version of the chain — uses the test fixture from PR 1 if
// pdftotext is available. Skips otherwise so CI without poppler
// stays green.
pub fn attachment_pdf_round_trip_via_converter_test() {
  case exec.which("pdftotext") {
    Error(_) -> Nil
    Ok(_) -> {
      let root = test_dir("e2e_pdf")
      let inbox_dir = root <> "/inbox"

      // Read the fixture PDF that PR 1 ships and "treat it as an
      // attachment payload" — same flow as if it had arrived via
      // email.
      let assert Ok(pdf_bytes) =
        simplifile.read_bits("test/fixtures/sample.pdf")
      let assert Ok(_) =
        poller.write_attachment_to_inbox(
          inbox_dir,
          "msg-pdf-from-email",
          "research.pdf",
          pdf_bytes,
        )

      // Inbox processing converts the PDF to markdown.
      let processed =
        inbox.process_inbox(
          root,
          inbox_dir,
          root <> "/sources",
          root <> "/indexes",
        )
      processed |> should.equal(1)

      // Verify converted content is in sources, with the
      // fixture's known marker text.
      case simplifile.read_directory(root <> "/sources/inbox") {
        Ok([only]) ->
          case simplifile.read(root <> "/sources/inbox/" <> only) {
            Ok(content) ->
              content
              |> string.contains("Hello from Springdrift test fixture.")
              |> should.be_true
            Error(_) -> should.fail()
          }
        _ -> should.fail()
      }

      let _ = simplifile.delete(root)
      Nil
    }
  }
}
