//// Git backup — automated git commit/push for .springdrift/ data.
////
//// Provides git operations for the backup actor. All operations run
//// against the .springdrift/ directory as a standalone git repo.
//// Uses springdrift_ffi.run_cmd for subprocess execution.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import sandbox/podman_ffi
import slog

/// Timeout for git operations (ms).
const git_timeout_ms = 30_000

/// Initialise a git repo in the given directory if one doesn't exist.
pub fn init(data_dir: String) -> Result(Nil, String) {
  case is_git_repo(data_dir) {
    True -> {
      slog.info("backup/git", "init", "Git repo already exists", None)
      Ok(Nil)
    }
    False -> {
      slog.info(
        "backup/git",
        "init",
        "Initialising git repo in " <> data_dir,
        None,
      )
      case run_git(data_dir, ["init"]) {
        Ok(_) -> {
          // Create .gitignore for schemas/ (regenerated at startup)
          let _ =
            run_git(data_dir, ["config", "user.email", "agent@springdrift"])
          let _ =
            run_git(data_dir, ["config", "user.name", "Springdrift Agent"])
          Ok(Nil)
        }
        Error(e) -> Error("git init failed: " <> e)
      }
    }
  }
}

/// Check if the data directory is already a git repo.
pub fn is_git_repo(data_dir: String) -> Bool {
  case run_git(data_dir, ["rev-parse", "--is-inside-work-tree"]) {
    Ok(output) -> string.trim(output) == "true"
    Error(_) -> False
  }
}

/// Stage all changes and commit with a generated message.
/// Returns the commit hash, or None if nothing to commit.
pub fn commit(
  data_dir: String,
  message: String,
) -> Result(Option(String), String) {
  // Stage everything
  case run_git(data_dir, ["add", "-A"]) {
    Error(e) -> Error("git add failed: " <> e)
    Ok(_) -> {
      // Check if there's anything to commit
      case run_git(data_dir, ["status", "--porcelain"]) {
        Error(e) -> Error("git status failed: " <> e)
        Ok(status) ->
          case string.trim(status) {
            "" -> {
              slog.debug("backup/git", "commit", "Nothing to commit", None)
              Ok(None)
            }
            _ -> {
              case run_git(data_dir, ["commit", "-m", message]) {
                Error(e) -> Error("git commit failed: " <> e)
                Ok(_) -> {
                  // Get the commit hash
                  case run_git(data_dir, ["rev-parse", "HEAD"]) {
                    Ok(hash) -> Ok(Some(string.trim(hash)))
                    Error(_) -> Ok(Some("unknown"))
                  }
                }
              }
            }
          }
      }
    }
  }
}

/// Push to a remote. Returns Ok if successful or no remote configured.
pub fn push(
  data_dir: String,
  remote: String,
  branch: String,
) -> Result(Nil, String) {
  case run_git(data_dir, ["push", remote, branch]) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error("git push failed: " <> e)
  }
}

/// Get the number of commits since the last push to the given remote/branch.
pub fn commits_since_push(
  data_dir: String,
  remote: String,
  branch: String,
) -> Int {
  let ref = remote <> "/" <> branch <> "..HEAD"
  case run_git(data_dir, ["rev-list", "--count", ref]) {
    Ok(count_str) ->
      case int.parse(string.trim(count_str)) {
        Ok(n) -> n
        Error(_) -> 0
      }
    Error(_) -> 0
  }
}

/// Get the last commit hash.
pub fn last_commit_hash(data_dir: String) -> Option(String) {
  case run_git(data_dir, ["rev-parse", "--short", "HEAD"]) {
    Ok(hash) -> Some(string.trim(hash))
    Error(_) -> None
  }
}

/// Get the last commit timestamp.
pub fn last_commit_time(data_dir: String) -> Option(String) {
  case run_git(data_dir, ["log", "-1", "--format=%aI"]) {
    Ok(ts) -> Some(string.trim(ts))
    Error(_) -> None
  }
}

/// Count total commits in the repo.
pub fn commit_count(data_dir: String) -> Int {
  case run_git(data_dir, ["rev-list", "--count", "HEAD"]) {
    Ok(count_str) ->
      case int.parse(string.trim(count_str)) {
        Ok(n) -> n
        Error(_) -> 0
      }
    Error(_) -> 0
  }
}

/// Check if a remote is configured.
pub fn has_remote(data_dir: String, remote: String) -> Bool {
  case run_git(data_dir, ["remote", "get-url", remote]) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Add a remote.
pub fn add_remote(
  data_dir: String,
  name: String,
  url: String,
) -> Result(Nil, String) {
  case run_git(data_dir, ["remote", "add", name, url]) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error("git remote add failed: " <> e)
  }
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn run_git(data_dir: String, args: List(String)) -> Result(String, String) {
  let full_args = ["-C", data_dir, ..args]
  case podman_ffi.run_cmd("git", full_args, git_timeout_ms) {
    Ok(result) ->
      case result.exit_code {
        0 -> Ok(result.stdout)
        code -> Error("exit " <> int.to_string(code) <> ": " <> result.stderr)
      }
    Error(e) -> Error(e)
  }
}
