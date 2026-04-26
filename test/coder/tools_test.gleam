// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleeunit/should
import llm/types as llm_types
import tools/coder

// ── Tool surface contract ─────────────────────────────────────────────────
//
// These tests pin the published tool names. The agent's system prompt
// names every tool by its exact identifier; if the constructors here
// drift, the agent's prompt becomes a lie. Tests catch the drift.
//
// R6 collapsed `tools/coder.gleam` to only the host-side project_*
// tools. Session control moved to tools/coder_dispatch.gleam; host-side
// verification (run_tests/build/format) was removed entirely as
// scaffolding around an autonomous coder.

pub fn tool_surface_lists_expected_tools_test() {
  let names =
    coder.all()
    |> list.map(fn(t: llm_types.Tool) { t.name })

  names |> list.contains("project_status") |> should.be_true
  names |> list.contains("project_read") |> should.be_true
  names |> list.contains("project_grep") |> should.be_true
}

pub fn tool_surface_has_no_duplicates_test() {
  let names =
    coder.all()
    |> list.map(fn(t: llm_types.Tool) { t.name })
  list.length(names)
  |> should.equal(list.unique(names) |> list.length)
}

pub fn tool_count_is_three_test() {
  // Pin: only project_* tools live here after R6.
  list.length(coder.all())
  |> should.equal(3)
}

pub fn is_project_tool_recognises_set_test() {
  coder.is_project_tool("project_status") |> should.be_true
  coder.is_project_tool("project_read") |> should.be_true
  coder.is_project_tool("project_grep") |> should.be_true
  coder.is_project_tool("dispatch_coder") |> should.be_false
  coder.is_project_tool("run_tests") |> should.be_false
}
