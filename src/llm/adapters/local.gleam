//// Local provider adapter for OpenAI-compatible servers (Ollama, LM Studio, etc.).
////
//// Uses the OpenAI-compatible chat completions endpoint with full tool call
//// support. No API key required — the server runs locally.
//// Default base URL is Ollama's localhost:11434. Override with LOCAL_LLM_HOST
//// env var (e.g. http://localhost:1234 for LM Studio).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider, Provider}
import llm/types

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const default_base_url = "http://localhost:11434/v1"

pub const smollm3 = "smollm3:3b"

pub const llama3_1 = "llama3.1"

pub const qwen2_5_coder = "qwen2.5-coder:7b"

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

/// POST JSON body to url with headers. Returns #(status_code, body).
@external(erlang, "springdrift_ffi", "http_post")
fn http_post(
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), String)

// ---------------------------------------------------------------------------
// Public provider constructors
// ---------------------------------------------------------------------------

/// Create a local provider using the default base URL.
pub fn provider() -> Provider {
  provider_with_base_url(default_base_url)
}

/// Create a local provider with a custom base URL.
pub fn provider_with_base_url(base_url: String) -> Provider {
  Provider(name: "local", chat: fn(req) { do_chat(base_url, req) })
}

/// Create a local provider, reading optional LOCAL_LLM_HOST from env.
/// Always succeeds — local server, no API key needed.
pub fn provider_from_env() -> Result(Provider, types.LlmError) {
  let base_url = case get_env("LOCAL_LLM_HOST") {
    Ok(host) -> host <> "/v1"
    Error(Nil) -> default_base_url
  }
  Ok(provider_with_base_url(base_url))
}

// ---------------------------------------------------------------------------
// Chat implementation
// ---------------------------------------------------------------------------

fn do_chat(
  base_url: String,
  req: types.LlmRequest,
) -> Result(types.LlmResponse, types.LlmError) {
  let url = base_url <> "/chat/completions"
  let headers = []
  let body = encode_request(req)

  case http_post(url, headers, body) {
    Error(reason) -> Error(types.NetworkError(reason: reason))
    Ok(#(status_code, response_body)) ->
      case status_code {
        200 -> decode_response(response_body)
        429 ->
          Error(types.RateLimitError(
            message: "Local LLM rate limit exceeded (429)",
          ))
        code if code >= 500 ->
          Error(types.ApiError(status_code: code, message: response_body))
        code -> Error(types.ApiError(status_code: code, message: response_body))
      }
  }
}

// ---------------------------------------------------------------------------
// Request encoding
// ---------------------------------------------------------------------------

fn encode_request(req: types.LlmRequest) -> String {
  let messages = encode_messages(req)
  let base = [
    #("model", json.string(req.model)),
    #("messages", json.array(messages, fn(m) { m })),
    #("max_tokens", json.int(req.max_tokens)),
  ]

  let with_temp = case req.temperature {
    Some(t) -> list.append(base, [#("temperature", json.float(t))])
    None -> base
  }

  let with_top_p = case req.top_p {
    Some(p) -> list.append(with_temp, [#("top_p", json.float(p))])
    None -> with_temp
  }

  let with_stop = case req.stop_sequences {
    Some(seqs) ->
      list.append(with_top_p, [#("stop", json.array(seqs, json.string))])
    None -> with_top_p
  }

  let with_tools = case req.tools {
    Some(tools) ->
      case tools {
        [] -> with_stop
        _ ->
          list.append(with_stop, [
            #("tools", json.array(tools, encode_tool)),
          ])
      }
    None -> with_stop
  }

  let with_tool_choice = case req.tool_choice {
    Some(choice) ->
      list.append(with_tools, [
        #("tool_choice", encode_tool_choice(choice)),
      ])
    None -> with_tools
  }

  json.object(with_tool_choice)
  |> json.to_string
}

fn encode_messages(req: types.LlmRequest) -> List(json.Json) {
  let system_msgs = case req.system {
    Some(s) -> [
      json.object([
        #("role", json.string("system")),
        #("content", json.string(s)),
      ]),
    ]
    None -> []
  }
  let conv_msgs = list.flat_map(req.messages, encode_message)
  list.append(system_msgs, conv_msgs)
}

fn encode_message(msg: types.Message) -> List(json.Json) {
  let role_str = case msg.role {
    types.User -> "user"
    types.Assistant -> "assistant"
  }

  // Separate tool results from other content — they need their own messages
  let #(tool_results, other_blocks) =
    list.partition(msg.content, fn(block) {
      case block {
        types.ToolResultContent(..) -> True
        _ -> False
      }
    })

  // Tool result blocks become individual "tool" role messages
  let tool_msgs =
    list.map(tool_results, fn(block) {
      case block {
        types.ToolResultContent(tool_use_id:, content:, ..) ->
          json.object([
            #("role", json.string("tool")),
            #("tool_call_id", json.string(tool_use_id)),
            #("content", json.string(content)),
          ])
        _ -> json.object([])
      }
    })

  // Other blocks become the main message
  let main_msg = case other_blocks {
    [] -> []
    _ -> {
      // Check if there are tool_use blocks
      let tool_calls =
        list.filter_map(other_blocks, fn(block) {
          case block {
            types.ToolUseContent(id:, name:, input_json:) ->
              Ok(
                json.object([
                  #("id", json.string(id)),
                  #("type", json.string("function")),
                  #(
                    "function",
                    json.object([
                      #("name", json.string(name)),
                      #("arguments", json.string(input_json)),
                    ]),
                  ),
                ]),
              )
            _ -> Error(Nil)
          }
        })

      let text_parts =
        list.filter_map(other_blocks, fn(block) {
          case block {
            types.TextContent(text:) -> Ok(text)
            _ -> Error(Nil)
          }
        })
      let text = string.join(text_parts, "")

      let base = [#("role", json.string(role_str))]
      let with_content = case text {
        "" -> base
        _ -> list.append(base, [#("content", json.string(text))])
      }
      let with_tool_calls = case tool_calls {
        [] -> with_content
        _ ->
          list.append(with_content, [
            #("tool_calls", json.array(tool_calls, fn(tc) { tc })),
          ])
      }
      [json.object(with_tool_calls)]
    }
  }

  // Main message first, then tool results
  list.append(main_msg, tool_msgs)
}

fn encode_tool(tool: types.Tool) -> json.Json {
  let properties =
    list.map(tool.parameters, fn(param) {
      let #(name, schema) = param
      #(name, encode_param_schema(schema))
    })

  let required = json.array(tool.required_params, json.string)

  let input_schema = case tool.parameters {
    [] ->
      json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
      ])
    _ ->
      json.object([
        #("type", json.string("object")),
        #("properties", json.object(properties)),
        #("required", required),
      ])
  }

  json.object([
    #("type", json.string("function")),
    #(
      "function",
      json.object([
        #("name", json.string(tool.name)),
        #("description", case tool.description {
          Some(d) -> json.string(d)
          None -> json.string("")
        }),
        #("parameters", input_schema),
      ]),
    ),
  ])
}

fn encode_param_schema(schema: types.ParameterSchema) -> json.Json {
  let type_str = case schema.param_type {
    types.StringProperty -> "string"
    types.NumberProperty -> "number"
    types.IntegerProperty -> "integer"
    types.BooleanProperty -> "boolean"
    types.ArrayProperty -> "array"
    types.ObjectProperty -> "object"
  }
  let base = [#("type", json.string(type_str))]
  let with_desc = case schema.description {
    Some(d) -> list.append(base, [#("description", json.string(d))])
    None -> base
  }
  let with_enum = case schema.enum_values {
    Some(vals) ->
      list.append(with_desc, [#("enum", json.array(vals, json.string))])
    None -> with_desc
  }
  json.object(with_enum)
}

fn encode_tool_choice(choice: types.ToolChoice) -> json.Json {
  case choice {
    types.AutoToolChoice -> json.string("auto")
    types.AnyToolChoice -> json.string("any")
    types.NoToolChoice -> json.string("none")
    types.SpecificToolChoice(name:) ->
      json.object([
        #("type", json.string("function")),
        #("function", json.object([#("name", json.string(name))])),
      ])
  }
}

// ---------------------------------------------------------------------------
// Response decoding
// ---------------------------------------------------------------------------

fn decode_response(body: String) -> Result(types.LlmResponse, types.LlmError) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use model <- decode.field("model", decode.string)
    use choices <- decode.field("choices", decode.list(choice_decoder()))
    use usage <- decode.field("usage", usage_decoder())
    decode.success(#(id, model, choices, usage))
  }

  case json.parse(body, decoder) {
    Error(_) ->
      Error(types.DecodeError(
        reason: "Failed to decode local LLM response: " <> body,
      ))
    Ok(#(id, model, choices, usage)) -> {
      let #(content, stop_reason) = case list.first(choices) {
        Error(Nil) -> #([], None)
        Ok(choice) -> choice
      }
      Ok(types.LlmResponse(id:, content:, model:, stop_reason:, usage:))
    }
  }
}

fn choice_decoder() -> decode.Decoder(
  #(List(types.ContentBlock), Option(types.StopReason)),
) {
  use message <- decode.field("message", message_decoder())
  use finish_reason <- decode.field("finish_reason", decode.string)
  let stop_reason = case finish_reason {
    "stop" -> Some(types.EndTurn)
    "length" -> Some(types.MaxTokens)
    "tool_calls" -> Some(types.ToolUseRequested)
    _ -> Some(types.EndTurn)
  }
  decode.success(#(message, stop_reason))
}

fn message_decoder() -> decode.Decoder(List(types.ContentBlock)) {
  use content <- decode.optional_field(
    "content",
    None,
    decode.optional(decode.string),
  )
  use tool_calls_opt <- decode.optional_field(
    "tool_calls",
    None,
    decode.optional(decode.list(tool_call_decoder())),
  )

  let text_blocks = case content {
    Some(text) ->
      case text {
        "" -> []
        _ -> [types.TextContent(text:)]
      }
    None -> []
  }

  let tool_calls = option.unwrap(tool_calls_opt, [])
  let tool_blocks =
    list.map(tool_calls, fn(tc) {
      let #(id, name, arguments) = tc
      types.ToolUseContent(id:, name:, input_json: arguments)
    })

  decode.success(list.append(text_blocks, tool_blocks))
}

fn tool_call_decoder() -> decode.Decoder(#(String, String, String)) {
  use id <- decode.field("id", decode.string)
  use function <- decode.field("function", function_decoder())
  let #(name, arguments) = function
  decode.success(#(id, name, arguments))
}

fn function_decoder() -> decode.Decoder(#(String, String)) {
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("arguments", decode.string)
  decode.success(#(name, arguments))
}

fn usage_decoder() -> decode.Decoder(types.Usage) {
  use prompt_tokens <- decode.field("prompt_tokens", decode.int)
  use completion_tokens <- decode.field("completion_tokens", decode.int)
  decode.success(types.Usage(
    input_tokens: prompt_tokens,
    output_tokens: completion_tokens,
    thinking_tokens: 0,
    cache_creation_tokens: 0,
    cache_read_tokens: 0,
  ))
}
