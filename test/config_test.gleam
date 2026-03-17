import config.{AppConfig}
import gleam/option.{None, Some}
import gleam/string
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

  cfg.agent_name |> should.equal(None)
  cfg.agent_version |> should.equal(None)
  cfg.max_tokens |> should.equal(None)
  cfg.max_turns |> should.equal(None)
  cfg.max_consecutive_errors |> should.equal(None)
  cfg.max_context_messages |> should.equal(None)
  cfg.task_model |> should.equal(None)
  cfg.reasoning_model |> should.equal(None)
  cfg.config_path |> should.equal(None)
  cfg.log_verbose |> should.equal(None)
  cfg.skills_dirs |> should.equal(None)
  cfg.write_anywhere |> should.equal(None)
  cfg.gui |> should.equal(None)
  cfg.dprime_enabled |> should.equal(None)
  cfg.dprime_config |> should.equal(None)
  // New fields
  cfg.llm_request_timeout_ms |> should.equal(None)
  cfg.retry_max_retries |> should.equal(None)
  cfg.max_artifact_chars |> should.equal(None)
  cfg.vsa_dimensions |> should.equal(None)
  cfg.web_port |> should.equal(None)
  cfg.planner_max_turns |> should.equal(None)
}

// ---------------------------------------------------------------------------
// from_args
// ---------------------------------------------------------------------------

pub fn from_args_provider_test() {
  let cfg = config.from_args(["--provider", "anthropic"])
  cfg.provider |> should.equal(Some("anthropic"))
}

pub fn from_args_agent_name_test() {
  let cfg = config.from_args(["--agent-name", "TestBot"])
  cfg.agent_name |> should.equal(Some("TestBot"))
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
      "--provider", "anthropic", "--task-model", "claude-haiku-4-5-20251001",
      "--max-tokens", "1024",
    ])
  cfg.provider |> should.equal(Some("anthropic"))
  cfg.task_model |> should.equal(Some("claude-haiku-4-5-20251001"))
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
  let base = AppConfig(..config.default(), provider: Some("anthropic"))
  let override = AppConfig(..config.default(), provider: Some("openai"))
  let merged = config.merge(base, override:)
  merged.provider |> should.equal(Some("openai"))
}

pub fn merge_base_preserved_when_override_none_test() {
  let base = AppConfig(..config.default(), provider: Some("anthropic"))
  let override = config.default()
  let merged = config.merge(base, override:)
  merged.provider |> should.equal(Some("anthropic"))
}

pub fn merge_combines_different_fields_test() {
  let base = AppConfig(..config.default(), provider: Some("anthropic"))
  let override = AppConfig(..config.default(), agent_name: Some("TestBot"))
  let merged = config.merge(base, override:)
  merged.provider |> should.equal(Some("anthropic"))
  merged.agent_name |> should.equal(Some("TestBot"))
}

// ---------------------------------------------------------------------------
// parse_config_toml
// ---------------------------------------------------------------------------

pub fn parse_config_toml_full_test() {
  let toml =
    "provider = \"anthropic\"
task_model = \"claude-haiku-4-5-20251001\"
max_tokens = 2048

[agent]
name = \"TestBot\""
  let result = config.parse_config_toml(toml)
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.provider |> should.equal(Some("anthropic"))
  cfg.task_model |> should.equal(Some("claude-haiku-4-5-20251001"))
  cfg.agent_name |> should.equal(Some("TestBot"))
  cfg.max_tokens |> should.equal(Some(2048))
}

pub fn parse_config_toml_partial_test() {
  let result = config.parse_config_toml("provider = \"openrouter\"")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.provider |> should.equal(Some("openrouter"))

  cfg.max_tokens |> should.equal(None)
}

pub fn parse_config_toml_empty_document_test() {
  let result = config.parse_config_toml("")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.provider |> should.equal(None)
  cfg.max_tokens |> should.equal(None)
}

pub fn parse_config_toml_invalid_test() {
  config.parse_config_toml("= this is not valid toml !!!") |> should.be_error
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

pub fn parse_config_toml_new_fields_test() {
  let toml =
    "max_turns = 8
max_consecutive_errors = 4
max_context_messages = 100"
  let result = config.parse_config_toml(toml)
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.max_turns |> should.equal(Some(8))
  cfg.max_consecutive_errors |> should.equal(Some(4))
  cfg.max_context_messages |> should.equal(Some(100))
}

pub fn merge_new_fields_test() {
  let base = AppConfig(..config.default(), max_turns: Some(5))
  let override =
    AppConfig(
      ..config.default(),
      max_turns: Some(10),
      max_consecutive_errors: Some(2),
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

pub fn parse_config_toml_task_model_test() {
  let result =
    config.parse_config_toml("task_model = \"claude-haiku-4-5-20251001\"")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.task_model |> should.equal(Some("claude-haiku-4-5-20251001"))
}

pub fn parse_config_toml_reasoning_model_test() {
  let result = config.parse_config_toml("reasoning_model = \"claude-opus-4-6\"")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.reasoning_model |> should.equal(Some("claude-opus-4-6"))
}

pub fn parse_config_toml_all_model_fields_test() {
  let toml =
    "task_model = \"gpt-4o-mini\"
reasoning_model = \"gpt-4o\""
  let result = config.parse_config_toml(toml)
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.task_model |> should.equal(Some("gpt-4o-mini"))
  cfg.reasoning_model |> should.equal(Some("gpt-4o"))
}

pub fn merge_model_fields_override_wins_test() {
  let base =
    AppConfig(
      ..config.default(),
      task_model: Some("base-task"),
      reasoning_model: Some("base-reasoning"),
    )
  let override =
    AppConfig(..config.default(), task_model: Some("override-task"))
  let merged = config.merge(base, override:)
  merged.task_model |> should.equal(Some("override-task"))
  merged.reasoning_model |> should.equal(Some("base-reasoning"))
}

pub fn merge_model_fields_base_preserved_test() {
  let base =
    AppConfig(
      ..config.default(),
      task_model: Some("haiku"),
      reasoning_model: Some("opus"),
    )
  let override = config.default()
  let merged = config.merge(base, override:)
  merged.task_model |> should.equal(Some("haiku"))
  merged.reasoning_model |> should.equal(Some("opus"))
}

// ---------------------------------------------------------------------------
// New flags: --config, --verbose
// ---------------------------------------------------------------------------

pub fn from_args_config_flag_test() {
  let cfg = config.from_args(["--config", "/tmp/test.toml"])
  cfg.config_path |> should.equal(Some("/tmp/test.toml"))
}

pub fn from_args_verbose_flag_test() {
  let cfg = config.from_args(["--verbose"])
  cfg.log_verbose |> should.equal(Some(True))
}

pub fn from_args_verbose_default_none_test() {
  let cfg = config.from_args([])
  cfg.log_verbose |> should.equal(None)
}

pub fn parse_config_toml_log_verbose_false_test() {
  let result = config.parse_config_toml("log_verbose = false")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.log_verbose |> should.equal(Some(False))
}

pub fn parse_config_toml_log_verbose_true_test() {
  let result = config.parse_config_toml("log_verbose = true")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.log_verbose |> should.equal(Some(True))
}

// ---------------------------------------------------------------------------
// to_string
// ---------------------------------------------------------------------------

pub fn to_string_fully_set_test() {
  let cfg =
    AppConfig(
      ..config.default(),
      provider: Some("anthropic"),
      agent_name: Some("TestBot"),
      agent_version: Some("1.0"),
      max_tokens: Some(1024),
      max_turns: Some(5),
      max_consecutive_errors: Some(3),
      max_context_messages: Some(50),
      task_model: Some("claude-haiku-4-5-20251001"),
      reasoning_model: Some("claude-opus-4-6"),
      config_path: Some("/tmp/cfg.toml"),
      log_verbose: Some(True),
      skills_dirs: Some(["/tmp/skills"]),
    )
  let s = config.to_string(cfg)
  string.contains(s, "provider") |> should.be_true
  string.contains(s, "anthropic") |> should.be_true
  string.contains(s, "task_model") |> should.be_true
  string.contains(s, "max_tokens") |> should.be_true
  string.contains(s, "log_verbose") |> should.be_true
}

pub fn to_string_all_none_is_empty_test() {
  let cfg = config.default()
  let s = config.to_string(cfg)
  s |> should.equal("")
}

pub fn to_string_partial_test() {
  let cfg = config.from_args(["--provider", "openai", "--verbose"])
  let s = config.to_string(cfg)
  string.contains(s, "provider") |> should.be_true
  string.contains(s, "openai") |> should.be_true
  string.contains(s, "log_verbose") |> should.be_true
}

// ---------------------------------------------------------------------------
// skills_dirs config field
// ---------------------------------------------------------------------------

pub fn from_args_skills_dir_test() {
  let cfg = config.from_args(["--skills-dir", "/tmp/skills"])
  cfg.skills_dirs |> should.equal(Some(["/tmp/skills"]))
}

pub fn from_args_multiple_skills_dirs_test() {
  let cfg =
    config.from_args(["--skills-dir", "/path/a", "--skills-dir", "/path/b"])
  cfg.skills_dirs |> should.equal(Some(["/path/a", "/path/b"]))
}

pub fn parse_config_toml_skills_dirs_test() {
  let result =
    config.parse_config_toml("skills_dirs = [\"/path/a\", \"/path/b\"]")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.skills_dirs |> should.equal(Some(["/path/a", "/path/b"]))
}

// ---------------------------------------------------------------------------
// write_anywhere config field
// ---------------------------------------------------------------------------

pub fn from_args_allow_write_anywhere_test() {
  let cfg = config.from_args(["--allow-write-anywhere"])
  cfg.write_anywhere |> should.equal(Some(True))
}

pub fn parse_config_toml_write_anywhere_false_test() {
  let result = config.parse_config_toml("write_anywhere = false")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.write_anywhere |> should.equal(Some(False))
}

pub fn parse_config_toml_write_anywhere_true_test() {
  let result = config.parse_config_toml("write_anywhere = true")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.write_anywhere |> should.equal(Some(True))
}

// ---------------------------------------------------------------------------
// gui config field
// ---------------------------------------------------------------------------

pub fn default_gui_is_none_test() {
  let cfg = config.default()
  cfg.gui |> should.equal(None)
}

pub fn from_args_gui_web_test() {
  let cfg = config.from_args(["--gui", "web"])
  cfg.gui |> should.equal(Some("web"))
}

pub fn from_args_gui_tui_test() {
  let cfg = config.from_args(["--gui", "tui"])
  cfg.gui |> should.equal(Some("tui"))
}

pub fn parse_config_toml_gui_test() {
  let result = config.parse_config_toml("gui = \"web\"")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.gui |> should.equal(Some("web"))
}

pub fn merge_gui_override_wins_test() {
  let base = AppConfig(..config.default(), gui: Some("tui"))
  let override = AppConfig(..config.default(), gui: Some("web"))
  let merged = config.merge(base, override:)
  merged.gui |> should.equal(Some("web"))
}

pub fn to_string_includes_gui_test() {
  let cfg = config.from_args(["--gui", "web"])
  let s = config.to_string(cfg)
  string.contains(s, "gui: web") |> should.be_true
}

// ---------------------------------------------------------------------------
// TOML-specific: comments are valid
// ---------------------------------------------------------------------------

pub fn parse_config_toml_with_comments_test() {
  let toml =
    "# Provider to use
provider = \"anthropic\"
# Max tokens
max_tokens = 4096"
  let result = config.parse_config_toml(toml)
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.provider |> should.equal(Some("anthropic"))
  cfg.max_tokens |> should.equal(Some(4096))
}

// ---------------------------------------------------------------------------
// D' safety config fields
// ---------------------------------------------------------------------------

pub fn from_args_dprime_flag_test() {
  let cfg = config.from_args(["--dprime"])
  cfg.dprime_enabled |> should.equal(Some(True))
}

pub fn from_args_no_dprime_flag_test() {
  let cfg = config.from_args(["--no-dprime"])
  cfg.dprime_enabled |> should.equal(Some(False))
}

pub fn from_args_dprime_config_flag_test() {
  let cfg = config.from_args(["--dprime-config", "/tmp/dprime.json"])
  cfg.dprime_config |> should.equal(Some("/tmp/dprime.json"))
}

pub fn from_args_dprime_combined_test() {
  let cfg =
    config.from_args(["--dprime", "--dprime-config", "/tmp/dprime.json"])
  cfg.dprime_enabled |> should.equal(Some(True))
  cfg.dprime_config |> should.equal(Some("/tmp/dprime.json"))
}

pub fn parse_config_toml_dprime_enabled_test() {
  let result = config.parse_config_toml("dprime_enabled = true")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.dprime_enabled |> should.equal(Some(True))
}

pub fn parse_config_toml_dprime_config_test() {
  let result = config.parse_config_toml("dprime_config = \"/etc/dprime.json\"")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.dprime_config |> should.equal(Some("/etc/dprime.json"))
}

pub fn merge_dprime_override_wins_test() {
  let base =
    AppConfig(
      ..config.default(),
      dprime_enabled: Some(False),
      dprime_config: Some("/old.json"),
    )
  let override =
    AppConfig(
      ..config.default(),
      dprime_enabled: Some(True),
      dprime_config: Some("/new.json"),
    )
  let merged = config.merge(base, override:)
  merged.dprime_enabled |> should.equal(Some(True))
  merged.dprime_config |> should.equal(Some("/new.json"))
}

pub fn to_string_includes_dprime_test() {
  let cfg = config.from_args(["--dprime", "--dprime-config", "/tmp/d.json"])
  let s = config.to_string(cfg)
  string.contains(s, "dprime_enabled: true") |> should.be_true
  string.contains(s, "dprime_config: /tmp/d.json") |> should.be_true
}

// ---------------------------------------------------------------------------
// Config validation
// ---------------------------------------------------------------------------

pub fn parse_config_toml_unknown_key_still_ok_test() {
  let result = config.parse_config_toml("totally_bogus_key = \"hello\"")
  result |> should.be_ok
}

pub fn parse_config_toml_unknown_key_preserves_known_test() {
  let toml =
    "provider = \"anthropic\"
bogus_key = \"ignored\"
max_tokens = 2048"
  let result = config.parse_config_toml(toml)
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.provider |> should.equal(Some("anthropic"))
  cfg.max_tokens |> should.equal(Some(2048))
}

pub fn parse_config_toml_unknown_narrative_key_still_ok_test() {
  let toml =
    "[narrative]
directory = \"my-narrative\"
bogus_sub_key = \"hello\""
  let result = config.parse_config_toml(toml)
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.narrative_dir |> should.equal(Some("my-narrative"))
}

pub fn parse_config_toml_negative_max_tokens_still_ok_test() {
  let result = config.parse_config_toml("max_tokens = -5")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.max_tokens |> should.equal(Some(-5))
}

pub fn parse_config_toml_zero_max_turns_still_ok_test() {
  let result = config.parse_config_toml("max_turns = 0")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.max_turns |> should.equal(Some(0))
}

pub fn parse_config_toml_unknown_provider_still_ok_test() {
  let result = config.parse_config_toml("provider = \"nonexistent\"")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.provider |> should.equal(Some("nonexistent"))
}

pub fn parse_config_toml_unknown_gui_still_ok_test() {
  let result = config.parse_config_toml("gui = \"desktop\"")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.gui |> should.equal(Some("desktop"))
}

pub fn parse_config_toml_valid_provider_no_warning_test() {
  let result = config.parse_config_toml("provider = \"anthropic\"")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.provider |> should.equal(Some("anthropic"))
}

pub fn parse_config_toml_valid_gui_no_warning_test() {
  let result = config.parse_config_toml("gui = \"web\"")
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.gui |> should.equal(Some("web"))
}

pub fn parse_config_toml_positive_values_ok_test() {
  let toml =
    "max_tokens = 4096
max_turns = 10
max_consecutive_errors = 5
max_context_messages = 100"
  let result = config.parse_config_toml(toml)
  result |> should.be_ok
  let assert Ok(cfg) = result
  cfg.max_tokens |> should.equal(Some(4096))
  cfg.max_turns |> should.equal(Some(10))
  cfg.max_consecutive_errors |> should.equal(Some(5))
  cfg.max_context_messages |> should.equal(Some(100))
}

// ---------------------------------------------------------------------------
// New TOML sections: timeouts, retry, limits, scoring, embedding, agents, etc.
// ---------------------------------------------------------------------------

pub fn parse_config_toml_timeouts_test() {
  let toml =
    "[timeouts]
llm_request_ms = 120000
classify_ms = 5000
inter_turn_delay_ms = 100"
  let assert Ok(cfg) = config.parse_config_toml(toml)
  cfg.llm_request_timeout_ms |> should.equal(Some(120_000))
  cfg.classify_timeout_ms |> should.equal(Some(5000))
  cfg.inter_turn_delay_ms |> should.equal(Some(100))
}

pub fn parse_config_toml_retry_test() {
  let toml =
    "[retry]
max_retries = 5
initial_delay_ms = 1000
max_delay_ms = 30000"
  let assert Ok(cfg) = config.parse_config_toml(toml)
  cfg.retry_max_retries |> should.equal(Some(5))
  cfg.retry_initial_delay_ms |> should.equal(Some(1000))
  cfg.retry_max_delay_ms |> should.equal(Some(30_000))
}

pub fn parse_config_toml_limits_test() {
  let toml =
    "[limits]
max_artifact_chars = 100000
mailbox_warn_threshold = 100"
  let assert Ok(cfg) = config.parse_config_toml(toml)
  cfg.max_artifact_chars |> should.equal(Some(100_000))
  cfg.mailbox_warn_threshold |> should.equal(Some(100))
}

pub fn parse_config_toml_cbr_test() {
  let toml =
    "[cbr]
vsa_dimensions = 2000"
  let assert Ok(cfg) = config.parse_config_toml(toml)
  cfg.vsa_dimensions |> should.equal(Some(2000))
}

pub fn parse_config_toml_agents_test() {
  let toml =
    "[agents.planner]
max_tokens = 1024
max_turns = 2

[agents.researcher]
max_tokens = 4096
max_context_messages = 20"
  let assert Ok(cfg) = config.parse_config_toml(toml)
  cfg.planner_max_tokens |> should.equal(Some(1024))
  cfg.planner_max_turns |> should.equal(Some(2))
  cfg.researcher_max_tokens |> should.equal(Some(4096))
  cfg.researcher_max_context |> should.equal(Some(20))
}

pub fn parse_config_toml_web_port_test() {
  let toml =
    "[web]
port = 9090"
  let assert Ok(cfg) = config.parse_config_toml(toml)
  cfg.web_port |> should.equal(Some(9090))
}

pub fn parse_config_toml_services_test() {
  let toml =
    "[services]
duckduckgo_url = \"https://my-proxy.example.com/html/\""
  let assert Ok(cfg) = config.parse_config_toml(toml)
  cfg.duckduckgo_url
  |> should.equal(Some("https://my-proxy.example.com/html/"))
}

pub fn parse_config_toml_scoring_threading_test() {
  let toml =
    "[scoring.threading]
location_weight = 5
threshold = 6"
  let assert Ok(cfg) = config.parse_config_toml(toml)
  cfg.threading_location_weight |> should.equal(Some(5))
  cfg.threading_threshold |> should.equal(Some(6))
}

pub fn parse_config_toml_cbr_vsa_test() {
  let toml =
    "[cbr]
vsa_dimensions = 500"
  let assert Ok(cfg) = config.parse_config_toml(toml)
  cfg.vsa_dimensions |> should.equal(Some(500))
}

pub fn parse_config_toml_housekeeping_test() {
  let toml =
    "[housekeeping]
dedup_similarity = 0.95
cbr_pruning_days = 90"
  let assert Ok(cfg) = config.parse_config_toml(toml)
  let assert Some(ds) = cfg.dedup_similarity
  { ds >. 0.94 && ds <. 0.96 } |> should.be_true
  cfg.cbr_pruning_days |> should.equal(Some(90))
}

pub fn merge_new_sections_test() {
  let base =
    AppConfig(
      ..config.default(),
      llm_request_timeout_ms: Some(300_000),
      web_port: Some(8080),
    )
  let override = AppConfig(..config.default(), web_port: Some(9090))
  let merged = config.merge(base, override:)
  merged.llm_request_timeout_ms |> should.equal(Some(300_000))
  merged.web_port |> should.equal(Some(9090))
}

// ---------------------------------------------------------------------------
// Brave/Jina service URLs and limits
// ---------------------------------------------------------------------------

pub fn parse_config_toml_brave_services_test() {
  let toml =
    "[services]
brave_search_base_url = \"https://my-brave-proxy.example.com\"
brave_answers_base_url = \"https://my-answers-proxy.example.com\"
jina_reader_base_url = \"https://my-jina-proxy.example.com/\""
  let assert Ok(cfg) = config.parse_config_toml(toml)
  cfg.brave_search_base_url
  |> should.equal(Some("https://my-brave-proxy.example.com"))
  cfg.brave_answers_base_url
  |> should.equal(Some("https://my-answers-proxy.example.com"))
  cfg.jina_reader_base_url
  |> should.equal(Some("https://my-jina-proxy.example.com/"))
}

pub fn parse_config_toml_brave_limits_test() {
  let toml =
    "[limits]
brave_search_max_results = 10
brave_rate_limit_rps = 15
brave_answers_rate_limit_rps = 1
brave_cache_ttl_ms = 600000"
  let assert Ok(cfg) = config.parse_config_toml(toml)
  cfg.brave_search_max_results |> should.equal(Some(10))
  cfg.brave_rate_limit_rps |> should.equal(Some(15))
  cfg.brave_answers_rate_limit_rps |> should.equal(Some(1))
  cfg.brave_cache_ttl_ms |> should.equal(Some(600_000))
}

pub fn default_brave_fields_none_test() {
  let cfg = config.default()
  cfg.brave_search_base_url |> should.equal(None)
  cfg.brave_answers_base_url |> should.equal(None)
  cfg.jina_reader_base_url |> should.equal(None)
  cfg.brave_search_max_results |> should.equal(None)
  cfg.brave_rate_limit_rps |> should.equal(None)
  cfg.brave_answers_rate_limit_rps |> should.equal(None)
  cfg.brave_cache_ttl_ms |> should.equal(None)
}

pub fn merge_brave_fields_test() {
  let base =
    AppConfig(
      ..config.default(),
      brave_search_base_url: Some("https://base.example.com"),
      brave_rate_limit_rps: Some(10),
    )
  let override =
    AppConfig(
      ..config.default(),
      brave_search_base_url: Some("https://override.example.com"),
    )
  let merged = config.merge(base, override:)
  merged.brave_search_base_url
  |> should.equal(Some("https://override.example.com"))
  merged.brave_rate_limit_rps |> should.equal(Some(10))
}
