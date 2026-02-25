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
////     "max_context_messages": 50
////   }

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
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
  decode.success(AppConfig(
    provider:,
    model:,
    system_prompt:,
    max_tokens:,
    max_turns:,
    max_consecutive_errors:,
    max_context_messages:,
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
