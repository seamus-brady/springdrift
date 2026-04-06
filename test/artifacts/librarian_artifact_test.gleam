// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import artifacts/log as artifacts_log
import artifacts/types.{type ArtifactMeta, ArtifactMeta, ArtifactRecord}
import gleam/erlang/process
import gleam/list
import gleeunit/should
import narrative/librarian
import simplifile

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/springdrift_test_lib_artifact_" <> suffix
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

fn make_meta(artifact_id: String, cycle_id: String) -> ArtifactMeta {
  ArtifactMeta(
    artifact_id:,
    cycle_id:,
    stored_at: "2026-03-10T12:00:00Z",
    tool: "fetch_url",
    url: "https://example.com",
    summary: "Test artifact",
    char_count: 100,
    truncated: False,
  )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn librarian_indexes_artifact_test() {
  let #(lib, _dir, _artifacts_dir) = start_lib("index")

  let meta = make_meta("art-idx1", "cycle-001")
  librarian.index_artifact(lib, meta)
  process.sleep(50)

  let results = librarian.query_artifacts_by_cycle(lib, "cycle-001")
  list.length(results) |> should.equal(1)
  let assert [m] = results
  m.artifact_id |> should.equal("art-idx1")

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_queries_empty_cycle_test() {
  let #(lib, _dir, _artifacts_dir) = start_lib("empty_cycle")

  let results = librarian.query_artifacts_by_cycle(lib, "nonexistent")
  results |> should.equal([])

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_lookup_artifact_by_id_test() {
  let #(lib, _dir, _artifacts_dir) = start_lib("lookup")

  let meta = make_meta("art-look1", "cycle-001")
  librarian.index_artifact(lib, meta)
  process.sleep(50)

  case librarian.lookup_artifact(lib, "art-look1") {
    Ok(m) -> m.artifact_id |> should.equal("art-look1")
    Error(_) -> should.fail()
  }

  case librarian.lookup_artifact(lib, "art-nonexistent") {
    Error(Nil) -> Nil
    Ok(_) -> should.fail()
  }

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_retrieve_content_from_disk_test() {
  let #(lib, _dir, artifacts_dir) = start_lib("retrieve")

  // Write an artifact to disk
  let record =
    ArtifactRecord(
      schema_version: 1,
      artifact_id: "art-ret1",
      cycle_id: "cycle-001",
      stored_at: "2026-03-10T12:00:00Z",
      tool: "fetch_url",
      url: "https://example.com",
      summary: "Test content",
      char_count: 13,
      truncated: False,
    )
  artifacts_log.append(
    artifacts_dir,
    record,
    "Hello, world!",
    artifacts_log.default_max_content_chars,
  )

  // Index metadata in ETS
  let meta = make_meta("art-ret1", "cycle-001")
  librarian.index_artifact(lib, meta)
  process.sleep(50)

  // Retrieve content via librarian
  case
    librarian.retrieve_artifact_content(lib, "art-ret1", "2026-03-10T12:00:00Z")
  {
    Ok(content) -> content |> should.equal("Hello, world!")
    Error(_) -> should.fail()
  }

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_replays_artifacts_from_disk_test() {
  let dir = test_dir("replay")
  let artifacts_dir = dir <> "/artifacts"
  let _ = simplifile.create_directory_all(artifacts_dir)

  // Write artifacts to disk before starting librarian
  let r1 =
    ArtifactRecord(
      schema_version: 1,
      artifact_id: "art-rep1",
      cycle_id: "cycle-001",
      stored_at: "2026-03-10T10:00:00Z",
      tool: "fetch_url",
      url: "https://example.com/1",
      summary: "First artifact",
      char_count: 7,
      truncated: False,
    )
  let r2 =
    ArtifactRecord(
      schema_version: 1,
      artifact_id: "art-rep2",
      cycle_id: "cycle-001",
      stored_at: "2026-03-10T11:00:00Z",
      tool: "web_search",
      url: "",
      summary: "Second artifact",
      char_count: 8,
      truncated: False,
    )
  artifacts_log.append(
    artifacts_dir,
    r1,
    "Content1",
    artifacts_log.default_max_content_chars,
  )
  artifacts_log.append(
    artifacts_dir,
    r2,
    "Content2",
    artifacts_log.default_max_content_chars,
  )

  // Start librarian — should replay artifact metadata
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

  let results = librarian.query_artifacts_by_cycle(lib, "cycle-001")
  list.length(results) |> should.equal(2)

  // Verify both are accessible
  case librarian.lookup_artifact(lib, "art-rep1") {
    Ok(m) -> m.summary |> should.equal("First artifact")
    Error(_) -> should.fail()
  }

  process.send(lib, librarian.Shutdown)
}
