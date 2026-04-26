// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive
import agent/cognitive/escalation as agent_cognitive_escalation
import agent/cognitive_config.{CognitiveConfig}
import agent/registry
import agent/supervisor
import agent/team as agent_team
import agent/types as agent_types
import agent_identity
import agentlair/types as agentlair_types
import agents/coder
import agents/comms as comms_agent
import agents/observer
import agents/planner
import agents/project_manager
import agents/remembrancer as remembrancer_agent
import agents/researcher
import agents/scheduler as scheduler_agent
import agents/writer
import backup/actor as backup_actor
import captures/expiry as captures_expiry
import cbr/bridge as cbr_bridge
import coder/manager as coder_manager
import coder/types as coder_types
import comms/email as comms_email
import comms/poller as comms_poller
import comms/types as comms_types
import config.{type AppConfig}
import dot_env
import dprime/config as dprime_config_mod
import embedding
import facts/log as facts_log
import facts/provenance_check
import frontdoor
import frontdoor/types as frontdoor_types
import gleam/erlang/process
import gleam/http/request as http_request
import gleam/httpc
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
import meta_learning/workers as meta_workers
import narrative/appraiser
import narrative/curator
import narrative/housekeeper
import narrative/librarian
import narrative/threading as narrative_threading
import normative/character as normative_character
import paths
import planner/config as planner_config
import planner/forecaster
import planner/types as planner_types
import sandbox/manager as sandbox_manager_mod
import sandbox/podman_ffi as sandbox_podman
import sandbox/types as sandbox_types
import scenario/runner as scenario_runner
import scheduler/log as schedule_log
import scheduler/runner as scheduler_runner
import scheduler/types as scheduler_types
import simplifile
import skills
import slog
import strategy/seed as strategy_seed
import tools/cache
import tools/coder_dispatch
import tools/how_to_content
import tools/knowledge as tools_knowledge
import tools/memory as tools_memory
import tools/rate_limiter
import tools/remembrancer as tools_remembrancer
import tools/sandbox_admin
import tui
import web/auth as web_auth
import web/gui as web_gui

/// Exit the process with the given status code.
@external(erlang, "erlang", "halt")
fn do_halt(code: Int) -> Nil

@external(erlang, "springdrift_ffi", "get_date")
fn get_date_ffi() -> String

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

/// Read the package version from the OTP application metadata that
/// Gleam derives from gleam.toml. Single source of truth — bumping
/// gleam.toml updates the agent_version default automatically.
@external(erlang, "springdrift_ffi", "package_version")
fn package_version() -> String

fn default_skill_dirs() -> List(String) {
  paths.default_skills_dirs()
}

/// Append the agent-scoped skills XML to a spec's system_prompt. Specialists
/// only see "always-inject" skills (empty contexts list) — domain-scoped
/// skills require the live cycle context that only the Curator (cognitive
/// loop) has access to.
fn append_skills_to_spec(
  spec: agent_types.AgentSpec,
  discovered: List(skills.SkillMeta),
) -> agent_types.AgentSpec {
  let scoped =
    discovered
    |> skills.for_agent(spec.name)
    |> skills.for_context([])
    |> skills.to_system_prompt_xml
  case scoped {
    "" -> spec
    xml ->
      agent_types.AgentSpec(
        ..spec,
        system_prompt: spec.system_prompt <> "\n\n" <> xml,
      )
  }
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
      case find_arg_value(args, "--scenario") {
        option.Some(path) -> scenario_runner.run(path)
        option.None ->
          case list.contains(args, "--print-config") {
            True -> {
              let cfg = resolve_config()
              io.println(config.to_string(cfg))
              do_halt(0)
            }
            False ->
              case list.contains(args, "--selftest") {
                True -> {
                  let cfg = resolve_config()
                  run_selftest(cfg)
                }
                False -> {
                  let cfg = resolve_config()
                  run(cfg)
                }
              }
          }
      }
  }
}

/// Look up a flag argument's value. `find_arg_value(["--scenario", "foo.toml"],
/// "--scenario")` returns `Some("foo.toml")`. Returns None if the flag is
/// absent or at the tail with no value.
fn find_arg_value(args: List(String), flag: String) -> option.Option(String) {
  case args {
    [] -> option.None
    [head, next, ..] if head == flag -> option.Some(next)
    [_, ..rest] -> find_arg_value(rest, flag)
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
    "  --gui <tui|web>           GUI mode: tui (default) or web (port 12001)",
  )
  io.println("  --skills-dir <path>       Add a skills directory (repeatable)")
  io.println(
    "                            (default: ~/.config/springdrift/skills and .springdrift/skills)",
  )
  io.println("  --config <path>           Load an additional TOML config file")
  io.println(
    "  --verbose                 Log full LLM payloads to the cycle log",
  )
  io.println("  --print-config            Print resolved config and exit")
  io.println(
    "  --selftest                Boot, verify HTTP, exit 0 (pass) or 1 (fail)",
  )
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
  io.println("  skills_dirs    = [\"/path/to/skills\"]")
}

fn run_selftest(cfg: AppConfig) -> Nil {
  let selftest_cfg =
    config.AppConfig(
      ..cfg,
      gui: option.Some("web"),
      cbr_embedding_enabled: option.Some(False),
    )
  let port = option.unwrap(selftest_cfg.web_port, 12_001)

  let _ = process.spawn(fn() { run(selftest_cfg) })

  let max_wait = 15
  let result = selftest_poll(port, max_wait, 0)
  case result {
    Ok(status) -> {
      io.println(
        "selftest: PASS (HTTP "
        <> int.to_string(status)
        <> " on port "
        <> int.to_string(port)
        <> ")",
      )
      do_halt(0)
    }
    Error(reason) -> {
      io.println("selftest: FAIL (" <> reason <> ")")
      do_halt(1)
    }
  }
}

fn selftest_poll(port: Int, max_wait: Int, elapsed: Int) -> Result(Int, String) {
  case elapsed >= max_wait {
    True ->
      Error("app did not respond within " <> int.to_string(max_wait) <> "s")
    False -> {
      case
        http_request.to("http://localhost:" <> int.to_string(port) <> "/chat")
      {
        Error(_) -> Error("invalid request URL")
        Ok(req) ->
          case httpc.send(req) {
            Ok(resp) ->
              case resp.status >= 200 && resp.status < 500 {
                True -> Ok(resp.status)
                False ->
                  Error("unexpected status " <> int.to_string(resp.status))
              }
            Error(_) -> {
              process.sleep(1000)
              selftest_poll(port, max_wait, elapsed + 1)
            }
          }
      }
    }
  }
}

fn run(cfg: AppConfig) -> Nil {
  let verbose = option.unwrap(cfg.log_verbose, False)
  slog.init(verbose)
  let log_retention_days = option.unwrap(cfg.log_retention_days, 30)
  slog.cleanup_old_logs(log_retention_days)
  slog.info("springdrift", "run", "Starting springdrift", option.None)

  let skill_dirs = option.unwrap(cfg.skills_dirs, default_skill_dirs())
  let discovered = skills.discover(skill_dirs)
  // Cognitive-loop fallback prompt: scoped to skills the cognitive loop
  // should see. The Curator builds the richer per-cycle prompt with
  // context filtering; this is only used when Curator falls back (no
  // persona/preamble files present).
  let system = case discovered {
    [] -> ""
    _ ->
      discovered
      |> skills.for_agent("cognitive")
      |> skills.to_system_prompt_xml
  }
  let agent_name = option.unwrap(cfg.agent_name, "Springdrift")
  let agent_version = option.unwrap(cfg.agent_version, package_version())
  let max_tokens = option.unwrap(cfg.max_tokens, 2048)

  let llm_timeout_ms = option.unwrap(cfg.llm_request_timeout_ms, 300_000)
  let #(p, default_task_model, default_reasoning_model) =
    select_provider(cfg, llm_timeout_ms)

  let task_model = option.unwrap(cfg.task_model, default_task_model)
  let reasoning_model =
    option.unwrap(cfg.reasoning_model, default_reasoning_model)

  // Always start with a clean conversation — durable memory is in JSONL
  let initial_messages = []

  // Narrative config (always enabled)
  let narrative_dir = option.unwrap(cfg.narrative_dir, paths.narrative_dir())
  let archivist_model = option.unwrap(cfg.archivist_model, task_model)
  let archivist_max_tokens = option.unwrap(cfg.archivist_max_tokens, 8192)
  let thinking_budget_tokens = cfg.thinking_budget_tokens
  let appraiser_model = option.unwrap(cfg.appraiser_model, task_model)
  let appraiser_max_tokens = option.unwrap(cfg.appraiser_max_tokens, 4096)
  let appraisal_min_complexity =
    option.unwrap(cfg.appraisal_min_complexity, "medium")
  let appraisal_min_steps = option.unwrap(cfg.appraisal_min_steps, 3)

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
  let librarian_max_days = option.unwrap(cfg.librarian_max_days, 180)
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

  // Captures (MVP commitment tracker): sweep expired pending captures at
  // startup, then populate the Librarian's pending cache from disk. The
  // sweep is startup-only in MVP — a long-running agent picks up any
  // captures that aged out since the last boot.
  let _ =
    captures_expiry.sweep(
      paths.captures_dir(),
      option.unwrap(cfg.captures_expiry_days, 14),
      option.None,
    )
  librarian.init_captures(librarian_subj, paths.captures_dir())

  // Seed the Strategy Registry's floor strategies on a fresh instance.
  // No-op when the registry already has any events — operator-curated
  // and CBR-mined strategies are never disturbed. The four floor
  // strategies (reconnaissance-first, search-then-read,
  // synthesise-in-root, parallel-after-reconnaissance) are derived
  // from the 2026-04-26 Nemo session and ship in
  // .springdrift_example/skills/orchestration-large-inputs and
  // .springdrift_example/skills/when-to-use-writer.
  let _ = strategy_seed.seed_if_empty(paths.strategy_log_dir())

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
          image_recovery_enabled: option.unwrap(
            cfg.sandbox_image_recovery_enabled,
            True,
          ),
          image_pull_timeout_ms: option.unwrap(
            cfg.sandbox_image_pull_timeout_ms,
            300_000,
          ),
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

  // Build agent specs, then append the agent-scoped skills XML to each
  // spec's system_prompt. Specialists only see "always-inject" skills
  // (empty contexts list); domain-scoped skills require live cycle
  // context which the Curator handles for the cognitive loop.
  let #(raw_agent_specs, real_coder_deps) =
    default_agent_specs(
      cfg,
      p,
      task_model,
      librarian_subj,
      brave_cache,
      brave_search_limiter,
      brave_answers_limiter,
      brave_cache_ttl_ms,
      skill_dirs,
    )
  let agent_specs =
    raw_agent_specs
    |> list.map(fn(spec) { append_skills_to_spec(spec, discovered) })
  let coder_manager_handle = case real_coder_deps {
    option.Some(deps) -> option.Some(deps.manager)
    option.None -> option.None
  }
  let coder_dispatch_defaults = build_dispatch_defaults(cfg)

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
  let knowledge_tools = case option.unwrap(cfg.knowledge_enabled, False) {
    True -> {
      io.println("Knowledge: enabled")
      tools_knowledge.cognitive_tools()
    }
    False -> []
  }
  let agent_tools =
    list.flatten([
      list.map(agent_specs, cognitive.agent_to_tool),
      [scheduler_tool],
      knowledge_tools,
    ])

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

  // Hand the discovered skills to the Curator so it can filter per-cycle.
  curator.set_skills(curator_subj, discovered)

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

  // Start Frontdoor before cognitive so cognitive receives a live
  // output channel at construction. Adapters (web GUI, TUI, scheduler,
  // comms poller) subscribe separately once cognitive is up.
  let frontdoor_subj = frontdoor.start()

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
      thinking_budget_tokens:,
      archivist_model:,
      archivist_max_tokens:,
      appraiser_model:,
      appraiser_max_tokens:,
      appraisal_min_complexity:,
      appraisal_min_steps:,
      librarian: lib,
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
      sandbox_admin_images: sandbox_admin.ResetImages(
        sandbox_image: option.unwrap(cfg.sandbox_image, "python:3.12-slim"),
        coder_image: option.unwrap(cfg.coder_image, ""),
      ),
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
      team_specs: build_team_specs(cfg.team_templates, task_model),
      team_guards: agent_team.TeamGuards(
        max_members: option.unwrap(cfg.team_max_members, 5),
        token_budget: option.unwrap(cfg.team_token_budget, 200_000),
        max_debate_rounds: option.unwrap(cfg.team_max_debate_rounds, 3),
      ),
      agentlair_config: build_agentlair_config(cfg),
      strategy_registry_enabled: option.unwrap(
        cfg.strategy_registry_enabled,
        True,
      ),
      evidence_config: provenance_check.default_config(),
      frontdoor: option.Some(frontdoor_subj),
      captures_scanner_enabled: option.unwrap(
        cfg.captures_scanner_enabled,
        True,
      ),
      captures_dir: paths.captures_dir(),
      captures_max_per_cycle: option.unwrap(cfg.captures_max_per_cycle, 10),
      deputies_enabled: option.unwrap(cfg.deputies_enabled, True),
      deputies_model: option.unwrap(
        cfg.deputies_model,
        option.unwrap(cfg.task_model, "claude-haiku-4-5-20251001"),
      ),
      deputies_max_tokens: option.unwrap(cfg.deputies_max_tokens, 800),
      deputy_timeout_ms: option.unwrap(cfg.deputy_timeout_ms, 15_000),
      skills_dirs: skill_dirs,
      coder_manager: coder_manager_handle,
      coder_dispatch_defaults: coder_dispatch_defaults,
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

  // Tell Frontdoor about cognitive's inbox so it can inject canned
  // answers when an autonomous cycle raises a human question.
  process.send(
    frontdoor_subj,
    frontdoor_types.SetCognitiveInbox(inbox: cognitive_subj),
  )

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
  // Meta-learning no longer goes through the agent scheduler — it runs
  // as BEAM workers off-cog (see `src/meta_learning/workers.gleam`).
  // Pass an empty task list here; the worker pool starts below.
  let meta_tasks: List(scheduler_types.ScheduleTaskConfig) = []
  let meta_budget_pct = option.unwrap(cfg.meta_max_reflection_budget_pct, 25)
  // Idle-gate config. Defaults: 10 min idle window, 60 min hard defer
  // ceiling, 60 s retry interval. Set idle_window_minutes=0 in the
  // config to disable gating entirely.
  let idle_window_minutes = option.unwrap(cfg.scheduler_idle_window_minutes, 10)
  let max_defer_minutes = option.unwrap(cfg.scheduler_max_defer_minutes, 60)
  let retry_interval_seconds =
    option.unwrap(cfg.scheduler_retry_interval_seconds, 60)
  let idle_config =
    scheduler_types.IdleConfig(
      idle_window_ms: idle_window_minutes * 60 * 1000,
      max_defer_ms: max_defer_minutes * 60 * 1000,
      retry_interval_ms: retry_interval_seconds * 1000,
    )
  let runner_result =
    scheduler_runner.start(
      meta_tasks,
      cognitive_subj,
      paths.schedule_dir(),
      stuck_timeout_ms,
      max_cycles_per_hour,
      token_budget_per_hour,
      meta_budget_pct,
      frontdoor_subj,
      idle_config,
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

  // Wire scheduler to cognitive for idle-gate signalling: cognitive
  // pushes UserInputObserved on each UserInput so the scheduler can
  // defer recurring ticks while the operator is active.
  case scheduler_subj {
    option.Some(sched) ->
      process.send(cognitive_subj, agent_types.SetScheduler(scheduler: sched))
    option.None -> Nil
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

  // Start Phase 2 meta-learning BEAM workers. These run three
  // mechanical audits (affect correlation, fabrication audit, voice
  // drift) on their own timers, bypassing the cognitive loop so
  // operator chat is never interrupted by a housekeeping tick.
  // Judgement jobs stay on the scheduler (Phase 1 idle-gate handles
  // those).
  let worker_ctx =
    tools_remembrancer.RemembrancerContext(
      narrative_dir: option.unwrap(cfg.narrative_dir, paths.narrative_dir()),
      cbr_dir: paths.cbr_dir(),
      facts_dir: paths.facts_dir(),
      knowledge_consolidation_dir: paths.knowledge_consolidation_dir(),
      consolidation_log_dir: paths.consolidation_log_dir(),
      cycle_id: "meta-worker",
      agent_id: "meta-worker",
      librarian: option.Some(librarian_subj),
      review_confidence_threshold: option.unwrap(
        cfg.remembrancer_review_confidence_threshold,
        0.3,
      ),
      dormant_thread_days: option.unwrap(
        cfg.remembrancer_dormant_thread_days,
        7,
      ),
      min_pattern_cases: option.unwrap(cfg.remembrancer_min_pattern_cases, 3),
      fact_decay_half_life_days: option.unwrap(
        cfg.fact_decay_half_life_days,
        30,
      ),
      gate_provider: option.None,
      gate_model: "",
      skills_dir: case option.unwrap(cfg.skills_dirs, default_skill_dirs()) {
        [first, ..] -> first
        [] -> paths.project_dir() <> "/skills"
      },
      max_promotions_per_day: option.unwrap(cfg.meta_max_promotions_per_day, 3),
    )
  let _meta_worker_subjects =
    meta_workers.start_all(cfg, worker_ctx, option.Some(sup))

  // Start Forecaster if enabled (needs cognitive_subj + librarian)
  case option.unwrap(cfg.forecaster_enabled, False) {
    True -> {
      let features_path = case cfg.forecaster_features_path {
        option.Some(p) -> paths.project_dir() <> "/" <> p
        option.None -> paths.project_dir() <> "/planner_features.json"
      }
      let features_config = planner_config.load(features_path)
      let forecaster_config =
        forecaster.ForecasterConfig(
          tick_ms: option.unwrap(cfg.forecaster_tick_ms, 300_000),
          replan_threshold: option.unwrap(cfg.forecaster_replan_threshold, 0.55),
          min_cycles: option.unwrap(cfg.forecaster_min_cycles, 2),
          planner_dir: paths.planner_dir(),
          features_config:,
        )
      let _forecaster_subj =
        forecaster.start(forecaster_config, librarian_subj, cognitive_subj)
      io.println("Forecaster: started")
    }
    False -> Nil
  }

  // Inject active tasks as sensory events so the agent knows what's pending
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
        "Tasks    : " <> int.to_string(list.length(tasks)) <> " active task(s)",
      )
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

  // Start comms inbox poller (if comms enabled and inbox resolved)
  // Reuse the same resolution logic as comms_specs
  case option.unwrap(cfg.comms_enabled, True) {
    True -> {
      let poller_api_key_env =
        option.unwrap(cfg.comms_api_key_env, "AGENTMAIL_API_KEY")
      let poller_from = option.unwrap(cfg.comms_from_address, "")
      let poller_inbox_id = case option.unwrap(cfg.comms_inbox_id, "") {
        "" ->
          case poller_from {
            "" -> ""
            addr ->
              case comms_email.resolve_inbox_id(poller_api_key_env, addr) {
                Ok(id) -> id
                Error(_) -> ""
              }
          }
        id -> id
      }
      case poller_inbox_id {
        "" -> Nil
        _ -> {
          let poll_config =
            comms_poller.PollerConfig(
              inbox_id: poller_inbox_id,
              api_key_env: poller_api_key_env,
              poll_interval_ms: option.unwrap(
                cfg.comms_poll_interval_ms,
                60_000,
              ),
              from_address: poller_from,
            )
          let _poller =
            comms_poller.start(poll_config, cognitive_subj, frontdoor_subj)
          io.println(
            "Comms    : inbox poller started ("
            <> int.to_string(poll_config.poll_interval_ms / 1000)
            <> "s interval)",
          )
        }
      }
    }
    False -> Nil
  }

  // Start GUI
  let tui_input_limit = option.unwrap(cfg.tui_input_limit, 102_400)
  let ws_max_bytes = option.unwrap(cfg.websocket_max_bytes, 1_048_576)
  let max_upload_bytes = option.unwrap(cfg.max_upload_bytes, 26_214_400)
  let gui = option.unwrap(cfg.gui, "tui")
  case gui {
    "web" -> {
      let port = option.unwrap(cfg.web_port, 12_001)
      // Auth posture decision (single source of truth). If the
      // operator hasn't set SPRINGDRIFT_WEB_TOKEN AND hasn't passed
      // --web-no-auth, refuse to start the GUI silently. Better to
      // halt with a clear message than to ship an unauthed surface.
      let env_token = case get_env("SPRINGDRIFT_WEB_TOKEN") {
        Ok(t) -> option.Some(t)
        Error(_) -> option.None
      }
      let no_auth = option.unwrap(cfg.web_no_auth, False)
      case web_auth.decide_startup(env_token, no_auth) {
        web_auth.RefuseToStart(reason) -> {
          io.println("Web GUI  : refusing to start.")
          io.println(reason)
          Nil
        }
        web_auth.NoAuthLocalhostOnly -> {
          io.println(
            "Web GUI  : http://127.0.0.1:"
            <> int.to_string(port)
            <> "  [no auth — localhost only]",
          )
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
            max_upload_bytes,
            web_auth.NoAuthLocalhostOnly,
            scheduler_subj,
            frontdoor_subj,
            option.Some(sup),
          )
        }
        web_auth.AuthRequired(token) -> {
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
            max_upload_bytes,
            web_auth.AuthRequired(token),
            scheduler_subj,
            frontdoor_subj,
            option.Some(sup),
          )
        }
      }
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
        frontdoor_subj,
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
  skill_dirs: List(String),
) -> #(List(agent_types.AgentSpec), option.Option(coder.RealCoderDeps)) {
  let delay = option.unwrap(cfg.inter_turn_delay_ms, 200)
  let p_spec = planner.spec(provider, task_model)
  let appraiser_ctx =
    option.Some(appraiser.AppraiserContext(
      provider:,
      model: option.unwrap(cfg.appraiser_model, task_model),
      max_tokens: option.unwrap(cfg.appraiser_max_tokens, 4096),
      planner_dir: paths.planner_dir(),
      cbr_dir: paths.cbr_dir(),
      librarian: librarian_subj,
      cognitive: option.None,
      min_complexity: option.unwrap(cfg.appraisal_min_complexity, "medium"),
      min_steps: option.unwrap(cfg.appraisal_min_steps, 3),
    ))
  let pm_spec =
    project_manager.spec(
      provider,
      task_model,
      paths.planner_dir(),
      librarian_subj,
      appraiser_ctx,
    )
  let max_artifact_chars = option.unwrap(cfg.max_artifact_chars, 50_000)
  let researcher_auto_store_threshold =
    option.unwrap(cfg.researcher_auto_store_threshold_bytes, 8192)
  let kagi_enabled = option.unwrap(cfg.kagi_enabled, False)
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
      researcher_auto_store_threshold,
      skill_dirs,
      kagi_enabled,
    )
  // Real-coder mode activates only when [coder] is fully configured
  // AND ANTHROPIC_API_KEY is in env. When None, the coder agent is
  // simply not registered — the cog/PM still has dispatch_coder
  // exposed via the cog-loop tool list, but agent_coder is absent.
  let real_coder_deps =
    maybe_build_real_coder_deps(
      cfg,
      paths.planner_dir(),
      librarian_subj,
      appraiser_ctx,
    )
  let c_spec_list = case real_coder_deps {
    option.Some(deps) -> [coder.spec(provider, task_model, skill_dirs, deps)]
    option.None -> []
  }
  let w_spec =
    writer.spec(
      provider,
      task_model,
      paths.artifacts_dir(),
      option.Some(librarian_subj),
      max_artifact_chars,
      skill_dirs,
    )
  let recall_max_entries = option.unwrap(cfg.recall_max_entries, 50)
  let cbr_max_results = option.unwrap(cfg.cbr_max_results, 20)
  let o_spec =
    observer.spec(
      provider,
      task_model,
      option.unwrap(cfg.narrative_dir, paths.narrative_dir()),
      paths.facts_dir(),
      librarian_subj,
      tools_memory.MemoryLimits(recall_max_entries:, cbr_max_results:),
      option.None,
      option.unwrap(cfg.fact_decay_half_life_days, 30),
      paths.artifacts_dir(),
      max_artifact_chars,
    )
  let redact = option.unwrap(cfg.redact_secrets, True)
  let specs = [
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
      ..pm_spec,
      max_tokens: option.unwrap(cfg.pm_max_tokens, pm_spec.max_tokens),
      max_turns: option.unwrap(cfg.pm_max_turns, pm_spec.max_turns),
      max_consecutive_errors: option.unwrap(
        cfg.pm_max_errors,
        pm_spec.max_consecutive_errors,
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
      ..w_spec,
      max_tokens: option.unwrap(cfg.writer_max_tokens, w_spec.max_tokens),
      max_turns: option.unwrap(cfg.writer_max_turns, w_spec.max_turns),
      max_consecutive_errors: option.unwrap(
        cfg.writer_max_errors,
        w_spec.max_consecutive_errors,
      ),
      inter_turn_delay_ms: delay,
      redact_secrets: redact,
    ),
    agent_types.AgentSpec(..o_spec, redact_secrets: redact),
    ..list.flatten([
      list.map(c_spec_list, fn(c_spec) {
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
        )
      }),
      comms_specs(cfg, provider, task_model, delay, redact, skill_dirs),
      remembrancer_specs(
        cfg,
        provider,
        task_model,
        librarian_subj,
        delay,
        redact,
        skill_dirs,
      ),
    ])
  ]
  #(specs, real_coder_deps)
}

fn comms_specs(
  cfg: AppConfig,
  provider: Provider,
  task_model: String,
  delay: Int,
  redact: Bool,
  skill_dirs: List(String),
) -> List(agent_types.AgentSpec) {
  case option.unwrap(cfg.comms_enabled, True) {
    False -> []
    True -> {
      let api_key_env =
        option.unwrap(cfg.comms_api_key_env, "AGENTMAIL_API_KEY")
      let from_address = option.unwrap(cfg.comms_from_address, "")
      // Resolve inbox_id: use config if set, otherwise look up by from_address
      let inbox_id = case option.unwrap(cfg.comms_inbox_id, "") {
        "" ->
          case from_address {
            "" -> ""
            addr ->
              case comms_email.resolve_inbox_id(api_key_env, addr) {
                Ok(id) -> {
                  io.println("Comms    : resolved inbox_id for " <> addr)
                  id
                }
                Error(reason) -> {
                  io.println("Comms    : failed to resolve inbox — " <> reason)
                  ""
                }
              }
          }
        configured_id -> configured_id
      }
      let comms_config =
        comms_types.CommsConfig(
          enabled: True,
          inbox_id:,
          api_key_env:,
          from_address:,
          allowed_recipients: option.unwrap(cfg.comms_allowed_recipients, []),
          from_name: option.unwrap(
            cfg.comms_from_name,
            option.unwrap(cfg.agent_name, "Agent"),
          ),
          max_outbound_per_hour: option.unwrap(
            cfg.comms_max_outbound_per_hour,
            20,
          ),
        )
      case comms_config.inbox_id {
        "" -> {
          slog.warn(
            "springdrift",
            "comms_specs",
            "comms_enabled=true but no inbox_id (set from_address or inbox_id) — comms agent disabled",
            option.None,
          )
          []
        }
        _ -> [
          agent_types.AgentSpec(
            ..comms_agent.spec(
              provider,
              task_model,
              comms_config,
              paths.comms_dir(),
              option.unwrap(cfg.max_tokens, 2048),
              option.unwrap(cfg.max_turns, 6),
              option.unwrap(cfg.max_consecutive_errors, 2),
              skill_dirs,
            ),
            inter_turn_delay_ms: delay,
            redact_secrets: redact,
          ),
        ]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Real-coder (OpenCode-backed) wiring
// ---------------------------------------------------------------------------

/// Resolve per-task budget defaults + ceilings from AppConfig, applying
/// the same defaults used by `default_test_config` so the values stay
/// consistent between live runs and tests.
fn build_dispatch_defaults(cfg: AppConfig) -> coder_dispatch.DispatchDefaults {
  coder_dispatch.DispatchDefaults(
    default_max_tokens: option.unwrap(
      cfg.coder_default_max_tokens_per_task,
      200_000,
    ),
    default_max_cost_usd: option.unwrap(
      cfg.coder_default_max_cost_per_task_usd,
      5.0,
    ),
    default_max_minutes: option.unwrap(
      cfg.coder_default_max_minutes_per_task,
      10,
    ),
    default_max_turns: option.unwrap(cfg.coder_default_max_turns_per_task, 50),
    ceiling_max_tokens: option.unwrap(
      cfg.coder_ceiling_max_tokens_per_task,
      1_000_000,
    ),
    ceiling_max_cost_usd: option.unwrap(
      cfg.coder_ceiling_max_cost_per_task_usd,
      25.0,
    ),
    ceiling_max_minutes: option.unwrap(
      cfg.coder_ceiling_max_minutes_per_task,
      60,
    ),
    ceiling_max_turns: option.unwrap(cfg.coder_ceiling_max_turns_per_task, 200),
  )
}

@external(erlang, "springdrift_ffi", "get_cwd")
fn get_cwd() -> String

/// Ensure the coder image exists locally, building it from
/// Containerfile.coder when missing. Logs progress so first-boot
/// users see what's happening (the build can take several minutes).
/// Returns Ok(Nil) when the image is present (already there or just
/// built), Error(reason) on build failure.
fn ensure_coder_image(image: String) -> Result(Nil, String) {
  case sandbox_podman.run_cmd("podman", ["image", "exists", image], 5000) {
    Ok(r) if r.exit_code == 0 -> Ok(Nil)
    _ -> {
      slog.info(
        "coder",
        "ensure_image",
        "Image "
          <> image
          <> " not present locally; building now (one-time, takes a few minutes)",
        option.None,
      )
      io.println(
        "Coder    : building " <> image <> " (first boot — a few minutes)…",
      )
      let cf = get_cwd() <> "/Containerfile.coder"
      case
        sandbox_podman.run_cmd(
          "podman",
          ["build", "-f", cf, "-t", image, "."],
          900_000,
        )
      {
        Ok(r) if r.exit_code == 0 -> {
          slog.info("coder", "ensure_image", "Built " <> image, option.None)
          io.println("Coder    : built " <> image)
          Ok(Nil)
        }
        Ok(r) ->
          Error(
            "podman build exited "
            <> int.to_string(r.exit_code)
            <> ":\n"
            <> r.stderr,
          )
        Error(reason) -> Error("podman build failed to start: " <> reason)
      }
    }
  }
}

/// Build the RealCoderDeps the coder agent needs for real-coder mode.
/// Returns None when ANTHROPIC_API_KEY is missing or the image build
/// fails. Defaults: image = "springdrift-coder:1.14.25" (set in
/// AppConfig.default), project_root = cwd if not configured,
/// model_id = "claude-sonnet-4-6" (set in AppConfig.default). The only
/// thing the operator MUST provide is ANTHROPIC_API_KEY.
///   - [coder] image
///   - [coder] project_root
///   - [coder] model_id
///   - ANTHROPIC_API_KEY env var
/// Each gating omission logs a warn-level reason at startup so the
/// operator can see why real-coder isn't active.
fn maybe_build_real_coder_deps(
  cfg: AppConfig,
  planner_dir: String,
  librarian: process.Subject(librarian.LibrarianMessage),
  appraiser_ctx: option.Option(appraiser.AppraiserContext),
) -> option.Option(coder.RealCoderDeps) {
  // Defaults come from AppConfig.default (image + provider_id +
  // model_id). project_root falls back to cwd. Operator only needs to
  // set ANTHROPIC_API_KEY.
  let image = option.unwrap(cfg.coder_image, "")
  let project_root = case cfg.coder_project_root {
    option.Some(p) -> p
    option.None -> get_cwd()
  }
  let model_id = option.unwrap(cfg.coder_model_id, "")
  let api_key = case get_env("ANTHROPIC_API_KEY") {
    Ok(k) -> k
    Error(_) -> ""
  }

  case image, project_root, model_id, api_key {
    "", _, _, _ -> {
      slog.info(
        "coder",
        "wire",
        "real-coder mode disabled: [coder] image not set",
        option.None,
      )
      option.None
    }
    _, "", _, _ -> {
      slog.info(
        "coder",
        "wire",
        "real-coder mode disabled: cwd unavailable as project_root fallback",
        option.None,
      )
      option.None
    }
    _, _, "", _ -> {
      slog.info(
        "coder",
        "wire",
        "real-coder mode disabled: [coder] model_id not set",
        option.None,
      )
      option.None
    }
    _, _, _, "" -> {
      io.println(
        "Coder    : ANTHROPIC_API_KEY not set in .env — coder agent disabled. Add it and restart to enable.",
      )
      slog.info(
        "coder",
        "wire",
        "real-coder mode disabled: ANTHROPIC_API_KEY env var not set",
        option.None,
      )
      option.None
    }
    _, _, _, _ ->
      case ensure_coder_image(image) {
        Error(reason) -> {
          io.println("Coder    : image build failed — " <> reason)
          slog.warn(
            "coder",
            "wire",
            "Coder image build failed: " <> reason,
            option.None,
          )
          option.None
        }
        Ok(Nil) -> {
          let coder_config =
            coder_types.CoderConfig(
              image: image,
              project_root: project_root,
              session_timeout_ms: option.unwrap(
                cfg.coder_session_timeout_ms,
                600_000,
              ),
              max_tokens_per_task: option.unwrap(
                cfg.coder_max_tokens_per_task,
                200_000,
              ),
              max_cost_per_task_usd: option.unwrap(
                cfg.coder_max_cost_per_task_usd,
                5.0,
              ),
              max_cost_per_hour_usd: option.unwrap(
                cfg.coder_max_cost_per_hour_usd,
                20.0,
              ),
              cost_poll_interval_ms: option.unwrap(
                cfg.coder_cost_poll_interval_ms,
                5000,
              ),
              provider_id: option.unwrap(cfg.coder_provider_id, "anthropic"),
              model_id: model_id,
              image_recovery_enabled: option.unwrap(
                cfg.coder_image_recovery_enabled,
                True,
              ),
              image_pull_timeout_ms: option.unwrap(
                cfg.coder_image_pull_timeout_ms,
                300_000,
              ),
            )

          let pool_config =
            coder_manager.pool_config_from_options(
              warm_pool_size: cfg.coder_warm_pool_size,
              max_concurrent_sessions: cfg.coder_max_concurrent_sessions,
              container_idle_ttl_ms: cfg.coder_container_idle_ttl_ms,
              container_name_prefix: cfg.coder_container_name_prefix,
              slot_id_base: cfg.coder_slot_id_base,
              container_memory_mb: cfg.coder_container_memory_mb,
              container_cpus: cfg.coder_container_cpus,
              container_pids_limit: cfg.coder_container_pids_limit,
            )

          case
            coder_manager.start(
              coder_config,
              api_key,
              paths.cbr_dir(),
              paths.coder_sessions_dir(),
              pool_config,
            )
          {
            Error(reason) -> {
              slog.warn(
                "coder",
                "wire",
                "CoderManager startup failed: " <> reason,
                option.None,
              )
              option.None
            }
            Ok(mgr) -> {
              slog.info(
                "coder",
                "wire",
                "real-coder mode active: image="
                  <> image
                  <> " project_root="
                  <> project_root
                  <> " model="
                  <> model_id,
                option.None,
              )
              option.Some(coder.RealCoderDeps(
                manager: mgr,
                project_root: project_root,
                planner_dir: planner_dir,
                librarian: librarian,
                appraiser_ctx: appraiser_ctx,
                dispatch_defaults: build_dispatch_defaults(cfg),
              ))
            }
          }
        }
      }
  }
}

fn remembrancer_specs(
  cfg: AppConfig,
  provider: Provider,
  task_model: String,
  librarian_subj: process.Subject(librarian.LibrarianMessage),
  delay: Int,
  redact: Bool,
  skill_dirs: List(String),
) -> List(agent_types.AgentSpec) {
  case option.unwrap(cfg.remembrancer_enabled, True) {
    False -> []
    True -> {
      let model = option.unwrap(cfg.remembrancer_model, task_model)
      let review_threshold =
        option.unwrap(cfg.remembrancer_review_confidence_threshold, 0.3)
      let dormant_days = option.unwrap(cfg.remembrancer_dormant_thread_days, 7)
      let min_cases = option.unwrap(cfg.remembrancer_min_pattern_cases, 3)
      let ctx =
        tools_remembrancer.RemembrancerContext(
          narrative_dir: option.unwrap(cfg.narrative_dir, paths.narrative_dir()),
          cbr_dir: paths.cbr_dir(),
          facts_dir: paths.facts_dir(),
          knowledge_consolidation_dir: paths.knowledge_consolidation_dir(),
          consolidation_log_dir: paths.consolidation_log_dir(),
          cycle_id: "remembrancer",
          agent_id: "remembrancer",
          librarian: option.Some(librarian_subj),
          review_confidence_threshold: review_threshold,
          dormant_thread_days: dormant_days,
          min_pattern_cases: min_cases,
          fact_decay_half_life_days: option.unwrap(
            cfg.fact_decay_half_life_days,
            30,
          ),
          // Skills safety gate uses the same provider + model as the
          // Remembrancer itself (the gate reuses the agent's LLM, no
          // need for a separate scoring model).
          gate_provider: option.Some(provider),
          gate_model: model,
          // Promoted skills land in the first configured skills dir.
          skills_dir: case
            option.unwrap(cfg.skills_dirs, default_skill_dirs())
          {
            [first, ..] -> first
            [] -> paths.project_dir() <> "/skills"
          },
          max_promotions_per_day: option.unwrap(
            cfg.meta_max_promotions_per_day,
            3,
          ),
        )
      [
        agent_types.AgentSpec(
          ..remembrancer_agent.spec(
            provider,
            model,
            ctx,
            option.unwrap(cfg.max_tokens, 4096),
            option.unwrap(cfg.remembrancer_max_turns, 8),
            option.unwrap(cfg.max_consecutive_errors, 3),
            skill_dirs,
          ),
          inter_turn_delay_ms: delay,
          redact_secrets: redact,
        ),
      ]
    }
  }
}

/// Convert team template configs from TOML into TeamSpec values.
fn build_agentlair_config(
  cfg: AppConfig,
) -> option.Option(agentlair_types.AgentLairConfig) {
  case option.unwrap(cfg.agentlair_enabled, False) {
    False -> option.None
    True ->
      case cfg.agentlair_api_key {
        option.None -> {
          io.println(
            "Warning: [agentlair] enabled but no api_key set — disabling",
          )
          option.None
        }
        option.Some(api_key) ->
          option.Some(agentlair_types.AgentLairConfig(
            enabled: True,
            api_key:,
            endpoint_url: option.unwrap(
              cfg.agentlair_endpoint_url,
              "https://api.agentlair.dev",
            ),
            trust_query: option.unwrap(cfg.agentlair_trust_query, True),
          ))
      }
  }
}

fn build_team_specs(
  templates: option.Option(List(config.TeamTemplateConfig)),
  default_model: String,
) -> List(agent_team.TeamSpec) {
  case templates {
    option.None -> []
    option.Some(configs) ->
      list.map(configs, fn(t) {
        let members =
          list.map(t.members, fn(m) {
            let #(agent_name, role, perspective) = m
            agent_team.TeamMember(agent_name:, role:, perspective:)
          })
        let strategy = case t.strategy {
          "pipeline" -> agent_team.TeamPipeline
          "debate" -> agent_team.DebateAndConsensus(max_debate_rounds: 3)
          "lead" ->
            case members {
              [first, ..] ->
                agent_team.LeadWithSpecialists(lead: first.agent_name)
              [] -> agent_team.ParallelMerge
            }
          _ -> agent_team.ParallelMerge
        }
        agent_team.TeamSpec(
          name: t.name,
          description: t.description,
          members:,
          strategy:,
          context_scope: agent_team.SharedFacts,
          max_rounds: 1,
          synthesis_model: option.unwrap(t.synthesis_model, default_model),
          synthesis_max_tokens: 4096,
        )
      })
  }
}
