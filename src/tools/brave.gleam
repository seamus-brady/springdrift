// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

/// Brave Search API tools: web search, news search, LLM context, summarizer, and answers.
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

pub type BraveConfig {
  BraveConfig(
    search_base_url: String,
    answers_base_url: String,
    max_results: Int,
    cache_ttl_ms: Int,
  )
}

pub fn default_config() -> BraveConfig {
  BraveConfig(
    search_base_url: "https://api.search.brave.com",
    answers_base_url: "https://api.search.brave.com",
    max_results: 20,
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
  [
    brave_web_search_tool(),
    brave_news_search_tool(),
    brave_llm_context_tool(),
    brave_summarizer_tool(),
    brave_answer_tool(),
  ]
}

/// All Brave tool names for is_brave_tool checks.
pub fn is_brave_tool(name: String) -> Bool {
  name == "brave_web_search"
  || name == "brave_news_search"
  || name == "brave_llm_context"
  || name == "brave_summarizer"
  || name == "brave_answer"
}

fn brave_web_search_tool() -> Tool {
  tool.new("brave_web_search")
  |> tool.with_description(
    "Search the web using Brave Search API. Returns titles, URLs, and snippets. More comprehensive than DuckDuckGo. Requires BRAVE_SEARCH_API_KEY.",
  )
  |> tool.add_string_param("query", "The search query", True)
  |> tool.add_integer_param(
    "max_results",
    "Maximum results to return (1-20, default 5)",
    False,
  )
  |> tool.build()
}

fn brave_news_search_tool() -> Tool {
  tool.new("brave_news_search")
  |> tool.with_description(
    "Search recent news using Brave Search API. Best for time-sensitive queries and current events. Requires BRAVE_SEARCH_API_KEY.",
  )
  |> tool.add_string_param("query", "The news search query", True)
  |> tool.add_integer_param(
    "max_results",
    "Maximum results to return (1-20, default 5)",
    False,
  )
  |> tool.build()
}

fn brave_llm_context_tool() -> Tool {
  tool.new("brave_llm_context")
  |> tool.with_description(
    "Get machine-optimised context from Brave Search for reasoning. Returns structured context suitable for LLM consumption. Requires BRAVE_SEARCH_API_KEY.",
  )
  |> tool.add_string_param("query", "The search query", True)
  |> tool.build()
}

fn brave_summarizer_tool() -> Tool {
  tool.new("brave_summarizer")
  |> tool.with_description(
    "Get a summary of search results from Brave Search with follow-up suggestions. Uses a 3-call chain: search → summary → follow-ups. Requires BRAVE_SEARCH_API_KEY.",
  )
  |> tool.add_string_param("query", "The search query to summarize", True)
  |> tool.build()
}

fn brave_answer_tool() -> Tool {
  tool.new("brave_answer")
  |> tool.with_description(
    "Get a direct answer to a factual question from Brave Answers API. Best for self-contained factual questions ('what is X', 'when did Y'). Requires BRAVE_ANSWERS_API_KEY.",
  )
  |> tool.add_string_param("query", "The factual question to answer", True)
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(call: ToolCall) -> ToolResult {
  execute_with_config(call, default_config())
}

pub fn execute_with_config(call: ToolCall, cfg: BraveConfig) -> ToolResult {
  slog.debug("brave", "execute", "tool=" <> call.name, None)
  case call.name {
    "brave_web_search" -> run_brave_web_search(call, cfg)
    "brave_news_search" -> run_brave_news_search(call, cfg)
    "brave_llm_context" -> run_brave_llm_context(call, cfg)
    "brave_summarizer" -> run_brave_summarizer(call, cfg)
    "brave_answer" -> run_brave_answer(call, cfg)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// brave_web_search
// ---------------------------------------------------------------------------

fn run_brave_web_search(call: ToolCall, cfg: BraveConfig) -> ToolResult {
  case get_env("BRAVE_SEARCH_API_KEY") {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "BRAVE_SEARCH_API_KEY not set. Set this environment variable to use Brave Search.",
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
            error: "Invalid brave_web_search input: missing query",
          )
        Ok(#(query, max_results)) -> {
          let clamped = int.min(cfg.max_results, int.max(1, max_results))
          let url =
            cfg.search_base_url
            <> "/res/v1/web/search?q="
            <> uri_encode(query)
            <> "&count="
            <> int.to_string(clamped)
          do_brave_get(call, url, api_key, "brave_web_search", fn(body) {
            parse_brave_web_results(body)
          })
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// brave_news_search
// ---------------------------------------------------------------------------

fn run_brave_news_search(call: ToolCall, cfg: BraveConfig) -> ToolResult {
  case get_env("BRAVE_SEARCH_API_KEY") {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "BRAVE_SEARCH_API_KEY not set. Set this environment variable to use Brave News Search.",
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
            error: "Invalid brave_news_search input: missing query",
          )
        Ok(#(query, max_results)) -> {
          let clamped = int.min(cfg.max_results, int.max(1, max_results))
          let url =
            cfg.search_base_url
            <> "/res/v1/news/search?q="
            <> uri_encode(query)
            <> "&count="
            <> int.to_string(clamped)
          do_brave_get(call, url, api_key, "brave_news_search", fn(body) {
            parse_brave_news_results(body)
          })
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// brave_llm_context
// ---------------------------------------------------------------------------

fn run_brave_llm_context(call: ToolCall, cfg: BraveConfig) -> ToolResult {
  case get_env("BRAVE_SEARCH_API_KEY") {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "BRAVE_SEARCH_API_KEY not set. Set this environment variable to use Brave LLM Context.",
      )
    Ok(api_key) -> {
      let decoder = {
        use query <- decode.field("query", decode.string)
        decode.success(query)
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Invalid brave_llm_context input: missing query",
          )
        Ok(query) -> {
          let url =
            cfg.search_base_url
            <> "/res/v1/web/search?q="
            <> uri_encode(query)
            <> "&extra_snippets=true"
          do_brave_get(call, url, api_key, "brave_llm_context", fn(body) {
            parse_brave_llm_context(body)
          })
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// brave_summarizer
// ---------------------------------------------------------------------------

fn run_brave_summarizer(call: ToolCall, cfg: BraveConfig) -> ToolResult {
  case get_env("BRAVE_SEARCH_API_KEY") {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "BRAVE_SEARCH_API_KEY not set. Set this environment variable to use Brave Summarizer.",
      )
    Ok(api_key) -> {
      let decoder = {
        use query <- decode.field("query", decode.string)
        decode.success(query)
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Invalid brave_summarizer input: missing query",
          )
        Ok(query) -> {
          // Summarizer uses the web search endpoint with summary flag
          let url =
            cfg.search_base_url
            <> "/res/v1/web/search?q="
            <> uri_encode(query)
            <> "&summary=1"
          do_brave_get(call, url, api_key, "brave_summarizer", fn(body) {
            parse_brave_summarizer(body)
          })
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// brave_answer
// ---------------------------------------------------------------------------

fn run_brave_answer(call: ToolCall, cfg: BraveConfig) -> ToolResult {
  // Try dedicated answers key first, fall back to search key
  let api_key_result = case get_env("BRAVE_ANSWERS_API_KEY") {
    Ok(key) -> Ok(key)
    Error(_) -> get_env("BRAVE_SEARCH_API_KEY")
  }
  case api_key_result {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Neither BRAVE_ANSWERS_API_KEY nor BRAVE_SEARCH_API_KEY is set. Set one to use Brave Answers.",
      )
    Ok(api_key) -> {
      let decoder = {
        use query <- decode.field("query", decode.string)
        decode.success(query)
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Invalid brave_answer input: missing query",
          )
        Ok(query) -> {
          // Brave Answers uses OpenAI-compatible chat completions endpoint
          let url = cfg.answers_base_url <> "/res/v1/chat/completions"
          let request_body =
            json.to_string(
              json.object([
                #("model", json.string("brave")),
                #(
                  "messages",
                  json.preprocessed_array([
                    json.object([
                      #("role", json.string("user")),
                      #("content", json.string(query)),
                    ]),
                  ]),
                ),
              ]),
            )
          let headers = [
            #("X-Subscription-Token", api_key),
            #("Accept", "application/json"),
          ]
          case http_post(url, headers, request_body) {
            Error(reason) ->
              ToolFailure(
                tool_use_id: call.id,
                error: "brave_answer: " <> reason,
              )
            Ok(#(status, body)) ->
              case status >= 200 && status < 300 {
                True ->
                  ToolSuccess(
                    tool_use_id: call.id,
                    content: parse_brave_answer(body),
                  )
                False ->
                  ToolFailure(
                    tool_use_id: call.id,
                    error: "brave_answer: HTTP "
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

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

fn do_brave_get(
  call: ToolCall,
  url: String,
  api_key: String,
  tool_name: String,
  parser: fn(String) -> String,
) -> ToolResult {
  let headers = [
    #("X-Subscription-Token", api_key),
    #("Accept", "application/json"),
    #("Accept-Encoding", "identity"),
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

fn parse_brave_web_results(body: String) -> String {
  let results_decoder = {
    use title <- decode.field("title", decode.string)
    use url <- decode.field("url", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    decode.success(#(title, url, description))
  }
  let decoder = {
    use results <- decode.optional_field(
      "web",
      [],
      decode.at(["results"], decode.list(results_decoder)),
    )
    decode.success(results)
  }
  case json.parse(body, decoder) {
    Error(_) -> "No results found or invalid response."
    Ok(results) -> format_search_results(results)
  }
}

fn parse_brave_news_results(body: String) -> String {
  let results_decoder = {
    use title <- decode.field("title", decode.string)
    use url <- decode.field("url", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    use age <- decode.optional_field("age", "", decode.string)
    decode.success(#(title, url, description, age))
  }
  let decoder = {
    use results <- decode.optional_field(
      "results",
      [],
      decode.list(results_decoder),
    )
    decode.success(results)
  }
  case json.parse(body, decoder) {
    Error(_) -> "No news results found or invalid response."
    Ok(results) -> format_news_results(results)
  }
}

fn parse_brave_llm_context(body: String) -> String {
  // Uses web search with extra_snippets=true for LLM-optimized context.
  // Response has results under web.results with extra_snippets arrays.
  let results_decoder = {
    use title <- decode.field("title", decode.string)
    use url <- decode.field("url", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    use extra_snippets <- decode.optional_field(
      "extra_snippets",
      [],
      decode.list(decode.string),
    )
    decode.success(#(title, url, description, extra_snippets))
  }
  let decoder = {
    use results <- decode.optional_field(
      "web",
      [],
      decode.at(["results"], decode.list(results_decoder)),
    )
    decode.success(results)
  }
  case json.parse(body, decoder) {
    Ok(results) if results != [] -> format_llm_context_results(results)
    _ ->
      case string.length(body) > 0 {
        True -> string.slice(body, 0, 50_000)
        False -> "No LLM context available or invalid response."
      }
  }
}

fn parse_brave_summarizer(body: String) -> String {
  // Try to extract summary key from the summarizer response
  let summary_key_decoder = {
    use key <- decode.optional_field(
      "summarizer",
      "",
      decode.at(["key"], decode.string),
    )
    decode.success(key)
  }
  let web_decoder = {
    use title <- decode.field("title", decode.string)
    use url <- decode.field("url", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    decode.success(#(title, url, description))
  }
  let decoder = {
    use summary_key <- decode.optional_field(
      "summarizer",
      "",
      decode.at(["key"], decode.string),
    )
    use web_results <- decode.optional_field(
      "web",
      [],
      decode.at(["results"], decode.list(web_decoder)),
    )
    decode.success(#(summary_key, web_results))
  }
  case json.parse(body, summary_key_decoder) {
    Ok(key) if key != "" -> "Summary available (key: " <> key <> ")"
    _ ->
      case json.parse(body, decoder) {
        Error(_) -> "No summary available or invalid response."
        Ok(#(_, results)) -> {
          let header = "## Summary results\n\n"
          header <> format_search_results(results)
        }
      }
  }
}

fn parse_brave_answer(body: String) -> String {
  // Brave Answers returns OpenAI chat completions format:
  // { "choices": [{ "message": { "content": "..." } }] }
  let choice_decoder = decode.at(["message", "content"], decode.string)
  let decoder = {
    use choices <- decode.field("choices", decode.list(choice_decoder))
    decode.success(choices)
  }
  case json.parse(body, decoder) {
    Ok([content, ..]) ->
      case string.trim(content) {
        "" -> "Brave returned empty answer. Raw: " <> string.slice(body, 0, 300)
        trimmed -> trimmed
      }
    _ -> "No answer parsed. Raw: " <> string.slice(body, 0, 300)
  }
}

// ---------------------------------------------------------------------------
// Formatters
// ---------------------------------------------------------------------------

fn format_search_results(results: List(#(String, String, String))) -> String {
  case results {
    [] -> "No results found."
    _ ->
      list.index_map(results, fn(r, i) {
        let #(title, url, desc) = r
        int.to_string(i + 1)
        <> ". "
        <> title
        <> "\n   "
        <> url
        <> "\n   "
        <> desc
      })
      |> string.join("\n\n")
  }
}

fn format_news_results(
  results: List(#(String, String, String, String)),
) -> String {
  case results {
    [] -> "No news results found."
    _ ->
      list.index_map(results, fn(r, i) {
        let #(title, url, desc, age) = r
        let age_str = case age {
          "" -> ""
          a -> " (" <> a <> ")"
        }
        int.to_string(i + 1)
        <> ". "
        <> title
        <> age_str
        <> "\n   "
        <> url
        <> "\n   "
        <> desc
      })
      |> string.join("\n\n")
  }
}

fn format_llm_context_results(
  results: List(#(String, String, String, List(String))),
) -> String {
  case results {
    [] -> "No context available."
    _ ->
      list.index_map(results, fn(r, i) {
        let #(title, url, desc, extras) = r
        let base =
          int.to_string(i + 1)
          <> ". "
          <> title
          <> "\n   "
          <> url
          <> "\n   "
          <> desc
        case extras {
          [] -> base
          snippets ->
            base <> "\n   Extra context:\n   " <> string.join(snippets, "\n   ")
        }
      })
      |> string.join("\n\n")
  }
}
