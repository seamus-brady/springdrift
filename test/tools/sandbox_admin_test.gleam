// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/string
import gleeunit/should
import llm/types as llm_types
import tools/sandbox_admin

fn make_call(input: String) -> llm_types.ToolCall {
  llm_types.ToolCall(id: "t1", name: "sandbox_reset", input_json: input)
}

fn images() -> sandbox_admin.ResetImages {
  sandbox_admin.ResetImages(
    sandbox_image: "python:3.12-slim",
    coder_image: "springdrift-coder:test",
  )
}

// ── Tool surface ───────────────────────────────────────────────────────────

pub fn reset_tool_name_test() {
  sandbox_admin.reset_tool().name
  |> should.equal("sandbox_reset")
}

pub fn is_sandbox_admin_tool_recognises_reset_test() {
  sandbox_admin.is_sandbox_admin_tool("sandbox_reset")
  |> should.be_true
}

pub fn is_sandbox_admin_tool_rejects_other_test() {
  sandbox_admin.is_sandbox_admin_tool("run_code")
  |> should.be_false
  sandbox_admin.is_sandbox_admin_tool("dispatch_coder")
  |> should.be_false
}

// ── execute: no podman / no matching containers ────────────────────────────
//
// In the test environment podman is either absent or has no
// springdrift-* containers. Either way, the executor must not crash —
// it returns a ToolSuccess with a zero-count summary. This is the
// "safe to call when nothing's wrong" promise the tool description
// makes to the agent.

pub fn execute_with_defaults_returns_summary_test() {
  let result = sandbox_admin.execute(make_call("{}"), images())
  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      string.contains(content, "springdrift-sandbox-")
      |> should.be_true
      string.contains(content, "springdrift-coder-")
      |> should.be_true
    }
    llm_types.ToolFailure(error:, ..) -> {
      // Should not happen — the executor swallows podman errors and
      // reports zero counts. If it does, surface the message.
      should.equal(error, "(should be ToolSuccess)")
      Nil
    }
  }
}

pub fn execute_with_purge_coder_false_skips_coder_test() {
  let result =
    sandbox_admin.execute(make_call("{\"purge_coder\": false}"), images())
  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      // Coder leg should be marked as skipped in the summary.
      string.contains(content, "skipped")
      |> should.be_true
    }
    llm_types.ToolFailure(error:, ..) -> {
      should.equal(error, "(should be ToolSuccess)")
      Nil
    }
  }
}

pub fn execute_with_invalid_json_uses_defaults_test() {
  // Bad JSON should not crash — defaults apply. This protects the
  // agent from accidentally locking itself out of the recovery tool
  // by sending a malformed payload.
  let result = sandbox_admin.execute(make_call("not json"), images())
  case result {
    llm_types.ToolSuccess(..) -> Nil
    llm_types.ToolFailure(error:, ..) -> {
      should.equal(error, "(should be ToolSuccess on bad JSON)")
      Nil
    }
  }
}

pub fn unknown_tool_name_returns_failure_test() {
  let call = llm_types.ToolCall(id: "x", name: "not_a_tool", input_json: "{}")
  case sandbox_admin.execute(call, images()) {
    llm_types.ToolFailure(error:, ..) -> {
      string.contains(error, "Unknown sandbox_admin tool")
      |> should.be_true
    }
    llm_types.ToolSuccess(..) -> {
      should.equal("ToolSuccess", "(should be ToolFailure)")
      Nil
    }
  }
}

// ── purge_by_prefix: zero-match safety ─────────────────────────────────────
//
// With a deliberately weird prefix, no containers match and the
// helper returns 0. Confirms the predicate's "safe when nothing
// matches" path independent of the executor.

pub fn purge_by_prefix_no_match_test() {
  sandbox_admin.purge_by_prefix("springdrift-doesnotexist-prefix")
  |> should.equal(0)
}
