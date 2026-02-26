//// Application configuration loaded from CLI flags and JSON config files.
////
//// Priority (highest to lowest):
////   1. CLI flags       (--provider, --model, --system, --max-tokens, etc.)
////   2. Local config    (.springdrift.json in current directory)
////   3. User config     (~/.config/springdrift/config.json)
////
//// Config file format:
////   {
////     "provider": "anthropic",
////     "model": "claude-sonnet-4-20250514",
////     "system_prompt": "You are a helpful assistant.",
////     "max_tokens": 2048,
////     "max_turns": 5,
////     "max_consecutive_errors": 3,
////     "max_context_messages": 50,
////     "task_model": "claude-haiku-4-5-20251001",
////     "reasoning_model": "claude-opus-4-6",
////     "prompt_on_complex": true
////   }

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

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
    prompt_on_complex: Option(Bool),
    config_path: Option(String),
    log_verbose: Option(Bool),
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
    prompt_on_complex: None,
    config_path: None,
    log_verbose: None,
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
    prompt_on_complex: option.or(
      override_cfg.prompt_on_complex,
      base.prompt_on_complex,
    ),
    config_path: option.or(override_cfg.config_path, base.config_path),
    log_verbose: option.or(override_cfg.log_verbose, base.log_verbose),
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
///   --no-model-prompt      auto-switch to reasoning model without prompting
pub fn from_args(args: List(String)) -> AppConfig {
  do_parse_args(args, default())
}

/// Parse a JSON string into an AppConfig. Returns Error(Nil) on parse failure.
pub fn parse_config_json(input: String) -> Result(AppConfig, Nil) {
  json.parse(input, config_decoder())
  |> result.map_error(fn(_) { Nil })
}

/// Load config from disk: merges user config with local config (local wins).
pub fn load_file() -> AppConfig {
  let local = load_from_path(".springdrift.json")
  let user = case get_env("HOME") {
    Ok(home) -> load_from_path(home <> "/.config/springdrift/config.json")
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
    option.map(cfg.prompt_on_complex, fn(v) {
      "prompt_on_complex: "
      <> case v {
        True -> "true"
        False -> "false"
      }
    }),
    option.map(cfg.config_path, fn(v) { "config_path: " <> v }),
    option.map(cfg.log_verbose, fn(v) {
      "log_verbose: "
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
    ["--no-model-prompt", ..rest] ->
      do_parse_args(rest, AppConfig(..acc, prompt_on_complex: Some(False)))
    ["--config", path, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, config_path: Some(path)))
    ["--verbose", ..rest] ->
      do_parse_args(rest, AppConfig(..acc, log_verbose: Some(True)))
    [_, ..rest] -> do_parse_args(rest, acc)
  }
}

fn config_decoder() -> decode.Decoder(AppConfig) {
  use provider <- decode.optional_field(
    "provider",
    None,
    decode.string |> decode.map(Some),
  )
  use model <- decode.optional_field(
    "model",
    None,
    decode.string |> decode.map(Some),
  )
  use system_prompt <- decode.optional_field(
    "system_prompt",
    None,
    decode.string |> decode.map(Some),
  )
  use max_tokens <- decode.optional_field(
    "max_tokens",
    None,
    decode.int |> decode.map(Some),
  )
  use max_turns <- decode.optional_field(
    "max_turns",
    None,
    decode.int |> decode.map(Some),
  )
  use max_consecutive_errors <- decode.optional_field(
    "max_consecutive_errors",
    None,
    decode.int |> decode.map(Some),
  )
  use max_context_messages <- decode.optional_field(
    "max_context_messages",
    None,
    decode.int |> decode.map(Some),
  )
  use task_model <- decode.optional_field(
    "task_model",
    None,
    decode.string |> decode.map(Some),
  )
  use reasoning_model <- decode.optional_field(
    "reasoning_model",
    None,
    decode.string |> decode.map(Some),
  )
  use prompt_on_complex <- decode.optional_field(
    "prompt_on_complex",
    None,
    decode.bool |> decode.map(Some),
  )
  use log_verbose <- decode.optional_field(
    "log_verbose",
    None,
    decode.bool |> decode.map(Some),
  )
  decode.success(AppConfig(
    provider:,
    model:,
    system_prompt:,
    max_tokens:,
    max_turns:,
    max_consecutive_errors:,
    max_context_messages:,
    task_model:,
    reasoning_model:,
    prompt_on_complex:,
    config_path: None,
    log_verbose:,
  ))
}

fn load_from_path(path: String) -> AppConfig {
  case simplifile.read(path) {
    Error(_) -> default()
    Ok(contents) ->
      parse_config_json(contents)
      |> result.unwrap(default())
  }
}
