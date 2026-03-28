import agent/cognitive
import agent/cognitive/escalation as agent_cognitive_escalation
import agent/cognitive_config.{CognitiveConfig}
import agent/registry
import agent/supervisor
import agent/types as agent_types
import agent_identity
import agents/coder
import agents/observer
import agents/planner
import agents/researcher
import agents/scheduler as scheduler_agent
import backup/actor as backup_actor
import cbr/bridge as cbr_bridge
import config.{type AppConfig}
import dot_env
import dprime/config as dprime_config_mod
import embedding
import facts/log as facts_log
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import llm/adapters/anthropic as anthropic_adapter
import llm/adapters/local as local_adapter
import llm/adapters/mistral as mistral_adapter
import llm/adapters/mock
import llm/adapters/openai as openai_adapter
import llm/adapters/vertex as vertex_adapter
import llm/provider.{type Provider}
import llm/retry
import llm/types as llm_types
import narrative/curator
import narrative/housekeeper
import narrative/librarian
import narrative/threading as narrative_threading
import normative/character as normative_character
import paths
import planner/forecaster
import planner/types as planner_types
import sandbox/manager as sandbox_manager_mod
import sandbox/types as sandbox_types
import scheduler/log as schedule_log
import scheduler/runner as scheduler_runner
import simplifile
import skills
import slog
import storage
import tools/cache
import tools/how_to_content
import tools/memory as tools_memory
import tools/rate_limiter
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

  let initial_messages = case list.contains(get_startup_args(), "--fresh") {
    True -> []
    False -> storage.load()
  }

  // Narrative config (always enabled)
  let narrative_dir = option.unwrap(cfg.narrative_dir, paths.narrative_dir())
  let archivist_model = option.unwrap(cfg.archivist_model, task_model)
  let archivist_max_tokens = option.unwrap(cfg.archivist_max_tokens, 8192)

  let redact_secrets = option.unwrap(cfg.redact_secrets, True)
  case redact_secrets {
    True -> Nil
    False ->
      slog.warn(
        "springdrift",
        "run",
        "Secret redaction is DISABLED — logs may contain sensitive data",
        option.None,
      )
  }

  // Migrate legacy facts.jsonl to daily rotation (no-op if already done)
  facts_log.migrate_legacy(paths.facts_dir())

  // Build CBR retrieval config
  let default_weights = cbr_bridge.default_weights()
  let embedding_base_url =
    option.unwrap(cfg.cbr_embedding_base_url, "http://localhost:11434")
  let embed_fn = case option.unwrap(cfg.cbr_embedding_enabled, True) {
    True -> {
      let model = option.unwrap(cfg.cbr_embedding_model, "nomic-embed-text")
      case embedding.start_serving(embedding_base_url, model) {
        Ok(_) -> {
          io.println(
            "CBR      : embeddings via Ollama ("
            <> model
            <> " at "
            <> embedding_base_url
            <> ")",
          )
          option.Some(embedding.make_embed_fn(embedding_base_url, model))
        }
        Error(reason) -> {
          io.println("Fatal: CBR embedding startup failed: " <> reason)
          panic as "CBR embedding startup failed"
        }
      }
    }
    False -> option.None
  }
  let cbr_config =
    librarian.CbrConfig(
      weights: cbr_bridge.RetrievalWeights(
        field_weight: option.unwrap(
          cfg.cbr_field_weight,
          default_weights.field_weight,
        ),
        index_weight: option.unwrap(
          cfg.cbr_index_weight,
          default_weights.index_weight,
        ),
        recency_weight: option.unwrap(
          cfg.cbr_recency_weight,
          default_weights.recency_weight,
        ),
        domain_weight: option.unwrap(
          cfg.cbr_domain_weight,
          default_weights.domain_weight,
        ),
        embedding_weight: option.unwrap(
          cfg.cbr_embedding_weight,
          default_weights.embedding_weight,
        ),
        utility_weight: option.unwrap(
          cfg.cbr_utility_weight,
          default_weights.utility_weight,
        ),
      ),
      min_score: option.unwrap(cfg.cbr_min_score, 0.0),
      embed_fn:,
      cbr_decay_half_life_days: option.unwrap(cfg.cbr_decay_half_life_days, 60),
    )

  // Start the Librarian (supervised — auto-restarts on crash)
  let librarian_max_days = option.unwrap(cfg.librarian_max_days, 90)
  let librarian_subj = case
    librarian.start_supervised(
      narrative_dir,
      paths.cbr_dir(),
      paths.facts_dir(),
      paths.artifacts_dir(),
      paths.planner_dir(),
      librarian_max_days,
      5,
      cbr_config,
    )
  {
    Ok(subj) -> subj
    Error(_) -> {
      io.println("Fatal: Librarian failed to start")
      panic as "Librarian startup failed"
    }
  }
  let lib = option.Some(librarian_subj)

  // Start the Housekeeper (non-critical — log + continue on failure)
  let hk_default = housekeeper.default_config()
  let housekeeper_config =
    housekeeper.HousekeeperConfig(
      short_tick_ms: option.unwrap(
        cfg.housekeeper_short_tick_ms,
        hk_default.short_tick_ms,
      ),
      medium_tick_ms: option.unwrap(
        cfg.housekeeper_medium_tick_ms,
        hk_default.medium_tick_ms,
      ),
      long_tick_ms: option.unwrap(
        cfg.housekeeper_long_tick_ms,
        hk_default.long_tick_ms,
      ),
      narrative_days: option.unwrap(
        cfg.housekeeper_narrative_days,
        hk_default.narrative_days,
      ),
      cbr_days: option.unwrap(cfg.housekeeper_cbr_days, hk_default.cbr_days),
      dag_days: option.unwrap(cfg.housekeeper_dag_days, hk_default.dag_days),
      artifact_days: option.unwrap(
        cfg.housekeeper_artifact_days,
        hk_default.artifact_days,
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
      budget_dedup_debounce_ms: option.unwrap(
        cfg.housekeeper_budget_dedup_debounce_ms,
        hk_default.budget_dedup_debounce_ms,
      ),
    )
  let housekeeper_subj = case
    housekeeper.start(
      librarian_subj,
      narrative_dir,
      paths.facts_dir(),
      housekeeper_config,
    )
  {
    Ok(subj) -> {
      io.println("Housekeeper: started")
      option.Some(subj)
    }
    Error(_) -> {
      io.println("Housekeeper: failed to start (non-critical)")
      option.None
    }
  }

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

  // Create notification channel (early, needed by sandbox startup)
  let notify: process.Subject(agent_types.Notification) = process.new_subject()

  // Sandbox
  let sandbox_mgr = case option.unwrap(cfg.sandbox_enabled, True) {
    True -> {
      let sandbox_cfg =
        sandbox_types.SandboxConfig(
          pool_size: option.unwrap(cfg.sandbox_pool_size, 2),
          memory_mb: option.unwrap(cfg.sandbox_memory_mb, 512),
          cpus: option.unwrap(cfg.sandbox_cpus, "1"),
          image: option.unwrap(cfg.sandbox_image, "python:3.12-slim"),
          exec_timeout_ms: option.unwrap(cfg.sandbox_exec_timeout_ms, 60_000),
          port_base: option.unwrap(cfg.sandbox_port_base, 10_000),
          port_stride: option.unwrap(cfg.sandbox_port_stride, 100),
          ports_per_slot: option.unwrap(cfg.sandbox_ports_per_slot, 5),
          auto_machine: option.unwrap(cfg.sandbox_auto_machine, True),
          workspace_dir: paths.sandbox_workspaces_dir(),
        )
      case sandbox_manager_mod.start(sandbox_cfg, notify, option.None) {
        Ok(mgr) -> {
          io.println(
            "Sandbox  : started (pool="
            <> int.to_string(sandbox_cfg.pool_size)
            <> ")",
          )
          option.Some(mgr)
        }
        Error(reason) -> {
          io.println("Sandbox  : unavailable (" <> reason <> ")")
          option.None
        }
      }
    }
    False -> {
      io.println(
        "Sandbox  : disabled (set [sandbox] enabled = true to re-enable)",
      )
      option.None
    }
  }

  // Build agent specs
  let agent_specs =
    default_agent_specs(
      cfg,
      p,
      task_model,
      librarian_subj,
      brave_cache,
      brave_search_limiter,
      brave_answers_limiter,
      brave_cache_ttl_ms,
      sandbox_mgr,
    )

  // Build agent tools for the cognitive loop (includes scheduler)
  let scheduler_tool =
    agent_types.agent_to_tool(agent_types.AgentSpec(
      name: "scheduler",
      human_name: "Scheduler",
      description: "Manage reminders, todos, and appointments. "
        <> "Set one-shot or recurring reminders that fire at a specific time — "
        <> "as input to the cognitive loop (for agent self-reminders) or as "
        <> "user notifications. Maintain a todo list. Schedule appointments. "
        <> "List, cancel, complete, or reschedule existing items.",
      system_prompt: "",
      provider: p,
      model: task_model,
      max_tokens: 1024,
      max_turns: 4,
      max_consecutive_errors: 2,
      max_context_messages: option.None,
      tools: [],
      restart: agent_types.Permanent,
      tool_executor: fn(_call) {
        llm_types.ToolFailure(tool_use_id: "", error: "stub")
      },
      inter_turn_delay_ms: 0,
      redact_secrets:,
    ))
  let agent_tools =
    list.append(list.map(agent_specs, cognitive.agent_to_tool), [scheduler_tool])

  // Load D' config if enabled (unified: input + tool + output + post_exec gates)
  let unified_dprime = case cfg.dprime_config {
    option.Some(path) -> dprime_config_mod.load_unified(path)
    option.None -> dprime_config_mod.default_unified()
  }
  let #(input_dprime_state, dprime_state, output_dprime_state) = case
    option.unwrap(cfg.dprime_enabled, True)
  {
    False -> #(option.None, option.None, option.None)
    True -> {
      let input_state =
        option.Some(dprime_config_mod.initial_state(unified_dprime.input_gate))
      let tool_state =
        option.Some(dprime_config_mod.initial_state(unified_dprime.tool_gate))
      let output_state = case unified_dprime.output_gate {
        option.Some(ocfg) -> option.Some(dprime_config_mod.initial_state(ocfg))
        option.None -> option.None
      }
      #(input_state, tool_state, output_state)
    }
  }

  // Start Curator (stays alive for dynamic system prompt assembly)
  let curator_subj = case
    curator.start_with_identity(
      librarian_subj,
      narrative_dir,
      paths.cbr_dir(),
      paths.facts_dir(),
      paths.default_identity_dirs(),
      "memory",
      agent_name,
      agent_version,
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

  // Load HOW_TO content (file on disk, or built-in default)
  let how_to_content =
    paths.how_to_paths()
    |> list.find_map(fn(path) {
      case simplifile.read(path) {
        Ok(c) -> Ok(c)
        Error(_) -> Error(Nil)
      }
    })
    |> result.unwrap(how_to_content.builtin())

  // Load character spec for normative calculus (from identity directories)
  let normative_calculus_enabled =
    option.unwrap(cfg.normative_calculus_enabled, True)
  let character_spec = case normative_calculus_enabled {
    True -> normative_character.load_character(paths.default_identity_dirs())
    False -> option.None
  }

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
      input_dprime_state:,
      tool_dprime_state: dprime_state,
      output_dprime_state:,
      meta_config: unified_dprime.meta,
      narrative_dir:,
      cbr_dir: paths.cbr_dir(),
      archivist_model:,
      archivist_max_tokens:,
      librarian: lib,
      write_anywhere:,
      curator: option.Some(curator_subj),
      agent_uuid: stable_identity.agent_uuid,
      agent_name:,
      session_since:,
      retry_config:,
      classify_timeout_ms:,
      threading_config:,
      memory_limits: tools_memory.MemoryLimits(
        recall_max_entries:,
        cbr_max_results:,
      ),
      input_queue_cap: option.unwrap(cfg.input_queue_cap, 10),
      how_to_content: option.Some(how_to_content),
      redact_secrets:,
      planner_dir: paths.planner_dir(),
      max_delegation_depth: option.unwrap(cfg.max_delegation_depth, 3),
      sandbox_enabled: option.is_some(sandbox_mgr),
      deterministic_config: case option.unwrap(cfg.dprime_enabled, True) {
        True -> option.Some(unified_dprime.deterministic)
        False -> option.None
      },
      fact_decay_half_life_days: option.unwrap(
        cfg.fact_decay_half_life_days,
        30,
      ),
      escalation_config: {
        let esc_default = agent_cognitive_escalation.default_config()
        agent_cognitive_escalation.EscalationConfig(
          enabled: option.unwrap(cfg.escalation_enabled, esc_default.enabled),
          tool_failure_threshold: option.unwrap(
            cfg.escalation_tool_failure_threshold,
            esc_default.tool_failure_threshold,
          ),
          safety_score_threshold: option.unwrap(
            cfg.escalation_safety_score_threshold,
            esc_default.safety_score_threshold,
          ),
        )
      },
      gate_timeout_ms: option.unwrap(cfg.gate_timeout_ms, 60_000),
      normative_calculus_enabled:,
      character_spec:,
    ))
  {
    Ok(subj) -> subj
    Error(_) -> {
      io.println("Fatal: Cognitive loop failed to start")
      panic as "Cognitive loop startup failed"
    }
  }

  // Wire sandbox manager to cognitive loop for crash log sensory events
  case sandbox_mgr {
    option.Some(mgr) -> sandbox_manager_mod.set_cognitive(mgr, cognitive_subj)
    option.None -> Nil
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

  // Wire supervisor into cognitive loop
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
  // Migrate old scheduler checkpoint to JSONL (no-op if already done)
  let schedule_dir = paths.schedule_dir()
  schedule_log.migrate_checkpoint(schedule_dir, paths.scheduler_checkpoint())

  // Start the scheduler runner
  let stuck_timeout_ms = option.unwrap(cfg.scheduler_stuck_timeout_ms, 600_000)
  let max_cycles_per_hour =
    option.unwrap(cfg.max_autonomous_cycles_per_hour, 20)
  let token_budget_per_hour =
    option.unwrap(cfg.autonomous_token_budget_per_hour, 500_000)
  let runner_result =
    scheduler_runner.start(
      [],
      cognitive_subj,
      paths.schedule_dir(),
      stuck_timeout_ms,
      max_cycles_per_hour,
      token_budget_per_hour,
    )
  let scheduler_subj = case runner_result {
    Ok(runner_subj) -> {
      io.println("Scheduler: started")
      // Register scheduler agent with the supervisor
      let sched_spec = scheduler_agent.spec(p, task_model, runner_subj)
      let reply_subj = process.new_subject()
      process.send(
        sup,
        agent_types.StartChild(spec: sched_spec, reply_to: reply_subj),
      )
      case process.receive(reply_subj, 5000) {
        Ok(Ok(_)) -> io.println("  Agent  : scheduler started")
        Ok(Error(msg)) ->
          io.println("  Agent  : scheduler failed (" <> msg <> ")")
        Error(_) -> io.println("  Agent  : scheduler failed (timeout)")
      }
      option.Some(runner_subj)
    }
    Error(_) -> {
      io.println("Scheduler: failed to start")
      option.None
    }
  }

  // Wire scheduler to curator for open_commitments slot
  case scheduler_subj {
    option.Some(sched) -> curator.set_scheduler(curator_subj, sched)
    option.None -> Nil
  }

  // Set preamble budget from config
  let preamble_budget = option.unwrap(cfg.preamble_budget_chars, 8000)
  curator.set_preamble_budget(curator_subj, preamble_budget)

  // Wire housekeeper to curator for budget-triggered dedup
  case housekeeper_subj {
    option.Some(hk) -> curator.set_housekeeper(curator_subj, hk)
    option.None -> Nil
  }

  // Start Forecaster if enabled (needs cognitive_subj + librarian)
  case option.unwrap(cfg.forecaster_enabled, False) {
    True -> {
      let forecaster_config =
        forecaster.ForecasterConfig(
          tick_ms: option.unwrap(cfg.forecaster_tick_ms, 300_000),
          replan_threshold: option.unwrap(cfg.forecaster_replan_threshold, 0.55),
          min_cycles: option.unwrap(cfg.forecaster_min_cycles, 2),
          planner_dir: paths.planner_dir(),
        )
      let _forecaster_subj =
        forecaster.start(forecaster_config, librarian_subj, cognitive_subj)
      io.println("Forecaster: started")
    }
    False -> Nil
  }

  // Inject active tasks as sensory events on resume
  case list.contains(get_startup_args(), "--fresh") {
    True -> Nil
    False -> {
      let active_tasks = librarian.get_active_tasks(librarian_subj)
      let now = get_date_ffi()
      list.each(active_tasks, fn(task) {
        let status_str = case task.status {
          planner_types.Pending -> "pending"
          planner_types.Active -> "active"
          planner_types.Complete -> "complete"
          planner_types.Failed -> "failed"
          planner_types.Abandoned -> "abandoned"
        }
        let steps_str = int.to_string(list.length(task.plan_steps)) <> " steps"
        process.send(
          cognitive_subj,
          agent_types.QueuedSensoryEvent(event: agent_types.SensoryEvent(
            name: "task_resume",
            title: "Active task: " <> task.title,
            body: "Task "
              <> task.task_id
              <> " ["
              <> status_str
              <> "] with "
              <> steps_str,
            fired_at: now,
          )),
        )
      })
      case active_tasks {
        [] -> Nil
        tasks ->
          io.println(
            "Tasks    : "
            <> int.to_string(list.length(tasks))
            <> " active task(s) resumed",
          )
      }
    }
  }

  // Start git backup actor (if enabled)
  case option.unwrap(cfg.backup_enabled, True) {
    True -> {
      let backup_config =
        backup_actor.BackupConfig(
          enabled: True,
          data_dir: paths.project_dir(),
          mode: option.unwrap(cfg.backup_mode, "periodic"),
          cycle_interval: 1,
          periodic_interval_ms: option.unwrap(cfg.backup_interval_ms, 300_000),
          remote_url: cfg.backup_remote_url,
          branch: option.unwrap(cfg.backup_branch, "main"),
          push_interval_ms: 3_600_000,
        )
      case backup_actor.start(backup_config) {
        Ok(_) ->
          io.println("Backup   : started (git, " <> backup_config.mode <> ")")
        Error(e) -> io.println("Backup   : failed to start — " <> e)
      }
    }
    False -> Nil
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
        scheduler_subj,
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

  // Shutdown sandbox containers on exit
  case sandbox_mgr {
    option.Some(mgr) -> sandbox_manager_mod.shutdown(mgr)
    option.None -> Nil
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
          let tm =
            option.unwrap(cfg.anthropic_task_model, "claude-haiku-4-5-20251001")
          let rm =
            option.unwrap(cfg.anthropic_reasoning_model, "claude-opus-4-6")
          #(p, tm, rm)
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
          let tm =
            option.unwrap(cfg.mistral_task_model, mistral_adapter.mistral_small)
          let rm =
            option.unwrap(
              cfg.mistral_reasoning_model,
              mistral_adapter.mistral_large,
            )
          #(p, tm, rm)
        }
        Error(_) -> {
          io.println("Error: MISTRAL_API_KEY not set. Falling back to mock.")
          #(mock_provider(), "mock-model", "mock-model")
        }
      }
    }
    option.Some("vertex") -> {
      let project_id = option.unwrap(cfg.vertex_project_id, "")
      let location = option.unwrap(cfg.vertex_location, "europe-west1")
      let endpoint =
        option.unwrap(
          cfg.vertex_endpoint,
          location <> "-aiplatform.googleapis.com",
        )
      case project_id {
        "" -> {
          io.println(
            "Error: vertex provider requires [vertex] project_id in config.toml.",
          )
          #(mock_provider(), "mock-model", "mock-model")
        }
        _ ->
          case
            vertex_adapter.provider_from_config(
              project_id,
              location,
              endpoint,
              cfg.vertex_credentials,
            )
          {
            Ok(p) -> {
              io.println(
                "Provider : Vertex AI (project: "
                <> project_id
                <> ", endpoint: "
                <> endpoint
                <> ")",
              )
              let tm =
                option.unwrap(
                  cfg.vertex_task_model,
                  vertex_adapter.claude_haiku_4_5,
                )
              let rm =
                option.unwrap(
                  cfg.vertex_reasoning_model,
                  vertex_adapter.claude_opus_4_6,
                )
              #(p, tm, rm)
            }
            Error(e) -> {
              let reason = case e {
                llm_types.ConfigError(reason:) -> reason
                _ -> "unknown error"
              }
              io.println("Error: Vertex AI auth failed: " <> reason)
              io.println("Falling back to mock.")
              #(mock_provider(), "mock-model", "mock-model")
            }
          }
      }
    }
    option.Some("local") ->
      case local_adapter.provider_from_env() {
        Ok(p) -> {
          io.println("Provider : Local")
          let tm = option.unwrap(cfg.local_task_model, local_adapter.smollm3)
          let rm =
            option.unwrap(cfg.local_reasoning_model, local_adapter.smollm3)
          #(p, tm, rm)
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
  sandbox_manager: option.Option(sandbox_types.SandboxManager),
) -> List(agent_types.AgentSpec) {
  let delay = option.unwrap(cfg.inter_turn_delay_ms, 200)
  let p_spec = planner.spec(provider, task_model)
  let max_artifact_chars = option.unwrap(cfg.max_artifact_chars, 50_000)
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
  let c_spec = coder.spec(provider, task_model, sandbox_manager)
  let recall_max_entries = option.unwrap(cfg.recall_max_entries, 50)
  let cbr_max_results = option.unwrap(cfg.cbr_max_results, 20)
  let o_spec =
    observer.spec(
      provider,
      task_model,
      option.unwrap(cfg.narrative_dir, paths.narrative_dir()),
      librarian_subj,
      tools_memory.MemoryLimits(recall_max_entries:, cbr_max_results:),
      option.None,
    )
  let redact = option.unwrap(cfg.redact_secrets, True)
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
      redact_secrets: redact,
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
      redact_secrets: redact,
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
      redact_secrets: redact,
    ),
    agent_types.AgentSpec(..o_spec, redact_secrets: redact),
  ]
}
