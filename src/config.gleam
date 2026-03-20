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
//// See .springdrift_example/config.toml for the full reference with all
//// sections and defaults documented.
////
//// CLI flags always override config file values.
//// --skills-dir is repeatable and appends to (rather than replaces) the list.

import gleam/dict
import gleam/float
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
    // ── LLM provider and models ──
    provider: Option(String),
    task_model: Option(String),
    reasoning_model: Option(String),
    max_tokens: Option(Int),
    // ── Loop control ──
    max_turns: Option(Int),
    max_consecutive_errors: Option(Int),
    max_context_messages: Option(Int),
    // ── Logging and filesystem ──
    log_verbose: Option(Bool),
    write_anywhere: Option(Bool),
    skills_dirs: Option(List(String)),
    log_retention_days: Option(Int),
    log_max_file_bytes: Option(Int),
    // ── Session ──
    config_path: Option(String),
    // ── GUI ──
    gui: Option(String),
    // ── D' safety system ──
    dprime_enabled: Option(Bool),
    dprime_config: Option(String),
    // ── Narrative (always enabled) ──
    narrative_dir: Option(String),
    archivist_model: Option(String),
    archivist_max_tokens: Option(Int),
    narrative_threading: Option(Bool),
    narrative_summaries: Option(Bool),
    narrative_summary_schedule: Option(String),
    redact_secrets: Option(Bool),
    // ── Profiles ──
    profiles_dirs: Option(List(String)),
    default_profile: Option(String),
    // ── Agent identity ──
    agent_name: Option(String),
    agent_version: Option(String),
    // ── Librarian startup ──
    librarian_max_days: Option(Int),
    // ── Timeouts (ms unless noted) ──
    llm_request_timeout_ms: Option(Int),
    classify_timeout_ms: Option(Int),
    inter_turn_delay_ms: Option(Int),
    startup_timeout_ms: Option(Int),
    librarian_startup_timeout_ms: Option(Int),
    scheduler_job_timeout_ms: Option(Int),
    restart_window_ms: Option(Int),
    // ── Sandbox ──
    sandbox_enabled: Option(Bool),
    sandbox_pool_size: Option(Int),
    sandbox_memory_mb: Option(Int),
    sandbox_cpus: Option(String),
    sandbox_image: Option(String),
    sandbox_exec_timeout_ms: Option(Int),
    sandbox_port_base: Option(Int),
    sandbox_port_stride: Option(Int),
    sandbox_ports_per_slot: Option(Int),
    sandbox_auto_machine: Option(Bool),
    // ── Housekeeper GenServer ──
    housekeeper_short_tick_ms: Option(Int),
    housekeeper_medium_tick_ms: Option(Int),
    housekeeper_long_tick_ms: Option(Int),
    housekeeper_narrative_days: Option(Int),
    housekeeper_cbr_days: Option(Int),
    housekeeper_dag_days: Option(Int),
    housekeeper_artifact_days: Option(Int),
    // ── Retry ──
    retry_max_retries: Option(Int),
    retry_initial_delay_ms: Option(Int),
    retry_rate_limit_delay_ms: Option(Int),
    retry_overload_delay_ms: Option(Int),
    retry_max_delay_ms: Option(Int),
    // ── Size limits ──
    max_artifact_chars: Option(Int),
    max_fetch_chars: Option(Int),
    tui_input_limit: Option(Int),
    websocket_max_bytes: Option(Int),
    recall_max_entries: Option(Int),
    cbr_max_results: Option(Int),
    web_search_max_results: Option(Int),
    // ── Thread scoring ──
    threading_location_weight: Option(Int),
    threading_domain_weight: Option(Int),
    threading_keyword_weight: Option(Int),
    threading_topic_weight: Option(Int),
    threading_threshold: Option(Int),
    // ── CBR embedding (Ollama) ──
    cbr_embedding_enabled: Option(Bool),
    cbr_embedding_model: Option(String),
    cbr_embedding_base_url: Option(String),
    // ── CBR retrieval weights ──
    cbr_field_weight: Option(Float),
    cbr_index_weight: Option(Float),
    cbr_recency_weight: Option(Float),
    cbr_domain_weight: Option(Float),
    cbr_embedding_weight: Option(Float),
    cbr_min_score: Option(Float),
    // ── Housekeeping ──
    dedup_similarity: Option(Float),
    pruning_confidence: Option(Float),
    fact_confidence: Option(Float),
    cbr_pruning_days: Option(Int),
    thread_pruning_days: Option(Int),
    // ── Agent specs ──
    planner_max_tokens: Option(Int),
    planner_max_turns: Option(Int),
    planner_max_errors: Option(Int),
    researcher_max_tokens: Option(Int),
    researcher_max_turns: Option(Int),
    researcher_max_errors: Option(Int),
    researcher_max_context: Option(Int),
    coder_max_tokens: Option(Int),
    coder_max_turns: Option(Int),
    coder_max_errors: Option(Int),
    writer_max_tokens: Option(Int),
    writer_max_turns: Option(Int),
    writer_max_errors: Option(Int),
    // ── Web GUI ──
    web_port: Option(Int),
    // ── External services ──
    duckduckgo_url: Option(String),
    brave_search_base_url: Option(String),
    brave_answers_base_url: Option(String),
    jina_reader_base_url: Option(String),
    // ── Brave API settings ──
    brave_search_max_results: Option(Int),
    brave_rate_limit_rps: Option(Int),
    brave_answers_rate_limit_rps: Option(Int),
    brave_cache_ttl_ms: Option(Int),
    // ── Input queue ──
    input_queue_cap: Option(Int),
    // ── Scheduler stuck timeout ──
    scheduler_stuck_timeout_ms: Option(Int),
    // ── Scheduler tool timeout ──
    scheduler_tool_timeout_ms: Option(Int),
    // ── Scheduler resource limits ──
    max_autonomous_cycles_per_hour: Option(Int),
    autonomous_token_budget_per_hour: Option(Int),
    // ── XStructor ──
    xstructor_max_retries: Option(Int),
    // ── Preamble budget ──
    preamble_budget_chars: Option(Int),
    // ── Forecaster ──
    forecaster_enabled: Option(Bool),
    forecaster_tick_ms: Option(Int),
    forecaster_replan_threshold: Option(Float),
    forecaster_min_cycles: Option(Int),
    forecaster_stale_threshold_ms: Option(Int),
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
    max_tokens: None,
    max_turns: None,
    max_consecutive_errors: None,
    max_context_messages: None,
    log_verbose: None,
    write_anywhere: None,
    skills_dirs: None,
    log_retention_days: None,
    log_max_file_bytes: None,
    config_path: None,
    gui: None,
    dprime_enabled: None,
    dprime_config: None,
    narrative_dir: None,
    archivist_model: None,
    archivist_max_tokens: None,
    narrative_threading: None,
    narrative_summaries: None,
    narrative_summary_schedule: None,
    redact_secrets: None,
    profiles_dirs: None,
    default_profile: None,
    agent_name: None,
    agent_version: None,
    librarian_max_days: None,
    llm_request_timeout_ms: None,
    classify_timeout_ms: None,
    inter_turn_delay_ms: None,
    startup_timeout_ms: None,
    librarian_startup_timeout_ms: None,
    scheduler_job_timeout_ms: None,
    restart_window_ms: None,
    sandbox_enabled: None,
    sandbox_pool_size: None,
    sandbox_memory_mb: None,
    sandbox_cpus: None,
    sandbox_image: None,
    sandbox_exec_timeout_ms: None,
    sandbox_port_base: None,
    sandbox_port_stride: None,
    sandbox_ports_per_slot: None,
    sandbox_auto_machine: None,
    housekeeper_short_tick_ms: None,
    housekeeper_medium_tick_ms: None,
    housekeeper_long_tick_ms: None,
    housekeeper_narrative_days: None,
    housekeeper_cbr_days: None,
    housekeeper_dag_days: None,
    housekeeper_artifact_days: None,
    retry_max_retries: None,
    retry_initial_delay_ms: None,
    retry_rate_limit_delay_ms: None,
    retry_overload_delay_ms: None,
    retry_max_delay_ms: None,
    max_artifact_chars: None,
    max_fetch_chars: None,
    tui_input_limit: None,
    websocket_max_bytes: None,
    recall_max_entries: None,
    cbr_max_results: None,
    web_search_max_results: None,
    threading_location_weight: None,
    threading_domain_weight: None,
    threading_keyword_weight: None,
    threading_topic_weight: None,
    threading_threshold: None,
    cbr_embedding_enabled: None,
    cbr_embedding_model: None,
    cbr_embedding_base_url: None,
    cbr_field_weight: None,
    cbr_index_weight: None,
    cbr_recency_weight: None,
    cbr_domain_weight: None,
    cbr_embedding_weight: None,
    cbr_min_score: None,
    dedup_similarity: None,
    pruning_confidence: None,
    fact_confidence: None,
    cbr_pruning_days: None,
    thread_pruning_days: None,
    planner_max_tokens: None,
    planner_max_turns: None,
    planner_max_errors: None,
    researcher_max_tokens: None,
    researcher_max_turns: None,
    researcher_max_errors: None,
    researcher_max_context: None,
    coder_max_tokens: None,
    coder_max_turns: None,
    coder_max_errors: None,
    writer_max_tokens: None,
    writer_max_turns: None,
    writer_max_errors: None,
    web_port: None,
    duckduckgo_url: None,
    brave_search_base_url: None,
    brave_answers_base_url: None,
    jina_reader_base_url: None,
    brave_search_max_results: None,
    brave_rate_limit_rps: None,
    brave_answers_rate_limit_rps: None,
    brave_cache_ttl_ms: None,
    input_queue_cap: None,
    scheduler_stuck_timeout_ms: None,
    scheduler_tool_timeout_ms: None,
    max_autonomous_cycles_per_hour: None,
    autonomous_token_budget_per_hour: None,
    xstructor_max_retries: None,
    preamble_budget_chars: None,
    forecaster_enabled: None,
    forecaster_tick_ms: None,
    forecaster_replan_threshold: None,
    forecaster_min_cycles: None,
    forecaster_stale_threshold_ms: None,
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
    log_retention_days: option.or(
      override_cfg.log_retention_days,
      base.log_retention_days,
    ),
    log_max_file_bytes: option.or(
      override_cfg.log_max_file_bytes,
      base.log_max_file_bytes,
    ),
    config_path: option.or(override_cfg.config_path, base.config_path),
    gui: option.or(override_cfg.gui, base.gui),
    dprime_enabled: option.or(override_cfg.dprime_enabled, base.dprime_enabled),
    dprime_config: option.or(override_cfg.dprime_config, base.dprime_config),
    narrative_dir: option.or(override_cfg.narrative_dir, base.narrative_dir),
    archivist_model: option.or(
      override_cfg.archivist_model,
      base.archivist_model,
    ),
    archivist_max_tokens: option.or(
      override_cfg.archivist_max_tokens,
      base.archivist_max_tokens,
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
    redact_secrets: option.or(override_cfg.redact_secrets, base.redact_secrets),
    profiles_dirs: option.or(override_cfg.profiles_dirs, base.profiles_dirs),
    default_profile: option.or(
      override_cfg.default_profile,
      base.default_profile,
    ),
    agent_name: option.or(override_cfg.agent_name, base.agent_name),
    agent_version: option.or(override_cfg.agent_version, base.agent_version),
    librarian_max_days: option.or(
      override_cfg.librarian_max_days,
      base.librarian_max_days,
    ),
    // Timeouts
    llm_request_timeout_ms: option.or(
      override_cfg.llm_request_timeout_ms,
      base.llm_request_timeout_ms,
    ),
    classify_timeout_ms: option.or(
      override_cfg.classify_timeout_ms,
      base.classify_timeout_ms,
    ),
    inter_turn_delay_ms: option.or(
      override_cfg.inter_turn_delay_ms,
      base.inter_turn_delay_ms,
    ),
    startup_timeout_ms: option.or(
      override_cfg.startup_timeout_ms,
      base.startup_timeout_ms,
    ),
    librarian_startup_timeout_ms: option.or(
      override_cfg.librarian_startup_timeout_ms,
      base.librarian_startup_timeout_ms,
    ),
    scheduler_job_timeout_ms: option.or(
      override_cfg.scheduler_job_timeout_ms,
      base.scheduler_job_timeout_ms,
    ),
    restart_window_ms: option.or(
      override_cfg.restart_window_ms,
      base.restart_window_ms,
    ),
    sandbox_enabled: option.or(
      override_cfg.sandbox_enabled,
      base.sandbox_enabled,
    ),
    sandbox_pool_size: option.or(
      override_cfg.sandbox_pool_size,
      base.sandbox_pool_size,
    ),
    sandbox_memory_mb: option.or(
      override_cfg.sandbox_memory_mb,
      base.sandbox_memory_mb,
    ),
    sandbox_cpus: option.or(override_cfg.sandbox_cpus, base.sandbox_cpus),
    sandbox_image: option.or(override_cfg.sandbox_image, base.sandbox_image),
    sandbox_exec_timeout_ms: option.or(
      override_cfg.sandbox_exec_timeout_ms,
      base.sandbox_exec_timeout_ms,
    ),
    sandbox_port_base: option.or(
      override_cfg.sandbox_port_base,
      base.sandbox_port_base,
    ),
    sandbox_port_stride: option.or(
      override_cfg.sandbox_port_stride,
      base.sandbox_port_stride,
    ),
    sandbox_ports_per_slot: option.or(
      override_cfg.sandbox_ports_per_slot,
      base.sandbox_ports_per_slot,
    ),
    sandbox_auto_machine: option.or(
      override_cfg.sandbox_auto_machine,
      base.sandbox_auto_machine,
    ),
    housekeeper_short_tick_ms: option.or(
      override_cfg.housekeeper_short_tick_ms,
      base.housekeeper_short_tick_ms,
    ),
    housekeeper_medium_tick_ms: option.or(
      override_cfg.housekeeper_medium_tick_ms,
      base.housekeeper_medium_tick_ms,
    ),
    housekeeper_long_tick_ms: option.or(
      override_cfg.housekeeper_long_tick_ms,
      base.housekeeper_long_tick_ms,
    ),
    housekeeper_narrative_days: option.or(
      override_cfg.housekeeper_narrative_days,
      base.housekeeper_narrative_days,
    ),
    housekeeper_cbr_days: option.or(
      override_cfg.housekeeper_cbr_days,
      base.housekeeper_cbr_days,
    ),
    housekeeper_dag_days: option.or(
      override_cfg.housekeeper_dag_days,
      base.housekeeper_dag_days,
    ),
    housekeeper_artifact_days: option.or(
      override_cfg.housekeeper_artifact_days,
      base.housekeeper_artifact_days,
    ),
    // Retry
    retry_max_retries: option.or(
      override_cfg.retry_max_retries,
      base.retry_max_retries,
    ),
    retry_initial_delay_ms: option.or(
      override_cfg.retry_initial_delay_ms,
      base.retry_initial_delay_ms,
    ),
    retry_rate_limit_delay_ms: option.or(
      override_cfg.retry_rate_limit_delay_ms,
      base.retry_rate_limit_delay_ms,
    ),
    retry_overload_delay_ms: option.or(
      override_cfg.retry_overload_delay_ms,
      base.retry_overload_delay_ms,
    ),
    retry_max_delay_ms: option.or(
      override_cfg.retry_max_delay_ms,
      base.retry_max_delay_ms,
    ),
    // Size limits
    max_artifact_chars: option.or(
      override_cfg.max_artifact_chars,
      base.max_artifact_chars,
    ),
    max_fetch_chars: option.or(
      override_cfg.max_fetch_chars,
      base.max_fetch_chars,
    ),
    tui_input_limit: option.or(
      override_cfg.tui_input_limit,
      base.tui_input_limit,
    ),
    websocket_max_bytes: option.or(
      override_cfg.websocket_max_bytes,
      base.websocket_max_bytes,
    ),
    recall_max_entries: option.or(
      override_cfg.recall_max_entries,
      base.recall_max_entries,
    ),
    cbr_max_results: option.or(
      override_cfg.cbr_max_results,
      base.cbr_max_results,
    ),
    web_search_max_results: option.or(
      override_cfg.web_search_max_results,
      base.web_search_max_results,
    ),
    // Thread scoring
    threading_location_weight: option.or(
      override_cfg.threading_location_weight,
      base.threading_location_weight,
    ),
    threading_domain_weight: option.or(
      override_cfg.threading_domain_weight,
      base.threading_domain_weight,
    ),
    threading_keyword_weight: option.or(
      override_cfg.threading_keyword_weight,
      base.threading_keyword_weight,
    ),
    threading_topic_weight: option.or(
      override_cfg.threading_topic_weight,
      base.threading_topic_weight,
    ),
    threading_threshold: option.or(
      override_cfg.threading_threshold,
      base.threading_threshold,
    ),
    // CBR embedding
    cbr_embedding_enabled: option.or(
      override_cfg.cbr_embedding_enabled,
      base.cbr_embedding_enabled,
    ),
    cbr_embedding_model: option.or(
      override_cfg.cbr_embedding_model,
      base.cbr_embedding_model,
    ),
    cbr_embedding_base_url: option.or(
      override_cfg.cbr_embedding_base_url,
      base.cbr_embedding_base_url,
    ),
    // CBR retrieval weights
    cbr_field_weight: option.or(
      override_cfg.cbr_field_weight,
      base.cbr_field_weight,
    ),
    cbr_index_weight: option.or(
      override_cfg.cbr_index_weight,
      base.cbr_index_weight,
    ),
    cbr_recency_weight: option.or(
      override_cfg.cbr_recency_weight,
      base.cbr_recency_weight,
    ),
    cbr_domain_weight: option.or(
      override_cfg.cbr_domain_weight,
      base.cbr_domain_weight,
    ),
    cbr_embedding_weight: option.or(
      override_cfg.cbr_embedding_weight,
      base.cbr_embedding_weight,
    ),
    cbr_min_score: option.or(override_cfg.cbr_min_score, base.cbr_min_score),
    // Housekeeping
    dedup_similarity: option.or(
      override_cfg.dedup_similarity,
      base.dedup_similarity,
    ),
    pruning_confidence: option.or(
      override_cfg.pruning_confidence,
      base.pruning_confidence,
    ),
    fact_confidence: option.or(
      override_cfg.fact_confidence,
      base.fact_confidence,
    ),
    cbr_pruning_days: option.or(
      override_cfg.cbr_pruning_days,
      base.cbr_pruning_days,
    ),
    thread_pruning_days: option.or(
      override_cfg.thread_pruning_days,
      base.thread_pruning_days,
    ),
    // Agent specs
    planner_max_tokens: option.or(
      override_cfg.planner_max_tokens,
      base.planner_max_tokens,
    ),
    planner_max_turns: option.or(
      override_cfg.planner_max_turns,
      base.planner_max_turns,
    ),
    planner_max_errors: option.or(
      override_cfg.planner_max_errors,
      base.planner_max_errors,
    ),
    researcher_max_tokens: option.or(
      override_cfg.researcher_max_tokens,
      base.researcher_max_tokens,
    ),
    researcher_max_turns: option.or(
      override_cfg.researcher_max_turns,
      base.researcher_max_turns,
    ),
    researcher_max_errors: option.or(
      override_cfg.researcher_max_errors,
      base.researcher_max_errors,
    ),
    researcher_max_context: option.or(
      override_cfg.researcher_max_context,
      base.researcher_max_context,
    ),
    coder_max_tokens: option.or(
      override_cfg.coder_max_tokens,
      base.coder_max_tokens,
    ),
    coder_max_turns: option.or(
      override_cfg.coder_max_turns,
      base.coder_max_turns,
    ),
    coder_max_errors: option.or(
      override_cfg.coder_max_errors,
      base.coder_max_errors,
    ),
    writer_max_tokens: option.or(
      override_cfg.writer_max_tokens,
      base.writer_max_tokens,
    ),
    writer_max_turns: option.or(
      override_cfg.writer_max_turns,
      base.writer_max_turns,
    ),
    writer_max_errors: option.or(
      override_cfg.writer_max_errors,
      base.writer_max_errors,
    ),
    // Web GUI
    web_port: option.or(override_cfg.web_port, base.web_port),
    // External services
    duckduckgo_url: option.or(override_cfg.duckduckgo_url, base.duckduckgo_url),
    brave_search_base_url: option.or(
      override_cfg.brave_search_base_url,
      base.brave_search_base_url,
    ),
    brave_answers_base_url: option.or(
      override_cfg.brave_answers_base_url,
      base.brave_answers_base_url,
    ),
    jina_reader_base_url: option.or(
      override_cfg.jina_reader_base_url,
      base.jina_reader_base_url,
    ),
    brave_search_max_results: option.or(
      override_cfg.brave_search_max_results,
      base.brave_search_max_results,
    ),
    brave_rate_limit_rps: option.or(
      override_cfg.brave_rate_limit_rps,
      base.brave_rate_limit_rps,
    ),
    brave_answers_rate_limit_rps: option.or(
      override_cfg.brave_answers_rate_limit_rps,
      base.brave_answers_rate_limit_rps,
    ),
    brave_cache_ttl_ms: option.or(
      override_cfg.brave_cache_ttl_ms,
      base.brave_cache_ttl_ms,
    ),
    input_queue_cap: option.or(
      override_cfg.input_queue_cap,
      base.input_queue_cap,
    ),
    scheduler_stuck_timeout_ms: option.or(
      override_cfg.scheduler_stuck_timeout_ms,
      base.scheduler_stuck_timeout_ms,
    ),
    scheduler_tool_timeout_ms: option.or(
      override_cfg.scheduler_tool_timeout_ms,
      base.scheduler_tool_timeout_ms,
    ),
    max_autonomous_cycles_per_hour: option.or(
      override_cfg.max_autonomous_cycles_per_hour,
      base.max_autonomous_cycles_per_hour,
    ),
    autonomous_token_budget_per_hour: option.or(
      override_cfg.autonomous_token_budget_per_hour,
      base.autonomous_token_budget_per_hour,
    ),
    xstructor_max_retries: option.or(
      override_cfg.xstructor_max_retries,
      base.xstructor_max_retries,
    ),
    preamble_budget_chars: option.or(
      override_cfg.preamble_budget_chars,
      base.preamble_budget_chars,
    ),
    forecaster_enabled: option.or(
      override_cfg.forecaster_enabled,
      base.forecaster_enabled,
    ),
    forecaster_tick_ms: option.or(
      override_cfg.forecaster_tick_ms,
      base.forecaster_tick_ms,
    ),
    forecaster_replan_threshold: option.or(
      override_cfg.forecaster_replan_threshold,
      base.forecaster_replan_threshold,
    ),
    forecaster_min_cycles: option.or(
      override_cfg.forecaster_min_cycles,
      base.forecaster_min_cycles,
    ),
    forecaster_stale_threshold_ms: option.or(
      override_cfg.forecaster_stale_threshold_ms,
      base.forecaster_stale_threshold_ms,
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
  let bool_str = fn(v) {
    case v {
      True -> "true"
      False -> "false"
    }
  }
  [
    // LLM provider and models
    option.map(cfg.provider, fn(v) { "provider: " <> v }),
    option.map(cfg.task_model, fn(v) { "task_model: " <> v }),
    option.map(cfg.reasoning_model, fn(v) { "reasoning_model: " <> v }),
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
    option.map(cfg.log_verbose, fn(v) { "log_verbose: " <> bool_str(v) }),
    option.map(cfg.write_anywhere, fn(v) { "write_anywhere: " <> bool_str(v) }),
    option.map(cfg.skills_dirs, fn(dirs) {
      "skills_dirs: " <> string.join(dirs, ", ")
    }),
    option.map(cfg.log_retention_days, fn(v) {
      "log_retention_days: " <> int.to_string(v)
    }),
    option.map(cfg.log_max_file_bytes, fn(v) {
      "log_max_file_bytes: " <> int.to_string(v)
    }),
    // Session
    option.map(cfg.config_path, fn(v) { "config_path: " <> v }),
    // GUI
    option.map(cfg.gui, fn(v) { "gui: " <> v }),
    // D' safety system
    option.map(cfg.dprime_enabled, fn(v) { "dprime_enabled: " <> bool_str(v) }),
    option.map(cfg.dprime_config, fn(v) { "dprime_config: " <> v }),
    // Narrative
    option.map(cfg.narrative_dir, fn(v) { "narrative_dir: " <> v }),
    option.map(cfg.archivist_model, fn(v) { "archivist_model: " <> v }),
    option.map(cfg.archivist_max_tokens, fn(v) {
      "archivist_max_tokens: " <> int.to_string(v)
    }),
    // Redaction
    option.map(cfg.redact_secrets, fn(v) { "redact_secrets: " <> bool_str(v) }),
    // Profile
    option.map(cfg.default_profile, fn(v) { "profile: " <> v }),
    option.map(cfg.profiles_dirs, fn(dirs) {
      "profiles_dirs: " <> string.join(dirs, ", ")
    }),
    // Agent identity
    option.map(cfg.agent_name, fn(v) { "agent_name: " <> v }),
    option.map(cfg.agent_version, fn(v) { "agent_version: " <> v }),
    // Librarian
    option.map(cfg.librarian_max_days, fn(v) {
      "librarian_max_days: " <> int.to_string(v)
    }),
    // Timeouts
    option.map(cfg.llm_request_timeout_ms, fn(v) {
      "llm_request_timeout_ms: " <> int.to_string(v)
    }),
    option.map(cfg.classify_timeout_ms, fn(v) {
      "classify_timeout_ms: " <> int.to_string(v)
    }),
    option.map(cfg.inter_turn_delay_ms, fn(v) {
      "inter_turn_delay_ms: " <> int.to_string(v)
    }),
    option.map(cfg.restart_window_ms, fn(v) {
      "restart_window_ms: " <> int.to_string(v)
    }),
    // Retry
    option.map(cfg.retry_max_retries, fn(v) {
      "retry.max_retries: " <> int.to_string(v)
    }),
    option.map(cfg.retry_initial_delay_ms, fn(v) {
      "retry.initial_delay_ms: " <> int.to_string(v)
    }),
    // Limits
    option.map(cfg.max_artifact_chars, fn(v) {
      "max_artifact_chars: " <> int.to_string(v)
    }),
    option.map(cfg.max_fetch_chars, fn(v) {
      "max_fetch_chars: " <> int.to_string(v)
    }),
    // CBR
    option.map(cfg.cbr_min_score, fn(v) {
      "cbr.min_score: " <> float.to_string(v)
    }),
    // Web
    option.map(cfg.web_port, fn(v) { "web.port: " <> int.to_string(v) }),
    // Forecaster
    option.map(cfg.forecaster_enabled, fn(v) {
      "forecaster.enabled: " <> bool_str(v)
    }),
    option.map(cfg.forecaster_tick_ms, fn(v) {
      "forecaster.tick_ms: " <> int.to_string(v)
    }),
    option.map(cfg.forecaster_replan_threshold, fn(v) {
      "forecaster.replan_threshold: " <> float.to_string(v)
    }),
    option.map(cfg.forecaster_min_cycles, fn(v) {
      "forecaster.min_cycles: " <> int.to_string(v)
    }),
    option.map(cfg.forecaster_stale_threshold_ms, fn(v) {
      "forecaster.stale_threshold_ms: " <> int.to_string(v)
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
    ["--agent-name", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, agent_name: Some(value)))
    ["--agent-version", value, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, agent_version: Some(value)))
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
    ["--no-redact", ..rest] ->
      do_parse_args(rest, AppConfig(..acc, redact_secrets: Some(False)))
    ["--narrative-dir", path, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, narrative_dir: Some(path)))
    // Profiles
    ["--profile", name, ..rest] ->
      do_parse_args(rest, AppConfig(..acc, default_profile: Some(name)))
    ["--narrative-max-days", value, ..rest] ->
      case int.parse(value) {
        Ok(n) ->
          do_parse_args(rest, AppConfig(..acc, librarian_max_days: Some(n)))
        Error(_) -> do_parse_args(rest, acc)
      }
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

// ---------------------------------------------------------------------------
// TOML helpers
// ---------------------------------------------------------------------------

fn get_toml_str(
  table: dict.Dict(String, tom.Toml),
  path: List(String),
) -> Option(String) {
  case tom.get_string(table, path) {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

fn get_toml_int(
  table: dict.Dict(String, tom.Toml),
  path: List(String),
) -> Option(Int) {
  case tom.get_int(table, path) {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

fn get_toml_bool(
  table: dict.Dict(String, tom.Toml),
  path: List(String),
) -> Option(Bool) {
  case tom.get_bool(table, path) {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

fn get_toml_float(
  table: dict.Dict(String, tom.Toml),
  path: List(String),
) -> Option(Float) {
  case tom.get_float(table, path) {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

fn get_toml_string_array(
  table: dict.Dict(String, tom.Toml),
  path: List(String),
) -> Option(List(String)) {
  case tom.get_array(table, path) {
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
}

fn toml_to_config(table: dict.Dict(String, tom.Toml)) -> AppConfig {
  let get_str = fn(key) { get_toml_str(table, [key]) }
  let get_int = fn(key) { get_toml_int(table, [key]) }
  let get_bool = fn(key) { get_toml_bool(table, [key]) }

  AppConfig(
    // ── Top-level ──
    provider: get_str("provider"),
    task_model: get_str("task_model"),
    reasoning_model: get_str("reasoning_model"),
    max_tokens: get_int("max_tokens"),
    max_turns: get_int("max_turns"),
    max_consecutive_errors: get_int("max_consecutive_errors"),
    max_context_messages: get_int("max_context_messages"),
    log_verbose: get_bool("log_verbose"),
    write_anywhere: get_bool("write_anywhere"),
    skills_dirs: get_toml_string_array(table, ["skills_dirs"]),
    log_retention_days: get_int("log_retention_days"),
    log_max_file_bytes: get_int("log_max_file_bytes"),
    config_path: None,
    gui: get_str("gui"),
    dprime_enabled: get_bool("dprime_enabled"),
    dprime_config: get_str("dprime_config"),
    default_profile: get_str("profile"),
    profiles_dirs: get_toml_string_array(table, ["profiles_dirs"]),
    // ── [agent] ──
    agent_name: get_toml_str(table, ["agent", "name"]),
    agent_version: get_toml_str(table, ["agent", "version"]),
    // ── [narrative] ──
    narrative_dir: get_toml_str(table, ["narrative", "directory"]),
    archivist_model: get_toml_str(table, ["narrative", "archivist_model"]),
    archivist_max_tokens: get_toml_int(table, [
      "narrative", "archivist_max_tokens",
    ]),
    narrative_threading: get_toml_bool(table, ["narrative", "threading"]),
    narrative_summaries: get_toml_bool(table, ["narrative", "summaries"]),
    narrative_summary_schedule: get_toml_str(table, [
      "narrative", "summary_schedule",
    ]),
    redact_secrets: get_toml_bool(table, ["narrative", "redact_secrets"]),
    librarian_max_days: get_toml_int(table, ["narrative", "max_days"]),
    // ── [timeouts] ──
    llm_request_timeout_ms: get_toml_int(table, ["timeouts", "llm_request_ms"]),
    classify_timeout_ms: get_toml_int(table, ["timeouts", "classify_ms"]),
    inter_turn_delay_ms: get_toml_int(table, ["timeouts", "inter_turn_delay_ms"]),
    startup_timeout_ms: get_toml_int(table, ["timeouts", "startup_ms"]),
    librarian_startup_timeout_ms: get_toml_int(table, [
      "timeouts", "librarian_startup_ms",
    ]),
    scheduler_job_timeout_ms: get_toml_int(table, [
      "timeouts", "scheduler_job_ms",
    ]),
    restart_window_ms: get_toml_int(table, ["timeouts", "restart_window_ms"]),
    // ── [sandbox] ──
    sandbox_enabled: get_toml_bool(table, ["sandbox", "enabled"]),
    sandbox_pool_size: get_toml_int(table, ["sandbox", "pool_size"]),
    sandbox_memory_mb: get_toml_int(table, ["sandbox", "memory_mb"]),
    sandbox_cpus: get_toml_str(table, ["sandbox", "cpus"]),
    sandbox_image: get_toml_str(table, ["sandbox", "image"]),
    sandbox_exec_timeout_ms: get_toml_int(table, ["sandbox", "exec_timeout_ms"]),
    sandbox_port_base: get_toml_int(table, ["sandbox", "port_base"]),
    sandbox_port_stride: get_toml_int(table, ["sandbox", "port_stride"]),
    sandbox_ports_per_slot: get_toml_int(table, ["sandbox", "ports_per_slot"]),
    sandbox_auto_machine: get_toml_bool(table, ["sandbox", "auto_machine"]),
    // ── [housekeeper] ──
    housekeeper_short_tick_ms: get_toml_int(table, [
      "housekeeper", "short_tick_ms",
    ]),
    housekeeper_medium_tick_ms: get_toml_int(table, [
      "housekeeper", "medium_tick_ms",
    ]),
    housekeeper_long_tick_ms: get_toml_int(table, [
      "housekeeper", "long_tick_ms",
    ]),
    housekeeper_narrative_days: get_toml_int(table, [
      "housekeeper", "narrative_days",
    ]),
    housekeeper_cbr_days: get_toml_int(table, ["housekeeper", "cbr_days"]),
    housekeeper_dag_days: get_toml_int(table, ["housekeeper", "dag_days"]),
    housekeeper_artifact_days: get_toml_int(table, [
      "housekeeper", "artifact_days",
    ]),
    // ── [retry] ──
    retry_max_retries: get_toml_int(table, ["retry", "max_retries"]),
    retry_initial_delay_ms: get_toml_int(table, ["retry", "initial_delay_ms"]),
    retry_rate_limit_delay_ms: get_toml_int(table, [
      "retry", "rate_limit_delay_ms",
    ]),
    retry_overload_delay_ms: get_toml_int(table, ["retry", "overload_delay_ms"]),
    retry_max_delay_ms: get_toml_int(table, ["retry", "max_delay_ms"]),
    // ── [limits] ──
    max_artifact_chars: get_toml_int(table, ["limits", "max_artifact_chars"]),
    max_fetch_chars: get_toml_int(table, ["limits", "max_fetch_chars"]),
    tui_input_limit: get_toml_int(table, ["limits", "tui_input_limit"]),
    websocket_max_bytes: get_toml_int(table, ["limits", "websocket_max_bytes"]),
    recall_max_entries: get_toml_int(table, ["limits", "recall_max_entries"]),
    cbr_max_results: get_toml_int(table, ["limits", "cbr_max_results"]),
    web_search_max_results: get_toml_int(table, [
      "limits", "web_search_max_results",
    ]),
    // ── [scoring.threading] ──
    threading_location_weight: get_toml_int(table, [
      "scoring", "threading", "location_weight",
    ]),
    threading_domain_weight: get_toml_int(table, [
      "scoring", "threading", "domain_weight",
    ]),
    threading_keyword_weight: get_toml_int(table, [
      "scoring", "threading", "keyword_weight",
    ]),
    threading_topic_weight: get_toml_int(table, [
      "scoring", "threading", "topic_weight",
    ]),
    threading_threshold: get_toml_int(table, [
      "scoring", "threading", "threshold",
    ]),
    // ── [cbr] ──
    cbr_embedding_enabled: get_toml_bool(table, ["cbr", "embedding_enabled"]),
    cbr_embedding_model: get_toml_str(table, ["cbr", "embedding_model"]),
    cbr_embedding_base_url: get_toml_str(table, ["cbr", "embedding_base_url"]),
    cbr_field_weight: get_toml_float(table, ["cbr", "field_weight"]),
    cbr_index_weight: get_toml_float(table, ["cbr", "index_weight"]),
    cbr_recency_weight: get_toml_float(table, ["cbr", "recency_weight"]),
    cbr_domain_weight: get_toml_float(table, ["cbr", "domain_weight"]),
    cbr_embedding_weight: get_toml_float(table, ["cbr", "embedding_weight"]),
    cbr_min_score: get_toml_float(table, ["cbr", "min_score"]),
    // ── [housekeeping] ──
    dedup_similarity: get_toml_float(table, ["housekeeping", "dedup_similarity"]),
    pruning_confidence: get_toml_float(table, [
      "housekeeping", "pruning_confidence",
    ]),
    fact_confidence: get_toml_float(table, ["housekeeping", "fact_confidence"]),
    cbr_pruning_days: get_toml_int(table, ["housekeeping", "cbr_pruning_days"]),
    thread_pruning_days: get_toml_int(table, [
      "housekeeping", "thread_pruning_days",
    ]),
    // ── [agents.*] ──
    planner_max_tokens: get_toml_int(table, ["agents", "planner", "max_tokens"]),
    planner_max_turns: get_toml_int(table, ["agents", "planner", "max_turns"]),
    planner_max_errors: get_toml_int(table, ["agents", "planner", "max_errors"]),
    researcher_max_tokens: get_toml_int(table, [
      "agents", "researcher", "max_tokens",
    ]),
    researcher_max_turns: get_toml_int(table, [
      "agents", "researcher", "max_turns",
    ]),
    researcher_max_errors: get_toml_int(table, [
      "agents", "researcher", "max_errors",
    ]),
    researcher_max_context: get_toml_int(table, [
      "agents", "researcher", "max_context_messages",
    ]),
    coder_max_tokens: get_toml_int(table, ["agents", "coder", "max_tokens"]),
    coder_max_turns: get_toml_int(table, ["agents", "coder", "max_turns"]),
    coder_max_errors: get_toml_int(table, ["agents", "coder", "max_errors"]),
    writer_max_tokens: get_toml_int(table, ["agents", "writer", "max_tokens"]),
    writer_max_turns: get_toml_int(table, ["agents", "writer", "max_turns"]),
    writer_max_errors: get_toml_int(table, ["agents", "writer", "max_errors"]),
    // ── [web] ──
    web_port: get_toml_int(table, ["web", "port"]),
    // ── [services] ──
    duckduckgo_url: get_toml_str(table, ["services", "duckduckgo_url"]),
    brave_search_base_url: get_toml_str(table, [
      "services", "brave_search_base_url",
    ]),
    brave_answers_base_url: get_toml_str(table, [
      "services", "brave_answers_base_url",
    ]),
    jina_reader_base_url: get_toml_str(table, [
      "services", "jina_reader_base_url",
    ]),
    // ── [limits] brave ──
    brave_search_max_results: get_toml_int(table, [
      "limits", "brave_search_max_results",
    ]),
    brave_rate_limit_rps: get_toml_int(table, ["limits", "brave_rate_limit_rps"]),
    brave_answers_rate_limit_rps: get_toml_int(table, [
      "limits", "brave_answers_rate_limit_rps",
    ]),
    brave_cache_ttl_ms: get_toml_int(table, ["limits", "brave_cache_ttl_ms"]),
    // ── [limits] input queue ──
    input_queue_cap: get_toml_int(table, ["limits", "input_queue_cap"]),
    // ── [timeouts] scheduler stuck ──
    scheduler_stuck_timeout_ms: get_toml_int(table, [
      "timeouts", "scheduler_stuck_ms",
    ]),
    scheduler_tool_timeout_ms: get_toml_int(table, [
      "timeouts", "scheduler_tool_ms",
    ]),
    max_autonomous_cycles_per_hour: get_toml_int(table, [
      "scheduler", "max_autonomous_cycles_per_hour",
    ]),
    autonomous_token_budget_per_hour: get_toml_int(table, [
      "scheduler", "autonomous_token_budget_per_hour",
    ]),
    // ── [xstructor] ──
    xstructor_max_retries: get_toml_int(table, ["xstructor", "max_retries"]),
    // ── [narrative] preamble budget ──
    preamble_budget_chars: get_toml_int(table, [
      "narrative", "preamble_budget_chars",
    ]),
    // ── [forecaster] ──
    forecaster_enabled: get_toml_bool(table, ["forecaster", "enabled"]),
    forecaster_tick_ms: get_toml_int(table, ["forecaster", "tick_ms"]),
    forecaster_replan_threshold: get_toml_float(table, [
      "forecaster", "replan_threshold",
    ]),
    forecaster_min_cycles: get_toml_int(table, ["forecaster", "min_cycles"]),
    forecaster_stale_threshold_ms: get_toml_int(table, [
      "forecaster", "stale_threshold_ms",
    ]),
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
  "provider", "task_model", "reasoning_model", "max_tokens", "max_turns",
  "max_consecutive_errors", "max_context_messages", "log_verbose",
  "write_anywhere", "skills_dirs", "gui", "dprime_enabled", "dprime_config",
  "narrative", "profile", "profiles_dirs", "agent", "log_retention_days",
  "log_max_file_bytes", "timeouts", "retry", "limits", "scoring", "housekeeping",
  "housekeeper", "cbr", "agents", "web", "services", "scheduler", "xstructor",
  "forecaster", "sandbox",
]

const known_narrative_keys = [
  "directory", "archivist_model", "archivist_max_tokens", "threading",
  "summaries", "summary_schedule", "max_days", "redact_secrets",
  "preamble_budget_chars",
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
  case tom.get_table(table, ["agent"]) {
    Ok(agent_table) ->
      dict.keys(agent_table)
      |> list.each(fn(key) {
        case list.contains(["name", "version"], key) {
          True -> Nil
          False ->
            slog.warn(
              "config",
              "validate",
              "Unknown agent config key: \"" <> key <> "\" — possible typo?",
              None,
            )
        }
      })
    Error(_) -> Nil
  }
  Nil
}

fn validate_config_values(cfg: AppConfig) -> Nil {
  validate_positive("max_tokens", cfg.max_tokens)
  validate_positive("max_turns", cfg.max_turns)
  validate_positive("max_consecutive_errors", cfg.max_consecutive_errors)
  validate_positive("max_context_messages", cfg.max_context_messages)
  validate_positive("llm_request_timeout_ms", cfg.llm_request_timeout_ms)
  validate_positive("classify_timeout_ms", cfg.classify_timeout_ms)
  validate_positive("retry.max_retries", cfg.retry_max_retries)
  validate_positive("web.port", cfg.web_port)
  validate_positive("input_queue_cap", cfg.input_queue_cap)
  validate_positive(
    "scheduler_stuck_timeout_ms",
    cfg.scheduler_stuck_timeout_ms,
  )
  validate_positive(
    "scheduler.max_autonomous_cycles_per_hour",
    cfg.max_autonomous_cycles_per_hour,
  )
  validate_positive(
    "scheduler.autonomous_token_budget_per_hour",
    cfg.autonomous_token_budget_per_hour,
  )
  validate_positive(
    "narrative.preamble_budget_chars",
    cfg.preamble_budget_chars,
  )
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

fn validate_positive(name: String, value: Option(Int)) -> Nil {
  case value {
    Some(n) if n <= 0 ->
      slog.warn(
        "config",
        "validate",
        name <> " must be positive, got " <> int.to_string(n),
        None,
      )
    _ -> Nil
  }
}
