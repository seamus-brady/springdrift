import dprime/types as dprime_types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/types.{
  type ContentBlock, type LlmRequest, type LlmResponse, type Message,
  type ParameterSchema, type Role, type StopReason, type Tool, type ToolCall,
  type ToolResult, ArrayProperty, Assistant, BooleanProperty, EndTurn,
  ImageContent, IntegerProperty, MaxTokens, Message, NumberProperty,
  ObjectProperty, StopSequenceReached, StringProperty, TextContent, ToolFailure,
  ToolResultContent, ToolSuccess, ToolUseContent, ToolUseRequested, User,
}
import simplifile

@external(erlang, "springdrift_ffi", "generate_uuid")
pub fn generate_uuid() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

fn cycle_log_dir() -> String {
  "cycle-log"
}

fn log_path() -> String {
  cycle_log_dir() <> "/" <> get_date() <> ".jsonl"
}

fn append_entry(entry: json.Json) -> Nil {
  let dir = cycle_log_dir()
  let _ = simplifile.create_directory_all(dir)
  let _ = simplifile.append(log_path(), json.to_string(entry) <> "\n")
  Nil
}

// ---------------------------------------------------------------------------
// Public logging API
// ---------------------------------------------------------------------------

pub fn log_human_input(
  cycle_id: String,
  parent_id: Option(String),
  text: String,
) -> Nil {
  let parent_field = case parent_id {
    None -> json.null()
    Some(id) -> json.string(id)
  }
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("parent_id", parent_field),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("human_input")),
      #("text", json.string(text)),
    ]),
  )
}

pub fn log_llm_request(cycle_id: String, req: LlmRequest) -> Nil {
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("llm_request")),
      #("model", json.string(req.model)),
      #("system", case req.system {
        None -> json.null()
        Some(s) -> json.string(s)
      }),
      #("max_tokens", json.int(req.max_tokens)),
      #("messages", json.array(req.messages, encode_message)),
      #("tools", case req.tools {
        None -> json.preprocessed_array([])
        Some(tools) -> json.array(tools, encode_tool)
      }),
    ]),
  )
}

pub fn log_llm_response(cycle_id: String, resp: LlmResponse) -> Nil {
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("llm_response")),
      #("response_id", json.string(resp.id)),
      #("model", json.string(resp.model)),
      #("stop_reason", encode_stop_reason(resp.stop_reason)),
      #("content", json.array(resp.content, encode_content_block)),
      #("input_tokens", json.int(resp.usage.input_tokens)),
      #("output_tokens", json.int(resp.usage.output_tokens)),
      #("thinking_tokens", json.int(resp.usage.thinking_tokens)),
    ]),
  )
}

pub fn log_llm_error(cycle_id: String, error: String) -> Nil {
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("llm_error")),
      #("error", json.string(error)),
    ]),
  )
}

pub fn log_tool_call(cycle_id: String, call: ToolCall) -> Nil {
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("tool_call")),
      #("tool_use_id", json.string(call.id)),
      #("name", json.string(call.name)),
      #("input", json.string(call.input_json)),
    ]),
  )
}

pub fn log_classification(
  cycle_id: String,
  complexity: String,
  suggested_model: String,
  prompted_user: Bool,
  user_confirmed: option.Option(Bool),
) -> Nil {
  let confirmed_val = case user_confirmed {
    None -> json.null()
    Some(b) -> json.bool(b)
  }
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("classification")),
      #("complexity", json.string(complexity)),
      #("suggested_model", json.string(suggested_model)),
      #("prompted_user", json.bool(prompted_user)),
      #("user_confirmed", confirmed_val),
    ]),
  )
}

pub fn log_tool_result(cycle_id: String, result: ToolResult) -> Nil {
  let #(tool_use_id, success, content) = case result {
    ToolSuccess(tool_use_id:, content:) -> #(tool_use_id, True, content)
    ToolFailure(tool_use_id:, error:) -> #(tool_use_id, False, error)
  }
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("tool_result")),
      #("tool_use_id", json.string(tool_use_id)),
      #("success", json.bool(success)),
      #("content", json.string(content)),
    ]),
  )
}

pub fn log_dprime_canary(
  cycle_id: String,
  hijack_detected: Bool,
  leakage_detected: Bool,
  details: String,
) -> Nil {
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("dprime_canary")),
      #("hijack_detected", json.bool(hijack_detected)),
      #("leakage_detected", json.bool(leakage_detected)),
      #("details", json.string(details)),
    ]),
  )
}

pub fn log_dprime_layer(
  cycle_id: String,
  layer: String,
  decision: String,
  score: Float,
  explanation: String,
) -> Nil {
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("dprime_layer")),
      #("layer", json.string(layer)),
      #("decision", json.string(decision)),
      #("score", json.float(score)),
      #("explanation", json.string(explanation)),
    ]),
  )
}

pub fn log_dprime_scorer_fallback(
  cycle_id: String,
  reason: String,
  feature_count: Int,
) -> Nil {
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("dprime_scorer_fallback")),
      #("reason", json.string(reason)),
      #("feature_count", json.int(feature_count)),
    ]),
  )
}

pub fn log_dprime_meta_stall(
  cycle_id: String,
  stall_detected: Bool,
  window_size: Int,
  original_decision: String,
  final_decision: String,
) -> Nil {
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("dprime_meta_stall")),
      #("stall_detected", json.bool(stall_detected)),
      #("window_size", json.int(window_size)),
      #("original_decision", json.string(original_decision)),
      #("final_decision", json.string(final_decision)),
    ]),
  )
}

pub fn log_dprime_evaluation(
  cycle_id: String,
  result: dprime_types.GateResult,
) -> Nil {
  let decision_str = case result.decision {
    dprime_types.Accept -> "accept"
    dprime_types.Modify -> "modify"
    dprime_types.Reject -> "reject"
  }
  let layer_str = case result.layer {
    dprime_types.Reactive -> "reactive"
    dprime_types.Deliberative -> "deliberative"
    dprime_types.MetaManagement -> "meta_management"
  }
  let forecasts_json =
    json.array(result.forecasts, fn(f) {
      json.object([
        #("feature", json.string(f.feature_name)),
        #("magnitude", json.int(f.magnitude)),
        #("rationale", json.string(f.rationale)),
      ])
    })
  append_entry(
    json.object([
      #("cycle_id", json.string(cycle_id)),
      #("timestamp", json.string(get_datetime())),
      #("type", json.string("dprime_evaluation")),
      #("decision", json.string(decision_str)),
      #("score", json.float(result.dprime_score)),
      #("layer", json.string(layer_str)),
      #("explanation", json.string(result.explanation)),
      #("forecasts", forecasts_json),
      #("canary_result", case result.canary_result {
        None -> json.null()
        Some(probe) ->
          json.object([
            #("hijack_detected", json.bool(probe.hijack_detected)),
            #("leakage_detected", json.bool(probe.leakage_detected)),
            #("details", json.string(probe.details)),
          ])
      }),
    ]),
  )
}

// ---------------------------------------------------------------------------
// Encoders
// ---------------------------------------------------------------------------

fn encode_message(msg: Message) -> json.Json {
  json.object([
    #("role", encode_role(msg.role)),
    #("content", json.array(msg.content, encode_content_block)),
  ])
}

fn encode_role(role: Role) -> json.Json {
  case role {
    User -> json.string("user")
    Assistant -> json.string("assistant")
  }
}

fn encode_content_block(block: ContentBlock) -> json.Json {
  case block {
    TextContent(text:) ->
      json.object([#("type", json.string("text")), #("text", json.string(text))])
    ToolUseContent(id:, name:, input_json:) ->
      json.object([
        #("type", json.string("tool_use")),
        #("id", json.string(id)),
        #("name", json.string(name)),
        #("input", json.string(input_json)),
      ])
    ToolResultContent(tool_use_id:, content:, is_error:) ->
      json.object([
        #("type", json.string("tool_result")),
        #("tool_use_id", json.string(tool_use_id)),
        #("content", json.string(content)),
        #("is_error", json.bool(is_error)),
      ])
    ImageContent(media_type:, data:) ->
      json.object([
        #("type", json.string("image")),
        #("media_type", json.string(media_type)),
        #("data", json.string(data)),
      ])
  }
}

fn encode_tool(tool: Tool) -> json.Json {
  let params =
    json.object(
      list.map(tool.parameters, fn(param) {
        let #(name, schema) = param
        #(name, encode_parameter_schema(schema))
      }),
    )
  let base = [
    #("name", json.string(tool.name)),
    #("parameters", params),
    #("required", json.array(tool.required_params, json.string)),
  ]
  let with_desc = case tool.description {
    None -> base
    Some(desc) -> list.append(base, [#("description", json.string(desc))])
  }
  json.object(with_desc)
}

fn encode_parameter_schema(schema: ParameterSchema) -> json.Json {
  let type_str = case schema.param_type {
    StringProperty -> "string"
    NumberProperty -> "number"
    IntegerProperty -> "integer"
    BooleanProperty -> "boolean"
    ArrayProperty -> "array"
    ObjectProperty -> "object"
  }
  let base = [#("type", json.string(type_str))]
  let with_desc = case schema.description {
    None -> base
    Some(desc) -> list.append(base, [#("description", json.string(desc))])
  }
  let with_enum = case schema.enum_values {
    None -> with_desc
    Some(vals) ->
      list.append(with_desc, [#("enum", json.array(vals, json.string))])
  }
  json.object(with_enum)
}

fn encode_stop_reason(reason: Option(StopReason)) -> json.Json {
  case reason {
    None -> json.null()
    Some(EndTurn) -> json.string("end_turn")
    Some(MaxTokens) -> json.string("max_tokens")
    Some(StopSequenceReached) -> json.string("stop_sequence")
    Some(ToolUseRequested) -> json.string("tool_use")
  }
}

// ---------------------------------------------------------------------------
// Log reading — types
// ---------------------------------------------------------------------------

pub type CycleData {
  CycleData(
    cycle_id: String,
    parent_id: Option(String),
    timestamp: String,
    human_input: String,
    tool_names: List(String),
    response_text: String,
    input_tokens: Int,
    output_tokens: Int,
    thinking_tokens: Int,
    complexity: Option(String),
  )
}

type CycleAcc {
  CycleAcc(
    cycle_id: String,
    parent_id: Option(String),
    timestamp: String,
    human_input: String,
    tool_names: List(String),
    response_text: String,
    input_tokens: Int,
    output_tokens: Int,
    thinking_tokens: Int,
    complexity: Option(String),
  )
}

type RawEvent {
  HumanInputEvent(
    cycle_id: String,
    parent_id: Option(String),
    timestamp: String,
    text: String,
  )
  LlmResponseEvent(
    cycle_id: String,
    content_text: String,
    input_tokens: Int,
    output_tokens: Int,
    thinking_tokens: Int,
  )
  ToolCallEvent(cycle_id: String, name: String)
  ClassificationEvent(cycle_id: String, complexity: String)
  OtherEvent
}

// ---------------------------------------------------------------------------
// Log reading — public API
// ---------------------------------------------------------------------------

pub fn load_cycles() -> List(CycleData) {
  case simplifile.read(log_path()) {
    Error(_) -> []
    Ok(contents) -> {
      let events =
        string.split(contents, "\n")
        |> list.filter_map(fn(line) {
          let trimmed = string.trim(line)
          case trimmed {
            "" -> Error(Nil)
            _ ->
              case json.parse(trimmed, event_decoder()) {
                Ok(event) -> Ok(event)
                Error(_) -> Error(Nil)
              }
          }
        })
      build_cycles(events)
    }
  }
}

pub fn messages_for_rewind(
  cycles: List(CycleData),
  up_to_index: Int,
) -> List(Message) {
  cycles
  |> list.take(up_to_index + 1)
  |> list.flat_map(fn(c) {
    let user_msg =
      Message(role: User, content: [TextContent(text: c.human_input)])
    case c.response_text {
      "" -> [user_msg]
      text -> [
        user_msg,
        Message(role: Assistant, content: [TextContent(text: text)]),
      ]
    }
  })
}

// ---------------------------------------------------------------------------
// Log reading — internal
// ---------------------------------------------------------------------------

fn build_cycles(events: List(RawEvent)) -> List(CycleData) {
  events
  |> list.fold([], fn(acc, event) {
    case event {
      HumanInputEvent(cycle_id:, parent_id:, timestamp:, text:) ->
        list.append(acc, [
          CycleAcc(
            cycle_id:,
            parent_id:,
            timestamp:,
            human_input: text,
            tool_names: [],
            response_text: "",
            input_tokens: 0,
            output_tokens: 0,
            thinking_tokens: 0,
            complexity: None,
          ),
        ])
      LlmResponseEvent(
        cycle_id:,
        content_text:,
        input_tokens:,
        output_tokens:,
        thinking_tokens:,
      ) ->
        list.map(acc, fn(c) {
          case c.cycle_id == cycle_id {
            True ->
              CycleAcc(
                ..c,
                response_text: content_text,
                input_tokens: c.input_tokens + input_tokens,
                output_tokens: c.output_tokens + output_tokens,
                thinking_tokens: c.thinking_tokens + thinking_tokens,
              )
            False -> c
          }
        })
      ToolCallEvent(cycle_id:, name:) ->
        list.map(acc, fn(c) {
          case c.cycle_id == cycle_id {
            True -> CycleAcc(..c, tool_names: list.append(c.tool_names, [name]))
            False -> c
          }
        })
      ClassificationEvent(cycle_id:, complexity:) ->
        list.map(acc, fn(c) {
          case c.cycle_id == cycle_id {
            True -> CycleAcc(..c, complexity: Some(complexity))
            False -> c
          }
        })
      OtherEvent -> acc
    }
  })
  |> list.map(fn(c) {
    CycleData(
      cycle_id: c.cycle_id,
      parent_id: c.parent_id,
      timestamp: c.timestamp,
      human_input: c.human_input,
      tool_names: c.tool_names,
      response_text: c.response_text,
      input_tokens: c.input_tokens,
      output_tokens: c.output_tokens,
      thinking_tokens: c.thinking_tokens,
      complexity: c.complexity,
    )
  })
}

fn event_decoder() -> decode.Decoder(RawEvent) {
  use type_str <- decode.field("type", decode.string)
  case type_str {
    "human_input" -> {
      use cycle_id <- decode.field("cycle_id", decode.string)
      use timestamp <- decode.field("timestamp", decode.string)
      use text <- decode.field("text", decode.string)
      use parent_id <- decode.optional_field(
        "parent_id",
        None,
        decode.string |> decode.map(Some),
      )
      decode.success(HumanInputEvent(cycle_id:, parent_id:, timestamp:, text:))
    }
    "llm_response" -> {
      use cycle_id <- decode.field("cycle_id", decode.string)
      use parts <- decode.field(
        "content",
        decode.list(content_block_text_decoder()),
      )
      use input_tokens <- decode.field("input_tokens", decode.int)
      use output_tokens <- decode.field("output_tokens", decode.int)
      use thinking_tokens <- decode.optional_field(
        "thinking_tokens",
        0,
        decode.int,
      )
      decode.success(LlmResponseEvent(
        cycle_id:,
        content_text: string.join(parts, ""),
        input_tokens:,
        output_tokens:,
        thinking_tokens:,
      ))
    }
    "tool_call" -> {
      use cycle_id <- decode.field("cycle_id", decode.string)
      use name <- decode.field("name", decode.string)
      decode.success(ToolCallEvent(cycle_id:, name:))
    }
    "classification" -> {
      use cycle_id <- decode.field("cycle_id", decode.string)
      use complexity <- decode.field("complexity", decode.string)
      decode.success(ClassificationEvent(cycle_id:, complexity:))
    }
    _ -> decode.success(OtherEvent)
  }
}

fn content_block_text_decoder() -> decode.Decoder(String) {
  use type_str <- decode.field("type", decode.string)
  case type_str {
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(text)
    }
    _ -> decode.success("")
  }
}
