//// Skill discovery and system-prompt injection.
////
//// A skill is a directory containing a SKILL.md file with YAML frontmatter
//// (name + description + optional agents) followed by Markdown instructions.
////
//// ## skill.toml sidecar (additive, optional)
////
//// Skills may include a sidecar `skill.toml` alongside `SKILL.md`. The TOML
//// file extends the frontmatter with versioning, status, context tags,
//// provenance, and other managed metadata. Where both formats specify the
//// same field, `skill.toml` wins.
////
//// ```toml
//// id = "web-research"
//// name = "Web Research Patterns"
//// description = "Decision tree for tool selection during web research"
//// version = 3
//// status = "active"
////
//// [scoping]
//// agents = ["researcher", "cognitive"]
//// contexts = ["research", "web"]
////
//// [provenance]
//// author = "operator"
//// created_at = "2026-03-20T10:00:00Z"
//// updated_at = "2026-03-25T16:00:00Z"
//// ```
////
//// ## Backward compatibility
////
//// Skills without `skill.toml` continue to work — discovery falls back to
//// the existing frontmatter parsing and applies sensible defaults
//// (status: Active, version: 1, author: Operator, contexts: []).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import slog
import tom

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type SkillStatus {
  Active
  Archived
}

pub type SkillAuthor {
  Operator
  Agent(agent_name: String, cycle_id: String)
  System
}

pub type SkillMeta {
  SkillMeta(
    id: String,
    name: String,
    description: String,
    path: String,
    version: Int,
    status: SkillStatus,
    /// Agent names this skill is scoped to. Empty list = legacy "all"
    /// (frontmatter-only skills); skill.toml skills with no `agents` array
    /// get the conservative default of `["cognitive"]` applied at parse
    /// time. Special tokens: `"all"` (cognitive + all specialists) and
    /// `"all_specialists"` (specialists only).
    agents: List(String),
    /// Domain tags for context activation. Empty = always inject (no filter).
    contexts: List(String),
    /// Approximate token cost when injected, computed from body length.
    /// Used by the decay recommender; not a behavioural input.
    token_cost_estimate: Int,
    author: SkillAuthor,
    /// ISO 8601 timestamp; empty string when unknown.
    created_at: String,
    /// ISO 8601 timestamp; empty string when unknown.
    updated_at: String,
    /// CBR case ID(s) the skill was derived from, if auto-generated.
    derived_from: Option(String),
  )
}

// ---------------------------------------------------------------------------
// Erlang FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Scan each directory for subdirs containing a SKILL.md file.
/// Returns only skills whose frontmatter parses successfully. When a
/// `skill.toml` sidecar is present it extends the metadata; otherwise
/// sensible defaults are applied (Active status, version 1, Operator
/// author, no context filter).
pub fn discover(dirs: List(String)) -> List(SkillMeta) {
  let results =
    dirs
    |> list.flat_map(discover_in_dir)
  slog.info(
    "skills",
    "discover",
    "Searched "
      <> int.to_string(list.length(dirs))
      <> " dirs, found "
      <> int.to_string(list.length(results))
      <> " skills",
    None,
  )
  results
}

/// Build the <available_skills> XML block for injection into the system prompt.
/// Returns "" when the list is empty (no skills configured).
pub fn to_system_prompt_xml(skills: List(SkillMeta)) -> String {
  case skills {
    [] -> ""
    _ ->
      "<available_skills>\n"
      <> string.join(list.map(skills, skill_to_xml), "\n")
      <> "\n</available_skills>"
  }
}

/// Parse YAML frontmatter from a SKILL.md content string.
/// Returns Ok(#(name, description, agents)) or Error(Nil) if required
/// fields are missing.
pub fn parse_frontmatter(
  content: String,
) -> Result(#(String, String, List(String)), Nil) {
  // Strip leading "---\n" fence if present
  let body = case string.starts_with(content, "---\n") {
    True -> string.drop_start(content, 4)
    False -> content
  }
  // Take everything before the closing "\n---" fence
  let fm = case string.split(body, "\n---") {
    [first, ..] -> first
    [] -> body
  }
  let pairs =
    fm
    |> string.split("\n")
    |> list.filter_map(parse_kv_line)

  case list.key_find(pairs, "name"), list.key_find(pairs, "description") {
    Ok(name), Ok(description) -> {
      let agents = case list.key_find(pairs, "agents") {
        Ok(agents_str) ->
          agents_str
          |> string.split(",")
          |> list.map(string.trim)
          |> list.filter(fn(s) { s != "" })
        Error(_) -> []
      }
      Ok(#(name, description, agents))
    }
    _, _ -> Error(Nil)
  }
}

/// Filter skills to those scoped for a specific agent.
/// - Empty agents list → True (legacy "all" behaviour for frontmatter-only
///   skills; preserved for backward compatibility).
/// - Contains the agent's name → True.
/// - Contains "all" → True for any agent.
/// - Contains "all_specialists" → True for any non-cognitive agent.
pub fn for_agent(skills: List(SkillMeta), agent_name: String) -> List(SkillMeta) {
  let is_specialist = agent_name != "cognitive"
  list.filter(skills, fn(s) {
    case s.agents {
      [] -> True
      agents ->
        list.contains(agents, agent_name)
        || list.contains(agents, "all")
        || { is_specialist && list.contains(agents, "all_specialists") }
    }
  })
}

/// Filter skills to those whose context tags match the active query domains.
/// - Empty contexts list → True (no filter, always injected).
/// - Contains "all" → True.
/// - Otherwise injected when at least one context tag matches a query domain.
pub fn for_context(
  skills: List(SkillMeta),
  query_domains: List(String),
) -> List(SkillMeta) {
  list.filter(skills, fn(s) {
    case s.contexts {
      [] -> True
      contexts ->
        list.contains(contexts, "all")
        || list.any(contexts, fn(c) { list.contains(query_domains, c) })
    }
  })
}

/// Convert a SkillStatus to its lowercase string form (used in skill.toml).
pub fn status_to_string(status: SkillStatus) -> String {
  case status {
    Active -> "active"
    Archived -> "archived"
  }
}

/// Parse a skill status string (case-insensitive). Unknown values map to
/// Active so a malformed value never silently archives a skill.
pub fn status_from_string(s: String) -> SkillStatus {
  case string.lowercase(s) {
    "archived" -> Archived
    _ -> Active
  }
}

/// Estimate token cost from body length using a rough chars/token ratio.
/// Used for cost-aware deprecation; not used to gate behaviour.
pub fn estimate_token_cost(body: String) -> Int {
  string.length(body) / 4
}

// ---------------------------------------------------------------------------
// Internal — discovery + sidecar merge
// ---------------------------------------------------------------------------

fn expand_tilde(path: String) -> String {
  case string.starts_with(path, "~/") {
    True ->
      case get_env("HOME") {
        Ok(home) -> home <> string.drop_start(path, 1)
        Error(_) -> path
      }
    False -> path
  }
}

fn discover_in_dir(dir: String) -> List(SkillMeta) {
  let dir = expand_tilde(dir)
  case simplifile.read_directory(at: dir) {
    Error(_) -> []
    Ok(entries) ->
      entries
      |> list.filter_map(fn(entry) {
        let entry_dir = dir <> "/" <> entry
        let skill_md_path = entry_dir <> "/SKILL.md"
        let skill_toml_path = entry_dir <> "/skill.toml"
        case simplifile.read(skill_md_path) {
          Error(_) -> Error(Nil)
          Ok(content) ->
            case parse_frontmatter(content) {
              Error(_) -> Error(Nil)
              Ok(#(fm_name, fm_description, fm_agents)) -> {
                let toml_overrides = case simplifile.read(skill_toml_path) {
                  Ok(toml_text) ->
                    parse_skill_toml(toml_text) |> result.unwrap(empty_toml())
                  Error(_) -> empty_toml()
                }
                Ok(merge_skill(
                  default_id: entry,
                  path: skill_md_path,
                  body: content,
                  fm_name: fm_name,
                  fm_description: fm_description,
                  fm_agents: fm_agents,
                  toml: toml_overrides,
                ))
              }
            }
        }
      })
  }
}

/// Bag-of-fields parsed from skill.toml. Each field is Optional so the merge
/// step can tell "field missing" from "field set to empty value" — important
/// for the agents default (omitted → ["cognitive"], explicit empty array
/// would be invalid and is rejected).
type TomlOverrides {
  TomlOverrides(
    id: Option(String),
    name: Option(String),
    description: Option(String),
    version: Option(Int),
    status: Option(SkillStatus),
    agents: Option(List(String)),
    contexts: Option(List(String)),
    author: Option(SkillAuthor),
    created_at: Option(String),
    updated_at: Option(String),
    derived_from: Option(String),
  )
}

fn empty_toml() -> TomlOverrides {
  TomlOverrides(
    id: None,
    name: None,
    description: None,
    version: None,
    status: None,
    agents: None,
    contexts: None,
    author: None,
    created_at: None,
    updated_at: None,
    derived_from: None,
  )
}

/// Parse a skill.toml string into TomlOverrides. Returns Error(Nil) only on
/// TOML syntax errors; missing fields produce None values.
fn parse_skill_toml(input: String) -> Result(TomlOverrides, Nil) {
  case tom.parse(input) {
    Error(_) -> Error(Nil)
    Ok(table) ->
      Ok(TomlOverrides(
        id: tom_string(table, ["id"]),
        name: tom_string(table, ["name"]),
        description: tom_string(table, ["description"]),
        version: tom_int(table, ["version"]),
        status: tom_string(table, ["status"]) |> option.map(status_from_string),
        agents: tom_string_array(table, ["scoping", "agents"]),
        contexts: tom_string_array(table, ["scoping", "contexts"]),
        author: parse_author_from_toml(table),
        created_at: tom_string(table, ["provenance", "created_at"]),
        updated_at: tom_string(table, ["provenance", "updated_at"]),
        derived_from: tom_string(table, ["provenance", "derived_from"]),
      ))
  }
}

fn parse_author_from_toml(table) -> Option(SkillAuthor) {
  case tom_string(table, ["provenance", "author"]) {
    None -> None
    Some(s) ->
      case string.lowercase(s) {
        "operator" -> Some(Operator)
        "system" -> Some(System)
        "agent" -> {
          let name =
            tom_string(table, ["provenance", "agent_name"])
            |> option.unwrap("unknown")
          let cycle_id =
            tom_string(table, ["provenance", "cycle_id"])
            |> option.unwrap("")
          Some(Agent(agent_name: name, cycle_id: cycle_id))
        }
        _ -> Some(Operator)
      }
  }
}

fn merge_skill(
  default_id default_id: String,
  path path: String,
  body body: String,
  fm_name fm_name: String,
  fm_description fm_description: String,
  fm_agents fm_agents: List(String),
  toml toml: TomlOverrides,
) -> SkillMeta {
  let id = toml.id |> option.unwrap(default_id)
  let name = toml.name |> option.unwrap(fm_name)
  let description = toml.description |> option.unwrap(fm_description)
  let version = toml.version |> option.unwrap(1)
  let status = toml.status |> option.unwrap(Active)
  // Agents defaulting:
  //   - skill.toml present + agents missing → ["cognitive"] (conservative)
  //   - skill.toml absent → frontmatter agents (empty = legacy "all")
  let agents = case toml.agents {
    Some(list) -> list
    None ->
      case toml_present(toml) {
        True -> ["cognitive"]
        False -> fm_agents
      }
  }
  let contexts = toml.contexts |> option.unwrap([])
  let author = toml.author |> option.unwrap(Operator)
  let created_at = toml.created_at |> option.unwrap("")
  let updated_at = toml.updated_at |> option.unwrap("")
  let derived_from = toml.derived_from
  SkillMeta(
    id: id,
    name: name,
    description: description,
    path: path,
    version: version,
    status: status,
    agents: agents,
    contexts: contexts,
    token_cost_estimate: estimate_token_cost(body),
    author: author,
    created_at: created_at,
    updated_at: updated_at,
    derived_from: derived_from,
  )
}

/// Heuristic: a TomlOverrides record is "present" when at least one field
/// was specified. If everything is None the sidecar wasn't loaded and we
/// preserve legacy frontmatter semantics.
fn toml_present(toml: TomlOverrides) -> Bool {
  toml.id != None
  || toml.name != None
  || toml.description != None
  || toml.version != None
  || toml.status != None
  || toml.contexts != None
  || toml.author != None
  || toml.created_at != None
  || toml.updated_at != None
  || toml.derived_from != None
}

// ---------------------------------------------------------------------------
// Internal — XML rendering + escaping
// ---------------------------------------------------------------------------

fn skill_to_xml(skill: SkillMeta) -> String {
  "  <skill>\n"
  <> "    <name>"
  <> xml_escape(skill.name)
  <> "</name>\n"
  <> "    <description>"
  <> xml_escape(skill.description)
  <> "</description>\n"
  <> "    <location>"
  <> xml_escape(skill.path)
  <> "</location>\n"
  <> "  </skill>"
}

/// Escape XML special characters in a string.
pub fn xml_escape(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&apos;")
}

fn parse_kv_line(line: String) -> Result(#(String, String), Nil) {
  case string.split(line, ": ") {
    [key, first, ..rest] ->
      Ok(#(string.trim(key), string.trim(string.join([first, ..rest], ": "))))
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Internal — TOML accessors (Option-wrapped wrappers around tom.get_*)
// ---------------------------------------------------------------------------

fn tom_string(table, path: List(String)) -> Option(String) {
  case tom.get_string(table, path) {
    Ok(s) -> Some(s)
    Error(_) -> None
  }
}

fn tom_int(table, path: List(String)) -> Option(Int) {
  case tom.get_int(table, path) {
    Ok(n) -> Some(n)
    Error(_) -> None
  }
}

fn tom_string_array(table, path: List(String)) -> Option(List(String)) {
  case tom.get_array(table, path) {
    Error(_) -> None
    Ok(values) -> {
      let strings =
        list.filter_map(values, fn(v) {
          case v {
            tom.String(s) -> Ok(s)
            _ -> Error(Nil)
          }
        })
      Some(strings)
    }
  }
}
