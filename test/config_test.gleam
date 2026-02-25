import config.{AppConfig}
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// default
// ---------------------------------------------------------------------------

pub fn default_has_all_none_test() {
  let cfg = config.default()
  cfg.provider |> should.equal(None)
  cfg.model |> should.equal(None)
  cfg.system_prompt |> should.equal(None)
  cfg.max_tokens |> should.equal(None)
  cfg.max_turns |> should.equal(None)
  cfg.max_consecutive_errors |> should.equal(None)
  cfg.max_context_messages |> should.equal(None)
  cfg.task_model |> should.equal(None)
  cfg.reasoning_model |> should.equal(None)
  cfg.prompt_on_complex |> should.equal(None)
  cfg.data_dir |> should.equal(None)
}

// ---------------------------------------------------------------------------
// from_args
// ---------------------------------------------------------------------------

pub fn from_args_provider_test() {
  let cfg = config.from_args(["--provider", "anthropic"])
  cfg.provider |> should.equal(Some("anthropic"))
}

pub fn from_args_model_test() {
  let cfg = config.from_args(["--model", "gpt-4o"])
  cfg.model |> should.equal(Some("gpt-4o"))
}

pub fn from_args_system_test() {
  let cfg = config.from_args(["--system", "You are helpful."])
  cfg.system_prompt |> should.equal(Some("You are helpful."))
}

pub fn from_args_max_tokens_test() {
  let cfg = config.from_args(["--max-tokens", "2048"])
  cfg.max_tokens |> should.equal(Some(2048))
}

pub fn from_args_invalid_max_tokens_ignored_test() {
  let cfg = config.from_args(["--max-tokens", "not-a-number"])
  cfg.max_tokens |> should.equal(None)
}

pub fn from_args_unknown_flags_ignored_test() {
  let cfg = config.from_args(["--unknown", "value", "--provider", "openai"])
  cfg.provider |> should.equal(Some("openai"))
}

pub fn from_args_multiple_flags_test() {
  let cfg =
    config.from_args([
      "--provider", "anthropic", "--model", "claude-sonnet-4-20250514",
      "--max-tokens", "1024",
    ])
  cfg.provider |> should.equal(Some("anthropic"))
  cfg.model |> should.equal(Some("claude-sonnet-4-20250514"))
  cfg.max_tokens |> should.equal(Some(1024))
}

pub fn from_args_empty_test() {
  let cfg = config.from_args([])
  cfg |> should.equal(config.default())
}

// ---------------------------------------------------------------------------
// merge
// ---------------------------------------------------------------------------

pub fn merge_override_wins_test() {
  let base =
    AppConfig(
      provider: Some("anthropic"),
      model: None,
      system_prompt: None,
      max_tokens: None,
      max_turns: None,
      max_consecutive_errors: None,
      max_context_messages: None,
      task_model: None,
      reasoning_model: None,
      prompt_on_complex: None,
      data_dir: None,
    )
  let override =
    AppConfig(
      provider: Some("openai"),
      model: None,
      system_prompt: None,
      max_tokens: None,
      max_turns: None,
      max_consecutive_errors: None,
      max_context_messages: None,
      task_model: None,
      reasoning_model: None,
      prompt_on_complex: None,
      data_dir: None,
    )
  let merged = config.merge(base, override:)
  merged.provider |> should.equal(Some("openai"))
}

pub fn merge_base_preserved_when_override_none_test() {
  let base =
    AppConfig(
      provider: Some("anthropic"),
      model: Some("claude"),
      system_prompt: None,
      max_tokens: None,
      max_turns: None,
      max_consecutive_errors: None,
      max_context_messages: None,
      task_model: None,
      reasoning_model: None,
      prompt_on_complex: None,
      data_dir: None,
    )
  let override =
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
      data_dir: None,
    )
  let merged = config.merge(base, override:)
  merged.provider |> should.equal(Some("anthropic"))
  merged.model |> should.equal(Some("claude"))
}

pub fn merge_combines_different_fields_test() {
  let base =
    AppConfig(
      provider: Some("anthropic"),
      model: None,
      system_prompt: None,
      max_tokens: None,
      max_turns: None,
      max_consecutive_errors: None,
      max_context_messages: None,
      task_model: None,
      reasoning_model: None,
      prompt_on_complex: None,
      data_dir: None,
    )
  let override =
    AppConfig(
      provider: None,
      model: Some("gpt-4o"),
      system_prompt: Some("Be concise."),
      max_tokens: None,
      max_turns: None,
      max_consecutive_errors: None,
      max_context_messages: None,
      task_model: None,
      reasoning_model: None,
      prompt_on_complex: None,
      data_dir: None,
    )
  let merged = config.merge(base, override:)
  merged.provider |> should.equal(Some("anthropic"))
  merged.model |> should.equal(Some("gpt-4o"))
  merged.system_prompt |> should.equal(Some("Be concise."))
}

// ---------------------------------------------------------------------------
// parse_config_json
// ---------------------------------------------------------------------------

pub fn parse_config_json_full_test() {
  let json =
    "{\"provider\":\"anthropic\",\"model\":\"claude-sonnet-4-20250514\",\"system_prompt\":\"You are helpful.\",\"max_tokens\":2048}"
  let result = config.parse_config_json(json)
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.provider |> should.equal(Some("anthropic"))
  cfg.model |> should.equal(Some("claude-sonnet-4-20250514"))
  cfg.system_prompt |> should.equal(Some("You are helpful."))
  cfg.max_tokens |> should.equal(Some(2048))
}

pub fn parse_config_json_partial_test() {
  let result = config.parse_config_json("{\"provider\":\"openrouter\"}")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.provider |> should.equal(Some("openrouter"))
  cfg.model |> should.equal(None)
  cfg.max_tokens |> should.equal(None)
}

pub fn parse_config_json_empty_object_test() {
  let result = config.parse_config_json("{}")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.provider |> should.equal(None)
  cfg.max_tokens |> should.equal(None)
}

pub fn parse_config_json_invalid_test() {
  config.parse_config_json("not json") |> should.be_error
}

pub fn parse_config_json_model_only_test() {
  let result = config.parse_config_json("{\"model\":\"gpt-4o-mini\"}")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.model |> should.equal(Some("gpt-4o-mini"))
  cfg.provider |> should.equal(None)
}

// ---------------------------------------------------------------------------
// New numeric config fields
// ---------------------------------------------------------------------------

pub fn from_args_max_turns_test() {
  let cfg = config.from_args(["--max-turns", "10"])
  cfg.max_turns |> should.equal(Some(10))
}

pub fn from_args_max_errors_test() {
  let cfg = config.from_args(["--max-errors", "5"])
  cfg.max_consecutive_errors |> should.equal(Some(5))
}

pub fn from_args_max_context_test() {
  let cfg = config.from_args(["--max-context", "50"])
  cfg.max_context_messages |> should.equal(Some(50))
}

pub fn from_args_invalid_max_turns_ignored_test() {
  let cfg = config.from_args(["--max-turns", "nope"])
  cfg.max_turns |> should.equal(None)
}

pub fn parse_config_json_new_fields_test() {
  let json =
    "{\"max_turns\":8,\"max_consecutive_errors\":4,\"max_context_messages\":100}"
  let result = config.parse_config_json(json)
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.max_turns |> should.equal(Some(8))
  cfg.max_consecutive_errors |> should.equal(Some(4))
  cfg.max_context_messages |> should.equal(Some(100))
}

pub fn merge_new_fields_test() {
  let base =
    AppConfig(
      provider: None,
      model: None,
      system_prompt: None,
      max_tokens: None,
      max_turns: Some(5),
      max_consecutive_errors: None,
      max_context_messages: None,
      task_model: None,
      reasoning_model: None,
      prompt_on_complex: None,
      data_dir: None,
    )
  let override =
    AppConfig(
      provider: None,
      model: None,
      system_prompt: None,
      max_tokens: None,
      max_turns: Some(10),
      max_consecutive_errors: Some(2),
      max_context_messages: None,
      task_model: None,
      reasoning_model: None,
      prompt_on_complex: None,
      data_dir: None,
    )
  let merged = config.merge(base, override:)
  merged.max_turns |> should.equal(Some(10))
  merged.max_consecutive_errors |> should.equal(Some(2))
  merged.max_context_messages |> should.equal(None)
}

// ---------------------------------------------------------------------------
// Model switching config fields
// ---------------------------------------------------------------------------

pub fn from_args_task_model_test() {
  let cfg = config.from_args(["--task-model", "claude-haiku-4-5-20251001"])
  cfg.task_model |> should.equal(Some("claude-haiku-4-5-20251001"))
}

pub fn from_args_reasoning_model_test() {
  let cfg = config.from_args(["--reasoning-model", "claude-opus-4-6"])
  cfg.reasoning_model |> should.equal(Some("claude-opus-4-6"))
}

pub fn from_args_no_model_prompt_test() {
  let cfg = config.from_args(["--no-model-prompt"])
  cfg.prompt_on_complex |> should.equal(Some(False))
}

pub fn from_args_no_model_prompt_does_not_set_task_model_test() {
  let cfg = config.from_args(["--no-model-prompt"])
  cfg.task_model |> should.equal(None)
  cfg.reasoning_model |> should.equal(None)
}

pub fn parse_config_json_task_model_test() {
  let result =
    config.parse_config_json("{\"task_model\":\"claude-haiku-4-5-20251001\"}")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.task_model |> should.equal(Some("claude-haiku-4-5-20251001"))
}

pub fn parse_config_json_reasoning_model_test() {
  let result =
    config.parse_config_json("{\"reasoning_model\":\"claude-opus-4-6\"}")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.reasoning_model |> should.equal(Some("claude-opus-4-6"))
}

pub fn parse_config_json_prompt_on_complex_true_test() {
  let result = config.parse_config_json("{\"prompt_on_complex\":true}")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.prompt_on_complex |> should.equal(Some(True))
}

pub fn parse_config_json_prompt_on_complex_false_test() {
  let result = config.parse_config_json("{\"prompt_on_complex\":false}")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.prompt_on_complex |> should.equal(Some(False))
}

pub fn parse_config_json_all_model_fields_test() {
  let json =
    "{\"task_model\":\"gpt-4o-mini\",\"reasoning_model\":\"gpt-4o\",\"prompt_on_complex\":true}"
  let result = config.parse_config_json(json)
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.task_model |> should.equal(Some("gpt-4o-mini"))
  cfg.reasoning_model |> should.equal(Some("gpt-4o"))
  cfg.prompt_on_complex |> should.equal(Some(True))
}

pub fn merge_model_fields_override_wins_test() {
  let base =
    AppConfig(
      provider: None,
      model: None,
      system_prompt: None,
      max_tokens: None,
      max_turns: None,
      max_consecutive_errors: None,
      max_context_messages: None,
      task_model: Some("base-task"),
      reasoning_model: Some("base-reasoning"),
      prompt_on_complex: Some(True),
      data_dir: None,
    )
  let override =
    AppConfig(
      provider: None,
      model: None,
      system_prompt: None,
      max_tokens: None,
      max_turns: None,
      max_consecutive_errors: None,
      max_context_messages: None,
      task_model: Some("override-task"),
      reasoning_model: None,
      prompt_on_complex: Some(False),
      data_dir: None,
    )
  let merged = config.merge(base, override:)
  merged.task_model |> should.equal(Some("override-task"))
  merged.reasoning_model |> should.equal(Some("base-reasoning"))
  merged.prompt_on_complex |> should.equal(Some(False))
}

pub fn merge_model_fields_base_preserved_test() {
  let base =
    AppConfig(
      provider: None,
      model: None,
      system_prompt: None,
      max_tokens: None,
      max_turns: None,
      max_consecutive_errors: None,
      max_context_messages: None,
      task_model: Some("haiku"),
      reasoning_model: Some("opus"),
      prompt_on_complex: Some(True),
      data_dir: None,
    )
  let override =
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
      data_dir: None,
    )
  let merged = config.merge(base, override:)
  merged.task_model |> should.equal(Some("haiku"))
  merged.reasoning_model |> should.equal(Some("opus"))
  merged.prompt_on_complex |> should.equal(Some(True))
}

// ---------------------------------------------------------------------------
// data_dir
// ---------------------------------------------------------------------------

pub fn from_args_data_dir_test() {
  let cfg = config.from_args(["--data-dir", "/tmp/myproject/.springdrift"])
  cfg.data_dir |> should.equal(Some("/tmp/myproject/.springdrift"))
}

pub fn from_args_data_dir_relative_test() {
  let cfg = config.from_args(["--data-dir", ".springdrift"])
  cfg.data_dir |> should.equal(Some(".springdrift"))
}

pub fn default_data_dir_is_none_test() {
  let cfg = config.default()
  cfg.data_dir |> should.equal(None)
}

pub fn merge_data_dir_override_wins_test() {
  let base =
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
      data_dir: Some("/base/dir"),
    )
  let override =
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
      data_dir: Some("/override/dir"),
    )
  let merged = config.merge(base, override:)
  merged.data_dir |> should.equal(Some("/override/dir"))
}

pub fn merge_data_dir_base_preserved_when_override_none_test() {
  let base =
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
      data_dir: Some("/base/dir"),
    )
  let override =
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
      data_dir: None,
    )
  let merged = config.merge(base, override:)
  merged.data_dir |> should.equal(Some("/base/dir"))
}
