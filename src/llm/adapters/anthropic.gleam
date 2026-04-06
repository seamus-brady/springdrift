// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider, Provider}
import llm/types
import slog

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "springdrift_ffi", "http_post")
fn http_post(
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), String)

/// Coerce a raw JSON string (already valid JSON) into gleam_json's Json type.
/// At the Erlang level, Json is just iodata — a binary passes through as-is.
@external(erlang, "springdrift_ffi", "identity")
fn json_raw(raw: String) -> json.Json

/// Re-encode an Erlang term (from json:decode) back to a JSON binary string.
@external(erlang, "springdrift_ffi", "json_encode_term")
fn json_encode_term(term: dynamic) -> String

/// Predefined model name constants
pub const claude_opus_4 = "claude-opus-4-6"

pub const claude_sonnet_4 = "claude-sonnet-4-6"

pub const claude_haiku_4_5 = "claude-haiku-4-5-20251001"

const api_url = "https://api.anthropic.com/v1/messages"

/// Create an Anthropic provider using the ANTHROPIC_API_KEY environment variable.
pub fn provider() -> Result(Provider, types.LlmError) {
  case get_env("ANTHROPIC_API_KEY") {
    Error(_) -> Error(types.ConfigError(reason: "ANTHROPIC_API_KEY not set"))
    Ok(api_key) ->
      Ok(
        Provider(name: "anthropic", chat: fn(req) {
          chat_with_cache(api_key, req)
        }),
      )
  }
}

/// Create an Anthropic provider with a configurable request timeout.
/// Timeout is handled by the FFI http_post (300s default) so this
/// delegates to provider() for now.
pub fn provider_with_timeout(
  _timeout_ms: Int,
) -> Result(Provider, types.LlmError) {
  provider()
}

/// Create an Anthropic provider with an explicit API key.
pub fn provider_with_key(api_key: String) -> Result(Provider, types.LlmError) {
  Ok(
    Provider(name: "anthropic", chat: fn(req) { chat_with_cache(api_key, req) }),
  )
}

// ---------------------------------------------------------------------------
// Core: chat_with_cache — raw HTTP with prompt caching + extended thinking
// ---------------------------------------------------------------------------

fn chat_with_cache(
  api_key: String,
  req: types.LlmRequest,
) -> Result(types.LlmResponse, types.LlmError) {
  check_message_roles(req.messages)

  let headers = [
    #("x-api-key", api_key),
    #("anthropic-version", "2023-06-01"),
    #("content-type", "application/json"),
  ]

  let body = build_request_json(req)

  case http_post(api_url, headers, body) {
    Error(reason) -> Error(types.NetworkError(reason: reason))
    Ok(#(status, resp_body)) ->
      case status >= 200 && status < 300 {
        True -> parse_response(resp_body)
        False -> {
          let msg = string.slice(resp_body, 0, 500)
          case status {
            429 -> Error(types.RateLimitError(message: msg))
            _ -> Error(types.ApiError(status_code: status, message: msg))
          }
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Request JSON building
// ---------------------------------------------------------------------------

fn build_request_json(req: types.LlmRequest) -> String {
  let messages_json = json.array(req.messages, encode_message)

  // System as array of content blocks with cache_control
  let system_json = case req.system {
    Some(s) ->
      json.preprocessed_array([
        json.object([
          #("type", json.string("text")),
          #("text", json.string(s)),
          #("cache_control", json.object([#("type", json.string("ephemeral"))])),
        ]),
      ])
    None -> json.preprocessed_array([])
  }

  let base_fields = [
    #("model", json.string(req.model)),
    #("max_tokens", json.int(req.max_tokens)),
    #("system", system_json),
    #("messages", messages_json),
  ]

  // Add tools with cache_control on the last tool
  let with_tools = case req.tools {
    Some([]) | None -> base_fields
    Some(tools) -> {
      let tool_jsons = encode_tools_with_cache(tools)
      list.append(base_fields, [
        #("tools", json.preprocessed_array(tool_jsons)),
      ])
    }
  }

  // Add thinking if requested (must come before temperature for models that
  // require thinking — temperature must be 1.0 when thinking is enabled)
  let with_thinking = case req.thinking_budget_tokens {
    Some(budget) ->
      list.append(with_tools, [
        #(
          "thinking",
          json.object([
            #("type", json.string("enabled")),
            #("budget_tokens", json.int(budget)),
          ]),
        ),
      ])
    None -> with_tools
  }

  // Add temperature
  let with_temp = case req.temperature {
    Some(t) -> list.append(with_thinking, [#("temperature", json.float(t))])
    None -> with_thinking
  }

  // Add top_p
  let with_top_p = case req.top_p {
    Some(p) -> list.append(with_temp, [#("top_p", json.float(p))])
    None -> with_temp
  }

  // Add stop sequences
  let with_stop = case req.stop_sequences {
    Some(seqs) ->
      list.append(with_top_p, [
        #("stop_sequences", json.array(seqs, json.string)),
      ])
    None -> with_top_p
  }

  // Add tool_choice
  let with_tool_choice = case req.tool_choice {
    Some(choice) ->
      list.append(with_stop, [#("tool_choice", encode_tool_choice(choice))])
    None -> with_stop
  }

  json.to_string(json.object(with_tool_choice))
}

fn encode_message(msg: types.Message) -> json.Json {
  let role = case msg.role {
    types.User -> "user"
    types.Assistant -> "assistant"
  }
  json.object([
    #("role", json.string(role)),
    #(
      "content",
      json.preprocessed_array(
        list.filter_map(msg.content, fn(b) {
          case encode_content_block(b) {
            Some(j) -> Ok(j)
            None -> Error(Nil)
          }
        }),
      ),
    ),
  ])
}

fn encode_content_block(block: types.ContentBlock) -> Option(json.Json) {
  case block {
    types.TextContent(text:) ->
      Some(
        json.object([
          #("type", json.string("text")),
          #("text", json.string(text)),
        ]),
      )
    types.ToolUseContent(id:, name:, input_json:) ->
      Some(
        json.object([
          #("type", json.string("tool_use")),
          #("id", json.string(id)),
          #("name", json.string(name)),
          #("input", json_raw(input_json)),
        ]),
      )
    types.ToolResultContent(tool_use_id:, content:, is_error:) ->
      Some(
        json.object([
          #("type", json.string("tool_result")),
          #("tool_use_id", json.string(tool_use_id)),
          #("content", json.string(content)),
          #("is_error", json.bool(is_error)),
        ]),
      )
    types.ImageContent(media_type:, data:) ->
      Some(
        json.object([
          #("type", json.string("image")),
          #(
            "source",
            json.object([
              #("type", json.string("base64")),
              #("media_type", json.string(media_type)),
              #("data", json.string(data)),
            ]),
          ),
        ]),
      )
    types.ThinkingContent(_) ->
      // Skip thinking blocks in outbound messages
      None
  }
}

// ---------------------------------------------------------------------------
// Tool encoding with cache_control on the last tool
// ---------------------------------------------------------------------------

fn encode_tools_with_cache(tools: List(types.Tool)) -> List(json.Json) {
  let len = list.length(tools)
  list.index_map(tools, fn(tool, idx) {
    let base_fields = [
      #("name", json.string(tool.name)),
      #("description", json.nullable(tool.description, json.string)),
      #("input_schema", encode_tool_schema(tool)),
    ]
    // Add cache_control to the LAST tool only
    case idx == len - 1 {
      True ->
        json.object(
          list.append(base_fields, [
            #(
              "cache_control",
              json.object([#("type", json.string("ephemeral"))]),
            ),
          ]),
        )
      False -> json.object(base_fields)
    }
  })
}

fn encode_tool_schema(tool: types.Tool) -> json.Json {
  let properties =
    list.map(tool.parameters, fn(pair) {
      let #(name, schema) = pair
      let type_str = case schema.param_type {
        types.StringProperty -> "string"
        types.NumberProperty -> "number"
        types.IntegerProperty -> "integer"
        types.BooleanProperty -> "boolean"
        types.ArrayProperty -> "array"
        types.ObjectProperty -> "object"
      }
      let fields = [
        #("type", json.string(type_str)),
        #("description", json.nullable(schema.description, json.string)),
      ]
      let with_enum = case schema.enum_values {
        Some(vals) ->
          list.append(fields, [#("enum", json.array(vals, json.string))])
        None -> fields
      }
      #(name, json.object(with_enum))
    })

  case tool.parameters {
    [] ->
      json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
      ])
    _ ->
      json.object([
        #("type", json.string("object")),
        #("properties", json.object(properties)),
        #("required", json.array(tool.required_params, json.string)),
      ])
  }
}

fn encode_tool_choice(choice: types.ToolChoice) -> json.Json {
  case choice {
    types.AutoToolChoice -> json.object([#("type", json.string("auto"))])
    types.AnyToolChoice -> json.object([#("type", json.string("any"))])
    types.NoToolChoice -> json.object([#("type", json.string("none"))])
    types.SpecificToolChoice(name:) ->
      json.object([
        #("type", json.string("tool")),
        #("name", json.string(name)),
      ])
  }
}

// ---------------------------------------------------------------------------
// Response parsing
// ---------------------------------------------------------------------------

fn parse_response(body: String) -> Result(types.LlmResponse, types.LlmError) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use model <- decode.field("model", decode.string)
    use content <- decode.field("content", decode.list(content_block_decoder()))
    use stop_reason <- decode.optional_field("stop_reason", "", decode.string)
    use usage <- decode.field("usage", usage_decoder())
    decode.success(types.LlmResponse(
      id:,
      content:,
      model:,
      stop_reason: case stop_reason {
        "end_turn" -> Some(types.EndTurn)
        "max_tokens" -> Some(types.MaxTokens)
        "stop_sequence" -> Some(types.StopSequenceReached)
        "tool_use" -> Some(types.ToolUseRequested)
        _ -> None
      },
      usage:,
    ))
  }
  case json.parse(body, decoder) {
    Ok(resp) -> Ok(resp)
    Error(_) ->
      Error(types.DecodeError(
        reason: "Failed to parse response: " <> string.slice(body, 0, 200),
      ))
  }
}

fn content_block_decoder() -> decode.Decoder(types.ContentBlock) {
  use block_type <- decode.field("type", decode.string)
  case block_type {
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(types.TextContent(text:))
    }
    "tool_use" -> {
      use id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      // input comes as a JSON object — capture as dynamic, re-encode to string
      use input <- decode.field("input", decode.dynamic)
      let input_str = json_encode_term(input)
      decode.success(types.ToolUseContent(id:, name:, input_json: input_str))
    }
    "thinking" -> {
      use text <- decode.field("thinking", decode.string)
      decode.success(types.ThinkingContent(text:))
    }
    _ -> decode.success(types.TextContent(text: ""))
  }
}

fn usage_decoder() -> decode.Decoder(types.Usage) {
  use input_tokens <- decode.field("input_tokens", decode.int)
  use output_tokens <- decode.field("output_tokens", decode.int)
  use cache_creation <- decode.optional_field(
    "cache_creation_input_tokens",
    0,
    decode.int,
  )
  use cache_read <- decode.optional_field(
    "cache_read_input_tokens",
    0,
    decode.int,
  )
  decode.success(types.Usage(
    input_tokens:,
    output_tokens:,
    thinking_tokens: 0,
    cache_creation_tokens: cache_creation,
    cache_read_tokens: cache_read,
  ))
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// Diagnostic: check message roles before sending to Anthropic API.
/// Logs a warning if messages don't alternate or start with Assistant.
fn check_message_roles(messages: List(types.Message)) -> Nil {
  let roles =
    list.map(messages, fn(m) {
      case m.role {
        types.User -> "U"
        types.Assistant -> "A"
      }
    })
  let role_str = string.join(roles, ",")

  // Check first message is User
  case messages {
    [types.Message(role: types.Assistant, ..), ..] ->
      slog.warn(
        "anthropic",
        "check_message_roles",
        "First message is Assistant (should be User). Roles: "
          <> role_str
          <> " (count="
          <> int.to_string(list.length(messages))
          <> ")",
        None,
      )
    _ -> Nil
  }

  // Check for consecutive same-role messages
  case find_consecutive_same_role(messages, 0) {
    Ok(idx) ->
      slog.warn(
        "anthropic",
        "check_message_roles",
        "Consecutive same-role messages at index "
          <> int.to_string(idx)
          <> ". Roles: "
          <> role_str
          <> " (count="
          <> int.to_string(list.length(messages))
          <> ")",
        None,
      )
    Error(_) -> Nil
  }
}

fn find_consecutive_same_role(
  messages: List(types.Message),
  idx: Int,
) -> Result(Int, Nil) {
  case messages {
    [a, b, ..rest] ->
      case a.role == b.role {
        True -> Ok(idx)
        False -> find_consecutive_same_role([b, ..rest], idx + 1)
      }
    _ -> Error(Nil)
  }
}
