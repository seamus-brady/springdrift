//// export_pdf tests.
////
//// Covers:
//// - draft-not-promoted rejection: clean error when exports/<slug>.md
////   doesn't exist (don't surface a confusing pandoc failure).
//// - slug sanitisation: path traversal in the slug doesn't escape
////   exports/.
//// - empty / whitespace slug rejection.
//// - happy path: only runs if pandoc + tectonic are on PATH, so CI
////   without the binaries stays green.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{None}
import gleam/string
import gleeunit/should
import llm/types as llm_types
import sandbox/podman_ffi as exec
import simplifile
import tools/knowledge as knowledge_tools

fn test_root(suffix: String) -> String {
  let root = "/tmp/springdrift_test_export_pdf_" <> suffix
  let _ = simplifile.delete(root)
  let _ = simplifile.create_directory_all(root)
  let _ = simplifile.create_directory_all(root <> "/exports")
  root
}

fn make_cfg(root: String) -> knowledge_tools.KnowledgeConfig {
  knowledge_tools.KnowledgeConfig(
    knowledge_dir: root,
    indexes_dir: root <> "/indexes",
    sources_dir: root <> "/sources",
    journal_dir: root <> "/journal",
    notes_dir: root <> "/notes",
    drafts_dir: root <> "/drafts",
    exports_dir: root <> "/exports",
    embed_fn: None,
    reason_fn: None,
  )
}

fn make_tool_call(input: String) -> llm_types.ToolCall {
  llm_types.ToolCall(id: "t", name: "export_pdf", input_json: input)
}

// ---------------------------------------------------------------------------
// Slug validation
// ---------------------------------------------------------------------------

pub fn rejects_missing_slug_param_test() {
  let root = test_root("missing_slug")
  let cfg = make_cfg(root)
  let result = knowledge_tools.execute(make_tool_call("{\"other\":\"x\"}"), cfg)
  case result {
    llm_types.ToolFailure(error:, ..) ->
      error |> string.contains("slug") |> should.be_true
    _ -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

pub fn rejects_empty_slug_after_sanitisation_test() {
  // A slug of just "/" or whitespace reduces to empty; reject so we
  // never run pandoc against a malformed input path.
  let root = test_root("empty_slug")
  let cfg = make_cfg(root)
  let result =
    knowledge_tools.execute(make_tool_call("{\"slug\":\"   \"}"), cfg)
  case result {
    llm_types.ToolFailure(error:, ..) ->
      error |> string.contains("Invalid slug") |> should.be_true
    _ -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Lifecycle — must operate on a promoted export, not a draft
// ---------------------------------------------------------------------------

pub fn rejects_when_no_promoted_export_test() {
  // The whole rationale for export_pdf scoping to exports/ rather
  // than drafts/: a PDF is a delivery artefact, not a working
  // surface. Asking for a PDF on a slug that hasn't been promoted
  // yet should produce a clean error, not a pandoc "no input file"
  // message that the operator can't act on.
  let root = test_root("no_export")
  let cfg = make_cfg(root)
  let result =
    knowledge_tools.execute(make_tool_call("{\"slug\":\"q4-report\"}"), cfg)
  case result {
    llm_types.ToolFailure(error:, ..) -> {
      error |> string.contains("No promoted export") |> should.be_true
      error |> string.contains("promote_draft") |> should.be_true
    }
    _ -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Slug containment — path traversal in the slug must not escape
// exports/. The sanitiser strips slashes and ".." sequences before
// the slug is composed into a path.
// ---------------------------------------------------------------------------

pub fn slug_with_path_traversal_does_not_escape_exports_test() {
  // Even with a malicious slug like "../../etc/passwd", the
  // sanitiser collapses path separators and ".." to underscores so
  // the resolved path is "exports/__/__/etc_passwd.md", entirely
  // inside exports/. Then no such file exists, so the tool returns
  // the clean "no promoted export" message — never tries to run
  // pandoc against /etc/passwd.
  let root = test_root("traversal")
  let cfg = make_cfg(root)
  let result =
    knowledge_tools.execute(
      make_tool_call("{\"slug\":\"../../etc/passwd\"}"),
      cfg,
    )
  case result {
    llm_types.ToolFailure(error:, ..) -> {
      // The error references the sanitised path, not the original
      // — confirms the slug never made it through raw.
      error |> string.contains("..") |> should.be_false
      error |> string.contains("/etc/passwd") |> should.be_false
    }
    _ -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Happy path — runs only if pandoc + tectonic are on PATH so CI
// without the binaries stays green. Same skip pattern as the
// existing pdftotext-dependent tests.
// ---------------------------------------------------------------------------

pub fn export_pdf_renders_when_binaries_present_test() {
  case exec.which("pandoc"), exec.which("tectonic") {
    Ok(_), Ok(_) -> {
      let root = test_root("happy")
      let cfg = make_cfg(root)
      // Seed a promoted export
      let md_path = root <> "/exports/sample.md"
      let _ =
        simplifile.write(md_path, "# Sample Report\n\nThis is a test export.\n")

      let result =
        knowledge_tools.execute(make_tool_call("{\"slug\":\"sample\"}"), cfg)
      case result {
        llm_types.ToolSuccess(content:, ..) -> {
          content |> string.contains("sample.pdf") |> should.be_true
          // Verify the PDF actually landed
          case simplifile.is_file(root <> "/exports/sample.pdf") {
            Ok(True) -> Nil
            _ -> should.fail()
          }
        }
        llm_types.ToolFailure(error:, ..) -> {
          // Surface the failure for diagnosis if happy path breaks
          echo error
          should.fail()
        }
      }
      let _ = simplifile.delete(root)
      Nil
    }
    _, _ -> Nil
  }
}
