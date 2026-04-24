//// Phase 4 test — the writer specialist's system prompt carries the
//// handoff summary section. Writer is a stand-in for all 8 specialists;
//// they were updated simultaneously and should stay in sync. A future
//// rewrite of one should carry the section forward.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agents/writer
import gleam/option.{None}
import gleam/string
import gleeunit/should
import llm/adapters/mock

pub fn writer_prompt_has_handoff_summary_test() {
  let provider = mock.provider_with_text("ignored")
  let spec = writer.spec(provider, "test-model", "/tmp", None, 50_000)
  spec.system_prompt
  |> string.contains("Before you return")
  |> should.be_true
  spec.system_prompt
  |> string.contains("Interpreted as:")
  |> should.be_true
}

pub fn writer_prompt_defaults_to_draft_for_long_work_test() {
  // Guard against prompt regressions that take the writer back to
  // "inline-return everything" — that pattern blows past the output
  // token cap on any multi-section report and silently loses work.
  let provider = mock.provider_with_text("ignored")
  let spec = writer.spec(provider, "test-model", "/tmp", None, 50_000)
  // Must instruct to use create_draft for long output.
  spec.system_prompt
  |> string.contains("create_draft")
  |> should.be_true
  // Must warn about the token cap so the model doesn't just ignore it.
  spec.system_prompt
  |> string.contains("output token cap")
  |> should.be_true
}

pub fn writer_prompt_documents_revise_flow_test() {
  // PR 4: writer prompt must teach the revise flow so draft_slug
  // refs trigger read → update rather than create-over-top.
  let provider = mock.provider_with_text("ignored")
  let spec = writer.spec(provider, "test-model", "/tmp", None, 50_000)
  // Mentions draft_slug as the trigger ref.
  spec.system_prompt
  |> string.contains("draft_slug")
  |> should.be_true
  // Mentions read_draft as the first step.
  spec.system_prompt
  |> string.contains("read_draft")
  |> should.be_true
  // Explicitly warns not to use create_draft when revising.
  spec.system_prompt
  |> string.contains("update_draft")
  |> should.be_true
}
