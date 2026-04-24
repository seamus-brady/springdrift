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
