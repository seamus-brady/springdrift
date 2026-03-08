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
////   ├── memory/
////   │   ├── cycle-log/        Per-cycle JSON-L logs
////   │   └── narrative/        Prime Narrative JSON-L + thread index
////   ├── skills/               Local skill definitions
////   └── profiles/             Local agent profiles

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// Root
// ---------------------------------------------------------------------------

/// The local project directory for all Springdrift runtime data.
pub const project_dir = ".springdrift"

/// The user-level config directory (XDG-style).
pub fn user_dir() -> String {
  case get_env("HOME") {
    Ok(home) -> home <> "/.config/springdrift"
    Error(_) -> project_dir
  }
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Local config file path: .springdrift/config.toml
pub fn local_config() -> String {
  project_dir <> "/config.toml"
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
  project_dir <> "/session.json"
}

// ---------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------

/// System log directory: .springdrift/logs/
pub fn logs_dir() -> String {
  project_dir <> "/logs"
}

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

/// Cycle log directory: .springdrift/memory/cycle-log/
pub fn cycle_log_dir() -> String {
  project_dir <> "/memory/cycle-log"
}

/// Narrative log directory: .springdrift/memory/narrative/
pub fn narrative_dir() -> String {
  project_dir <> "/memory/narrative"
}

// ---------------------------------------------------------------------------
// Skills
// ---------------------------------------------------------------------------

/// Default skill directories to scan (local + user-level).
pub fn default_skills_dirs() -> List(String) {
  case get_env("HOME") {
    Ok(home) -> [
      home <> "/.config/springdrift/skills",
      project_dir <> "/skills",
    ]
    Error(_) -> [project_dir <> "/skills"]
  }
}

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

/// Default profile directories to scan (local + user-level).
pub fn default_profiles_dirs() -> List(String) {
  case get_env("HOME") {
    Ok(home) -> [
      home <> "/.config/springdrift/profiles",
      project_dir <> "/profiles",
    ]
    Error(_) -> [project_dir <> "/profiles"]
  }
}
