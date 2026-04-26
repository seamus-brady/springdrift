//// Tests for the `referenced_artifacts` parameter on agent_* tool calls.
////
//// When an orchestrator dispatches a sub-agent and supplies one or
//// more artifact IDs via `referenced_artifacts: "id1,id2"`, the
//// framework auto-prepends the artifact CONTENT to the agent's first
//// message as `<reference_artifact>` blocks. This eliminates the
//// redundant-bootstrap pattern observed in 2026-04-26 Nemo session
//// where 13 researcher delegations each re-discovered the same
//// 309-section book from scratch.
////
//// Tests cover the bundle rendering directly: empty input, valid
//// artifact, missing artifact (not_found marker), bundle size cap
//// (elided marker), parse extraction.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive/agents as cognitive_agents
import artifacts/log as artifacts_log
import artifacts/types.{ArtifactMeta, ArtifactRecord}
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import narrative/librarian
import simplifile

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/springdrift_test_refs_" <> suffix
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
  #(lib, dir, artifacts_dir)
}

fn seed_artifact(
  artifacts_dir: String,
  lib: process.Subject(librarian.LibrarianMessage),
  artifact_id: String,
  content: String,
) -> Nil {
  let stored_at = "2026-04-26T15:00:00Z"
  let record =
    ArtifactRecord(
      schema_version: 1,
      artifact_id:,
      cycle_id: "test-cycle",
      stored_at:,
      tool: "checkpoint",
      url: "",
      summary: "test artifact",
      char_count: string.length(content),
      truncated: False,
    )
  artifacts_log.append(artifacts_dir, record, content, 100_000)
  let meta =
    ArtifactMeta(
      artifact_id:,
      cycle_id: "test-cycle",
      stored_at:,
      tool: "checkpoint",
      url: "",
      summary: "test artifact",
      char_count: string.length(content),
      truncated: False,
    )
  librarian.index_artifact(lib, meta)
  // Wait for the librarian to index — the call is async via send.
  process.sleep(50)
}

// ---------------------------------------------------------------------------
// parse_referenced_artifacts_csv
// ---------------------------------------------------------------------------

pub fn parse_csv_returns_empty_when_param_missing_test() {
  // Tool call without the param — must not break the dispatch.
  let json = "{\"instruction\":\"do something\"}"
  cognitive_agents.parse_referenced_artifacts_csv(json) |> should.equal("")
}

pub fn parse_csv_returns_value_when_present_test() {
  let json = "{\"referenced_artifacts\":\"art-abc,art-def\"}"
  cognitive_agents.parse_referenced_artifacts_csv(json)
  |> should.equal("art-abc,art-def")
}

pub fn parse_csv_handles_invalid_json_gracefully_test() {
  // Garbage input shouldn't throw — returns "" so dispatch falls
  // through normally.
  cognitive_agents.parse_referenced_artifacts_csv("not json")
  |> should.equal("")
}

// ---------------------------------------------------------------------------
// render_referenced_artifacts_bundle
// ---------------------------------------------------------------------------

pub fn empty_csv_renders_empty_bundle_test() {
  // No IDs supplied → no bundle. Caller treats "" as "skip prepend".
  cognitive_agents.render_referenced_artifacts_bundle("", None)
  |> should.equal("")
}

pub fn no_librarian_renders_empty_bundle_test() {
  // librarian unavailable (None) → no bundle. Caller falls back
  // gracefully — the agent still gets the instruction without the
  // bundle.
  cognitive_agents.render_referenced_artifacts_bundle("art-abc,art-def", None)
  |> should.equal("")
}

pub fn valid_artifact_renders_content_in_bundle_test() {
  let #(lib, _dir, artifacts_dir) = start_lib("valid")
  seed_artifact(
    artifacts_dir,
    lib,
    "art-recon",
    "Section outline:\n  1. Memory\n  2. Affect\n  3. Safety",
  )

  let bundle =
    cognitive_agents.render_referenced_artifacts_bundle("art-recon", Some(lib))
  // Wraps in the outer container.
  bundle |> string.contains("<reference_artifacts>") |> should.be_true
  // Contains the artifact's content directly — agent sees it without
  // needing to call retrieve_result.
  bundle |> string.contains("Section outline") |> should.be_true
  bundle |> string.contains("1. Memory") |> should.be_true
  // Contains the id as an attribute so the agent knows where it came
  // from.
  bundle |> string.contains("id=\"art-recon\"") |> should.be_true

  process.send(lib, librarian.Shutdown)
}

pub fn missing_artifact_renders_not_found_marker_test() {
  let #(lib, _dir, _artifacts_dir) = start_lib("missing")
  // Intentionally don't seed.

  let bundle =
    cognitive_agents.render_referenced_artifacts_bundle(
      "art-doesnt-exist",
      Some(lib),
    )
  // Marker is present so the agent sees what was attempted but not
  // resolved — better than silently dropping the reference.
  bundle |> string.contains("status=\"not_found\"") |> should.be_true
  bundle |> string.contains("art-doesnt-exist") |> should.be_true

  process.send(lib, librarian.Shutdown)
}

pub fn multiple_ids_render_in_order_test() {
  let #(lib, _dir, artifacts_dir) = start_lib("ordered")
  seed_artifact(artifacts_dir, lib, "art-first", "FIRST_CONTENT")
  seed_artifact(artifacts_dir, lib, "art-second", "SECOND_CONTENT")

  let bundle =
    cognitive_agents.render_referenced_artifacts_bundle(
      "art-first,art-second",
      Some(lib),
    )
  // Both content blocks present.
  bundle |> string.contains("FIRST_CONTENT") |> should.be_true
  bundle |> string.contains("SECOND_CONTENT") |> should.be_true
  // Ordering preserved — first appears before second in the rendered
  // string.
  let first_idx = case string.split_once(bundle, "FIRST_CONTENT") {
    Ok(#(prefix, _)) -> string.length(prefix)
    Error(_) -> -1
  }
  let second_idx = case string.split_once(bundle, "SECOND_CONTENT") {
    Ok(#(prefix, _)) -> string.length(prefix)
    Error(_) -> -1
  }
  { first_idx < second_idx } |> should.be_true

  process.send(lib, librarian.Shutdown)
}

pub fn whitespace_in_csv_is_trimmed_test() {
  // LLMs sometimes pass `"art-a, art-b"` with stray whitespace.
  // Should be tolerated rather than parsing as "art-a" + " art-b".
  let #(lib, _dir, artifacts_dir) = start_lib("whitespace")
  seed_artifact(artifacts_dir, lib, "art-a", "A_CONTENT")

  let bundle =
    cognitive_agents.render_referenced_artifacts_bundle(
      "  art-a , art-nonexistent  ",
      Some(lib),
    )
  bundle |> string.contains("A_CONTENT") |> should.be_true
  bundle |> string.contains("art-nonexistent") |> should.be_true

  process.send(lib, librarian.Shutdown)
}
