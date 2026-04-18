//// Per-skill version history. Snapshots earlier `SKILL.md` and `skill.toml`
//// pairs into `<skill_dir>/history/vN.md` + `<skill_dir>/history/vN.toml`.
//// Once the on-disk version count exceeds the retention budget, older
//// versions are compacted into `<skill_dir>/history/archive.jsonl` to bound
//// working-directory growth without losing history.
////
//// This module provides the substrate. Auto-snapshotting on edit is the
//// job of whatever performs the edit (an operator tool or the
//// Remembrancer's promotion pipeline). Functions here are pure I/O.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import slog

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type SkillVersion {
  SkillVersion(
    version: Int,
    archived_at: String,
    skill_md: String,
    skill_toml: String,
  )
}

pub type RestoreSource {
  FromHistoryDir
  FromArchive
}

// ---------------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------------

/// Snapshot the current SKILL.md + skill.toml of `skill_dir` as version
/// `version` under `<skill_dir>/history/`. Idempotent — if vN files
/// already exist they're left alone (rewriting would lose history).
pub fn snapshot_version(
  skill_dir: String,
  version: Int,
) -> Result(Nil, simplifile.FileError) {
  let history_dir = skill_dir <> "/history"
  let _ = simplifile.create_directory_all(history_dir)
  let v = int.to_string(version)
  let md_target = history_dir <> "/v" <> v <> ".md"
  let toml_target = history_dir <> "/v" <> v <> ".toml"

  case simplifile.is_file(md_target) {
    Ok(True) -> Ok(Nil)
    _ -> {
      use md_content <- result.try(simplifile.read(skill_dir <> "/SKILL.md"))
      let toml_content =
        simplifile.read(skill_dir <> "/skill.toml")
        |> result.unwrap("")
      use _ <- result.try(simplifile.write(md_target, md_content))
      case simplifile.write(toml_target, toml_content) {
        Ok(_) -> Ok(Nil)
        Error(e) -> Error(e)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------

/// Return every version recorded for the skill, oldest first. Reads from
/// both `history/vN.*` files and `history/archive.jsonl`. Returns an empty
/// list when no history exists.
pub fn list_versions(skill_dir: String) -> List(SkillVersion) {
  let history_dir = skill_dir <> "/history"
  let from_files = list_versions_in_history_dir(history_dir)
  let from_archive = load_archive(history_dir)
  list.append(from_archive, from_files)
  |> list.sort(fn(a, b) { int.compare(a.version, b.version) })
}

fn list_versions_in_history_dir(history_dir: String) -> List(SkillVersion) {
  case simplifile.read_directory(history_dir) {
    Error(_) -> []
    Ok(entries) ->
      entries
      |> list.filter_map(fn(name) {
        case string.starts_with(name, "v"), string.ends_with(name, ".md") {
          True, True -> {
            let version_str =
              name
              |> string.drop_start(1)
              |> string.drop_end(3)
            case int.parse(version_str) {
              Ok(v) -> {
                let md_path = history_dir <> "/" <> name
                let toml_path =
                  history_dir <> "/v" <> int.to_string(v) <> ".toml"
                case simplifile.read(md_path) {
                  Error(_) -> Error(Nil)
                  Ok(md) -> {
                    let toml = simplifile.read(toml_path) |> result.unwrap("")
                    Ok(SkillVersion(
                      version: v,
                      archived_at: "",
                      skill_md: md,
                      skill_toml: toml,
                    ))
                  }
                }
              }
              Error(_) -> Error(Nil)
            }
          }
          _, _ -> Error(Nil)
        }
      })
  }
}

// ---------------------------------------------------------------------------
// Compaction
// ---------------------------------------------------------------------------

/// Move history/vN.md+vN.toml pairs into history/archive.jsonl when the
/// total on-disk version count exceeds `retention`. Keeps the most-recent
/// `retention` versions in vN files for quick rollback.
pub fn compact_history(
  skill_dir: String,
  retention: Int,
  archived_at: String,
) -> Nil {
  let history_dir = skill_dir <> "/history"
  let on_disk =
    list_versions_in_history_dir(history_dir)
    |> list.sort(fn(a, b) { int.compare(a.version, b.version) })
  let count = list.length(on_disk)
  case count > retention {
    False -> Nil
    True -> {
      let to_archive_count = count - retention
      let to_archive = list.take(on_disk, to_archive_count)
      list.each(to_archive, fn(v) {
        append_to_archive(
          history_dir,
          SkillVersion(..v, archived_at: archived_at),
        )
        let v_str = int.to_string(v.version)
        let _ = simplifile.delete(history_dir <> "/v" <> v_str <> ".md")
        let _ = simplifile.delete(history_dir <> "/v" <> v_str <> ".toml")
        Nil
      })
      slog.info(
        "skills/versioning",
        "compact_history",
        "Compacted "
          <> int.to_string(to_archive_count)
          <> " version(s) at "
          <> skill_dir,
        None,
      )
    }
  }
}

fn append_to_archive(history_dir: String, version: SkillVersion) -> Nil {
  let path = history_dir <> "/archive.jsonl"
  let line = json.to_string(encode_version(version)) <> "\n"
  let _ = simplifile.append(path, line)
  Nil
}

fn load_archive(history_dir: String) -> List(SkillVersion) {
  let path = history_dir <> "/archive.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) ->
      string.split(content, "\n")
      |> list.filter_map(fn(line) {
        case string.trim(line) {
          "" -> Error(Nil)
          trimmed ->
            case json.parse(trimmed, version_decoder()) {
              Ok(v) -> Ok(v)
              Error(_) -> Error(Nil)
            }
        }
      })
  }
}

// ---------------------------------------------------------------------------
// Rollback
// ---------------------------------------------------------------------------

/// Restore an earlier version's SKILL.md + skill.toml as the current files.
/// Looks first in `history/vN.*`, then in `history/archive.jsonl`.
/// Snapshots the current files first so rollback itself is reversible.
pub fn rollback_to_version(
  skill_dir: String,
  target_version: Int,
  current_version: Int,
) -> Result(RestoreSource, String) {
  let history_dir = skill_dir <> "/history"
  // Snapshot what we're about to overwrite
  case snapshot_version(skill_dir, current_version) {
    Error(e) ->
      Error("snapshot before rollback failed: " <> simplifile.describe_error(e))
    Ok(_) -> {
      case find_version(history_dir, target_version) {
        None ->
          Error("version " <> int.to_string(target_version) <> " not found")
        Some(#(v, source)) -> {
          let _ = simplifile.write(skill_dir <> "/SKILL.md", v.skill_md)
          case v.skill_toml {
            "" -> Nil
            toml -> {
              let _ = simplifile.write(skill_dir <> "/skill.toml", toml)
              Nil
            }
          }
          Ok(source)
        }
      }
    }
  }
}

fn find_version(
  history_dir: String,
  version: Int,
) -> Option(#(SkillVersion, RestoreSource)) {
  // Prefer files in history/ (cheaper, fresher)
  let from_dir =
    list_versions_in_history_dir(history_dir)
    |> list.find(fn(v) { v.version == version })
  case from_dir {
    Ok(v) -> Some(#(v, FromHistoryDir))
    Error(_) -> {
      let from_archive =
        load_archive(history_dir)
        |> list.find(fn(v) { v.version == version })
      case from_archive {
        Ok(v) -> Some(#(v, FromArchive))
        Error(_) -> None
      }
    }
  }
}

// ---------------------------------------------------------------------------
// JSON encode/decode
// ---------------------------------------------------------------------------

fn encode_version(v: SkillVersion) -> json.Json {
  json.object([
    #("version", json.int(v.version)),
    #("archived_at", json.string(v.archived_at)),
    #("skill_md", json.string(v.skill_md)),
    #("skill_toml", json.string(v.skill_toml)),
  ])
}

fn version_decoder() -> decode.Decoder(SkillVersion) {
  use version <- decode.field("version", decode.int)
  use archived_at <- decode.optional_field("archived_at", "", decode.string)
  use skill_md <- decode.field("skill_md", decode.string)
  use skill_toml <- decode.optional_field("skill_toml", "", decode.string)
  decode.success(SkillVersion(
    version: version,
    archived_at: archived_at,
    skill_md: skill_md,
    skill_toml: skill_toml,
  ))
}
