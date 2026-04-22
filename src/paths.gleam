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

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

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

/// Skills proposal/lifecycle log directory: .springdrift/memory/skills/
pub fn skills_log_dir() -> String {
  project_dir() <> "/memory/skills"
}

/// Strategy Registry event log directory: .springdrift/memory/strategies/
pub fn strategy_log_dir() -> String {
  project_dir() <> "/memory/strategies"
}

/// Learning Goals event log directory: .springdrift/memory/learning_goals/
pub fn learning_goals_dir() -> String {
  project_dir() <> "/memory/learning_goals"
}

/// Communications log directory: .springdrift/memory/comms/
pub fn comms_dir() -> String {
  project_dir() <> "/memory/comms"
}

// ---------------------------------------------------------------------------
// Knowledge
// ---------------------------------------------------------------------------

/// Knowledge base root: .springdrift/knowledge/
pub fn knowledge_dir() -> String {
  project_dir() <> "/knowledge"
}

/// Knowledge source documents: .springdrift/knowledge/sources/
pub fn knowledge_sources_dir() -> String {
  knowledge_dir() <> "/sources"
}

/// Knowledge tree indexes: .springdrift/knowledge/indexes/
pub fn knowledge_indexes_dir() -> String {
  knowledge_dir() <> "/indexes"
}

/// Knowledge inbox: .springdrift/knowledge/inbox/
pub fn knowledge_inbox_dir() -> String {
  knowledge_dir() <> "/inbox"
}

/// Agent workspace: .springdrift/knowledge/workspace/
pub fn knowledge_workspace_dir() -> String {
  knowledge_dir() <> "/workspace"
}

/// Agent journal: .springdrift/knowledge/workspace/journal/
pub fn knowledge_journal_dir() -> String {
  knowledge_workspace_dir() <> "/journal"
}

/// Agent notes: .springdrift/knowledge/workspace/notes/
pub fn knowledge_notes_dir() -> String {
  knowledge_workspace_dir() <> "/notes"
}

/// Agent drafts: .springdrift/knowledge/workspace/drafts/
pub fn knowledge_drafts_dir() -> String {
  knowledge_workspace_dir() <> "/drafts"
}

/// Knowledge exports: .springdrift/knowledge/exports/
pub fn knowledge_exports_dir() -> String {
  knowledge_dir() <> "/exports"
}

/// Knowledge consolidation: .springdrift/knowledge/consolidation/
pub fn knowledge_consolidation_dir() -> String {
  knowledge_dir() <> "/consolidation"
}

/// Remembrancer run log: .springdrift/memory/consolidation/
pub fn consolidation_log_dir() -> String {
  project_dir() <> "/memory/consolidation"
}

/// Meta-learning worker state dir: .springdrift/memory/meta_learning/
/// Used by BEAM workers (affect correlation, fabrication audit, voice
/// drift) to persist `last_run_at` between restarts so a VM bounce
/// doesn't retrigger an audit that just ran.
pub fn meta_learning_dir() -> String {
  project_dir() <> "/memory/meta_learning"
}

/// Sidecar file tracking last-run timestamps for meta-learning workers.
pub fn meta_learning_state_file() -> String {
  meta_learning_dir() <> "/workers.json"
}

/// XStructor schema directory: .springdrift/schemas/
pub fn schemas_dir() -> String {
  project_dir() <> "/schemas"
}

/// Affect snapshot directory: .springdrift/memory/affect/
pub fn affect_dir() -> String {
  project_dir() <> "/memory/affect"
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
