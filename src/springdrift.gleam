import app_log
import chat/service
import config.{type AppConfig}
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/string
import llm/adapters/anthropic as anthropic_adapter
import llm/adapters/mock
import llm/adapters/openai as openai_adapter
import llm/provider.{type Provider}
import sandbox
import simplifile
import skills
import storage
import tools/builtin
import tools/files
import tools/sandbox_mgmt
import tools/shell
import tools/web
import tui

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
  io.println("Provider / model:")
  io.println(
    "  --provider <name>         anthropic | openrouter | openai | mock",
  )
  io.println("                            (default: auto-detect from env vars)")
  io.println(
    "  --model <name>            Main model identifier (default: provider default)",
  )
  io.println(
    "  --system <prompt>         System prompt (default: \"You are a helpful assistant.\")",
  )
  io.println("")
  io.println("Loop control:")
  io.println(
    "  --max-tokens <n>          Max output tokens per LLM call (default: 1024)",
  )
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
  io.println("Model switching:")
  io.println(
    "  --task-model <name>       Model for Simple queries (default: provider-specific)",
  )
  io.println(
    "  --reasoning-model <name>  Model for Complex queries (default: provider-specific)",
  )
  io.println(
    "  --no-model-prompt         Auto-switch to reasoning model without prompting",
  )
  io.println("")
  io.println("Tools / sandbox:")
  io.println(
    "  --allow-write-anywhere    Allow write_file outside the current working directory",
  )
  io.println(
    "  --sandbox-port <n>        Expose port N from sandbox (repeatable; default: 10001 10002 10003 10004)",
  )
  io.println("")
  io.println("Session / config:")
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
  io.println("Config files (checked in order; local overrides user config):")
  io.println("  .springdrift.toml")
  io.println("  ~/.config/springdrift/config.toml")
  io.println("")
  io.println("Example .springdrift.toml (all fields optional):")
  io.println("  # LLM provider and model")
  io.println("  provider = \"anthropic\"")
  io.println("  model    = \"claude-sonnet-4-20250514\"")
  io.println("")
  io.println("  # System prompt")
  io.println("  system_prompt = \"You are a helpful assistant.\"")
  io.println("")
  io.println("  # Token and loop limits")
  io.println("  max_tokens            = 2048")
  io.println("  max_turns             = 5")
  io.println("  max_consecutive_errors = 3")
  io.println("  max_context_messages   = 50   # omit for unlimited")
  io.println("")
  io.println("  # Model switching")
  io.println("  task_model       = \"claude-haiku-4-5-20251001\"")
  io.println("  reasoning_model  = \"claude-opus-4-6\"")
  io.println("  prompt_on_complex = true")
  io.println("")
  io.println("  # Logging and filesystem")
  io.println("  log_verbose   = false")
  io.println("  write_anywhere = false")
  io.println("")
  io.println("  # Extra skill directories")
  io.println("  skills_dirs = [\"/path/to/skills\"]")
}

fn run(cfg: AppConfig) -> Nil {
  app_log.info("startup", [])

  let base_system =
    option.unwrap(cfg.system_prompt, "You are a helpful assistant.")
  let skill_dirs = option.unwrap(cfg.skills_dirs, default_skill_dirs())
  let discovered = skills.discover(skill_dirs)
  app_log.info("skills_discovered", [
    #("count", int.to_string(list.length(discovered))),
  ])
  let system = case discovered {
    [] -> base_system
    _ -> base_system <> "\n\n" <> skills.to_system_prompt_xml(discovered)
  }
  let max_tokens = option.unwrap(cfg.max_tokens, 1024)
  let max_turns = option.unwrap(cfg.max_turns, 5)
  let max_consecutive_errors = option.unwrap(cfg.max_consecutive_errors, 3)
  let max_context_messages = cfg.max_context_messages
  let prompt_on_complex = option.unwrap(cfg.prompt_on_complex, False)
  let verbose = option.unwrap(cfg.log_verbose, False)
  let write_anywhere = option.unwrap(cfg.write_anywhere, False)
  let sandbox_ports =
    option.unwrap(cfg.sandbox_ports, [10_001, 10_002, 10_003, 10_004])

  let #(p, model, default_task_model, default_reasoning_model) =
    select_provider(cfg)

  let task_model = option.unwrap(cfg.task_model, default_task_model)
  let reasoning_model =
    option.unwrap(cfg.reasoning_model, default_reasoning_model)

  let ports_str = string.join(list.map(sandbox_ports, int.to_string), ", ")
  app_log.info("config_loaded", [
    #("provider", p.name),
    #("model", model),
    #("ports", ports_str),
  ])

  let initial_messages = case list.contains(get_startup_args(), "--resume") {
    True -> {
      let msgs = storage.load()
      app_log.info("session_loaded", [
        #("messages", int.to_string(list.length(msgs))),
      ])
      msgs
    }
    False -> []
  }

  let sandbox_dir = find_sandbox_dir()
  let sandbox_subj = case sandbox_dir {
    option.None -> {
      io.println(
        "Sandbox  : unavailable (sandbox/Dockerfile not found) — run_shell disabled",
      )
      option.None
    }
    option.Some(dir) -> {
      io.println("Sandbox  : starting...")
      case sandbox.start(dir, sandbox_ports) {
        Ok(s) -> {
          io.println("Sandbox  : ready (ports: " <> ports_str <> ")")
          option.Some(s)
        }
        Error(msg) -> {
          io.println(
            "Sandbox  : unavailable (" <> msg <> ") — run_shell disabled",
          )
          option.None
        }
      }
    }
  }

  let shell_tools = case sandbox_subj {
    option.None -> []
    option.Some(_) -> shell.all()
  }
  let sandbox_mgmt_tools = case sandbox_subj {
    option.None -> []
    option.Some(_) -> sandbox_mgmt.all()
  }
  let tools =
    list.flatten([
      builtin.all(),
      files.all(),
      web.all(),
      shell_tools,
      sandbox_mgmt_tools,
    ])

  let chat =
    service.start(
      p,
      model,
      system,
      max_tokens,
      max_turns,
      max_consecutive_errors,
      max_context_messages,
      tools,
      initial_messages,
      task_model,
      reasoning_model,
      prompt_on_complex,
      verbose,
      sandbox_subj,
      write_anywhere,
    )
  tui.start(
    chat,
    p.name,
    model,
    task_model,
    reasoning_model,
    initial_messages,
    sandbox_subj,
  )
  let _ = option.map(sandbox_subj, sandbox.send_shutdown)
  Nil
}

/// Find the sandbox directory containing the Dockerfile.
/// Checks ./sandbox/Dockerfile first, then priv/sandbox/Dockerfile.
fn find_sandbox_dir() -> option.Option(String) {
  case simplifile.is_file("./sandbox/Dockerfile") {
    Ok(True) -> option.Some("./sandbox")
    _ ->
      case simplifile.is_file("priv/sandbox/Dockerfile") {
        Ok(True) -> option.Some("priv/sandbox")
        _ -> option.None
      }
  }
}

fn select_provider(cfg: AppConfig) -> #(Provider, String, String, String) {
  case cfg.provider {
    option.Some("anthropic") -> {
      case anthropic_adapter.provider() {
        Ok(p) -> {
          let m = option.unwrap(cfg.model, anthropic_adapter.claude_sonnet_4)
          io.println("Provider : Anthropic (" <> m <> ")")
          #(p, m, "claude-haiku-4-5-20251001", "claude-opus-4-6")
        }
        Error(_) -> {
          io.println("Error: ANTHROPIC_API_KEY not set. Falling back to mock.")
          #(mock_provider(), "mock-model", "mock-model", "mock-model")
        }
      }
    }
    option.Some("openrouter") -> {
      case openai_adapter.provider_from_openrouter_env() {
        Ok(p) -> {
          let m = option.unwrap(cfg.model, openai_adapter.gpt_4o)
          io.println("Provider : OpenRouter (" <> m <> ")")
          #(p, m, openai_adapter.gpt_4o_mini, openai_adapter.gpt_4o)
        }
        Error(_) -> {
          io.println("Error: OPENROUTER_API_KEY not set. Falling back to mock.")
          #(mock_provider(), "mock-model", "mock-model", "mock-model")
        }
      }
    }
    option.Some("openai") -> {
      case openai_adapter.provider_from_env() {
        Ok(p) -> {
          let m = option.unwrap(cfg.model, openai_adapter.gpt_4o)
          io.println("Provider : OpenAI (" <> m <> ")")
          #(p, m, openai_adapter.gpt_4o_mini, openai_adapter.gpt_4o)
        }
        Error(_) -> {
          io.println("Error: OPENAI_API_KEY not set. Falling back to mock.")
          #(mock_provider(), "mock-model", "mock-model", "mock-model")
        }
      }
    }
    option.Some("mock") -> #(
      mock_provider(),
      "mock-model",
      "mock-model",
      "mock-model",
    )
    option.Some(unknown) -> {
      io.println("Unknown provider \"" <> unknown <> "\". Using auto-detect.")
      auto_detect(cfg.model)
    }
    option.None -> auto_detect(cfg.model)
  }
}

fn auto_detect(
  model_override: option.Option(String),
) -> #(Provider, String, String, String) {
  case anthropic_adapter.provider() {
    Ok(ap) -> {
      let m = option.unwrap(model_override, anthropic_adapter.claude_sonnet_4)
      io.println("Provider : Anthropic (" <> m <> ")")
      #(ap, m, "claude-haiku-4-5-20251001", "claude-opus-4-6")
    }
    Error(_) ->
      case openai_adapter.provider_from_openrouter_env() {
        Ok(op) -> {
          let m = option.unwrap(model_override, openai_adapter.gpt_4o)
          io.println("Provider : OpenRouter (" <> m <> ")")
          #(op, m, openai_adapter.gpt_4o_mini, openai_adapter.gpt_4o)
        }
        Error(_) ->
          case openai_adapter.provider_from_env() {
            Ok(op) -> {
              let m = option.unwrap(model_override, openai_adapter.gpt_4o)
              io.println("Provider : OpenAI (" <> m <> ")")
              #(op, m, openai_adapter.gpt_4o_mini, openai_adapter.gpt_4o)
            }
            Error(_) -> {
              io.println("Provider : mock")
              io.println(
                "           (set ANTHROPIC_API_KEY or OPENROUTER_API_KEY to use a real LLM)",
              )
              #(mock_provider(), "mock-model", "mock-model", "mock-model")
            }
          }
      }
  }
}

fn mock_provider() -> Provider {
  mock.provider_with_text(
    "I'm a mock assistant. Set ANTHROPIC_API_KEY or OPENROUTER_API_KEY to use a real LLM.",
  )
}
