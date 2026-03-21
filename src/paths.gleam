//// Centralised path definitions for the .springdrift project directory.
////
//// All runtime data lives under `.springdrift/` in the current working
//// directory. This keeps the project root clean and makes it easy to
//// gitignore a single directory.
////
//// Layout:
////   .springdrift/
////   ├── config.toml          Local project config
////   ├── session.json          Session persistence
////   ├── logs/                 System logs (date-rotated JSON-L)
////   ├── identity/             Agent identity files
////   │   ├── persona.md        First-person character text ({{agent_name}} slot)
////   │   └── session_preamble.md  Dynamic template with {{slot}} and [OMIT IF] rules
////   ├── identity.json          Stable agent UUID (auto-generated)
////   ├── memory/
////   │   ├── cycle-log/        Per-cycle JSON-L logs
////   │   ├── narrative/        Prime Narrative JSON-L + thread index
////   │   ├── cbr/              CBR case JSONL (procedural memory)
////   │   └── facts/            MemoryFact JSONL (semantic memory)
////   ├── skills/               Local skill definitions

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// Root
// ---------------------------------------------------------------------------

/// The local project directory for all Springdrift runtime data.
/// Defaults to `.springdrift` but can be overridden via `SPRINGDRIFT_DATA_DIR`
/// env var (used by tests to isolate writes to /tmp).
pub fn project_dir() -> String {
  case get_env("SPRINGDRIFT_DATA_DIR") {
    Ok(dir) -> dir
    Error(_) -> ".springdrift"
  }
}

/// The user-level config directory (XDG-style).
pub fn user_dir() -> String {
  case get_env("HOME") {
    Ok(home) -> home <> "/.config/springdrift"
    Error(_) -> project_dir()
  }
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Local config file path: .springdrift/config.toml
pub fn local_config() -> String {
  project_dir() <> "/config.toml"
}

/// User-level config file path: ~/.config/springdrift/config.toml
pub fn user_config() -> String {
  user_dir() <> "/config.toml"
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// Session persistence file: .springdrift/session.json
pub fn session() -> String {
  project_dir() <> "/session.json"
}

// ---------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------

/// System log directory: .springdrift/logs/
pub fn logs_dir() -> String {
  project_dir() <> "/logs"
}

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

/// Cycle log directory: .springdrift/memory/cycle-log/
pub fn cycle_log_dir() -> String {
  project_dir() <> "/memory/cycle-log"
}

/// Narrative log directory: .springdrift/memory/narrative/
pub fn narrative_dir() -> String {
  project_dir() <> "/memory/narrative"
}

/// CBR case directory: .springdrift/memory/cbr/
pub fn cbr_dir() -> String {
  project_dir() <> "/memory/cbr"
}

/// Facts directory: .springdrift/memory/facts/
pub fn facts_dir() -> String {
  project_dir() <> "/memory/facts"
}

/// Artifacts directory: .springdrift/memory/artifacts/
pub fn artifacts_dir() -> String {
  project_dir() <> "/memory/artifacts"
}

/// Planner directory: .springdrift/memory/planner/
pub fn planner_dir() -> String {
  project_dir() <> "/memory/planner"
}

/// Schedule directory: .springdrift/memory/schedule/
pub fn schedule_dir() -> String {
  project_dir() <> "/memory/schedule"
}

/// XStructor schema directory: .springdrift/schemas/
pub fn schemas_dir() -> String {
  project_dir() <> "/schemas"
}

/// Scheduler output directory: .springdrift/scheduler/outputs/
pub fn scheduler_outputs_dir() -> String {
  project_dir() <> "/scheduler/outputs"
}

/// Sandbox workspaces directory — a sibling of .springdrift/ in the project root.
/// Kept separate from .springdrift/ to isolate ephemeral container workspaces
/// from persistent agent memory. Uses a path under the project directory
/// (not /tmp) because podman machine on macOS only shares /Users.
pub fn sandbox_workspaces_dir() -> String {
  ".sandbox-workspaces"
}

/// Legacy scheduler checkpoint (one-time migration source only).
pub fn scheduler_checkpoint() -> String {
  project_dir() <> "/scheduler-checkpoint.json"
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

/// Persona filename (fixed first-person character text).
pub const persona_filename = "persona.md"

/// Session preamble filename (Curator-populated {{slot}} template).
pub const preamble_filename = "session_preamble.md"

/// Stable agent identity file: .springdrift/identity.json
pub fn agent_identity() -> String {
  project_dir() <> "/identity.json"
}

/// Local identity directory: .springdrift/identity/
pub fn local_identity_dir() -> String {
  project_dir() <> "/identity"
}

/// User-level identity directory: ~/.config/springdrift/identity/
pub fn user_identity_dir() -> String {
  user_dir() <> "/identity"
}

/// Identity directories to search (local first for override precedence).
/// Order: local project → user global.
pub fn default_identity_dirs() -> List(String) {
  case get_env("HOME") {
    Ok(home) -> [
      project_dir() <> "/identity",
      home <> "/.config/springdrift/identity",
    ]
    Error(_) -> [project_dir() <> "/identity"]
  }
}

// ---------------------------------------------------------------------------
// Skills
// ---------------------------------------------------------------------------

/// Default skill directories to scan (local + user-level).
pub fn default_skills_dirs() -> List(String) {
  case get_env("HOME") {
    Ok(home) -> [
      home <> "/.config/springdrift/skills",
      project_dir() <> "/skills",
    ]
    Error(_) -> [project_dir() <> "/skills"]
  }
}

// ---------------------------------------------------------------------------
// HOW_TO
// ---------------------------------------------------------------------------

/// HOW_TO filename — operator guide for tool selection and usage patterns.
pub const how_to_filename = "HOW_TO.md"

/// Search paths for HOW_TO.md (skills dir first, then legacy root, then user-level).
pub fn how_to_paths() -> List(String) {
  case get_env("HOME") {
    Ok(home) -> [
      project_dir() <> "/skills/" <> how_to_filename,
      project_dir() <> "/" <> how_to_filename,
      home <> "/.config/springdrift/skills/" <> how_to_filename,
      home <> "/.config/springdrift/" <> how_to_filename,
    ]
    Error(_) -> [
      project_dir() <> "/skills/" <> how_to_filename,
      project_dir() <> "/" <> how_to_filename,
    ]
  }
}
// ---------------------------------------------------------------------------
