//// read_skill containment tests.
////
//// Background: read_skill previously checked only the suffix of the
//// requested path (must end with "SKILL.md") and that the path
//// didn't contain "..". Either condition was trivially bypassed —
//// "/etc/services/SKILL.md" passed the suffix test, and a symlink
//// from a legitimate skills directory to a sensitive file passed
//// both. This let an LLM with read_skill access read any
//// SKILL.md-named file anywhere on the host.
////
//// The fix: resolve the requested path through symlinks and require
//// the result to be inside one of the configured skills_dirs (also
//// resolved). Tested directly against `is_safe_skill_path` since
//// it's pure and deterministic — the simplifile.read step is just
//// a wrapper after the safety check passes.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/string
import gleeunit/should
import simplifile
import tools/builtin

fn test_root(suffix: String) -> String {
  let root = "/tmp/springdrift_test_read_skill_" <> suffix
  let _ = simplifile.delete(root)
  let _ = simplifile.create_directory_all(root)
  root
}

fn write_skill(root: String, name: String, body: String) -> String {
  let dir = root <> "/" <> name
  let _ = simplifile.create_directory_all(dir)
  let path = dir <> "/SKILL.md"
  let _ = simplifile.write(path, body)
  path
}

// ---------------------------------------------------------------------------
// Happy path — a skill inside a configured skills directory is allowed
// ---------------------------------------------------------------------------

pub fn legitimate_skill_path_is_accepted_test() {
  let root = test_root("legitimate")
  let skill_path = write_skill(root, "demo-skill", "# Demo\n")

  case builtin.is_safe_skill_path(skill_path, [root]) {
    Ok(resolved) -> {
      // The resolved path may be canonicalised (e.g. macOS resolves
      // /tmp → /private/tmp) so we check the suffix rather than an
      // exact match. The point is: containment said yes.
      resolved
      |> string.ends_with("/demo-skill/SKILL.md")
      |> should.be_true
    }
    Error(reason) -> {
      echo reason
      should.fail()
    }
  }

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Suffix discipline
// ---------------------------------------------------------------------------

pub fn path_not_ending_in_skill_md_is_rejected_test() {
  let root = test_root("wrong_suffix")
  let _ = simplifile.write(root <> "/notskill.md", "x")
  case builtin.is_safe_skill_path(root <> "/notskill.md", [root]) {
    Error(reason) -> reason |> string.contains("SKILL.md") |> should.be_true
    Ok(_) -> should.fail()
  }
  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Containment — paths outside the skills_dirs are rejected
// ---------------------------------------------------------------------------

pub fn absolute_path_outside_skills_dirs_is_rejected_test() {
  // The most direct attack: a fully absolute path to a SKILL.md
  // somewhere unrelated. The suffix passes; containment must reject.
  let root = test_root("outside_root")
  // Simulate "the operator's skills root is a SUBdir of /tmp"
  // and the request points at a SKILL.md elsewhere on /tmp.
  let elsewhere_dir = "/tmp/springdrift_outside_attack_" <> "xyz"
  let _ = simplifile.delete(elsewhere_dir)
  let _ = simplifile.create_directory_all(elsewhere_dir)
  let elsewhere = elsewhere_dir <> "/SKILL.md"
  let _ = simplifile.write(elsewhere, "malicious")

  case builtin.is_safe_skill_path(elsewhere, [root]) {
    Error(reason) -> reason |> string.contains("outside") |> should.be_true
    Ok(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  let _ = simplifile.delete(elsewhere_dir)
  Nil
}

pub fn relative_traversal_does_not_escape_test() {
  // Even with a configured skills_dir, a relative ../ path should
  // resolve outside the dir and be rejected by containment.
  let root = test_root("traversal")
  let _ = write_skill(root, "real-skill", "x")

  // A path that uses ../ to climb up resolves to a real path
  // outside the skills root. Containment catches it.
  let escape = root <> "/real-skill/../../etc/SKILL.md"
  case builtin.is_safe_skill_path(escape, [root]) {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Symlink escape — resolved path matters, not the literal string
// ---------------------------------------------------------------------------

pub fn symlink_escape_is_rejected_test() {
  // A SKILL.md symlinked inside a skills_dir but pointing at
  // /etc/services. Suffix passes; literal path is "inside" the
  // skills_dir; but the resolved canonical path is /etc/services
  // and containment must reject.
  let root = test_root("symlink_escape")
  let attack_dir = root <> "/sneaky"
  let _ = simplifile.create_directory_all(attack_dir)
  let symlink_path = attack_dir <> "/SKILL.md"
  // Erlang's file:make_symlink creates a symlink pointing at the
  // target. We use simplifile here too — it has create_symlink.
  let _ = simplifile.delete(symlink_path)
  let target = "/etc/services"
  let _ = simplifile.create_symlink(target, symlink_path)

  case builtin.is_safe_skill_path(symlink_path, [root]) {
    Error(_) -> Nil
    Ok(resolved) -> {
      // If we ever pass, dump the resolved path so the failure is
      // diagnosable rather than just "should.fail".
      echo resolved
      should.fail()
    }
  }

  let _ = simplifile.delete(symlink_path)
  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Misconfiguration — empty skills_dirs rejects everything (fail-closed)
// ---------------------------------------------------------------------------

pub fn empty_skills_dirs_rejects_everything_test() {
  // A misconfiguration that previously would have been caught by
  // the suffix-only check (because there are no skills configured
  // at all). Now: explicit fail-closed with a clear reason.
  let root = test_root("empty_dirs")
  let path = write_skill(root, "demo", "x")

  case builtin.is_safe_skill_path(path, []) {
    Error(reason) ->
      reason |> string.contains("misconfiguration") |> should.be_true
    Ok(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Multiple skills_dirs — any one of them suffices for containment
// ---------------------------------------------------------------------------

pub fn skill_in_second_configured_dir_is_accepted_test() {
  // Real-world: operator has both ~/.config/springdrift/skills and
  // .springdrift/skills. A skill in the project-local one should
  // be accepted even when listed second.
  let root1 = test_root("multi_a")
  let root2 = test_root("multi_b")
  let path = write_skill(root2, "project-skill", "x")

  case builtin.is_safe_skill_path(path, [root1, root2]) {
    Ok(_) -> Nil
    Error(reason) -> {
      echo reason
      should.fail()
    }
  }

  let _ = simplifile.delete(root1)
  let _ = simplifile.delete(root2)
  Nil
}

// ---------------------------------------------------------------------------
// Trailing-slash guard — /foo/skills must NOT match /foo/skills-other
// ---------------------------------------------------------------------------

pub fn prefix_match_does_not_admit_sibling_directories_test() {
  // If containment used naive string.starts_with without a slash
  // boundary, "/tmp/skills" would accept paths inside
  // "/tmp/skills-other". Make sure the slash guard works.
  let parent = test_root("sibling_guard")
  let real = parent <> "/skills"
  let _ = simplifile.create_directory_all(real)
  let evil = parent <> "/skills-other"
  let _ = simplifile.create_directory_all(evil)
  let _ = simplifile.create_directory_all(evil <> "/x")
  let path = evil <> "/x/SKILL.md"
  let _ = simplifile.write(path, "y")

  case builtin.is_safe_skill_path(path, [real]) {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }

  let _ = simplifile.delete(parent)
  Nil
}

// ---------------------------------------------------------------------------
// Normalisation — accept bare ids, partial dirs, and tilde paths
// ---------------------------------------------------------------------------

pub fn normalise_resolves_bare_skill_id_test() {
  // The agent often refers to a skill by its id alone (the form it
  // sees in the sensorium <skill_procedures> block). The executor
  // should locate <id>/SKILL.md inside any configured skills dir.
  let root = test_root("normalise_id")
  let _ = write_skill(root, "delegation-strategy", "# d\n")

  case builtin.normalise_skill_path("delegation-strategy", [root]) {
    Ok(path) ->
      path
      |> string.ends_with("/delegation-strategy/SKILL.md")
      |> should.be_true
    Error(reason) -> {
      echo reason
      should.fail()
    }
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn normalise_appends_skill_md_to_directory_path_test() {
  // The agent sometimes drops the /SKILL.md suffix and just supplies
  // the skill directory path. Treat that as a partial path and
  // tack the canonical filename on.
  let root = test_root("normalise_dir")
  let _ = write_skill(root, "captures", "# c\n")

  let candidate = root <> "/captures"
  case builtin.normalise_skill_path(candidate, [root]) {
    Ok(path) -> path |> should.equal(candidate <> "/SKILL.md")
    Error(reason) -> {
      echo reason
      should.fail()
    }
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn normalise_passes_through_full_path_test() {
  // The default form — full /path/to/SKILL.md — comes through
  // unchanged so the safety check that follows can verify it.
  let root = test_root("normalise_passthrough")
  let path = write_skill(root, "noop", "x")

  case builtin.normalise_skill_path(path, [root]) {
    Ok(p) -> p |> should.equal(path)
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}

pub fn normalise_unknown_id_returns_helpful_error_test() {
  // If the id doesn't match any directory the operator gets a
  // pointer back to the right input form rather than a vague
  // "path must end with /SKILL.md" message.
  let root = test_root("normalise_unknown")
  case builtin.normalise_skill_path("does-not-exist", [root]) {
    Error(reason) -> {
      reason |> string.contains("does-not-exist") |> should.be_true
      reason |> string.contains("available_skills") |> should.be_true
    }
    Ok(_) -> should.fail()
  }

  let _ = simplifile.delete(root)
  Nil
}
