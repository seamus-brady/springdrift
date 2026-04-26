//// Tests for the checkpoint tool — the lighter sibling of store_result
//// for in-progress work. Saves an artifact with sensible defaults so
//// agents can save in chunks during synthesis without paying token
//// cost on metadata fields.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agents/researcher
import agents/writer
import gleam/erlang/process
import gleam/string
import gleeunit/should
import llm/types as llm_types
import narrative/librarian
import simplifile
import tools/artifacts as artifact_tools

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/springdrift_test_checkpoint_" <> suffix
  let _ = simplifile.delete(dir)
  let _ = simplifile.create_directory_all(dir)
  dir
}

fn start_lib(suffix: String) {
  let dir = test_dir(suffix)
  let artifacts_dir = dir <> "/artifacts"
  let _ = simplifile.create_directory_all(artifacts_dir)
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      artifacts_dir,
      dir <> "/planner",
      0,
      librarian.default_cbr_config(),
    )
  #(lib, artifacts_dir)
}

// ---------------------------------------------------------------------------
// checkpoint dispatch + storage
// ---------------------------------------------------------------------------

pub fn checkpoint_stores_artifact_and_returns_id_test() {
  // Happy path: well-formed input, content saved, id surfaced in
  // ToolSuccess so the agent can pass it to its orchestrator.
  let #(lib, artifacts_dir) = start_lib("happy")
  let call =
    llm_types.ToolCall(
      id: "t1",
      name: "checkpoint",
      input_json: "{\"label\":\"draft-section-1\",\"content\":\"section 1 body\"}",
    )

  let result =
    artifact_tools.execute(call, artifacts_dir, "cycle-test", lib, 100_000)
  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      content |> string.contains("artifact_id=") |> should.be_true
      content |> string.contains("art-") |> should.be_true
    }
    llm_types.ToolFailure(error:, ..) -> {
      echo error
      should.fail()
    }
  }

  process.send(lib, librarian.Shutdown)
}

pub fn checkpoint_uses_label_as_summary_test() {
  // The label parameter becomes the artifact's summary so the
  // operator can find checkpoints later by description.
  let #(lib, artifacts_dir) = start_lib("label_to_summary")
  let call =
    llm_types.ToolCall(
      id: "t2",
      name: "checkpoint",
      input_json: "{\"label\":\"market-analysis-q1\",\"content\":\"...\"}",
    )

  let _ =
    artifact_tools.execute(call, artifacts_dir, "cycle-test", lib, 100_000)
  process.sleep(50)

  // Query librarian for artifacts in this cycle and verify the
  // summary picked up the label.
  let metas = librarian.query_artifacts_by_cycle(lib, "cycle-test")
  case metas {
    [m, ..] -> {
      m.summary |> string.contains("market-analysis-q1") |> should.be_true
      m.tool |> should.equal("checkpoint")
    }
    [] -> should.fail()
  }

  process.send(lib, librarian.Shutdown)
}

pub fn checkpoint_rejects_missing_label_test() {
  // No label supplied — bail with a clear error rather than write a
  // garbage artifact.
  let #(lib, artifacts_dir) = start_lib("no_label")
  let call =
    llm_types.ToolCall(
      id: "t3",
      name: "checkpoint",
      input_json: "{\"content\":\"orphan content\"}",
    )

  let result =
    artifact_tools.execute(call, artifacts_dir, "cycle-test", lib, 100_000)
  case result {
    llm_types.ToolFailure(error:, ..) ->
      error |> string.contains("label") |> should.be_true
    _ -> should.fail()
  }

  process.send(lib, librarian.Shutdown)
}

pub fn checkpoint_rejects_missing_content_test() {
  let #(lib, artifacts_dir) = start_lib("no_content")
  let call =
    llm_types.ToolCall(
      id: "t4",
      name: "checkpoint",
      input_json: "{\"label\":\"x\"}",
    )

  let result =
    artifact_tools.execute(call, artifacts_dir, "cycle-test", lib, 100_000)
  case result {
    llm_types.ToolFailure(error:, ..) ->
      error |> string.contains("content") |> should.be_true
    _ -> should.fail()
  }

  process.send(lib, librarian.Shutdown)
}

// ---------------------------------------------------------------------------
// Routing — confirm the new tool is recognised by writer and researcher
// ---------------------------------------------------------------------------

pub fn writer_routes_checkpoint_test() {
  // Without this, the writer's executor falls through to builtin.execute
  // and returns "Unknown tool" — same bug class fixed in PR #163.
  writer.routes_tool("checkpoint") |> should.be_true
}

pub fn researcher_routes_checkpoint_test() {
  researcher.routes_tool("checkpoint") |> should.be_true
}
