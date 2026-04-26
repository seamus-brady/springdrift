// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import coder/circuit
import coder/types
import gleeunit/should

// ── Fixtures ───────────────────────────────────────────────────────────────

fn cfg() -> types.CoderConfig {
  types.CoderConfig(
    image: "springdrift-coder:test",
    project_root: "/tmp/proj",
    session_timeout_ms: 600_000,
    max_tokens_per_task: 200_000,
    max_cost_per_task_usd: 5.0,
    max_cost_per_hour_usd: 20.0,
    cost_poll_interval_ms: 5000,
    provider_id: "anthropic",
    model_id: "claude-sonnet-4-20250514",
  )
}

fn usage(tokens: Int, cost: Float) -> types.SessionUsage {
  types.SessionUsage(
    prompt_tokens: tokens / 2,
    completion_tokens: tokens / 2,
    total_tokens: tokens,
    cost_usd: cost,
    message_count: 1,
  )
}

// ── evaluate/4: under all caps ─────────────────────────────────────────────

pub fn continue_when_under_all_caps_test() {
  let h = circuit.new_hourly(0)
  circuit.evaluate(usage(50_000, 0.5), h, cfg(), 1000)
  |> should.equal(circuit.Continue)
}

// ── evaluate/4: per-task token cap ─────────────────────────────────────────

pub fn kill_task_on_token_cap_test() {
  let h = circuit.new_hourly(0)
  case circuit.evaluate(usage(250_000, 0.1), h, cfg(), 1000) {
    circuit.KillTask(types.TokenBudgetExceeded(consumed: 250_000, cap: 200_000)) ->
      Nil
    other -> {
      should.equal(other, circuit.KillTask(types.TokenBudgetExceeded(0, 0)))
      Nil
    }
  }
}

// ── evaluate/4: per-task cost cap ──────────────────────────────────────────

pub fn kill_task_on_cost_cap_test() {
  let h = circuit.new_hourly(0)
  case circuit.evaluate(usage(50_000, 7.5), h, cfg(), 1000) {
    circuit.KillTask(types.CostBudgetExceeded(consumed_usd: c_usd, cap_usd: cap)) -> {
      c_usd
      |> should.equal(7.5)
      cap
      |> should.equal(5.0)
    }
    other -> {
      should.equal(other, circuit.KillTask(types.CostBudgetExceeded(0.0, 0.0)))
      Nil
    }
  }
}

// ── evaluate/4: hourly takes precedence over per-task ──────────────────────
// If both per-task and hourly would fire, hourly wins because it's the
// stricter signal — the supervisor needs to refuse new sessions too.

pub fn hourly_outranks_task_when_both_exceeded_test() {
  // Already $19 in this hour; this session is at $1.50 (over per-task
  // cap of $5? No — well under). But $19 + $1.50 = $20.50 > $20 hourly.
  let h = circuit.HourlyCost(accumulated_usd: 19.0, window_started_at_ms: 0)
  case circuit.evaluate(usage(50_000, 1.5), h, cfg(), 1000) {
    circuit.KillHourly(types.HourlyBudgetExceeded(
      consumed_usd: total,
      cap_usd: cap,
    )) -> {
      total
      |> should.equal(20.5)
      cap
      |> should.equal(20.0)
    }
    other -> {
      should.equal(
        other,
        circuit.KillHourly(types.HourlyBudgetExceeded(0.0, 0.0)),
      )
      Nil
    }
  }
}

// ── evaluate/4: hourly with task-cost breach also yields KillHourly ────────

pub fn hourly_wins_over_task_cost_when_both_breach_test() {
  // Hourly $18 + task $7 = $25 > $20 hourly, AND task $7 > $5 task cap.
  let h = circuit.HourlyCost(accumulated_usd: 18.0, window_started_at_ms: 0)
  case circuit.evaluate(usage(50_000, 7.0), h, cfg(), 1000) {
    circuit.KillHourly(_) -> Nil
    other -> {
      should.equal(
        other,
        circuit.KillHourly(types.HourlyBudgetExceeded(0.0, 0.0)),
      )
      Nil
    }
  }
}

// ── maybe_roll_hourly/2 ────────────────────────────────────────────────────

pub fn maybe_roll_keeps_window_within_hour_test() {
  let h = circuit.HourlyCost(accumulated_usd: 5.0, window_started_at_ms: 0)
  // 30 minutes in
  let after = circuit.maybe_roll_hourly(h, 1_800_000)
  after.accumulated_usd
  |> should.equal(5.0)
  after.window_started_at_ms
  |> should.equal(0)
}

pub fn maybe_roll_rolls_after_hour_test() {
  let h = circuit.HourlyCost(accumulated_usd: 5.0, window_started_at_ms: 0)
  // Exactly one hour
  let after = circuit.maybe_roll_hourly(h, 3_600_000)
  after.accumulated_usd
  |> should.equal(0.0)
  after.window_started_at_ms
  |> should.equal(3_600_000)
}

pub fn maybe_roll_rolls_well_after_hour_test() {
  let h = circuit.HourlyCost(accumulated_usd: 5.0, window_started_at_ms: 0)
  // Two hours later
  let after = circuit.maybe_roll_hourly(h, 7_200_000)
  after.accumulated_usd
  |> should.equal(0.0)
  after.window_started_at_ms
  |> should.equal(7_200_000)
}

// ── add_session_cost/3 ─────────────────────────────────────────────────────

pub fn add_session_cost_within_window_test() {
  let h = circuit.HourlyCost(accumulated_usd: 3.0, window_started_at_ms: 0)
  let after = circuit.add_session_cost(h, 2.5, 1_000_000)
  after.accumulated_usd
  |> should.equal(5.5)
  after.window_started_at_ms
  |> should.equal(0)
}

pub fn add_session_cost_resets_after_window_roll_test() {
  // Window started at 0, "now" is past one hour. add_session_cost should
  // roll first, then add to the fresh accumulator.
  let h = circuit.HourlyCost(accumulated_usd: 18.0, window_started_at_ms: 0)
  let after = circuit.add_session_cost(h, 2.5, 4_000_000)
  after.accumulated_usd
  |> should.equal(2.5)
  after.window_started_at_ms
  |> should.equal(4_000_000)
}

// ── new_hourly/1 ───────────────────────────────────────────────────────────

pub fn new_hourly_starts_at_zero_test() {
  let h = circuit.new_hourly(12_345)
  h.accumulated_usd
  |> should.equal(0.0)
  h.window_started_at_ms
  |> should.equal(12_345)
}
