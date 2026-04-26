// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import coder/types
import gleam/string
import gleeunit/should

// format_error/1 is the surface the coder agent's prompt sees. These
// tests pin the wording shape — not character-perfect strings, but the
// signal each branch needs to carry: the path the operator should take
// next.

pub fn format_image_missing_test() {
  let msg =
    types.format_error(types.ImageMissing(image: "springdrift-coder:0.4.7"))
  msg
  |> string.contains("springdrift-coder:0.4.7")
  |> should.be_true

  msg
  |> string.contains("scripts/build-coder-image.sh")
  |> should.be_true
}

pub fn format_project_root_forbidden_test() {
  let msg =
    types.format_error(types.ProjectRootForbidden(
      reason: "contains .springdrift",
    ))
  msg
  |> string.contains("forbidden")
  |> should.be_true
  msg
  |> string.contains(".springdrift")
  |> should.be_true
}

pub fn format_auth_missing_test() {
  let msg = types.format_error(types.AuthMissing)
  msg
  |> string.contains("ANTHROPIC_API_KEY")
  |> should.be_true
  msg
  |> string.contains(".env")
  |> should.be_true
}

pub fn format_token_budget_exceeded_test() {
  let msg =
    types.format_error(types.TokenBudgetExceeded(
      consumed: 250_000,
      cap: 200_000,
    ))
  msg
  |> string.contains("token budget")
  |> should.be_true
  msg
  |> string.contains("250000")
  |> should.be_true
  msg
  |> string.contains("200000")
  |> should.be_true
}

pub fn format_cost_budget_exceeded_test() {
  let msg =
    types.format_error(types.CostBudgetExceeded(consumed_usd: 7.5, cap_usd: 5.0))
  msg
  |> string.contains("cost budget")
  |> should.be_true
  msg
  |> string.contains("$7.5")
  |> should.be_true
  msg
  |> string.contains("$5.0")
  |> should.be_true
}

pub fn format_hourly_budget_exceeded_test() {
  let msg =
    types.format_error(types.HourlyBudgetExceeded(
      consumed_usd: 21.0,
      cap_usd: 20.0,
    ))
  msg
  |> string.contains("hourly")
  |> should.be_true
  msg
  |> string.contains("coder_max_cost_per_hour_usd")
  |> should.be_true
}

pub fn format_health_timeout_seconds_test() {
  // 30_000 ms → "30 seconds"
  let msg = types.format_error(types.HealthTimeout(elapsed_ms: 30_000))
  msg
  |> string.contains("30 seconds")
  |> should.be_true
}

pub fn format_session_crashed_includes_log_test() {
  let msg =
    types.format_error(types.SessionCrashed(
      exit_code: 1,
      log_tail: "FATAL: provider not configured",
    ))
  msg
  |> string.contains("exit 1")
  |> should.be_true
  msg
  |> string.contains("FATAL: provider not configured")
  |> should.be_true
}

pub fn format_session_not_found_test() {
  let msg = types.format_error(types.SessionNotFound(session_id: "ses_abc123"))
  msg
  |> string.contains("ses_abc123")
  |> should.be_true
}
