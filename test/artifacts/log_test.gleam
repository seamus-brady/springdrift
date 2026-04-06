// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import artifacts/log as artifacts_log
import artifacts/types.{type ArtifactMeta, type ArtifactRecord, ArtifactRecord}
import gleam/list
import gleam/string
import gleeunit/should
import simplifile

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/springdrift_test_artifacts_log_" <> suffix
  let _ = simplifile.delete(dir)
  let _ = simplifile.create_directory_all(dir)
  dir
}

fn make_record(
  artifact_id: String,
  cycle_id: String,
  stored_at: String,
) -> ArtifactRecord {
  ArtifactRecord(
    schema_version: 1,
    artifact_id:,
    cycle_id:,
    stored_at:,
    tool: "fetch_url",
    url: "https://example.com",
    summary: "Test artifact",
    char_count: 0,
    truncated: False,
  )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn append_creates_dated_file_test() {
  let dir = test_dir("append")
  let record = make_record("art-001", "cycle-001", "2026-03-10T12:00:00Z")
  artifacts_log.append(
    dir,
    record,
    "Hello, world!",
    artifacts_log.default_max_content_chars,
  )

  // File should exist with the date prefix
  case simplifile.read(dir <> "/artifacts-2026-03-10.jsonl") {
    Ok(content) -> {
      should.be_true(string.contains(content, "art-001"))
      should.be_true(string.contains(content, "Hello, world!"))
    }
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(dir)
  Nil
}

pub fn load_date_meta_returns_metadata_test() {
  let dir = test_dir("meta")
  let r1 = make_record("art-m1", "cycle-001", "2026-03-10T10:00:00Z")
  let r2 = make_record("art-m2", "cycle-001", "2026-03-10T11:00:00Z")
  artifacts_log.append(
    dir,
    r1,
    "Content one",
    artifacts_log.default_max_content_chars,
  )
  artifacts_log.append(
    dir,
    r2,
    "Content two",
    artifacts_log.default_max_content_chars,
  )

  let metas = artifacts_log.load_date_meta(dir, "2026-03-10")
  list.length(metas) |> should.equal(2)
  let ids = list.map(metas, fn(m: ArtifactMeta) { m.artifact_id })
  should.be_true(list.contains(ids, "art-m1"))
  should.be_true(list.contains(ids, "art-m2"))

  let _ = simplifile.delete(dir)
  Nil
}

pub fn load_date_meta_returns_empty_for_missing_date_test() {
  let dir = test_dir("nometa")
  let metas = artifacts_log.load_date_meta(dir, "2026-03-10")
  metas |> should.equal([])
  let _ = simplifile.delete(dir)
  Nil
}

pub fn read_content_finds_by_id_test() {
  let dir = test_dir("readcontent")
  let r1 = make_record("art-r1", "cycle-001", "2026-03-10T10:00:00Z")
  let r2 = make_record("art-r2", "cycle-001", "2026-03-10T11:00:00Z")
  artifacts_log.append(
    dir,
    r1,
    "First content",
    artifacts_log.default_max_content_chars,
  )
  artifacts_log.append(
    dir,
    r2,
    "Second content",
    artifacts_log.default_max_content_chars,
  )

  case artifacts_log.read_content(dir, "art-r2", "2026-03-10") {
    Ok(content) -> content |> should.equal("Second content")
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(dir)
  Nil
}

pub fn read_content_returns_error_for_missing_id_test() {
  let dir = test_dir("missing")
  let record = make_record("art-x1", "cycle-001", "2026-03-10T10:00:00Z")
  artifacts_log.append(
    dir,
    record,
    "Some content",
    artifacts_log.default_max_content_chars,
  )

  case artifacts_log.read_content(dir, "art-nonexistent", "2026-03-10") {
    Error(Nil) -> Nil
    Ok(_) -> should.fail()
  }

  let _ = simplifile.delete(dir)
  Nil
}

pub fn truncation_caps_at_max_chars_test() {
  let dir = test_dir("truncate")
  // Create content larger than max_content_chars (50000)
  let big_content = string.repeat("x", 60_000)
  let record = make_record("art-big", "cycle-001", "2026-03-10T10:00:00Z")
  artifacts_log.append(
    dir,
    record,
    big_content,
    artifacts_log.default_max_content_chars,
  )

  // Metadata should show truncated=true
  let metas = artifacts_log.load_date_meta(dir, "2026-03-10")
  let assert [meta] = metas
  meta.truncated |> should.be_true()
  meta.char_count |> should.equal(50_000)

  // Content should be capped
  case artifacts_log.read_content(dir, "art-big", "2026-03-10") {
    Ok(content) -> string.length(content) |> should.equal(50_000)
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(dir)
  Nil
}
