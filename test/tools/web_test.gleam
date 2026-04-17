// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleeunit
import gleeunit/should
import llm/types.{ToolCall, ToolFailure}
import tools/web

pub fn main() -> Nil {
  gleeunit.main()
}

// Expose the FFI helper for direct testing. Keeps tests pure — no network.
@external(erlang, "springdrift_ffi", "is_binary_content_type_header")
fn is_binary_content_type(content_type: String) -> Bool

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn fetch_url_tool_defined_test() {
  let tools = web.all()
  tools |> should.not_equal([])
}

pub fn fetch_url_tool_has_url_param_test() {
  let tools = web.all()
  let assert [t, ..] = tools
  t.name |> should.equal("fetch_url")
  list.contains(t.required_params, "url") |> should.be_true
}

// ---------------------------------------------------------------------------
// URL validation
// ---------------------------------------------------------------------------

pub fn fetch_url_non_http_scheme_returns_failure_test() {
  let call =
    ToolCall(
      id: "w1",
      name: "fetch_url",
      input_json: "{\"url\":\"ftp://example.com/file\"}",
    )
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

pub fn fetch_url_file_scheme_returns_failure_test() {
  let call =
    ToolCall(
      id: "w2",
      name: "fetch_url",
      input_json: "{\"url\":\"file:///etc/passwd\"}",
    )
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

pub fn fetch_url_missing_input_returns_failure_test() {
  let call = ToolCall(id: "w3", name: "fetch_url", input_json: "{}")
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// web_search
// ---------------------------------------------------------------------------

pub fn web_search_tool_defined_test() {
  let tools = web.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "web_search") |> should.be_true
}

pub fn web_search_missing_query_returns_failure_test() {
  let call = ToolCall(id: "s1", name: "web_search", input_json: "{}")
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Tool count
// ---------------------------------------------------------------------------

pub fn all_tools_count_test() {
  let tools = web.all()
  tools |> list.length |> should.equal(2)
}

// ---------------------------------------------------------------------------
// Unknown tool
// ---------------------------------------------------------------------------

pub fn unknown_web_tool_returns_failure_test() {
  let call = ToolCall(id: "u1", name: "unknown_search", input_json: "{}")
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// is_web_tool covers all tool sets
// ---------------------------------------------------------------------------

pub fn is_web_tool_covers_ddg_test() {
  web.is_web_tool("fetch_url") |> should.be_true
  web.is_web_tool("web_search") |> should.be_true
}

pub fn is_web_tool_covers_brave_test() {
  web.is_web_tool("brave_web_search") |> should.be_true
  web.is_web_tool("brave_news_search") |> should.be_true
  web.is_web_tool("brave_llm_context") |> should.be_true
  web.is_web_tool("brave_summarizer") |> should.be_true
  web.is_web_tool("brave_answer") |> should.be_true
}

pub fn is_web_tool_covers_jina_test() {
  web.is_web_tool("jina_reader") |> should.be_true
}

pub fn is_web_tool_rejects_unknown_test() {
  web.is_web_tool("unknown_tool") |> should.be_false
}

// ---------------------------------------------------------------------------
// Binary content-type detection
//
// Three researcher workers crashed on 2026-04-16 after fetch_url returned PDF
// binary bytes; the subsequent LLM request or downstream string ops panicked
// silently. The FFI now refuses known binary content-types before returning
// the body. These tests cover the classifier.
// ---------------------------------------------------------------------------

pub fn content_type_pdf_is_binary_test() {
  is_binary_content_type("application/pdf") |> should.be_true
}

pub fn content_type_pdf_with_charset_is_binary_test() {
  // Some servers attach a charset even to pdf — prefix match must still catch it
  is_binary_content_type("application/pdf; charset=binary") |> should.be_true
}

pub fn content_type_zip_is_binary_test() {
  is_binary_content_type("application/zip") |> should.be_true
}

pub fn content_type_octet_stream_is_binary_test() {
  is_binary_content_type("application/octet-stream") |> should.be_true
}

pub fn content_type_image_is_binary_test() {
  is_binary_content_type("image/png") |> should.be_true
  is_binary_content_type("image/jpeg") |> should.be_true
  is_binary_content_type("image/webp") |> should.be_true
}

pub fn content_type_video_audio_font_are_binary_test() {
  is_binary_content_type("video/mp4") |> should.be_true
  is_binary_content_type("audio/mpeg") |> should.be_true
  is_binary_content_type("font/woff2") |> should.be_true
}

pub fn content_type_html_is_text_test() {
  is_binary_content_type("text/html") |> should.be_false
  is_binary_content_type("text/html; charset=utf-8") |> should.be_false
}

pub fn content_type_json_is_text_test() {
  is_binary_content_type("application/json") |> should.be_false
  is_binary_content_type("application/json; charset=utf-8") |> should.be_false
}

pub fn content_type_case_insensitive_test() {
  // Headers may arrive with any case
  is_binary_content_type("Application/PDF") |> should.be_true
  is_binary_content_type("IMAGE/PNG") |> should.be_true
  is_binary_content_type("Text/HTML") |> should.be_false
}

pub fn content_type_application_x_is_binary_test() {
  // application/x-* family (executables, archives, etc.) — refuse by default
  is_binary_content_type("application/x-gzip") |> should.be_true
  is_binary_content_type("application/x-msdownload") |> should.be_true
}
