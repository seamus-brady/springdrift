import agent/cognitive
import agent/cognitive_config.{CognitiveConfig}
import agent/registry
import agent/supervisor
import agent/types as agent_types
import agent_identity
import agents/coder
import agents/planner
import agents/researcher
import config.{type AppConfig}
import dot_env
import dprime/config as dprime_config_mod
import embedding/health as embedding_health
import embedding/types as embedding_types
import facts/log as facts_log
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/string
import llm/adapters/anthropic as anthropic_adapter
import llm/adapters/local as local_adapter
import llm/adapters/mistral as mistral_adapter
import llm/adapters/mock
import llm/adapters/openai as openai_adapter
import llm/provider.{type Provider}
import llm/retry
import llm/types as llm_types
import narrative/curator
import narrative/librarian
import narrative/threading as narrative_threading
import paths
import profile
import profile/types as profile_types
import scheduler/runner as scheduler_runner
import simplifile
import skills
import slog
import storage
import tools/brave as tools_brave
import tools/builtin as tools_builtin
import tools/cache
import tools/jina as tools_jina
import tools/memory as tools_memory
import tools/rate_limiter
import tools/web as tools_web
import tui
import web/gui as web_gui

/// Exit the process with the given status code.
@external(erlang, "erlang", "halt")
fn do_halt(code: Int) -> Nil

@external(erlang, "springdrift_ffi", "get_date")
fn get_date_ffi() -> String

fn default_skill_dirs() -> List(String) {
  paths.default_skills_dirs()
}

pub fn main() -> Nil {
  // Load .env file from project root (silently ignored if missing)
  dot_env.new()
  |> dot_env.set_ignore_missing_file(True)
  |> dot_env.load()

  let args = get_startup_args()
  case list.contains(args, "--help") || list.contains(args, "-h") {
    True -> {
      print_help()
      do_halt(0)
    }
    False ->
      case list.contains(args, "--print-config") {
        True -> {
          let cfg = resolve_config()
          io.println(config.to_string(cfg))
          do_halt(0)
        }
        False -> {
          let cfg = resolve_config()
          run(cfg)
        }
      }
  }
}

fn resolve_config() -> config.AppConfig {
  let base_cfg = config.resolve()
  case base_cfg.config_path {
    option.None -> base_cfg
    option.Some(path) ->
      case simplifile.read(path) {
        Error(_) -> {
          io.println("Warning: could not read config file: " <> path)
          base_cfg
        }
        Ok(contents) ->
          case config.parse_config_toml(contents) {
            Error(_) -> {
              io.println("Warning: could not parse config file: " <> path)
              base_cfg
            }
            Ok(file_cfg) -> config.merge(file_cfg, base_cfg)
          }
      }
  }
}

fn get_startup_args() -> List(String) {
  get_args_ffi()
}

@external(erlang, "springdrift_ffi", "get_args")
fn get_args_ffi() -> List(String)

fn print_help() -> Nil {
  io.println("Usage: gleam run [-- OPTIONS]")
  io.println("")
  io.println("LLM provider and models:")
  io.println(
    "  --provider <name>         anthropic | openrouter | openai | mistral | local | mock",
  )
  io.println(
    "                            (default: mock — set in config or via flag)",
  )
  io.println(
    "  --task-model <name>       Model for Simple queries (default: provider-specific)",
  )
  io.println(
    "  --reasoning-model <name>  Model for Complex queries (default: provider-specific)",
  )
  io.println(
    "  --agent-name <name>       Agent name for persona (default: \"Springdrift\")",
  )
  io.println(
    "  --agent-version <ver>     Agent version for persona (default: none)",
  )
  io.println(
    "  --max-tokens <n>          Max output tokens per LLM call (default: 1024)",
  )
  io.println("")
  io.println("Loop control:")
  io.println(
    "  --max-turns <n>           Max react-loop iterations per message (default: 5)",
  )
  io.println(
    "  --max-errors <n>          Consecutive tool failures before abort (default: 3)",
  )
  io.println(
    "  --max-context <n>         Sliding-window message cap (default: unlimited)",
  )
  io.println("")
  io.println("Session / config:")
  io.println(
    "  --gui <tui|web>           GUI mode: tui (default) or web (port 8080)",
  )
  io.println("  --resume                  Resume previous session from disk")
  io.println("  --skills-dir <path>       Add a skills directory (repeatable)")
  io.println(
    "                            (default: ~/.config/springdrift/skills and .springdrift/skills)",
  )
  io.println("  --config <path>           Load an additional TOML config file")
  io.println(
    "  --verbose                 Log full LLM payloads to the cycle log",
  )
  io.println("  --print-config            Print resolved config and exit")
  io.println("  --help, -h                Show this help")
  io.println("")
  io.println("Safety (D' discrepancy gate):")
  io.println(
    "  --dprime                  Enable D' safety evaluation before tool dispatch",
  )
  io.println(
    "  --no-dprime               Disable D' safety evaluation (default)",
  )
  io.println(
    "  --dprime-config <path>    Path to D' config JSON (default: built-in)",
  )
  io.println("")
  io.println("Narrative (Prime Narrative memory — always enabled):")
  io.println(
    "  --narrative-dir <path>    Directory for narrative logs (default: .springdrift/memory/narrative)",
  )
  io.println("")
  io.println("Config files (checked in order; local overrides user config):")
  io.println("  .springdrift/config.toml")
  io.println("  ~/.config/springdrift/config.toml")
  io.println("")
  io.println("Example .springdrift/config.toml (all fields optional):")
  io.println("  # LLM provider and models")
  io.println("  provider        = \"anthropic\"")
  io.println("  task_model      = \"claude-haiku-4-5-20251001\"")
  io.println("  reasoning_model = \"claude-opus-4-6\"")
  io.println("  max_tokens      = 2048")
  io.println("")
  io.println("  # Loop control")
  io.println("  max_turns              = 5")
  io.println("  max_consecutive_errors = 3")
  io.println("  max_context_messages   = 50   # omit for unlimited")
  io.println("")
  io.println("  # Logging and filesystem")
  io.println("  log_verbose    = false")
  io.println("  write_anywhere = false")
  io.println("  skills_dirs    = [\"/path/to/skills\"]")
}

fn run(cfg: AppConfig) -> Nil {
  let verbose = option.unwrap(cfg.log_verbose, False)
  slog.init(verbose)
  let log_retention_days = option.unwrap(cfg.log_retention_days, 30)
  slog.cleanup_old_logs(log_retention_days)
  slog.info("springdrift", "run", "Starting springdrift", option.None)

  let skill_dirs = option.unwrap(cfg.skills_dirs, default_skill_dirs())
  let discovered = skills.discover(skill_dirs)
  let system = case discovered {
    [] -> ""
    _ -> skills.to_system_prompt_xml(discovered)
  }
  let agent_name = option.unwrap(cfg.agent_name, "Springdrift")
  let agent_version = option.unwrap(cfg.agent_version, "")
  let max_tokens = option.unwrap(cfg.max_tokens, 2048)
  let write_anywhere = option.unwrap(cfg.write_anywhere, False)
  case write_anywhere {
    True ->
      slog.warn(
        "springdrift",
        "run",
        "write_anywhere is ENABLED — file writes are not restricted to CWD",
        option.None,
      )
    False -> Nil
  }

  let llm_timeout_ms = option.unwrap(cfg.llm_request_timeout_ms, 300_000)
  let #(p, default_task_model, default_reasoning_model) =
    select_provider(cfg, llm_timeout_ms)

  let task_model = option.unwrap(cfg.task_model, default_task_model)
  let reasoning_model =
    option.unwrap(cfg.reasoning_model, default_reasoning_model)

  let initial_messages = case list.contains(get_startup_args(), "--resume") {
    True -> storage.load()
    False -> []
  }

  // Narrative config (always enabled)
  let narrative_dir = option.unwrap(cfg.narrative_dir, paths.narrative_dir())
  let archivist_model = option.unwrap(cfg.archivist_model, task_model)
  let archivist_max_tokens = option.unwrap(cfg.archivist_max_tokens, 4096)

  // Migrate legacy facts.jsonl to daily rotation (no-op if already done)
  facts_log.migrate_legacy(paths.facts_dir())

  // Build CBR scoring config
  let default_sc = librarian.default_scoring_config()
  let scoring_config =
    librarian.CbrScoringConfig(
      cosine_weight: option.unwrap(
        cfg.cbr_cosine_weight,
        default_sc.cosine_weight,
      ),
      symbolic_weight: option.unwrap(
        cfg.cbr_symbolic_weight,
        default_sc.symbolic_weight,
      ),
      intent_weight: option.unwrap(
        cfg.cbr_intent_weight,
        default_sc.intent_weight,
      ),
      keyword_weight: option.unwrap(
        cfg.cbr_keyword_weight,
        default_sc.keyword_weight,
      ),
      entity_weight: option.unwrap(
        cfg.cbr_entity_weight,
        default_sc.entity_weight,
      ),
      domain_weight: option.unwrap(
        cfg.cbr_domain_weight,
        default_sc.domain_weight,
      ),
      recency_weight: option.unwrap(
        cfg.cbr_recency_weight,
        default_sc.recency_weight,
      ),
      min_score: option.unwrap(cfg.cbr_min_score, default_sc.min_score),
      recency_decay_days: option.unwrap(
        cfg.cbr_recency_decay_days,
        default_sc.recency_decay_days,
      ),
      mailbox_warn_threshold: option.unwrap(
        cfg.mailbox_warn_threshold,
        default_sc.mailbox_warn_threshold,
      ),
    )

  // Start the Librarian (supervised — auto-restarts on crash)
  let librarian_max_days = option.unwrap(cfg.librarian_max_days, 90)
  let librarian_subj = case
    librarian.start_supervised(
      narrative_dir,
      paths.cbr_dir(),
      paths.facts_dir(),
      paths.artifacts_dir(),
      librarian_max_days,
      5,
      scoring_config,
    )
  {
    Ok(subj) -> subj
    Error(_) -> {
      io.println("Fatal: Librarian failed to start")
      panic as "Librarian startup failed"
    }
  }
  let lib = option.Some(librarian_subj)

  // Start cache and rate limiter actors for web tools
  let brave_cache = case cache.start() {
    Ok(subj) -> option.Some(subj)
    Error(_) -> option.None
  }
  let brave_rate_limit_rps = option.unwrap(cfg.brave_rate_limit_rps, 20)
  let brave_search_limiter = case
    rate_limiter.start(brave_rate_limit_rps, 1000 / brave_rate_limit_rps)
  {
    Ok(subj) -> option.Some(subj)
    Error(_) -> option.None
  }
  let brave_answers_rate_limit_rps =
    option.unwrap(cfg.brave_answers_rate_limit_rps, 2)
  let brave_answers_limiter = case
    rate_limiter.start(
      brave_answers_rate_limit_rps,
      1000 / brave_answers_rate_limit_rps,
    )
  {
    Ok(subj) -> option.Some(subj)
    Error(_) -> option.None
  }
  let brave_cache_ttl_ms = option.unwrap(cfg.brave_cache_ttl_ms, 300_000)

  // Profile system
  let profile_dirs =
    option.unwrap(cfg.profiles_dirs, profile.default_profile_dirs())
  let available_profiles = profile.discover(profile_dirs)

  // Build agent specs (default or from profile)
  let #(agent_specs, active_profile) = case cfg.default_profile {
    option.Some(profile_name) ->
      case profile.load(profile_name, profile_dirs) {
        Ok(loaded_profile) -> {
          io.println("Profile  : " <> profile_name)
          let specs =
            build_profile_agent_specs(
              loaded_profile,
              p,
              task_model,
              write_anywhere,
            )
          #(specs, option.Some(profile_name))
        }
        Error(msg) -> {
          io.println(
            "Profile  : '"
            <> profile_name
            <> "' failed ("
            <> msg
            <> ") — using defaults",
          )
          #(
            default_agent_specs(
              cfg,
              p,
              task_model,
              librarian_subj,
              brave_cache,
              brave_search_limiter,
              brave_answers_limiter,
              brave_cache_ttl_ms,
            ),
            option.None,
          )
        }
      }
    option.None -> #(
      default_agent_specs(
        cfg,
        p,
        task_model,
        librarian_subj,
        brave_cache,
        brave_search_limiter,
        brave_answers_limiter,
        brave_cache_ttl_ms,
      ),
      option.None,
    )
  }

  // Build agent tools for the cognitive loop
  let agent_tools = list.map(agent_specs, cognitive.agent_to_tool)

  // Create notification channel
  let notify: process.Subject(agent_types.Notification) = process.new_subject()

  // Load D' config if enabled (dual-gate: tool_gate + optional output_gate)
  let #(dprime_state, output_dprime_state) = case
    option.unwrap(cfg.dprime_enabled, False)
  {
    False -> #(option.None, option.None)
    True -> {
      let #(tool_cfg, output_cfg) = case cfg.dprime_config {
        option.Some(path) -> dprime_config_mod.load_dual(path)
        option.None -> #(dprime_config_mod.default(), option.None)
      }
      let tool_state = option.Some(dprime_config_mod.initial_state(tool_cfg))
      let output_state = case output_cfg {
        option.Some(ocfg) -> option.Some(dprime_config_mod.initial_state(ocfg))
        option.None -> option.None
      }
      #(tool_state, output_state)
    }
  }

  // Ollama embedding service — obligatory health check at startup
  let default_embed = embedding_types.default_config()
  let embedding_config =
    embedding_types.EmbeddingConfig(
      model: option.unwrap(cfg.embedding_model, default_embed.model),
      base_url: option.unwrap(cfg.embedding_base_url, default_embed.base_url),
      dimensions: option.unwrap(
        cfg.embedding_dimensions,
        default_embed.dimensions,
      ),
      fallback: default_embed.fallback,
    )
  case embedding_health.check(embedding_config) {
    embedding_types.Healthy(model: m, dimensions: d) ->
      io.println(
        "Embeddings: " <> m <> " (" <> int.to_string(d) <> " dims) — OK",
      )
    embedding_types.Unhealthy(error: e) -> {
      io.println("FATAL: Ollama embedding service is required but unavailable.")
      case e {
        embedding_types.NotReachable(reason:) ->
          io.println(
            "  Ollama not reachable: " <> reason <> "\n  Fix: ollama serve",
          )
        embedding_types.ModelNotFound(model:) ->
          io.println(
            "  Model '" <> model <> "' not found.\n  Fix: ollama pull " <> model,
          )
        embedding_types.DimensionMismatch(expected:, got:) ->
          io.println(
            "  Dimension mismatch: expected "
            <> int.to_string(expected)
            <> ", got "
            <> int.to_string(got)
            <> "\n  Fix: ollama rm "
            <> embedding_config.model
            <> " && ollama pull "
            <> embedding_config.model,
          )
        embedding_types.HttpError(status:, body:) ->
          io.println("  HTTP error " <> int.to_string(status) <> ": " <> body)
        embedding_types.NetworkError(reason:) ->
          io.println("  Network error: " <> reason)
        embedding_types.DecodeError(reason:) ->
          io.println("  Decode error: " <> reason)
      }
      do_halt(1)
    }
  }

  // Build housekeeping config
  let hk_default = curator.default_housekeeping_config()
  let housekeeping_config =
    curator.HousekeepingConfig(
      tick_ms: option.unwrap(cfg.housekeeping_tick_ms, hk_default.tick_ms),
      interval_ticks: option.unwrap(
        cfg.housekeeping_interval_ticks,
        hk_default.interval_ticks,
      ),
      dedup_similarity: option.unwrap(
        cfg.dedup_similarity,
        hk_default.dedup_similarity,
      ),
      pruning_confidence: option.unwrap(
        cfg.pruning_confidence,
        hk_default.pruning_confidence,
      ),
      fact_confidence: option.unwrap(
        cfg.fact_confidence,
        hk_default.fact_confidence,
      ),
      cbr_pruning_days: option.unwrap(
        cfg.cbr_pruning_days,
        hk_default.cbr_pruning_days,
      ),
      thread_pruning_days: option.unwrap(
        cfg.thread_pruning_days,
        hk_default.thread_pruning_days,
      ),
    )

  // Start Curator (stays alive for dynamic system prompt assembly)
  let curator_subj = case
    curator.start_with_identity(
      librarian_subj,
      narrative_dir,
      paths.cbr_dir(),
      paths.facts_dir(),
      paths.default_identity_dirs(),
      "memory",
      active_profile,
      agent_name,
      agent_version,
      housekeeping_config,
    )
  {
    Ok(subj) -> subj
    Error(_) -> {
      io.println("Fatal: Curator failed to start")
      panic as "Curator startup failed"
    }
  }

  // Load or create stable agent identity
  let stable_identity = agent_identity.load_or_create()
  agent_identity.save(stable_identity)
  let session_since = get_date_ffi()

  // Start cognitive loop with empty registry (supervisor will register agents)
  // Build retry config from user settings
  let default_retry = retry.default_retry_config()
  let retry_config =
    retry.RetryConfig(
      max_retries: option.unwrap(
        cfg.retry_max_retries,
        default_retry.max_retries,
      ),
      initial_delay_ms: option.unwrap(
        cfg.retry_initial_delay_ms,
        default_retry.initial_delay_ms,
      ),
      rate_limit_delay_ms: option.unwrap(
        cfg.retry_rate_limit_delay_ms,
        default_retry.rate_limit_delay_ms,
      ),
      overload_delay_ms: option.unwrap(
        cfg.retry_overload_delay_ms,
        default_retry.overload_delay_ms,
      ),
      max_delay_ms: option.unwrap(
        cfg.retry_max_delay_ms,
        default_retry.max_delay_ms,
      ),
    )
  let classify_timeout_ms = option.unwrap(cfg.classify_timeout_ms, 10_000)
  let default_threading = narrative_threading.default_config()
  let threading_config =
    narrative_threading.ThreadingConfig(
      location_weight: option.unwrap(
        cfg.threading_location_weight,
        default_threading.location_weight,
      ),
      domain_weight: option.unwrap(
        cfg.threading_domain_weight,
        default_threading.domain_weight,
      ),
      keyword_weight: option.unwrap(
        cfg.threading_keyword_weight,
        default_threading.keyword_weight,
      ),
      topic_weight: option.unwrap(
        cfg.threading_topic_weight,
        default_threading.topic_weight,
      ),
      threshold: option.unwrap(
        cfg.threading_threshold,
        default_threading.threshold,
      ),
    )

  let recall_max_entries = option.unwrap(cfg.recall_max_entries, 50)
  let cbr_max_results = option.unwrap(cfg.cbr_max_results, 20)

  let cognitive_subj = case
    cognitive.start(CognitiveConfig(
      provider: p,
      system:,
      max_tokens:,
      max_context_messages: cfg.max_context_messages,
      agent_tools:,
      initial_messages:,
      registry: registry.new(),
      verbose:,
      notify:,
      task_model:,
      reasoning_model:,
      dprime_state:,
      output_dprime_state:,
      narrative_dir:,
      cbr_dir: paths.cbr_dir(),
      archivist_model:,
      archivist_max_tokens:,
      librarian: lib,
      profile_dirs:,
      write_anywhere:,
      curator: option.Some(curator_subj),
      embedding_config:,
      agent_uuid: stable_identity.agent_uuid,
      session_since:,
      retry_config:,
      classify_timeout_ms:,
      threading_config:,
      memory_limits: tools_memory.MemoryLimits(
        recall_max_entries:,
        cbr_max_results:,
      ),
      input_queue_cap: option.unwrap(cfg.input_queue_cap, 10),
    ))
  {
    Ok(subj) -> subj
    Error(_) -> {
      io.println("Fatal: Cognitive loop failed to start")
      panic as "Cognitive loop startup failed"
    }
  }

  // Start supervisor and register agents via StartChild
  let restart_window_ms = option.unwrap(cfg.restart_window_ms, 60_000)
  let sup = case supervisor.start(cognitive_subj, 5, restart_window_ms) {
    Ok(subj) -> subj
    Error(_) -> {
      io.println("Fatal: Supervisor failed to start")
      panic as "Supervisor startup failed"
    }
  }
  list.each(agent_specs, fn(spec) {
    let reply_subj = process.new_subject()
    process.send(sup, agent_types.StartChild(spec:, reply_to: reply_subj))
    case process.receive(reply_subj, 5000) {
      Ok(Ok(_task_subj)) -> io.println("  Agent  : " <> spec.name <> " started")
      Ok(Error(msg)) ->
        io.println("  Agent  : " <> spec.name <> " failed (" <> msg <> ")")
      Error(_) -> io.println("  Agent  : " <> spec.name <> " failed (timeout)")
    }
  })

  // Wire supervisor into cognitive loop so profile switching can manage agents
  cognitive.set_supervisor(cognitive_subj, sup)

  case dprime_state {
    option.Some(_) -> {
      io.println("D' Safety: enabled (tool gate)")
      case output_dprime_state {
        option.Some(_) -> io.println("D' Safety: enabled (output gate)")
        option.None -> Nil
      }
    }
    option.None -> Nil
  }
  io.println("Narrative: " <> narrative_dir)
  let agent_names =
    list.map(agent_specs, fn(s) { s.name })
    |> string.join(", ")
  io.println("Mode     : cognitive (agents: " <> agent_names <> ")")
  case available_profiles {
    [] -> Nil
    _ -> io.println("Profiles : " <> string.join(available_profiles, ", "))
  }

  // Start scheduler if profile has a schedule
  case cfg.default_profile {
    option.Some(profile_name) ->
      case profile.load(profile_name, profile_dirs) {
        Ok(loaded_profile) ->
          case loaded_profile.schedule_path {
            option.Some(schedule_path) ->
              case profile.parse_schedule(schedule_path) {
                Ok(tasks) ->
                  case tasks {
                    [] -> Nil
                    _ -> {
                      let checkpoint_path =
                        ".springdrift/scheduler-checkpoint.json"
                      let stuck_timeout_ms =
                        option.unwrap(cfg.scheduler_stuck_timeout_ms, 600_000)
                      case
                        scheduler_runner.start(
                          tasks,
                          cognitive_subj,
                          checkpoint_path,
                          stuck_timeout_ms,
                        )
                      {
                        Ok(_) ->
                          io.println(
                            "Scheduler: "
                            <> int.to_string(list.length(tasks))
                            <> " task(s) scheduled",
                          )
                        Error(_) -> io.println("Scheduler: failed to start")
                      }
                    }
                  }
                Error(_) -> Nil
              }
            option.None -> Nil
          }
        Error(_) -> Nil
      }
    option.None -> Nil
  }

  // Start GUI
  let tui_input_limit = option.unwrap(cfg.tui_input_limit, 102_400)
  let ws_max_bytes = option.unwrap(cfg.websocket_max_bytes, 1_048_576)
  let gui = option.unwrap(cfg.gui, "tui")
  case gui {
    "web" -> {
      let port = option.unwrap(cfg.web_port, 8080)
      io.println("Web GUI  : http://localhost:" <> int.to_string(port))
      web_gui.start(
        cognitive_subj,
        notify,
        p.name,
        task_model,
        reasoning_model,
        initial_messages,
        port,
        narrative_dir,
        lib,
        agent_name,
        agent_version,
        ws_max_bytes,
      )
    }
    _ ->
      tui.start(
        cognitive_subj,
        notify,
        p.name,
        task_model,
        reasoning_model,
        initial_messages,
        narrative_dir,
        lib,
        tui_input_limit,
      )
  }
  Nil
}

fn select_provider(
  cfg: AppConfig,
  llm_timeout_ms: Int,
) -> #(Provider, String, String) {
  slog.debug(
    "springdrift",
    "select_provider",
    "Selecting provider: " <> option.unwrap(cfg.provider, "none"),
    option.None,
  )
  case cfg.provider {
    option.Some("anthropic") -> {
      case anthropic_adapter.provider_with_timeout(llm_timeout_ms) {
        Ok(p) -> {
          io.println("Provider : Anthropic")
          #(p, "claude-haiku-4-5-20251001", "claude-opus-4-6")
        }
        Error(_) -> {
          io.println("Error: ANTHROPIC_API_KEY not set. Falling back to mock.")
          #(mock_provider(), "mock-model", "mock-model")
        }
      }
    }
    option.Some("openrouter") -> {
      case openai_adapter.provider_from_openrouter_env() {
        Ok(p) -> {
          io.println("Provider : OpenRouter")
          #(p, openai_adapter.gpt_4o_mini, openai_adapter.gpt_4o)
        }
        Error(_) -> {
          io.println("Error: OPENROUTER_API_KEY not set. Falling back to mock.")
          #(mock_provider(), "mock-model", "mock-model")
        }
      }
    }
    option.Some("openai") -> {
      case openai_adapter.provider_from_env() {
        Ok(p) -> {
          io.println("Provider : OpenAI")
          #(p, openai_adapter.gpt_4o_mini, openai_adapter.gpt_4o)
        }
        Error(_) -> {
          io.println("Error: OPENAI_API_KEY not set. Falling back to mock.")
          #(mock_provider(), "mock-model", "mock-model")
        }
      }
    }
    option.Some("mistral") -> {
      case mistral_adapter.provider_from_env() {
        Ok(p) -> {
          io.println("Provider : Mistral")
          #(p, mistral_adapter.mistral_small, mistral_adapter.mistral_large)
        }
        Error(_) -> {
          io.println("Error: MISTRAL_API_KEY not set. Falling back to mock.")
          #(mock_provider(), "mock-model", "mock-model")
        }
      }
    }
    option.Some("local") ->
      case local_adapter.provider_from_env() {
        Ok(p) -> {
          io.println("Provider : Local")
          #(p, local_adapter.smollm3, local_adapter.smollm3)
        }
        Error(_) -> {
          io.println(
            "Provider : Local failed (check LOCAL_LLM_HOST), falling back to mock",
          )
          #(mock_provider(), "mock-model", "mock-model")
        }
      }
    option.Some("mock") -> #(mock_provider(), "mock-model", "mock-model")
    option.Some(unknown) -> {
      io.println(
        "Unknown provider \""
        <> unknown
        <> "\". Set provider in config or use --provider flag.",
      )
      io.println("Falling back to mock.")
      #(mock_provider(), "mock-model", "mock-model")
    }
    option.None -> {
      io.println(
        "No provider configured. Set provider in config or use --provider flag.",
      )
      io.println("Falling back to mock.")
      #(mock_provider(), "mock-model", "mock-model")
    }
  }
}

fn mock_provider() -> Provider {
  mock.provider_with_text(
    "I'm a mock assistant. Set a provider in your config file or use --provider to use a real LLM.",
  )
}

fn default_agent_specs(
  cfg: AppConfig,
  provider: Provider,
  task_model: String,
  librarian_subj: process.Subject(librarian.LibrarianMessage),
  brave_cache: option.Option(process.Subject(cache.CacheMessage)),
  brave_search_limiter: option.Option(
    process.Subject(rate_limiter.RateLimiterMessage),
  ),
  brave_answers_limiter: option.Option(
    process.Subject(rate_limiter.RateLimiterMessage),
  ),
  brave_cache_ttl_ms: Int,
) -> List(agent_types.AgentSpec) {
  let delay = option.unwrap(cfg.inter_turn_delay_ms, 200)
  let p_spec = planner.spec(provider, task_model)
  let max_artifact_chars = option.unwrap(cfg.max_artifact_chars, 50_000)
  let sandbox_timeout = option.unwrap(cfg.sandbox_timeout_s, 600)
  let r_spec =
    researcher.spec(
      provider,
      task_model,
      paths.artifacts_dir(),
      librarian_subj,
      max_artifact_chars,
      brave_cache,
      brave_search_limiter,
      brave_answers_limiter,
      brave_cache_ttl_ms,
    )
  let c_spec = coder.spec(provider, task_model, sandbox_timeout)
  [
    agent_types.AgentSpec(
      ..p_spec,
      max_tokens: option.unwrap(cfg.planner_max_tokens, p_spec.max_tokens),
      max_turns: option.unwrap(cfg.planner_max_turns, p_spec.max_turns),
      max_consecutive_errors: option.unwrap(
        cfg.planner_max_errors,
        p_spec.max_consecutive_errors,
      ),
      inter_turn_delay_ms: delay,
    ),
    agent_types.AgentSpec(
      ..r_spec,
      max_tokens: option.unwrap(cfg.researcher_max_tokens, r_spec.max_tokens),
      max_turns: option.unwrap(cfg.researcher_max_turns, r_spec.max_turns),
      max_consecutive_errors: option.unwrap(
        cfg.researcher_max_errors,
        r_spec.max_consecutive_errors,
      ),
      max_context_messages: case cfg.researcher_max_context {
        option.Some(n) -> option.Some(n)
        option.None -> r_spec.max_context_messages
      },
      inter_turn_delay_ms: delay,
    ),
    agent_types.AgentSpec(
      ..c_spec,
      max_tokens: option.unwrap(cfg.coder_max_tokens, c_spec.max_tokens),
      max_turns: option.unwrap(cfg.coder_max_turns, c_spec.max_turns),
      max_consecutive_errors: option.unwrap(
        cfg.coder_max_errors,
        c_spec.max_consecutive_errors,
      ),
      inter_turn_delay_ms: delay,
    ),
  ]
}

fn build_profile_agent_specs(
  loaded_profile: profile_types.Profile,
  provider: Provider,
  task_model: String,
  write_anywhere: Bool,
) -> List(agent_types.AgentSpec) {
  list.map(loaded_profile.agents, fn(agent_def) {
    let tools_list = resolve_profile_tools(agent_def.tools)
    let system_prompt = case agent_def.system_prompt {
      option.Some(sp) -> sp
      option.None ->
        "You are a " <> agent_def.name <> " agent. " <> agent_def.description
    }
    let tool_executor =
      build_profile_tool_executor(agent_def.tools, write_anywhere)
    agent_types.AgentSpec(
      name: agent_def.name,
      human_name: string.capitalise(agent_def.name),
      description: agent_def.description,
      system_prompt:,
      provider:,
      model: task_model,
      max_tokens: 4096,
      max_turns: agent_def.max_turns,
      max_consecutive_errors: 3,
      max_context_messages: option.None,
      tools: tools_list,
      restart: agent_types.Permanent,
      tool_executor:,
      inter_turn_delay_ms: 200,
    )
  })
}

fn resolve_profile_tools(tool_groups: List(String)) -> List(llm_types.Tool) {
  list.flat_map(tool_groups, fn(group) {
    case group {
      "web" ->
        list.flatten([
          tools_brave.all(),
          tools_jina.all(),
          tools_web.all(),
        ])
      "builtin" -> tools_builtin.all()
      _ -> []
    }
  })
}

fn build_profile_tool_executor(
  tool_groups: List(String),
  _write_anywhere: Bool,
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  let has_web = list.contains(tool_groups, "web")
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case has_web {
      True ->
        case call.name {
          "brave_web_search"
          | "brave_news_search"
          | "brave_llm_context"
          | "brave_summarizer"
          | "brave_answer" -> tools_brave.execute(call)
          "jina_reader" -> tools_jina.execute(call)
          "fetch_url" | "web_search" -> tools_web.execute(call)
          _ -> tools_builtin.execute(call)
        }
      False -> tools_builtin.execute(call)
    }
  }
}
