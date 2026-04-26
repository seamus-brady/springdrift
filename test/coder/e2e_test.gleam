//// End-to-end coder dispatch test.
////
//// Spawns a real OpenCode container, runs one `dispatch_coder`-style
//// round-trip via the manager, asserts the response shape and the
//// CBR ingest landed. Costs a couple of cents per run.
////
//// Gated by `SPRINGDRIFT_CODER_E2E=1`. Without that env var the test
//// is a no-op so `gleam test` stays free in normal CI.
////
//// Required env (loaded by `scripts/e2e-coder.sh`):
////   SPRINGDRIFT_CODER_E2E=1
////   SPRINGDRIFT_CODER_E2E_PROJECT_ROOT=$HOME/coder-e2e-workspace
////   SPRINGDRIFT_CODER_PROVIDER_ID=anthropic
////   SPRINGDRIFT_CODER_MODEL_ID=<a model in the operator's bundle>
////   ANTHROPIC_API_KEY=<...>
////
//// Success signal: the script greps stdout for `[e2e] dispatch ok`.
//// That string only prints when:
////   - manager.start succeeded
////   - dispatch_task returned Ok
////   - response_text contained "pong"
////   - the CBR case file got an entry for this session
////   - manager.shutdown completed

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import coder/manager
import coder/types as coder_types
import gleam/io
import gleam/option.{None}
import gleam/result
import gleam/string
import gleeunit/should
import simplifile

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

const e2e_image: String = "springdrift-coder:latest"

const e2e_session_timeout_ms: Int = 180_000

const e2e_max_cost_per_task_usd: Float = 0.5

const e2e_max_cost_per_hour_usd: Float = 2.0

pub fn dispatch_coder_round_trip_test() {
  case get_env("SPRINGDRIFT_CODER_E2E") {
    Ok("1") -> run_e2e()
    _ -> {
      io.println("[e2e] skipped (set SPRINGDRIFT_CODER_E2E=1 to run)")
      Nil
    }
  }
}

fn run_e2e() -> Nil {
  io.println("[e2e] start")

  let project_root =
    get_env("SPRINGDRIFT_CODER_E2E_PROJECT_ROOT")
    |> result.unwrap("/tmp/coder-e2e-workspace")
  let provider_id =
    get_env("SPRINGDRIFT_CODER_PROVIDER_ID")
    |> result.unwrap("anthropic")
  let model_id =
    get_env("SPRINGDRIFT_CODER_MODEL_ID")
    |> result.unwrap("")
  let api_key =
    get_env("ANTHROPIC_API_KEY")
    |> result.unwrap("")

  case model_id, api_key {
    "", _ -> {
      io.println("[e2e] FAIL: SPRINGDRIFT_CODER_MODEL_ID is empty")
      should.fail()
      Nil
    }
    _, "" -> {
      io.println("[e2e] FAIL: ANTHROPIC_API_KEY is empty")
      should.fail()
      Nil
    }
    _, _ -> run_dispatch(project_root, provider_id, model_id, api_key)
  }
}

fn run_dispatch(
  project_root: String,
  provider_id: String,
  model_id: String,
  api_key: String,
) -> Nil {
  // Use scratch dirs so the test never pollutes a live agent's CBR
  // log or session archive.
  let cbr_dir = "/tmp/coder-e2e-cbr"
  let sessions_dir = "/tmp/coder-e2e-sessions"
  let _ = simplifile.create_directory_all(cbr_dir)
  let _ = simplifile.create_directory_all(sessions_dir)

  let coder_config =
    coder_types.CoderConfig(
      image: e2e_image,
      project_root: project_root,
      session_timeout_ms: e2e_session_timeout_ms,
      // These three are inert in the manager today (cost gate sits on
      // the rolling-hour pool), but populating them keeps the config
      // record valid and matches what springdrift.gleam wires in.
      max_tokens_per_task: 50_000,
      max_cost_per_task_usd: e2e_max_cost_per_task_usd,
      max_cost_per_hour_usd: e2e_max_cost_per_hour_usd,
      cost_poll_interval_ms: 5000,
      provider_id: provider_id,
      model_id: model_id,
      image_recovery_enabled: True,
      image_pull_timeout_ms: 300_000,
    )

  let pool_config =
    manager.pool_config_from_options(
      warm_pool_size: None,
      max_concurrent_sessions: None,
      container_idle_ttl_ms: None,
      container_name_prefix: None,
      slot_id_base: None,
      container_memory_mb: None,
      container_cpus: None,
      container_pids_limit: None,
    )

  case
    manager.start(coder_config, api_key, cbr_dir, sessions_dir, pool_config)
  {
    Error(reason) -> {
      io.println("[e2e] FAIL: manager.start: " <> reason)
      should.fail()
      Nil
    }
    Ok(mgr) -> {
      let budget =
        coder_types.TaskBudget(
          max_tokens: 8000,
          max_cost_usd: e2e_max_cost_per_task_usd,
          max_minutes: 3,
          max_turns: 4,
        )
      // The brief asks for an exact answer ("pong") so we can
      // substring-match deterministically without parsing prose.
      let brief =
        "Reply with exactly the word 'pong' on its own line. "
        <> "Do not call any tools. Do not edit any files."

      io.println("[e2e] dispatching")
      case manager.dispatch_task(mgr, brief, budget) {
        Error(e) -> {
          io.println(
            "[e2e] FAIL: dispatch_task: " <> coder_types.format_error(e),
          )
          let _ = manager.shutdown(mgr)
          should.fail()
          Nil
        }
        Ok(result) -> {
          io.println(
            "[e2e] dispatch returned: stop_reason="
            <> result.stop_reason
            <> " tokens="
            <> int_to_string(result.total_tokens)
            <> " cost="
            <> float_to_string(result.cost_usd),
          )

          // Assertion 1: the model produced "pong".
          let lower = string.lowercase(result.response_text)
          case string.contains(lower, "pong") {
            True -> Nil
            False -> {
              io.println(
                "[e2e] FAIL: response_text missing 'pong': "
                <> string.slice(result.response_text, 0, 200),
              )
              let _ = manager.shutdown(mgr)
              should.fail()
              Nil
            }
          }

          // Assertion 2: the session was archived.
          let archive_path = sessions_dir <> "/" <> result.session_id <> ".json"
          case simplifile.is_file(archive_path) {
            Ok(True) -> Nil
            _ -> {
              io.println("[e2e] FAIL: archive missing at " <> archive_path)
              let _ = manager.shutdown(mgr)
              should.fail()
              Nil
            }
          }

          // Assertion 3: the CBR log got an entry. The day-stamp
          // filename is set inside cbr_log; we just check the dir is
          // non-empty.
          case simplifile.read_directory(cbr_dir) {
            Ok([_, ..]) -> Nil
            _ -> {
              io.println("[e2e] FAIL: CBR dir empty after dispatch")
              let _ = manager.shutdown(mgr)
              should.fail()
              Nil
            }
          }

          let _ = manager.shutdown(mgr)
          io.println("[e2e] dispatch ok")
          Nil
        }
      }
    }
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String

@external(erlang, "erlang", "float_to_binary")
fn float_to_binary_raw(f: Float, opts: List(FloatOpt)) -> String

type FloatOpt {
  Decimals(Int)
  Compact
}

fn float_to_string(f: Float) -> String {
  float_to_binary_raw(f, [Decimals(4), Compact])
}
