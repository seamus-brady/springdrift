// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/int
import gleam/list
import gleeunit/should
import simplifile
import skills/versioning

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fresh_dir(suffix: String) -> String {
  let dir = "/tmp/skills_versioning_test_" <> suffix
  let _ = simplifile.delete_all([dir])
  let _ = simplifile.create_directory_all(dir)
  dir
}

fn write_skill(dir: String, md: String, toml: String) -> Nil {
  let _ = simplifile.write(dir <> "/SKILL.md", md)
  let _ = simplifile.write(dir <> "/skill.toml", toml)
  Nil
}

// ---------------------------------------------------------------------------
// snapshot_version
// ---------------------------------------------------------------------------

pub fn snapshot_creates_history_files_test() {
  let dir = fresh_dir("snap")
  write_skill(dir, "# v1 body", "id = \"foo\"\nversion = 1")
  let result = versioning.snapshot_version(dir, 1)
  result |> should.be_ok
  simplifile.is_file(dir <> "/history/v1.md") |> should.equal(Ok(True))
  simplifile.is_file(dir <> "/history/v1.toml") |> should.equal(Ok(True))
}

pub fn snapshot_is_idempotent_test() {
  let dir = fresh_dir("snap_idem")
  write_skill(dir, "first", "")
  let _ = versioning.snapshot_version(dir, 1)
  // Now overwrite SKILL.md but call snapshot for v1 again — should NOT
  // overwrite the existing v1 history file.
  let _ = simplifile.write(dir <> "/SKILL.md", "second")
  let _ = versioning.snapshot_version(dir, 1)
  let assert Ok(content) = simplifile.read(dir <> "/history/v1.md")
  content |> should.equal("first")
}

// ---------------------------------------------------------------------------
// list_versions
// ---------------------------------------------------------------------------

pub fn list_versions_returns_sorted_test() {
  let dir = fresh_dir("list")
  write_skill(dir, "v1", "")
  let _ = versioning.snapshot_version(dir, 1)
  let _ = simplifile.write(dir <> "/SKILL.md", "v2")
  let _ = versioning.snapshot_version(dir, 2)
  let _ = simplifile.write(dir <> "/SKILL.md", "v3")
  let _ = versioning.snapshot_version(dir, 3)
  let versions = versioning.list_versions(dir)
  list.length(versions) |> should.equal(3)
  let nums = list.map(versions, fn(v) { v.version })
  nums |> should.equal([1, 2, 3])
}

// ---------------------------------------------------------------------------
// compact_history
// ---------------------------------------------------------------------------

pub fn compact_archives_old_versions_test() {
  let dir = fresh_dir("compact")
  // Write 6 versions, retain 3 → 3 should move to archive.
  list.each([1, 2, 3, 4, 5, 6], fn(v) {
    let _ = simplifile.write(dir <> "/SKILL.md", "body v" <> int.to_string(v))
    let _ = versioning.snapshot_version(dir, v)
    Nil
  })
  versioning.compact_history(dir, 3, "2026-04-18T00:00:00Z")
  // History dir should now only have v4, v5, v6 + archive.jsonl.
  let assert Ok(entries) = simplifile.read_directory(dir <> "/history")
  let md_files =
    list.filter(entries, fn(f) {
      string_starts_with(f, "v") && string_ends_with(f, ".md")
    })
  list.length(md_files) |> should.equal(3)
  // archive.jsonl should exist with the 3 archived entries.
  simplifile.is_file(dir <> "/history/archive.jsonl")
  |> should.equal(Ok(True))
  // list_versions should still see all 6 (3 from disk + 3 from archive).
  let all = versioning.list_versions(dir)
  list.length(all) |> should.equal(6)
}

// ---------------------------------------------------------------------------
// rollback_to_version
// ---------------------------------------------------------------------------

pub fn rollback_restores_previous_version_test() {
  let dir = fresh_dir("rollback")
  write_skill(dir, "v1 content", "version = 1")
  let _ = versioning.snapshot_version(dir, 1)
  let _ = simplifile.write(dir <> "/SKILL.md", "v2 content")
  let _ = versioning.snapshot_version(dir, 2)
  let _ = simplifile.write(dir <> "/SKILL.md", "v3 content")
  // Roll back to v1
  let result = versioning.rollback_to_version(dir, 1, 3)
  result |> should.be_ok
  let assert Ok(content) = simplifile.read(dir <> "/SKILL.md")
  content |> should.equal("v1 content")
}

pub fn rollback_unknown_version_errors_test() {
  let dir = fresh_dir("rollback_err")
  write_skill(dir, "v1", "")
  let _ = versioning.snapshot_version(dir, 1)
  let result = versioning.rollback_to_version(dir, 99, 1)
  case result {
    Ok(_) -> True |> should.be_false
    Error(_) -> True |> should.be_true
  }
}

// ---------------------------------------------------------------------------
// Local string helpers (avoiding importing string just for two predicates)
// ---------------------------------------------------------------------------

import gleam/string

fn string_starts_with(s: String, p: String) -> Bool {
  string.starts_with(s, p)
}

fn string_ends_with(s: String, e: String) -> Bool {
  string.ends_with(s, e)
}
