//// Skill discovery and system-prompt injection for the agentskills.io standard.
////
//// A skill is a directory containing a SKILL.md file with YAML frontmatter
//// (name + description) followed by Markdown instructions.

import gleam/int
import gleam/list
import gleam/option
import gleam/string
import simplifile
import slog

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type SkillMeta {
  SkillMeta(
    name: String,
    description: String,
    path: String,
    /// Agent names this skill is scoped to. Empty = all agents.
    agents: List(String),
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
/// Returns only skills whose frontmatter parses successfully.
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
    option.None,
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
/// Returns Ok(#(name, description, agents)) or Error(Nil) if required fields missing.
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
/// Skills with empty agents list are included for all agents.
pub fn for_agent(skills: List(SkillMeta), agent_name: String) -> List(SkillMeta) {
  list.filter(skills, fn(s) {
    case s.agents {
      [] -> True
      agents ->
        list.contains(agents, agent_name) || list.contains(agents, "all")
    }
  })
}

// ---------------------------------------------------------------------------
// Internal
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
        let skill_md_path = dir <> "/" <> entry <> "/SKILL.md"
        case simplifile.read(skill_md_path) {
          Error(_) -> Error(Nil)
          Ok(content) ->
            case parse_frontmatter(content) {
              Error(_) -> Error(Nil)
              Ok(#(name, description, agents)) ->
                Ok(SkillMeta(name:, description:, path: skill_md_path, agents:))
            }
        }
      })
  }
}

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
