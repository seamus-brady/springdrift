import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import llm/types.{
  type ContentBlock, type Message, type Role, Assistant, ImageContent, Message,
  TextContent, ToolResultContent, ToolUseContent, User,
}
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

fn config_dir() -> String {
  case get_env("HOME") {
    Ok(home) -> home <> "/.config/springdrift"
    Error(_) -> "."
  }
}

fn session_path() -> String {
  case get_env("HOME") {
    Ok(home) -> home <> "/.config/springdrift/session.json"
    Error(_) -> ".springdrift_session.json"
  }
}

pub fn save(messages: List(Message)) -> Result(Nil, String) {
  slog.debug(
    "storage",
    "save",
    "Saving " <> int.to_string(list.length(messages)) <> " messages",
    option.None,
  )
  let dir = config_dir()
  case simplifile.create_directory_all(dir) {
    Error(e) ->
      Error(
        "Could not create config directory: " <> simplifile.describe_error(e),
      )
    Ok(_) -> {
      let json_str = json.to_string(encode_messages(messages))
      case simplifile.write(session_path(), json_str) {
        Error(e) ->
          Error("Could not write session: " <> simplifile.describe_error(e))
        Ok(_) -> Ok(Nil)
      }
    }
  }
}

pub fn load() -> List(Message) {
  slog.debug("storage", "load", "Loading session", option.None)
  case simplifile.read(session_path()) {
    Error(_) -> []
    Ok(contents) ->
      case json.parse(contents, decode.list(message_decoder())) {
        Error(_) -> []
        Ok(msgs) -> msgs
      }
  }
}

pub fn clear() -> Result(Nil, String) {
  case simplifile.delete(session_path()) {
    Error(e) ->
      Error("Could not clear session: " <> simplifile.describe_error(e))
    Ok(_) -> Ok(Nil)
  }
}

fn encode_messages(messages: List(Message)) -> json.Json {
  json.array(messages, encode_message)
}

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

fn message_decoder() -> decode.Decoder(Message) {
  use role <- decode.field("role", role_decoder())
  use content <- decode.field("content", decode.list(content_block_decoder()))
  decode.success(Message(role:, content:))
}

fn role_decoder() -> decode.Decoder(Role) {
  decode.string
  |> decode.map(fn(s) {
    case s {
      "assistant" -> Assistant
      _ -> User
    }
  })
}

fn content_block_decoder() -> decode.Decoder(ContentBlock) {
  use type_str <- decode.field("type", decode.string)
  case type_str {
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(TextContent(text:))
    }
    "tool_use" -> {
      use id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      use input_json <- decode.field("input", decode.string)
      decode.success(ToolUseContent(id:, name:, input_json:))
    }
    "tool_result" -> {
      use tool_use_id <- decode.field("tool_use_id", decode.string)
      use content <- decode.field("content", decode.string)
      use is_error <- decode.field("is_error", decode.bool)
      decode.success(ToolResultContent(tool_use_id:, content:, is_error:))
    }
    "image" -> {
      use media_type <- decode.field("media_type", decode.string)
      use data <- decode.field("data", decode.string)
      decode.success(ImageContent(media_type:, data:))
    }
    _ -> decode.failure(TextContent(""), "Unknown block type")
  }
}
