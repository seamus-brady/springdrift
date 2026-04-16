// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

/// Kagi Search API tools: web search and summarize.
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
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

pub type KagiConfig {
  KagiConfig(base_url: String, max_results: Int, cache_ttl_ms: Int)
}

pub fn default_config() -> KagiConfig {
  KagiConfig(
    base_url: "https://kagi.com/api/v0",
    max_results: 10,
    cache_ttl_ms: 300_000,
  )
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

@external(erlang, "springdrift_ffi", "http_post")
fn http_post(
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), String)

@external(erlang, "springdrift_ffi", "uri_encode")
fn uri_encode(text: String) -> String

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [kagi_search_tool(), kagi_summarize_tool()]
}

pub fn is_kagi_tool(name: String) -> Bool {
  name == "kagi_search" || name == "kagi_summarize"
}

fn kagi_search_tool() -> Tool {
  tool.new("kagi_search")
  |> tool.with_description(
    "Search the web using the Kagi Search API. High quality, ad-free results. Returns titles, URLs, and snippets. Requires KAGI_API_KEY.",
  )
  |> tool.add_string_param("query", "The search query", True)
  |> tool.add_integer_param(
    "max_results",
    "Maximum results to return (1-10, default 5)",
    False,
  )
  |> tool.build()
}

fn kagi_summarize_tool() -> Tool {
  tool.new("kagi_summarize")
  |> tool.with_description(
    "Summarize a URL or text using Kagi's Universal Summarizer. Returns a concise summary. Requires KAGI_API_KEY.",
  )
  |> tool.add_string_param(
    "url",
    "The URL to summarize (must start with http:// or https://)",
    True,
  )
  |> tool.add_string_param(
    "summary_type",
    "Summary type: summary (default), takeaway (key points), or cecil (informal)",
    False,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(call: ToolCall) -> ToolResult {
  execute_with_config(call, default_config())
}

pub fn execute_with_config(call: ToolCall, cfg: KagiConfig) -> ToolResult {
  slog.debug("kagi", "execute", "tool=" <> call.name, None)
  case call.name {
    "kagi_search" -> run_kagi_search(call, cfg)
    "kagi_summarize" -> run_kagi_summarize(call, cfg)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// kagi_search
// ---------------------------------------------------------------------------

fn run_kagi_search(call: ToolCall, cfg: KagiConfig) -> ToolResult {
  case get_env("KAGI_API_KEY") {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "KAGI_API_KEY not set. Set this environment variable to use Kagi Search.",
      )
    Ok(api_key) -> {
      let decoder = {
        use query <- decode.field("query", decode.string)
        use max <- decode.optional_field("max_results", 5, decode.int)
        decode.success(#(query, max))
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Invalid kagi_search input: missing query",
          )
        Ok(#(query, max_results)) -> {
          let clamped = int.min(cfg.max_results, int.max(1, max_results))
          let url =
            cfg.base_url
            <> "/search?q="
            <> uri_encode(query)
            <> "&limit="
            <> int.to_string(clamped)
          do_kagi_get(call, url, api_key, "kagi_search", fn(body) {
            parse_kagi_search_results(body)
          })
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// kagi_summarize
// ---------------------------------------------------------------------------

fn run_kagi_summarize(call: ToolCall, cfg: KagiConfig) -> ToolResult {
  case get_env("KAGI_API_KEY") {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "KAGI_API_KEY not set. Set this environment variable to use Kagi Summarizer.",
      )
    Ok(api_key) -> {
      let decoder = {
        use url <- decode.field("url", decode.string)
        use summary_type <- decode.optional_field(
          "summary_type",
          "summary",
          decode.string,
        )
        decode.success(#(url, summary_type))
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Invalid kagi_summarize input: missing url",
          )
        Ok(#(url, summary_type)) ->
          case
            string.starts_with(url, "http://")
            || string.starts_with(url, "https://")
          {
            False ->
              ToolFailure(
                tool_use_id: call.id,
                error: "kagi_summarize: URL must start with http:// or https://",
              )
            True -> {
              let engine = case summary_type {
                "takeaway" -> "muriel"
                "cecil" -> "cecil"
                _ -> "cecil"
              }
              let request_body =
                json.to_string(
                  json.object([
                    #("url", json.string(url)),
                    #("engine", json.string(engine)),
                  ]),
                )
              let headers = [
                #("Authorization", "Bot " <> api_key),
                #("Content-Type", "application/json"),
              ]
              case
                http_post(cfg.base_url <> "/summarize", headers, request_body)
              {
                Error(reason) ->
                  ToolFailure(
                    tool_use_id: call.id,
                    error: "kagi_summarize: " <> reason,
                  )
                Ok(#(status, body)) ->
                  case status >= 200 && status < 300 {
                    True ->
                      ToolSuccess(
                        tool_use_id: call.id,
                        content: parse_kagi_summary(body),
                      )
                    False ->
                      ToolFailure(
                        tool_use_id: call.id,
                        error: "kagi_summarize: HTTP "
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

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

fn do_kagi_get(
  call: ToolCall,
  url: String,
  api_key: String,
  tool_name: String,
  parser: fn(String) -> String,
) -> ToolResult {
  let headers = [
    #("Authorization", "Bot " <> api_key),
    #("Accept", "application/json"),
  ]
  case http_get_with_headers(url, headers) {
    Error(reason) ->
      ToolFailure(tool_use_id: call.id, error: tool_name <> ": " <> reason)
    Ok(#(status, body)) ->
      case status >= 200 && status < 300 {
        True -> ToolSuccess(tool_use_id: call.id, content: parser(body))
        False ->
          ToolFailure(
            tool_use_id: call.id,
            error: tool_name
              <> ": HTTP "
              <> int.to_string(status)
              <> " — "
              <> string.slice(body, 0, 500),
          )
      }
  }
}

// ---------------------------------------------------------------------------
// JSON response parsers
// ---------------------------------------------------------------------------

fn parse_kagi_search_results(body: String) -> String {
  let result_decoder = {
    use t <- decode.optional_field("t", "", decode.string)
    use url <- decode.optional_field("url", "", decode.string)
    use snippet <- decode.optional_field("snippet", "", decode.string)
    decode.success(#(t, url, snippet))
  }
  let decoder = {
    use data <- decode.field("data", decode.list(result_decoder))
    decode.success(data)
  }
  case json.parse(body, decoder) {
    Error(_) -> "No results found or invalid response."
    Ok(results) -> {
      let filtered =
        list.filter(results, fn(r) {
          let #(_, url, _) = r
          url != ""
        })
      format_results(filtered)
    }
  }
}

fn parse_kagi_summary(body: String) -> String {
  let decoder = decode.at(["data", "output"], decode.string)
  case json.parse(body, decoder) {
    Ok(output) ->
      case string.trim(output) {
        "" -> "Kagi returned empty summary. Raw: " <> string.slice(body, 0, 300)
        trimmed -> trimmed
      }
    Error(_) -> "No summary parsed. Raw: " <> string.slice(body, 0, 300)
  }
}

// ---------------------------------------------------------------------------
// Formatters
// ---------------------------------------------------------------------------

fn format_results(results: List(#(String, String, String))) -> String {
  case results {
    [] -> "No results found."
    _ ->
      list.index_map(results, fn(r, i) {
        let #(title, url, snippet) = r
        int.to_string(i + 1)
        <> ". "
        <> title
        <> "\n   "
        <> url
        <> "\n   "
        <> snippet
      })
      |> string.join("\n\n")
  }
}
