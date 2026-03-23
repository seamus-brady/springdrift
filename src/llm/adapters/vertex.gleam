//// Google Vertex AI adapter — Anthropic Claude models on Vertex AI.
////
//// Uses the Vertex AI rawPredict endpoint with Anthropic message format.
//// Auth via VERTEX_AI_TOKEN env var (pre-obtained OAuth2 bearer token).
//// Project ID and region configured in config.toml under [vertex].
////
//// Key differences from the direct Anthropic API:
//// - Model is in the URL path, not the request body
//// - anthropic_version goes in the request body, not as a header
//// - Auth uses Bearer token, not x-api-key

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/provider.{type Provider, Provider}
import llm/types
import slog

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Anthropic API version for Vertex AI transport.
const anthropic_version = "vertex-2023-10-16"

/// Claude Opus 4.6
pub const claude_opus_4_6 = "claude-opus-4-6"

/// Claude Haiku 4.5
pub const claude_haiku_4_5 = "claude-haiku-4-5-20251001"

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "springdrift_ffi", "http_post")
fn http_post(
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), String)

/// Encode an Erlang term (dynamic) to a JSON string.
@external(erlang, "springdrift_ffi", "json_encode_term")
fn json_encode_term(term: Dynamic) -> String

/// Create a raw Json value from a pre-encoded JSON string.
/// gleam_json's Json type is an opaque wrapper around iodata —
/// a binary string IS valid iodata, so this is a safe cast.
@external(erlang, "springdrift_ffi", "identity")
fn raw_json(value: String) -> json.Json

// ---------------------------------------------------------------------------
// Public provider constructors
// ---------------------------------------------------------------------------

/// Create a Vertex AI provider with explicit settings.
pub fn provider(
  token: String,
  project_id: String,
  location: String,
  endpoint: String,
) -> Provider {
  Provider(name: "vertex", chat: fn(req) {
    do_chat(token, project_id, location, endpoint, req)
  })
}

/// Create a Vertex AI provider from environment and config.
/// Reads VERTEX_AI_TOKEN from env. Project, location, and endpoint come from config.
pub fn provider_from_config(
  project_id: String,
  location: String,
  endpoint: String,
) -> Result(Provider, types.LlmError) {
  case get_env("VERTEX_AI_TOKEN") {
    Error(Nil) -> Error(types.ConfigError(reason: "VERTEX_AI_TOKEN is not set"))
    Ok(token) -> Ok(provider(token, project_id, location, endpoint))
  }
}

// ---------------------------------------------------------------------------
// URL construction
// ---------------------------------------------------------------------------

/// Build the Vertex AI rawPredict endpoint URL.
/// endpoint is the hostname (e.g. "europe-west1-aiplatform.googleapis.com")
/// location is the GCP location (e.g. "europe-west1")
fn endpoint_url(
  endpoint: String,
  project_id: String,
  location: String,
  model: String,
) -> String {
  "https://"
  <> endpoint
  <> "/v1/projects/"
  <> project_id
  <> "/locations/"
  <> location
  <> "/publishers/anthropic/models/"
  <> model
  <> ":rawPredict"
}

// ---------------------------------------------------------------------------
// Chat implementation
// ---------------------------------------------------------------------------

fn do_chat(
  token: String,
  project_id: String,
  location: String,
  endpoint: String,
  req: types.LlmRequest,
) -> Result(types.LlmResponse, types.LlmError) {
  let url = endpoint_url(endpoint, project_id, location, req.model)
  let headers = [#("Authorization", "Bearer " <> token)]
  let body = encode_request(req)

  slog.debug("vertex", "do_chat", "POST " <> url, None)

  case http_post(url, headers, body) {
    Error(reason) -> Error(types.NetworkError(reason: reason))
    Ok(#(status_code, response_body)) ->
      case status_code {
        200 -> decode_response(response_body)
        429 ->
          Error(types.RateLimitError(
            message: "Vertex AI rate limit exceeded (429)",
          ))
        401 | 403 ->
          Error(types.ConfigError(
            reason: "Vertex AI auth failed ("
            <> string.inspect(status_code)
            <> "): check VERTEX_AI_TOKEN. Response: "
            <> string.slice(response_body, 0, 200),
          ))
        code if code >= 500 ->
          Error(types.ApiError(status_code: code, message: response_body))
        code -> Error(types.ApiError(status_code: code, message: response_body))
      }
  }
}

// ---------------------------------------------------------------------------
// Request encoding — Anthropic format for Vertex AI
// ---------------------------------------------------------------------------

@internal
pub fn encode_request(req: types.LlmRequest) -> String {
  // Note: model is NOT in the body — it's in the URL path
  let base = [
    #("anthropic_version", json.string(anthropic_version)),
    #("max_tokens", json.int(req.max_tokens)),
    #("messages", json.array(req.messages, encode_message)),
  ]

  let with_system = case req.system {
    Some(s) -> [#("system", json.string(s)), ..base]
    None -> base
  }

  let with_temp = case req.temperature {
    Some(t) -> [#("temperature", json.float(t)), ..with_system]
    None -> with_system
  }

  let with_top_p = case req.top_p {
    Some(p) -> [#("top_p", json.float(p)), ..with_temp]
    None -> with_temp
  }

  let with_stop = case req.stop_sequences {
    Some(seqs) -> [
      #("stop_sequences", json.array(seqs, json.string)),
      ..with_top_p
    ]
    None -> with_top_p
  }

  let with_tools = case req.tools {
    Some(tools) ->
      case tools {
        [] -> with_stop
        _ -> [#("tools", json.array(tools, encode_tool)), ..with_stop]
      }
    None -> with_stop
  }

  let final_fields = case req.tool_choice {
    Some(choice) -> [#("tool_choice", encode_tool_choice(choice)), ..with_tools]
    None -> with_tools
  }

  json.object(final_fields)
  |> json.to_string
}

fn encode_message(msg: types.Message) -> json.Json {
  json.object([
    #("role", encode_role(msg.role)),
    #("content", json.array(msg.content, encode_content_block)),
  ])
}

fn encode_role(role: types.Role) -> json.Json {
  case role {
    types.User -> json.string("user")
    types.Assistant -> json.string("assistant")
  }
}

fn encode_content_block(block: types.ContentBlock) -> json.Json {
  case block {
    types.TextContent(text:) ->
      json.object([
        #("type", json.string("text")),
        #("text", json.string(text)),
      ])
    types.ImageContent(media_type:, data:) ->
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
      ])
    types.ToolUseContent(id:, name:, input_json:) ->
      // input must be a JSON object, not a string.
      // Use raw_json FFI to embed the pre-serialized input directly.
      raw_tool_use_json(id, name, input_json)
    types.ToolResultContent(tool_use_id:, content:, is_error:) ->
      json.object([
        #("type", json.string("tool_result")),
        #("tool_use_id", json.string(tool_use_id)),
        #("content", json.string(content)),
        #("is_error", json.bool(is_error)),
      ])
  }
}

/// Build a tool_use content block with raw JSON input.
/// The Anthropic API expects `input` as a JSON object, not a string.
fn raw_tool_use_json(id: String, name: String, input_json: String) -> json.Json {
  // Validate input_json is valid JSON; fall back to empty object
  let safe_input = case string.trim(input_json) {
    "" -> "{}"
    _ -> input_json
  }
  json.object([
    #("type", json.string("tool_use")),
    #("id", json.string(id)),
    #("name", json.string(name)),
    #("input", raw_json(safe_input)),
  ])
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
    #("name", json.string(tool.name)),
    #("description", case tool.description {
      Some(d) -> json.string(d)
      None -> json.string("")
    }),
    #("input_schema", input_schema),
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
    Some(d) -> [#("description", json.string(d)), ..base]
    None -> base
  }
  let with_enum = case schema.enum_values {
    Some(vals) -> [#("enum", json.array(vals, json.string)), ..with_desc]
    None -> with_desc
  }
  json.object(with_enum)
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
// Response decoding — Anthropic format
// ---------------------------------------------------------------------------

fn decode_response(body: String) -> Result(types.LlmResponse, types.LlmError) {
  case json.parse(body, response_decoder()) {
    Ok(resp) -> Ok(resp)
    Error(e) ->
      Error(types.DecodeError(
        reason: "Vertex AI response decode failed: "
        <> string.inspect(e)
        <> " body: "
        <> string.slice(body, 0, 500),
      ))
  }
}

fn response_decoder() -> decode.Decoder(types.LlmResponse) {
  use id <- decode.optional_field("id", "", decode.string)
  use model <- decode.optional_field("model", "", decode.string)
  use content <- decode.field("content", decode.list(content_block_decoder()))
  use stop_reason <- decode.optional_field("stop_reason", "", decode.string)
  use usage <- decode.optional_field(
    "usage",
    types.Usage(input_tokens: 0, output_tokens: 0, thinking_tokens: 0),
    usage_decoder(),
  )
  decode.success(types.LlmResponse(
    id:,
    model:,
    content:,
    stop_reason: case stop_reason {
      "end_turn" -> Some(types.EndTurn)
      "max_tokens" -> Some(types.MaxTokens)
      "stop_sequence" -> Some(types.StopSequenceReached)
      "tool_use" -> Some(types.ToolUseRequested)
      "" -> None
      _ -> None
    },
    usage:,
  ))
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
      // input comes as a JSON object — capture as dynamic and serialize to string
      use input_dynamic <- decode.field("input", decode.dynamic)
      let input_json = json_encode_term(input_dynamic)
      decode.success(types.ToolUseContent(id:, name:, input_json:))
    }
    _ -> decode.success(types.TextContent(text: ""))
  }
}

fn usage_decoder() -> decode.Decoder(types.Usage) {
  use input <- decode.optional_field("input_tokens", 0, decode.int)
  use output <- decode.optional_field("output_tokens", 0, decode.int)
  decode.success(types.Usage(
    input_tokens: input,
    output_tokens: output,
    thinking_tokens: 0,
  ))
}
