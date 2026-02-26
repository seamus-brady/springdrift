import chat/service
import config.{type AppConfig}
import gleam/io
import gleam/list
import gleam/option
import llm/adapters/anthropic as anthropic_adapter
import llm/adapters/mock
import llm/adapters/openai as openai_adapter
import llm/provider.{type Provider}
import simplifile
import storage
import tools/builtin
import tui

/// Exit the process with the given status code.
@external(erlang, "erlang", "halt")
fn do_halt(code: Int) -> Nil

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
          case config.parse_config_json(contents) {
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
  io.println("Options:")
  io.println(
    "  --provider <name>         Provider: anthropic, openrouter, openai (default: auto-detect)",
  )
  io.println(
    "  --model <name>            Model name (default: provider default)",
  )
  io.println("  --system <prompt>         System prompt")
  io.println("  --max-tokens <n>          Max output tokens (default: 1024)")
  io.println(
    "  --max-turns <n>           Max react-loop turns per message (default: 5)",
  )
  io.println(
    "  --max-errors <n>          Max consecutive tool failures before abort (default: 3)",
  )
  io.println(
    "  --max-context <n>         Max messages kept in context window (default: unlimited)",
  )
  io.println(
    "  --task-model <name>       Model for simple queries (default: provider-specific)",
  )
  io.println(
    "  --reasoning-model <name>  Model for complex queries (default: provider-specific)",
  )
  io.println(
    "  --no-model-prompt         Auto-switch to reasoning model without prompting",
  )
  io.println("  --resume                  Resume previous session")
  io.println("  --help, -h                Show this help")
  io.println("")
  io.println("Config files (checked in priority order, local overrides user):")
  io.println("  .springdrift.json")
  io.println("  ~/.config/springdrift/config.json")
  io.println("")
  io.println("Example config file (.springdrift.json):")
  io.println("  {")
  io.println("    \"provider\": \"anthropic\",")
  io.println("    \"model\": \"claude-sonnet-4-20250514\",")
  io.println("    \"system_prompt\": \"You are a helpful assistant.\",")
  io.println("    \"max_tokens\": 2048,")
  io.println("    \"max_turns\": 5,")
  io.println("    \"max_consecutive_errors\": 3,")
  io.println("    \"max_context_messages\": 50,")
  io.println("    \"task_model\": \"claude-haiku-4-5-20251001\",")
  io.println("    \"reasoning_model\": \"claude-opus-4-6\",")
  io.println("    \"prompt_on_complex\": true")
  io.println("  }")
}

fn run(cfg: AppConfig) -> Nil {
  let system = option.unwrap(cfg.system_prompt, "You are a helpful assistant.")
  let max_tokens = option.unwrap(cfg.max_tokens, 1024)
  let max_turns = option.unwrap(cfg.max_turns, 5)
  let max_consecutive_errors = option.unwrap(cfg.max_consecutive_errors, 3)
  let max_context_messages = cfg.max_context_messages
  let prompt_on_complex = option.unwrap(cfg.prompt_on_complex, True)
  let verbose = option.unwrap(cfg.log_verbose, False)

  let #(p, model, default_task_model, default_reasoning_model) =
    select_provider(cfg)

  let task_model = option.unwrap(cfg.task_model, default_task_model)
  let reasoning_model =
    option.unwrap(cfg.reasoning_model, default_reasoning_model)

  let initial_messages = case list.contains(get_startup_args(), "--resume") {
    True -> storage.load()
    False -> []
  }

  let chat =
    service.start(
      p,
      model,
      system,
      max_tokens,
      max_turns,
      max_consecutive_errors,
      max_context_messages,
      builtin.all(),
      initial_messages,
      task_model,
      reasoning_model,
      prompt_on_complex,
      verbose,
    )
  tui.start(chat, p.name, model, task_model, reasoning_model, initial_messages)
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
