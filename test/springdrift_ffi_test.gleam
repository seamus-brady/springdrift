//// Tests for the symlink-resolving FFI used by canonical-path checks.
////
//// `resolve_symlinks` is load-bearing for PR 15's read_skill
//// containment — if it stops following links correctly, an
//// attacker-controlled symlink inside a skills dir can read
//// arbitrary files. These tests anchor the FFI's behaviour:
////
//// 1. Non-symlink path resolves to itself (modulo macOS /tmp →
////    /private/tmp canonicalisation).
//// 2. A symlink to an absolute path resolves to that path.
//// 3. A symlink with a relative target resolves to the target's
////    absolute equivalent.
//// 4. Symlinks transitively chained resolve to the final target.
//// 5. Symlinks on parent components are followed.
////
//// What's NOT tested: cycle handling (the FFI has no explicit
//// cycle detection; relies on filesystem refusing to create cycles
//// at make_symlink time).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/string
import gleeunit/should
import simplifile

@external(erlang, "springdrift_ffi", "resolve_symlinks")
fn resolve_symlinks(path: String) -> String

fn test_root(suffix: String) -> String {
  let root = "/tmp/springdrift_test_resolve_" <> suffix
  let _ = simplifile.delete(root)
  let _ = simplifile.create_directory_all(root)
  root
}

// ---------------------------------------------------------------------------
// Non-symlink paths
// ---------------------------------------------------------------------------

pub fn non_symlink_path_resolves_to_self_test() {
  let root = test_root("plain")
  let path = root <> "/file.txt"
  let _ = simplifile.write(path, "x")

  // On macOS /tmp resolves to /private/tmp, so we don't assert
  // string equality with the input. We assert: (a) the resolved
  // path ends with the file we wrote, (b) it doesn't contain ".."
  // segments, (c) reading the resolved path returns our content.
  let resolved = resolve_symlinks(path)
  resolved |> string.ends_with("/file.txt") |> should.be_true
  resolved |> string.contains("..") |> should.be_false
  case simplifile.read(resolved) {
    Ok(content) -> content |> should.equal("x")
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Symlinks
// ---------------------------------------------------------------------------

pub fn absolute_symlink_resolves_to_target_test() {
  let root = test_root("abs_link")
  let target = root <> "/target.txt"
  let _ = simplifile.write(target, "real")
  let link = root <> "/link.txt"
  let _ = simplifile.delete(link)
  let _ = simplifile.create_symlink(target, link)

  let resolved = resolve_symlinks(link)
  resolved |> string.ends_with("/target.txt") |> should.be_true

  let _ = simplifile.delete(root)
  Nil
}

pub fn relative_symlink_resolves_to_absolute_target_test() {
  // A symlink whose target is a relative path. Must resolve to the
  // absolute path of the target, not stay relative.
  let root = test_root("rel_link")
  let target = root <> "/sibling.txt"
  let _ = simplifile.write(target, "y")
  let link = root <> "/rel-link.txt"
  let _ = simplifile.delete(link)
  // Relative target — same dir as the link.
  let _ = simplifile.create_symlink("sibling.txt", link)

  let resolved = resolve_symlinks(link)
  resolved |> string.ends_with("/sibling.txt") |> should.be_true
  // Resolved path must be absolute (start with /).
  resolved |> string.starts_with("/") |> should.be_true

  let _ = simplifile.delete(root)
  Nil
}

pub fn chained_symlinks_resolve_to_final_target_test() {
  // a → b → c (real file). Must resolve to c.
  let root = test_root("chain")
  let c = root <> "/c.txt"
  let _ = simplifile.write(c, "final")
  let b = root <> "/b.txt"
  let _ = simplifile.delete(b)
  let _ = simplifile.create_symlink(c, b)
  let a = root <> "/a.txt"
  let _ = simplifile.delete(a)
  let _ = simplifile.create_symlink(b, a)

  let resolved = resolve_symlinks(a)
  resolved |> string.ends_with("/c.txt") |> should.be_true

  let _ = simplifile.delete(root)
  Nil
}

pub fn symlink_on_parent_component_is_followed_test() {
  // A directory in the path is itself a symlink. Resolving the
  // path must walk through that symlink.
  // Layout:
  //   real_dir/
  //     file.txt
  //   link_dir → real_dir
  // Then resolve(link_dir/file.txt) must end with real_dir/file.txt.
  let root = test_root("parent_link")
  let real_dir = root <> "/real_dir"
  let _ = simplifile.create_directory_all(real_dir)
  let _ = simplifile.write(real_dir <> "/file.txt", "z")
  let link_dir = root <> "/link_dir"
  let _ = simplifile.delete(link_dir)
  let _ = simplifile.create_symlink(real_dir, link_dir)

  let resolved = resolve_symlinks(link_dir <> "/file.txt")
  resolved |> string.ends_with("/real_dir/file.txt") |> should.be_true

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Non-existent paths — handled gracefully (used for path-existence
// checks in tools, must not crash)
// ---------------------------------------------------------------------------

pub fn nonexistent_path_does_not_crash_test() {
  // resolve_symlinks should return SOME string (typically with the
  // real parent prefix and the missing leaf appended) rather than
  // throwing. read_skill's containment check depends on this — if
  // a malicious path has a missing leaf, we still need to compare
  // it against the skills_dirs prefix.
  let root = test_root("missing")
  let resolved = resolve_symlinks(root <> "/nope.txt")
  resolved |> string.ends_with("/nope.txt") |> should.be_true

  let _ = simplifile.delete(root)
  Nil
}
