/// Jina Reader tool: URL → clean markdown extraction.
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{None}
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import slog

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub type JinaConfig {
  JinaConfig(reader_base_url: String)
}

pub fn default_config() -> JinaConfig {
  JinaConfig(reader_base_url: "https://r.jina.ai/")
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "springdrift_ffi", "http_get_with_headers")
fn http_get_with_headers(
  url: String,
  headers: List(#(String, String)),
) -> Result(#(Int, String), String)

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [jina_reader_tool()]
}

pub fn is_jina_tool(name: String) -> Bool {
  name == "jina_reader"
}

fn jina_reader_tool() -> Tool {
  tool.new("jina_reader")
  |> tool.with_description(
    "Extract clean markdown content from a URL using Jina Reader. Returns the page content in a structured, readable format. Better than raw fetch_url for content extraction. Requires JINA_READER_API_KEY.",
  )
  |> tool.add_string_param(
    "url",
    "The URL to extract content from (must start with http:// or https://)",
    True,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(call: ToolCall) -> ToolResult {
  execute_with_config(call, default_config())
}

pub fn execute_with_config(call: ToolCall, cfg: JinaConfig) -> ToolResult {
  slog.debug("jina", "execute", "tool=" <> call.name, None)
  case call.name {
    "jina_reader" -> run_jina_reader(call, cfg)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// jina_reader
// ---------------------------------------------------------------------------

fn run_jina_reader(call: ToolCall, cfg: JinaConfig) -> ToolResult {
  case get_env("JINA_READER_API_KEY") {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "JINA_READER_API_KEY not set. Set this environment variable to use Jina Reader.",
      )
    Ok(api_key) -> {
      let decoder = {
        use url <- decode.field("url", decode.string)
        decode.success(url)
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Invalid jina_reader input: missing url",
          )
        Ok(url) ->
          case
            string.starts_with(url, "http://")
            || string.starts_with(url, "https://")
          {
            False ->
              ToolFailure(
                tool_use_id: call.id,
                error: "jina_reader: URL must start with http:// or https://",
              )
            True -> {
              let reader_url = cfg.reader_base_url <> url
              let headers = [
                #("Authorization", "Bearer " <> api_key),
                #("Accept", "text/markdown"),
                #("X-Return-Format", "markdown"),
              ]
              case http_get_with_headers(reader_url, headers) {
                Error(reason) ->
                  ToolFailure(
                    tool_use_id: call.id,
                    error: "jina_reader: " <> reason,
                  )
                Ok(#(status, body)) ->
                  case status >= 200 && status < 300 {
                    True ->
                      ToolSuccess(
                        tool_use_id: call.id,
                        content: string.slice(body, 0, 50_000),
                      )
                    False ->
                      ToolFailure(
                        tool_use_id: call.id,
                        error: "jina_reader: HTTP "
                          <> int.to_string(status)
                          <> " — "
                          <> string.slice(body, 0, 500),
                      )
                  }
              }
            }
          }
      }
    }
  }
}
