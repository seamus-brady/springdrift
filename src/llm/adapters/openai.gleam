//// OpenAI-compatible provider adapter built on the `gllm` package.
////
//// gllm 1.0.0 is designed primarily for OpenRouter, which returns additional
//// fields (`provider`, `native_finish_reason`) not present in vanilla OpenAI
//// responses. For best results use `openrouter_base_url` with an OpenRouter
//// key. `openai_base_url` works if the API surface matches OpenRouter's schema.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gllm
import gllm/types/api_error as gerr
import gllm/types/chat_completion as gcompletion
import gllm/types/message as gmsg
import llm/provider.{type Provider, Provider}
import llm/types

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Standard OpenAI REST API base URL.
/// Note: gllm 1.0.0 expects OpenRouter-style response fields; direct OpenAI
/// calls may return a decode error. Use `openrouter_base_url` for reliability.
pub const openai_base_url = "https://api.openai.com/v1"

/// OpenRouter base URL — fully compatible with gllm 1.0.0.
pub const openrouter_base_url = "https://openrouter.ai/api/v1"

pub const gpt_4o = "gpt-4o"

pub const gpt_4o_mini = "gpt-4o-mini"

pub const gpt_4_1 = "gpt-4.1"

pub const o3_mini = "o3-mini"

// ---------------------------------------------------------------------------
// Read an environment variable (Erlang FFI)
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// Public provider constructors
// ---------------------------------------------------------------------------

/// Create a provider with an explicit API key.
/// Uses `openai_base_url` by default. Swap for `openrouter_base_url` if you
/// have an OpenRouter key — gllm 1.0.0 is optimised for that response format.
pub fn provider(api_key: String) -> Provider {
  build_provider(gllm.Client(api_key: api_key, base_url: openai_base_url))
}

/// Create a provider with an explicit key and base URL.
/// Pass `openrouter_base_url` to use OpenRouter, or any other compatible URL.
pub fn provider_with_base_url(api_key: String, base_url: String) -> Provider {
  build_provider(gllm.Client(api_key: api_key, base_url: base_url))
}

/// Create a provider by reading OPENAI_API_KEY from the environment.
pub fn provider_from_env() -> Result(Provider, types.LlmError) {
  case get_env("OPENAI_API_KEY") {
    Error(Nil) -> Error(types.ConfigError(reason: "OPENAI_API_KEY is not set"))
    Ok(key) -> Ok(provider(key))
  }
}

/// Create a provider by reading OPENROUTER_API_KEY from the environment,
/// pointed at the OpenRouter base URL (recommended with gllm 1.0.0).
pub fn provider_from_openrouter_env() -> Result(Provider, types.LlmError) {
  case get_env("OPENROUTER_API_KEY") {
    Error(Nil) ->
      Error(types.ConfigError(reason: "OPENROUTER_API_KEY is not set"))
    Ok(key) -> Ok(provider_with_base_url(key, openrouter_base_url))
  }
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn build_provider(client: gllm.Client) -> Provider {
  let is_openrouter = string.contains(client.base_url, "openrouter.ai")
  Provider(name: "openai", chat: fn(req) {
    let model = case is_openrouter {
      True -> normalize_openrouter_model(req.model)
      False -> req.model
    }
    let messages = translate_messages(req)
    let temperature = option.unwrap(req.temperature, 1.0)
    gllm.completion(client, model, messages, temperature)
    |> result.map(translate_response)
    |> result.map_error(translate_error)
  })
}

/// Normalize model names for OpenRouter. Anthropic model IDs like
/// "claude-sonnet-4-5-20250514" need the "anthropic/" prefix on OpenRouter.
fn normalize_openrouter_model(model: String) -> String {
  case string.contains(model, "/") {
    // Already has a provider prefix (e.g. "anthropic/claude-...")
    True -> model
    False ->
      case string.starts_with(model, "claude-") {
        True -> "anthropic/" <> model
        False -> model
      }
  }
}

// ---------------------------------------------------------------------------
// Request translation
// ---------------------------------------------------------------------------

fn translate_messages(req: types.LlmRequest) -> List(gmsg.Message) {
  let system_msgs = case req.system {
    Some(s) -> [gllm.new_message("system", s)]
    None -> []
  }
  let conv_msgs = list.filter_map(req.messages, translate_message)
  list.append(system_msgs, conv_msgs)
}

/// Convert a single Message. Returns Error(Nil) and is silently dropped if
/// the message contains no translatable (text) content blocks.
fn translate_message(msg: types.Message) -> Result(gmsg.Message, Nil) {
  let role = case msg.role {
    types.User -> "user"
    types.Assistant -> "assistant"
  }
  let text =
    msg.content
    |> list.filter_map(fn(block) {
      case block {
        types.TextContent(text: t) -> Ok(t)
        _ -> Error(Nil)
      }
    })
    |> string.join("")
  case text {
    "" -> Error(Nil)
    _ -> Ok(gllm.new_message(role, text))
  }
}

// ---------------------------------------------------------------------------
// Response translation
// ---------------------------------------------------------------------------

fn translate_response(
  completion: gcompletion.ChatCompletion,
) -> types.LlmResponse {
  let content = case list.first(completion.choices) {
    Error(Nil) -> []
    Ok(choice) -> [types.TextContent(text: choice.message.content)]
  }
  let stop_reason = case list.first(completion.choices) {
    Error(Nil) -> None
    Ok(choice) -> Some(translate_finish_reason(choice.finish_reason))
  }
  types.LlmResponse(
    id: completion.id,
    content: content,
    model: completion.model,
    stop_reason: stop_reason,
    usage: types.Usage(
      input_tokens: completion.usage.prompt_tokens,
      output_tokens: completion.usage.completion_tokens,
      thinking_tokens: 0,
    ),
  )
}

fn translate_finish_reason(reason: String) -> types.StopReason {
  case reason {
    "stop" -> types.EndTurn
    "length" -> types.MaxTokens
    "tool_calls" -> types.ToolUseRequested
    _ -> types.EndTurn
  }
}

// ---------------------------------------------------------------------------
// Error translation
// ---------------------------------------------------------------------------

fn translate_error(error: gerr.ApiError) -> types.LlmError {
  case error {
    gerr.HttpError(_) ->
      types.NetworkError(reason: "HTTP error contacting OpenAI-compatible API")
    gerr.JsonDecodeError(_) ->
      types.DecodeError(
        reason: "Failed to decode API response — if using direct OpenAI, try openrouter_base_url instead (gllm 1.0.0 limitation)",
      )
  }
}
