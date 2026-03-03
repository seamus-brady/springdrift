//// Application configuration loaded from CLI flags and TOML config files.
////
//// Priority (highest to lowest):
////   1. CLI flags       (--provider, --model, --system, --max-tokens, etc.)
////   2. Local config    (.springdrift.toml in current directory)
////   3. User config     (~/.config/springdrift/config.toml)
////
//// All fields are optional. Unset fields fall back to built-in defaults
//// applied in springdrift.gleam at startup.
////
//// Config file format (all fields optional):
////
////   # LLM provider — "anthropic" | "openrouter" | "openai" | "mock"
////   # Default: auto-detect from environment variables
////   provider = "anthropic"
////
////   # Model identifier for the main model
////   # Default: provider-specific (e.g. claude-sonnet-4-20250514)
////   model = "claude-sonnet-4-20250514"
////
////   # System prompt sent to the LLM on every request
////   # Default: "You are a helpful assistant."
////   system_prompt = "You are a helpful assistant."
////
////   # Maximum output tokens per LLM call
////   # Default: 1024
////   max_tokens = 2048
////
////   # Maximum react-loop iterations before giving up on a single message
////   # Default: 5
////   max_turns = 5
////
////   # Consecutive tool failures before the loop aborts (circuit breaker)
////   # Default: 3
////   max_consecutive_errors = 3
////
////   # Sliding-window cap on context messages (oldest dropped first)
////   # Default: unlimited (omit field)
////   max_context_messages = 50
////
////   # Model used for queries classified as Simple
////   # Default: provider-specific (e.g. claude-haiku-4-5-20251001)
////   task_model = "claude-haiku-4-5-20251001"
////
////   # Model used for queries classified as Complex
////   # Default: provider-specific (e.g. claude-opus-4-6)
////   reasoning_model = "claude-opus-4-6"
////
////   # Log full LLM request/response payloads to the cycle log
////   # Default: false
////   log_verbose = false
////
////   # Additional skill directories scanned for SKILL.md files
////   # Default: ["~/.config/springdrift/skills", ".skills"]
////   skills_dirs = ["/path/to/my/skills"]
////
////   # Allow write_file to write files outside the current working directory
////   # Default: false
////   write_anywhere = false
////
//// CLI flags always override config file values.
//// --skills-dir is repeatable and appends to (rather than replaces) the list.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tom

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type AppConfig {
  AppConfig(
    provider: Option(String),
    model: Option(String),
    system_prompt: Option(String),
    max_tokens: Option(Int),
    max_turns: Option(Int),
    max_consecutive_errors: Option(Int),
    max_context_messages: Option(Int),
    task_model: Option(String),
    reasoning_model: Option(String),
    config_path: Option(String),
    log_verbose: Option(Bool),
    skills_dirs: Option(List(String)),
    write_anywhere: Option(Bool),
  )
}

// ---------------------------------------------------------------------------
// Erlang FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_args")
fn get_args() -> List(String)

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// An AppConfig with all fields unset.
pub fn default() -> AppConfig {
  AppConfig(
    provider: None,
    model: None,
    system_prompt: None,
    max_tokens: None,
    max_turns: None,
    max_consecutive_errors: None,
    max_context_messages: None,
    task_model: None,
    reasoning_model: None,
    config_path: None,
    log_verbose: None,
    skills_dirs: None,
    write_anywhere: None,
  )
}

/// Merge two configs. Fields set in `override` win; unset fields fall back to `base`.
pub fn merge(base: AppConfig, override override_cfg: AppConfig) -> AppConfig {
  AppConfig(
    provider: option.or(override_cfg.provider, base.provider),
    model: option.or(override_cfg.model, base.model),
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
    task_model: option.or(override_cfg.task_model, base.task_model),
    reasoning_model: option.or(
      override_cfg.reasoning_model,
      base.reasoning_model,
    ),
    config_path: option.or(override_cfg.config_path, base.config_path),
    log_verbose: option.or(override_cfg.log_verbose, base.log_verbose),
    skills_dirs: option.or(override_cfg.skills_dirs, base.skills_dirs),
    write_anywhere: option.or(override_cfg.write_anywhere, base.write_anywhere),
  )
}

/// Parse CLI flags into an AppConfig. Unknown flags are silently ignored.
///
/// Recognised flags:
///   --provider <name>      anthropic | openrouter | openai
///   --model    <name>      any model identifier
///   --system   <prompt>    system prompt string
///   --max-tokens <n>       integer — max output tokens per LLM call
///   --max-turns <n>        integer — max react-loop turns per user message (default 5)
///   --max-errors <n>       integer — max consecutive tool failures before abort (default 3)
///   --max-context <n>      integer — max messages kept in context window (default unlimited)
///   --task-model <name>    model to use for simple queries
///   --reasoning-model <name>  model to use for complex queries
pub fn from_args(args: List(String)) -> AppConfig {
  do_parse_args(args, default())
}

/// Parse a TOML string into an AppConfig. Returns Error(Nil) on parse failure.
pub fn parse_config_toml(input: String) -> Result(AppConfig, Nil) {
  case tom.parse(input) {
    Error(_) -> Error(Nil)
    Ok(toml) -> Ok(toml_to_config(toml))
  }
}

/// Load config from disk: merges user config with local config (local wins).
pub fn load_file() -> AppConfig {
  let local = load_from_path(".springdrift.toml")
  let user = case get_env("HOME") {
    Ok(home) -> load_from_path(home <> "/.config/springdrift/config.toml")
    Error(_) -> default()
  }
  merge(user, local)
}

/// Resolve the full config: file config merged with CLI args (CLI wins).
pub fn resolve() -> AppConfig {
  let file_cfg = load_file()
  let cli_cfg = from_args(get_args())
  merge(file_cfg, cli_cfg)
}

/// Produce a human-readable one-field-per-line summary of the config.
/// Only fields that are set (non-None) are included.
pub fn to_string(cfg: AppConfig) -> String {
  [
    option.map(cfg.provider, fn(v) { "provider: " <> v }),
    option.map(cfg.model, fn(v) { "model: " <> v }),
    option.map(cfg.system_prompt, fn(v) { "system_prompt: " <> v }),
    option.map(cfg.max_tokens, fn(v) { "max_tokens: " <> int.to_string(v) }),
    option.map(cfg.max_turns, fn(v) { "max_turns: " <> int.to_string(v) }),
    option.map(cfg.max_consecutive_errors, fn(v) {
      "max_consecutive_errors: " <> int.to_string(v)
    }),
    option.map(cfg.max_context_messages, fn(v) {
      "max_context_messages: " <> int.to_string(v)
    }),
    option.map(cfg.task_model, fn(v) { "task_model: " <> v }),
    option.map(cfg.reasoning_model, fn(v) { "reasoning_model: " <> v }),
    option.map(cfg.config_path, fn(v) { "config_path: " <> v }),
    option.map(cfg.log_verbose, fn(v) {
      "log_verbose: "
      <> case v {
        True -> "true"
        False -> "false"
      }
    }),
    option.map(cfg.skills_dirs, fn(dirs) {
      "skills_dirs: " <> string.join(dirs, ", ")
    }),
    option.map(cfg.write_anywhere, fn(v) {
      "write_anywhere: "
      <> case v {
        True -> "true"
        False -> "false"
      }
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
    ["--provider", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, provider: Some(value)))
    ["--model", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, model: Some(value)))
    ["--system", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, system_prompt: Some(value)))
    ["--max-tokens", value, ..rest] ->
      case int.parse(value) {
        Ok(n) -> do_parse_args(rest, AppConfig(..acc, max_tokens: Some(n)))
        Error(_) -> do_parse_args(rest, acc)
      }
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
    ["--task-model", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, task_model: Some(value)))
    ["--reasoning-model", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, reasoning_model: Some(value)))
    ["--config", path, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, config_path: Some(path)))
    ["--verbose", ..rest] ->
      do_parse_args(rest, AppConfig(..acc, log_verbose: Some(True)))
    ["--skills-dir", path, ..rest] ->
      case acc.skills_dirs {
        None -> do_parse_args(rest, AppConfig(..acc, skills_dirs: Some([path])))
        Some(existing) ->
          do_parse_args(
            rest,
            AppConfig(..acc, skills_dirs: Some(list.append(existing, [path]))),
          )
      }
    ["--allow-write-anywhere", ..rest] ->
      do_parse_args(rest, AppConfig(..acc, write_anywhere: Some(True)))
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
    model: get_str("model"),
    system_prompt: get_str("system_prompt"),
    max_tokens: get_int("max_tokens"),
    max_turns: get_int("max_turns"),
    max_consecutive_errors: get_int("max_consecutive_errors"),
    max_context_messages: get_int("max_context_messages"),
    task_model: get_str("task_model"),
    reasoning_model: get_str("reasoning_model"),
    config_path: None,
    log_verbose: get_bool("log_verbose"),
    skills_dirs:,
    write_anywhere: get_bool("write_anywhere"),
  )
}

fn load_from_path(path: String) -> AppConfig {
  case simplifile.read(path) {
    Error(_) -> default()
    Ok(contents) ->
      parse_config_toml(contents)
      |> result.unwrap(default())
  }
}
