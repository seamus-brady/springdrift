import agent/cognitive
import agent/registry
import agent/supervisor
import agent/types as agent_types
import agents/coder
import agents/planner
import agents/researcher
import config.{type AppConfig}
import dprime/config as dprime_config_mod
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
import llm/types as llm_types
import profile
import profile/types as profile_types
import scheduler/runner as scheduler_runner
import simplifile
import skills
import slog
import storage
import tools/builtin as tools_builtin
import tools/web as tools_web
import tui
import web/gui as web_gui

/// Exit the process with the given status code.
@external(erlang, "erlang", "halt")
fn do_halt(code: Int) -> Nil

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

fn default_skill_dirs() -> List(String) {
  case get_env("HOME") {
    Ok(home) -> [home <> "/.config/springdrift/skills", ".skills"]
    Error(_) -> [".skills"]
  }
}

pub fn main() -> Nil {
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
    "  --system <prompt>         System prompt (default: \"You are a helpful assistant.\")",
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
    "                            (default: ~/.config/springdrift/skills and .skills)",
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
  io.println("Narrative (Prime Narrative memory):")
  io.println(
    "  --narrative               Enable narrative logging after each cycle",
  )
  io.println("  --no-narrative            Disable narrative logging (default)")
  io.println(
    "  --narrative-dir <path>    Directory for narrative logs (default: prime-narrative)",
  )
  io.println("")
  io.println("Config files (checked in order; local overrides user config):")
  io.println("  .springdrift.toml")
  io.println("  ~/.config/springdrift/config.toml")
  io.println("")
  io.println("Example .springdrift.toml (all fields optional):")
  io.println("  # LLM provider and models")
  io.println("  provider        = \"anthropic\"")
  io.println("  task_model      = \"claude-haiku-4-5-20251001\"")
  io.println("  reasoning_model = \"claude-opus-4-6\"")
  io.println("  system_prompt   = \"You are a helpful assistant.\"")
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
  slog.cleanup_old_logs()
  slog.info("springdrift", "run", "Starting springdrift", option.None)

  let base_system =
    option.unwrap(
      cfg.system_prompt,
      "You are a cognitive orchestrator. You manage specialist agents and talk to the human. Use agent tools to delegate work and request_human_input to ask questions.",
    )
  let skill_dirs = option.unwrap(cfg.skills_dirs, default_skill_dirs())
  let discovered = skills.discover(skill_dirs)
  let system = case discovered {
    [] -> base_system
    _ -> base_system <> "\n\n" <> skills.to_system_prompt_xml(discovered)
  }
  let max_tokens = option.unwrap(cfg.max_tokens, 2048)
  let write_anywhere = option.unwrap(cfg.write_anywhere, False)

  let #(p, default_task_model, default_reasoning_model) = select_provider(cfg)

  let task_model = option.unwrap(cfg.task_model, default_task_model)
  let reasoning_model =
    option.unwrap(cfg.reasoning_model, default_reasoning_model)

  let initial_messages = case list.contains(get_startup_args(), "--resume") {
    True -> storage.load()
    False -> []
  }

  // Profile system
  let profile_dirs =
    option.unwrap(cfg.profiles_dirs, profile.default_profile_dirs())
  let available_profiles = profile.discover(profile_dirs)

  // Build agent specs (default or from profile)
  let #(agent_specs, _active_profile) = case cfg.default_profile {
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
          #(default_agent_specs(p, task_model), option.None)
        }
      }
    option.None -> #(default_agent_specs(p, task_model), option.None)
  }

  // Build agent tools for the cognitive loop
  let agent_tools = list.map(agent_specs, cognitive.agent_to_tool)

  // Create notification channel
  let notify: process.Subject(agent_types.Notification) = process.new_subject()

  // Load D' config if enabled
  let dprime_state = case option.unwrap(cfg.dprime_enabled, False) {
    False -> option.None
    True -> {
      let dprime_cfg = case cfg.dprime_config {
        option.Some(path) -> dprime_config_mod.load(path)
        option.None -> dprime_config_mod.default()
      }
      option.Some(dprime_config_mod.initial_state(dprime_cfg))
    }
  }

  // Narrative config
  let narrative_enabled = option.unwrap(cfg.narrative_enabled, False)
  let narrative_dir = option.unwrap(cfg.narrative_dir, "prime-narrative")
  let archivist_model = option.unwrap(cfg.archivist_model, task_model)

  // Start cognitive loop with empty registry (supervisor will register agents)
  let cognitive_subj =
    cognitive.start(
      p,
      system,
      max_tokens,
      cfg.max_context_messages,
      agent_tools,
      initial_messages,
      registry.new(),
      verbose,
      notify,
      task_model,
      reasoning_model,
      dprime_state,
      narrative_enabled,
      narrative_dir,
      archivist_model,
      profile_dirs,
      write_anywhere,
    )

  // Start supervisor and register agents via StartChild
  let sup = supervisor.start(cognitive_subj, 5)
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

  case dprime_state {
    option.Some(_) -> io.println("D' Safety: enabled")
    option.None -> Nil
  }
  case narrative_enabled {
    True -> io.println("Narrative: enabled (" <> narrative_dir <> ")")
    False -> Nil
  }
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
                      let _scheduler =
                        scheduler_runner.start(tasks, cognitive_subj)
                      io.println(
                        "Scheduler: "
                        <> int.to_string(list.length(tasks))
                        <> " task(s) scheduled",
                      )
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
  let gui = option.unwrap(cfg.gui, "tui")
  case gui {
    "web" -> {
      let port = 8080
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
        available_profiles,
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
      )
  }
  Nil
}

fn select_provider(cfg: AppConfig) -> #(Provider, String, String) {
  slog.debug(
    "springdrift",
    "select_provider",
    "Selecting provider: " <> option.unwrap(cfg.provider, "none"),
    option.None,
  )
  case cfg.provider {
    option.Some("anthropic") -> {
      case anthropic_adapter.provider() {
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
    option.Some("local") -> {
      let assert Ok(p) = local_adapter.provider_from_env()
      io.println("Provider : Local")
      #(p, local_adapter.smollm3, local_adapter.smollm3)
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
  provider: Provider,
  task_model: String,
) -> List(agent_types.AgentSpec) {
  [
    planner.spec(provider, task_model),
    researcher.spec(provider, task_model),
    coder.spec(provider, task_model),
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
      tools: tools_list,
      restart: agent_types.Permanent,
      tool_executor:,
    )
  })
}

fn resolve_profile_tools(tool_groups: List(String)) -> List(llm_types.Tool) {
  list.flat_map(tool_groups, fn(group) {
    case group {
      "web" -> tools_web.all()
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
    case call.name {
      "fetch_url" if has_web -> tools_web.execute(call)
      _ -> tools_builtin.execute(call)
    }
  }
}
