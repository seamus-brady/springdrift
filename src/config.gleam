//// Application configuration loaded from CLI flags and TOML config files.
////
//// Priority (highest to lowest):
////   1. CLI flags       (--provider, --task-model, --system, --max-tokens, etc.)
////   2. Local config    (.springdrift/config.toml in current directory)
////   3. User config     (~/.config/springdrift/config.toml)
////
//// All fields are optional. Unset fields fall back to built-in defaults
//// applied in springdrift.gleam at startup.
////
//// Config file format (all fields optional):
////
////   # LLM provider and models (provider is required for a real LLM)
////   provider        = "anthropic"        # "anthropic" | "openrouter" | "openai" | "mistral" | "local" | "mock"
////   task_model      = "claude-haiku-4-5-20251001"   # Model for Simple queries
////   reasoning_model = "claude-opus-4-6"             # Model for Complex queries
////   system_prompt   = "You are a helpful assistant."
////   max_tokens      = 2048               # Max output tokens per LLM call
////
////   # Loop control
////   max_turns              = 5            # React-loop iterations per message
////   max_consecutive_errors = 3            # Tool failures before abort
////   max_context_messages   = 50           # Sliding-window cap (omit for unlimited)
////
////   # Logging and filesystem
////   log_verbose    = false                # Log full LLM payloads to cycle log
////   write_anywhere = false                # Allow write_file outside CWD
////   skills_dirs    = ["/path/to/skills"]  # Extra skill directories
////
////   # GUI
////   gui = "tui"                           # "tui" (default) or "web"
////
//// CLI flags always override config file values.
//// --skills-dir is repeatable and appends to (rather than replaces) the list.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import paths
import simplifile
import slog
import tom

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type AppConfig {
  AppConfig(
    // LLM provider and models
    provider: Option(String),
    task_model: Option(String),
    reasoning_model: Option(String),
    system_prompt: Option(String),
    max_tokens: Option(Int),
    // Loop control
    max_turns: Option(Int),
    max_consecutive_errors: Option(Int),
    max_context_messages: Option(Int),
    // Logging and filesystem
    log_verbose: Option(Bool),
    write_anywhere: Option(Bool),
    skills_dirs: Option(List(String)),
    // Session
    config_path: Option(String),
    // GUI
    gui: Option(String),
    // D' safety system
    dprime_enabled: Option(Bool),
    dprime_config: Option(String),
    // Narrative
    narrative_enabled: Option(Bool),
    narrative_dir: Option(String),
    archivist_model: Option(String),
    narrative_threading: Option(Bool),
    narrative_summaries: Option(Bool),
    narrative_summary_schedule: Option(String),
    // Profiles
    profiles_dirs: Option(List(String)),
    default_profile: Option(String),
  )
}

// ---------------------------------------------------------------------------
// Erlang FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_args")
fn get_args() -> List(String)

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// An AppConfig with all fields unset.
pub fn default() -> AppConfig {
  AppConfig(
    provider: None,
    task_model: None,
    reasoning_model: None,
    system_prompt: None,
    max_tokens: None,
    max_turns: None,
    max_consecutive_errors: None,
    max_context_messages: None,
    log_verbose: None,
    write_anywhere: None,
    skills_dirs: None,
    config_path: None,
    gui: None,
    dprime_enabled: None,
    dprime_config: None,
    narrative_enabled: None,
    narrative_dir: None,
    archivist_model: None,
    narrative_threading: None,
    narrative_summaries: None,
    narrative_summary_schedule: None,
    profiles_dirs: None,
    default_profile: None,
  )
}

/// Merge two configs. Fields set in `override` win; unset fields fall back to `base`.
pub fn merge(base: AppConfig, override override_cfg: AppConfig) -> AppConfig {
  AppConfig(
    provider: option.or(override_cfg.provider, base.provider),
    task_model: option.or(override_cfg.task_model, base.task_model),
    reasoning_model: option.or(
      override_cfg.reasoning_model,
      base.reasoning_model,
    ),
    system_prompt: option.or(override_cfg.system_prompt, base.system_prompt),
    max_tokens: option.or(override_cfg.max_tokens, base.max_tokens),
    max_turns: option.or(override_cfg.max_turns, base.max_turns),
    max_consecutive_errors: option.or(
      override_cfg.max_consecutive_errors,
      base.max_consecutive_errors,
    ),
    max_context_messages: option.or(
      override_cfg.max_context_messages,
      base.max_context_messages,
    ),
    log_verbose: option.or(override_cfg.log_verbose, base.log_verbose),
    write_anywhere: option.or(override_cfg.write_anywhere, base.write_anywhere),
    skills_dirs: option.or(override_cfg.skills_dirs, base.skills_dirs),
    config_path: option.or(override_cfg.config_path, base.config_path),
    gui: option.or(override_cfg.gui, base.gui),
    dprime_enabled: option.or(override_cfg.dprime_enabled, base.dprime_enabled),
    dprime_config: option.or(override_cfg.dprime_config, base.dprime_config),
    narrative_enabled: option.or(
      override_cfg.narrative_enabled,
      base.narrative_enabled,
    ),
    narrative_dir: option.or(override_cfg.narrative_dir, base.narrative_dir),
    archivist_model: option.or(
      override_cfg.archivist_model,
      base.archivist_model,
    ),
    narrative_threading: option.or(
      override_cfg.narrative_threading,
      base.narrative_threading,
    ),
    narrative_summaries: option.or(
      override_cfg.narrative_summaries,
      base.narrative_summaries,
    ),
    narrative_summary_schedule: option.or(
      override_cfg.narrative_summary_schedule,
      base.narrative_summary_schedule,
    ),
    profiles_dirs: option.or(override_cfg.profiles_dirs, base.profiles_dirs),
    default_profile: option.or(
      override_cfg.default_profile,
      base.default_profile,
    ),
  )
}

/// Parse CLI flags into an AppConfig. Unknown flags are silently ignored.
pub fn from_args(args: List(String)) -> AppConfig {
  do_parse_args(args, default())
}

/// Parse a TOML string into an AppConfig. Returns Error(Nil) on parse failure.
/// Logs warnings for unknown keys and invalid values via slog.
pub fn parse_config_toml(input: String) -> Result(AppConfig, Nil) {
  case tom.parse(input) {
    Error(_) -> Error(Nil)
    Ok(toml) -> {
      validate_toml_keys(toml)
      let cfg = toml_to_config(toml)
      validate_config_values(cfg)
      Ok(cfg)
    }
  }
}

/// Load config from disk: merges user config with local config (local wins).
/// Also checks legacy .springdrift.toml for backwards compatibility.
pub fn load_file() -> AppConfig {
  let local = case simplifile.is_file(paths.local_config()) {
    Ok(True) -> load_from_path(paths.local_config())
    _ ->
      // Legacy fallback: .springdrift.toml in project root
      load_from_path(".springdrift.toml")
  }
  let user = load_from_path(paths.user_config())
  merge(user, local)
}

/// Resolve the full config: file config merged with CLI args (CLI wins).
pub fn resolve() -> AppConfig {
  slog.debug("config", "resolve", "Resolving config", None)
  let file_cfg = load_file()
  let cli_cfg = from_args(get_args())
  merge(file_cfg, cli_cfg)
}

/// Produce a human-readable one-field-per-line summary of the config.
/// Only fields that are set (non-None) are included.
pub fn to_string(cfg: AppConfig) -> String {
  [
    // LLM provider and models
    option.map(cfg.provider, fn(v) { "provider: " <> v }),
    option.map(cfg.task_model, fn(v) { "task_model: " <> v }),
    option.map(cfg.reasoning_model, fn(v) { "reasoning_model: " <> v }),
    option.map(cfg.system_prompt, fn(v) { "system_prompt: " <> v }),
    option.map(cfg.max_tokens, fn(v) { "max_tokens: " <> int.to_string(v) }),
    // Loop control
    option.map(cfg.max_turns, fn(v) { "max_turns: " <> int.to_string(v) }),
    option.map(cfg.max_consecutive_errors, fn(v) {
      "max_consecutive_errors: " <> int.to_string(v)
    }),
    option.map(cfg.max_context_messages, fn(v) {
      "max_context_messages: " <> int.to_string(v)
    }),
    // Logging and filesystem
    option.map(cfg.log_verbose, fn(v) {
      "log_verbose: "
      <> case v {
        True -> "true"
        False -> "false"
      }
    }),
    option.map(cfg.write_anywhere, fn(v) {
      "write_anywhere: "
      <> case v {
        True -> "true"
        False -> "false"
      }
    }),
    option.map(cfg.skills_dirs, fn(dirs) {
      "skills_dirs: " <> string.join(dirs, ", ")
    }),
    // Session
    option.map(cfg.config_path, fn(v) { "config_path: " <> v }),
    // GUI
    option.map(cfg.gui, fn(v) { "gui: " <> v }),
    // D' safety system
    option.map(cfg.dprime_enabled, fn(v) {
      "dprime_enabled: "
      <> case v {
        True -> "true"
        False -> "false"
      }
    }),
    option.map(cfg.dprime_config, fn(v) { "dprime_config: " <> v }),
    // Narrative
    option.map(cfg.narrative_enabled, fn(v) {
      "narrative_enabled: "
      <> case v {
        True -> "true"
        False -> "false"
      }
    }),
    option.map(cfg.narrative_dir, fn(v) { "narrative_dir: " <> v }),
    option.map(cfg.archivist_model, fn(v) { "archivist_model: " <> v }),
    // Profile
    option.map(cfg.default_profile, fn(v) { "profile: " <> v }),
    option.map(cfg.profiles_dirs, fn(dirs) {
      "profiles_dirs: " <> string.join(dirs, ", ")
    }),
  ]
  |> list.filter_map(fn(x) { option.to_result(x, Nil) })
  |> string.join("\n")
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn do_parse_args(args: List(String), acc: AppConfig) -> AppConfig {
  case args {
    [] -> acc
    // LLM provider and models
    ["--provider", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, provider: Some(value)))
    ["--task-model", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, task_model: Some(value)))
    ["--reasoning-model", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, reasoning_model: Some(value)))
    ["--system", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, system_prompt: Some(value)))
    ["--max-tokens", value, ..rest] ->
      case int.parse(value) {
        Ok(n) -> do_parse_args(rest, AppConfig(..acc, max_tokens: Some(n)))
        Error(_) -> do_parse_args(rest, acc)
      }
    // Loop control
    ["--max-turns", value, ..rest] ->
      case int.parse(value) {
        Ok(n) -> do_parse_args(rest, AppConfig(..acc, max_turns: Some(n)))
        Error(_) -> do_parse_args(rest, acc)
      }
    ["--max-errors", value, ..rest] ->
      case int.parse(value) {
        Ok(n) ->
          do_parse_args(rest, AppConfig(..acc, max_consecutive_errors: Some(n)))
        Error(_) -> do_parse_args(rest, acc)
      }
    ["--max-context", value, ..rest] ->
      case int.parse(value) {
        Ok(n) ->
          do_parse_args(rest, AppConfig(..acc, max_context_messages: Some(n)))
        Error(_) -> do_parse_args(rest, acc)
      }
    // Logging and filesystem
    ["--verbose", ..rest] ->
      do_parse_args(rest, AppConfig(..acc, log_verbose: Some(True)))
    ["--allow-write-anywhere", ..rest] ->
      do_parse_args(rest, AppConfig(..acc, write_anywhere: Some(True)))
    ["--skills-dir", path, ..rest] ->
      case acc.skills_dirs {
        None -> do_parse_args(rest, AppConfig(..acc, skills_dirs: Some([path])))
        Some(existing) ->
          do_parse_args(
            rest,
            AppConfig(..acc, skills_dirs: Some(list.append(existing, [path]))),
          )
      }
    // Session
    ["--config", path, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, config_path: Some(path)))
    // GUI
    ["--gui", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, gui: Some(value)))
    // D' safety system
    ["--dprime", ..rest] ->
      do_parse_args(rest, AppConfig(..acc, dprime_enabled: Some(True)))
    ["--no-dprime", ..rest] ->
      do_parse_args(rest, AppConfig(..acc, dprime_enabled: Some(False)))
    ["--dprime-config", path, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, dprime_config: Some(path)))
    // Narrative
    ["--narrative", ..rest] ->
      do_parse_args(rest, AppConfig(..acc, narrative_enabled: Some(True)))
    ["--no-narrative", ..rest] ->
      do_parse_args(rest, AppConfig(..acc, narrative_enabled: Some(False)))
    ["--narrative-dir", path, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, narrative_dir: Some(path)))
    // Profiles
    ["--profile", name, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, default_profile: Some(name)))
    ["--profiles-dir", path, ..rest] ->
      case acc.profiles_dirs {
        None ->
          do_parse_args(rest, AppConfig(..acc, profiles_dirs: Some([path])))
        Some(existing) ->
          do_parse_args(
            rest,
            AppConfig(..acc, profiles_dirs: Some(list.append(existing, [path]))),
          )
      }
    [_, ..rest] -> do_parse_args(rest, acc)
  }
}

fn toml_to_config(table: dict.Dict(String, tom.Toml)) -> AppConfig {
  let get_str = fn(key) {
    case tom.get_string(table, [key]) {
      Ok(v) -> Some(v)
      Error(_) -> None
    }
  }
  let get_int = fn(key) {
    case tom.get_int(table, [key]) {
      Ok(v) -> Some(v)
      Error(_) -> None
    }
  }
  let get_bool = fn(key) {
    case tom.get_bool(table, [key]) {
      Ok(v) -> Some(v)
      Error(_) -> None
    }
  }
  let skills_dirs = case tom.get_array(table, ["skills_dirs"]) {
    Error(_) -> None
    Ok(items) ->
      Some(
        list.filter_map(items, fn(item) {
          case item {
            tom.String(s) -> Ok(s)
            _ -> Error(Nil)
          }
        }),
      )
  }
  AppConfig(
    provider: get_str("provider"),
    task_model: get_str("task_model"),
    reasoning_model: get_str("reasoning_model"),
    system_prompt: get_str("system_prompt"),
    max_tokens: get_int("max_tokens"),
    max_turns: get_int("max_turns"),
    max_consecutive_errors: get_int("max_consecutive_errors"),
    max_context_messages: get_int("max_context_messages"),
    log_verbose: get_bool("log_verbose"),
    write_anywhere: get_bool("write_anywhere"),
    skills_dirs:,
    config_path: None,
    gui: get_str("gui"),
    dprime_enabled: get_bool("dprime_enabled"),
    dprime_config: get_str("dprime_config"),
    narrative_enabled: case tom.get_bool(table, ["narrative", "enabled"]) {
      Ok(v) -> Some(v)
      Error(_) -> None
    },
    narrative_dir: case tom.get_string(table, ["narrative", "directory"]) {
      Ok(v) -> Some(v)
      Error(_) -> None
    },
    archivist_model: case
      tom.get_string(table, ["narrative", "archivist_model"])
    {
      Ok(v) -> Some(v)
      Error(_) -> None
    },
    narrative_threading: case tom.get_bool(table, ["narrative", "threading"]) {
      Ok(v) -> Some(v)
      Error(_) -> None
    },
    narrative_summaries: case tom.get_bool(table, ["narrative", "summaries"]) {
      Ok(v) -> Some(v)
      Error(_) -> None
    },
    narrative_summary_schedule: case
      tom.get_string(table, ["narrative", "summary_schedule"])
    {
      Ok(v) -> Some(v)
      Error(_) -> None
    },
    default_profile: get_str("profile"),
    profiles_dirs: case tom.get_array(table, ["profiles_dirs"]) {
      Error(_) -> None
      Ok(items) ->
        Some(
          list.filter_map(items, fn(item) {
            case item {
              tom.String(s) -> Ok(s)
              _ -> Error(Nil)
            }
          }),
        )
    },
  )
}

fn load_from_path(path: String) -> AppConfig {
  case simplifile.read(path) {
    Error(_) -> default()
    Ok(contents) ->
      case parse_config_toml(contents) {
        Error(_) -> {
          slog.warn(
            "config",
            "load",
            "Failed to parse config file: " <> path,
            None,
          )
          default()
        }
        Ok(cfg) -> cfg
      }
  }
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

const known_keys = [
  "provider", "task_model", "reasoning_model", "system_prompt", "max_tokens",
  "max_turns", "max_consecutive_errors", "max_context_messages", "log_verbose",
  "write_anywhere", "skills_dirs", "gui", "dprime_enabled", "dprime_config",
  "narrative", "profile", "profiles_dirs",
]

const known_narrative_keys = [
  "enabled", "directory", "archivist_model", "threading", "summaries",
  "summary_schedule",
]

fn validate_toml_keys(table: dict.Dict(String, tom.Toml)) -> Nil {
  dict.keys(table)
  |> list.each(fn(key) {
    case list.contains(known_keys, key) {
      True -> Nil
      False ->
        slog.warn(
          "config",
          "validate",
          "Unknown config key: \"" <> key <> "\" — possible typo?",
          None,
        )
    }
  })
  case tom.get_table(table, ["narrative"]) {
    Ok(narrative_table) ->
      dict.keys(narrative_table)
      |> list.each(fn(key) {
        case list.contains(known_narrative_keys, key) {
          True -> Nil
          False ->
            slog.warn(
              "config",
              "validate",
              "Unknown narrative config key: \"" <> key <> "\" — possible typo?",
              None,
            )
        }
      })
    Error(_) -> Nil
  }
  Nil
}

fn validate_config_values(cfg: AppConfig) -> Nil {
  case cfg.max_tokens {
    Some(n) ->
      case n <= 0 {
        True ->
          slog.warn(
            "config",
            "validate",
            "max_tokens must be positive, got " <> int.to_string(n),
            None,
          )
        False -> Nil
      }
    None -> Nil
  }
  case cfg.max_turns {
    Some(n) ->
      case n <= 0 {
        True ->
          slog.warn(
            "config",
            "validate",
            "max_turns must be positive, got " <> int.to_string(n),
            None,
          )
        False -> Nil
      }
    None -> Nil
  }
  case cfg.max_consecutive_errors {
    Some(n) ->
      case n <= 0 {
        True ->
          slog.warn(
            "config",
            "validate",
            "max_consecutive_errors must be positive, got " <> int.to_string(n),
            None,
          )
        False -> Nil
      }
    None -> Nil
  }
  case cfg.max_context_messages {
    Some(n) ->
      case n <= 0 {
        True ->
          slog.warn(
            "config",
            "validate",
            "max_context_messages must be positive, got " <> int.to_string(n),
            None,
          )
        False -> Nil
      }
    None -> Nil
  }
  case cfg.provider {
    Some(p) ->
      case
        list.contains(
          ["anthropic", "openrouter", "openai", "mistral", "local", "mock"],
          p,
        )
      {
        True -> Nil
        False ->
          slog.warn(
            "config",
            "validate",
            "Unknown provider: \""
              <> p
              <> "\". Valid: anthropic, openrouter, openai, mistral, local, mock",
            None,
          )
      }
    None -> Nil
  }
  case cfg.gui {
    Some(g) ->
      case list.contains(["tui", "web"], g) {
        True -> Nil
        False ->
          slog.warn(
            "config",
            "validate",
            "Unknown gui mode: \"" <> g <> "\". Valid: tui, web",
            None,
          )
      }
    None -> Nil
  }
  Nil
}
