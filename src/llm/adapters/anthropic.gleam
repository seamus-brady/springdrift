import anthropic/api as aapi
import anthropic/client as aclient
import anthropic/error as aerr
import anthropic/message as amsg
import anthropic/request as areq
import anthropic/tool as atool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import llm/provider.{type Provider, Provider}
import llm/types

/// Predefined model name constants
pub const claude_opus_4 = "claude-opus-4-20250514"

pub const claude_sonnet_4 = "claude-sonnet-4-20250514"

pub const claude_haiku_3_5 = "claude-haiku-3-5-20241022"

/// Create an Anthropic provider using the ANTHROPIC_API_KEY environment variable
pub fn provider() -> Result(Provider, types.LlmError) {
  aclient.init()
  |> result.map_error(translate_error)
  |> result.map(fn(c) {
    Provider(
      name: "anthropic",
      chat: fn(req) {
        aapi.chat(c, translate_request(req))
        |> result.map(translate_response)
        |> result.map_error(translate_error)
      },
    )
  })
}

/// Create an Anthropic provider with an explicit API key
pub fn provider_with_key(api_key: String) -> Result(Provider, types.LlmError) {
  aclient.init_with_key(api_key)
  |> result.map_error(translate_error)
  |> result.map(fn(c) {
    Provider(
      name: "anthropic",
      chat: fn(req) {
        aapi.chat(c, translate_request(req))
        |> result.map(translate_response)
        |> result.map_error(translate_error)
      },
    )
  })
}

// ---------------------------------------------------------------------------
// Request translation
// ---------------------------------------------------------------------------

fn translate_request(req: types.LlmRequest) -> areq.CreateMessageRequest {
  let messages = list.map(req.messages, translate_message)
  let base = areq.new(req.model, messages, req.max_tokens)

  let r1 = case req.system {
    Some(s) -> areq.with_system(base, s)
    None -> base
  }

  let r2 = case req.temperature {
    Some(t) -> areq.with_temperature(r1, t)
    None -> r1
  }

  let r3 = case req.top_p {
    Some(p) -> areq.with_top_p(r2, p)
    None -> r2
  }

  let r4 = case req.stop_sequences {
    Some(seqs) -> areq.with_stop_sequences(r3, seqs)
    None -> r3
  }

  let r5 = case req.tools {
    Some(tools) -> areq.with_tools(r4, list.map(tools, translate_tool))
    None -> r4
  }

  case req.tool_choice {
    Some(choice) -> areq.with_tool_choice(r5, translate_tool_choice(choice))
    None -> r5
  }
}

fn translate_message(msg: types.Message) -> amsg.Message {
  amsg.Message(
    role: translate_role(msg.role),
    content: list.map(msg.content, translate_content_block),
  )
}

fn translate_role(role: types.Role) -> amsg.Role {
  case role {
    types.User -> amsg.User
    types.Assistant -> amsg.Assistant
  }
}

fn translate_content_block(block: types.ContentBlock) -> amsg.ContentBlock {
  case block {
    types.TextContent(text: text) -> amsg.TextBlock(text: text)
    types.ImageContent(media_type: mt, data: data) ->
      amsg.ImageBlock(
        source: amsg.ImageSource(
          source_type: amsg.Base64,
          media_type: mt,
          data: data,
        ),
      )
    types.ToolUseContent(id: id, name: name, input_json: input) ->
      amsg.ToolUseBlock(id: id, name: name, input: input)
    types.ToolResultContent(
      tool_use_id: tool_use_id,
      content: content,
      is_error: is_error,
    ) ->
      amsg.ToolResultBlock(
        tool_use_id: tool_use_id,
        content: content,
        is_error: is_error,
      )
  }
}

fn translate_tool(tool: types.Tool) -> atool.Tool {
  let properties =
    list.map(tool.parameters, fn(pair) {
      let #(name, schema) = pair
      #(name, translate_param_schema(schema))
    })
  let input_schema = case tool.parameters {
    [] -> atool.empty_input_schema()
    _ -> atool.input_schema(properties, tool.required_params)
  }
  atool.Tool(
    name: atool.tool_name_unchecked(tool.name),
    description: tool.description,
    input_schema: input_schema,
  )
}

fn translate_param_schema(schema: types.ParameterSchema) -> atool.PropertySchema {
  let type_str = case schema.param_type {
    types.StringProperty -> "string"
    types.NumberProperty -> "number"
    types.IntegerProperty -> "integer"
    types.BooleanProperty -> "boolean"
    types.ArrayProperty -> "array"
    types.ObjectProperty -> "object"
  }
  atool.PropertySchema(
    property_type: type_str,
    description: schema.description,
    enum_values: schema.enum_values,
    items: None,
    properties: None,
    required: None,
  )
}

fn translate_tool_choice(choice: types.ToolChoice) -> atool.ToolChoice {
  case choice {
    types.AutoToolChoice -> atool.Auto
    types.AnyToolChoice -> atool.Any
    types.NoToolChoice -> atool.NoTool
    types.SpecificToolChoice(name: n) -> atool.SpecificTool(n)
  }
}

// ---------------------------------------------------------------------------
// Response translation
// ---------------------------------------------------------------------------

fn translate_response(resp: areq.CreateMessageResponse) -> types.LlmResponse {
  types.LlmResponse(
    id: resp.id,
    content: list.map(resp.content, translate_response_block),
    model: resp.model,
    stop_reason: case resp.stop_reason {
      Some(reason) -> Some(translate_stop_reason(reason))
      None -> None
    },
    usage: types.Usage(
      input_tokens: resp.usage.input_tokens,
      output_tokens: resp.usage.output_tokens,
    ),
  )
}

fn translate_response_block(block: amsg.ContentBlock) -> types.ContentBlock {
  case block {
    amsg.TextBlock(text: text) -> types.TextContent(text: text)
    amsg.ImageBlock(source: source) ->
      types.ImageContent(media_type: source.media_type, data: source.data)
    amsg.ToolUseBlock(id: id, name: name, input: input) ->
      types.ToolUseContent(id: id, name: name, input_json: input)
    amsg.ToolResultBlock(
      tool_use_id: tool_use_id,
      content: content,
      is_error: is_error,
    ) ->
      types.ToolResultContent(
        tool_use_id: tool_use_id,
        content: content,
        is_error: is_error,
      )
  }
}

fn translate_stop_reason(reason: areq.StopReason) -> types.StopReason {
  case reason {
    areq.EndTurn -> types.EndTurn
    areq.MaxTokens -> types.MaxTokens
    areq.StopSequence -> types.StopSequenceReached
    areq.ToolUse -> types.ToolUseRequested
  }
}

// ---------------------------------------------------------------------------
// Error translation
// ---------------------------------------------------------------------------

fn translate_error(error: aerr.AnthropicError) -> types.LlmError {
  case error {
    aerr.ApiError(status_code: code, details: details) ->
      case details.error_type {
        aerr.RateLimitError ->
          types.RateLimitError(message: details.message)
        _ -> types.ApiError(status_code: code, message: details.message)
      }
    aerr.HttpError(reason: reason) -> types.NetworkError(reason: reason)
    aerr.NetworkError(reason: reason) -> types.NetworkError(reason: reason)
    aerr.ConfigError(reason: reason) -> types.ConfigError(reason: reason)
    aerr.TimeoutError(_) -> types.TimeoutError
    aerr.JsonError(reason: reason) -> types.DecodeError(reason: reason)
  }
}
