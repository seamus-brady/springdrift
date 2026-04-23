//// Pure-logic tests for the researcher agent — auto-store wrap decision
//// and preview rendering.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agents/researcher
import gleam/list
import gleam/string
import gleeunit/should

pub fn should_auto_store_web_tools_test() {
  // Network-fetching tools that can return bulky bodies — must auto-store.
  let web_tools = [
    "fetch_url", "web_search", "jina_reader", "kagi_search", "kagi_summarize",
    "brave_web_search", "brave_news_search", "brave_llm_context",
    "brave_summarizer", "brave_answer",
  ]
  list.each(web_tools, fn(t) { should.be_true(researcher.should_auto_store(t)) })
}

pub fn should_not_auto_store_artifact_tools_test() {
  // store_result/retrieve_result must be excluded — storing their output
  // would recursively wrap the confirmation string or the freshly
  // retrieved content.
  should.be_false(researcher.should_auto_store("store_result"))
  should.be_false(researcher.should_auto_store("retrieve_result"))
}

pub fn should_not_auto_store_builtin_tools_test() {
  // Builtin and knowledge tools return small structured output — no need
  // to auto-store, and wrapping would corrupt JSON/structured responses.
  let excluded = [
    "save_to_library", "search_library", "read_section", "get_document",
    "calculator", "get_current_datetime", "request_human_input", "read_skill",
  ]
  list.each(excluded, fn(t) { should.be_false(researcher.should_auto_store(t)) })
}

pub fn preview_includes_artifact_id_and_char_count_test() {
  let content =
    "This is a fairly long body of text that the researcher just fetched from the web."
  let wrapped =
    researcher.render_auto_store_preview(
      content,
      "jina_reader",
      "art-deadbeef",
      // threshold 8192 → preview ~2048 chars; our content is shorter so the
      // whole thing goes into preview.
      8192,
    )
  should.be_true(string.contains(wrapped, "art-deadbeef"))
  should.be_true(string.contains(wrapped, "jina_reader"))
  should.be_true(string.contains(wrapped, "retrieve_result"))
  should.be_true(string.contains(wrapped, "Auto-stored"))
  // Full content should be present as the preview since it's under threshold/4
  should.be_true(string.contains(wrapped, content))
}

pub fn preview_truncates_to_quarter_of_threshold_test() {
  // Large body with a distinctive marker at the end. Preview = threshold/4
  // = 1000 chars, so "STARTMARK" (at char 0) should appear in the wrapped
  // output, but "ENDMARKER" (at char 4991) should not.
  let body = "STARTMARK" <> string.repeat("-", 4982) <> "ENDMARKER"
  should.equal(string.length(body), 5000)
  let wrapped =
    researcher.render_auto_store_preview(
      body,
      "jina_reader",
      "art-xyz",
      // threshold 4000 → preview 1000 chars
      4000,
    )
  should.be_true(string.contains(wrapped, "STARTMARK"))
  should.be_false(string.contains(wrapped, "ENDMARKER"))
  // Full char count is mentioned so the agent knows how much is missing.
  should.be_true(string.contains(wrapped, "5000"))
}

pub fn preview_references_retrieve_result_tool_test() {
  // The agent must be told explicitly how to get the full content back.
  let wrapped =
    researcher.render_auto_store_preview(
      "hello world",
      "jina_reader",
      "art-abc",
      100,
    )
  should.be_true(string.contains(wrapped, "retrieve_result"))
  should.be_true(string.contains(wrapped, "art-abc"))
}
