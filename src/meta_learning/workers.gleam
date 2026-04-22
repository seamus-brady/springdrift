//// Meta-learning worker registry. Builds the list of BEAM workers
//// from `AppConfig` and spawns each under its own OTP process. Called
//// from `springdrift.gleam` at startup, after the Librarian and the
//// Remembrancer context are ready.
////
//// Three workers run here — the mechanical audits that don't need the
//// cognitive loop:
////
////   1. `affect_correlation`  — Pearson correlation over affect data
////   2. `fabrication_audit`   — synthesis-fact vs tool-log audit
////   3. `voice_drift`         — self-narration phrase counting
////
//// Judgement jobs (goal review, strategy review, skill decay,
//// consolidation) remain on the scheduler, idle-gated by Phase 1.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import config.{type AppConfig}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option
import meta_learning/worker.{type WorkerConfig, type WorkerMessage, WorkerConfig}
import paths
import simplifile
import slog
import tools/remembrancer as tools_remembrancer

// ---------------------------------------------------------------------------
// Defaults (hours) — mirror the retired scheduler-job cadences
// ---------------------------------------------------------------------------

const default_affect_correlation_hours = 168

const default_fabrication_audit_hours = 24

const default_voice_drift_hours = 24

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start every enabled meta-learning worker. Returns the list of their
/// subjects so the caller can shut them down on exit. Safe to call
/// with workers disabled — returns the empty list.
pub fn start_all(
  cfg: AppConfig,
  remembrancer_ctx: tools_remembrancer.RemembrancerContext,
) -> List(Subject(WorkerMessage)) {
  case option.unwrap(cfg.meta_scheduler_enabled, True) {
    False -> {
      slog.info(
        "meta_learning/workers",
        "start_all",
        "Meta-learning workers disabled via config",
        option.None,
      )
      []
    }
    True -> {
      // Ensure the sidecar directory exists up-front.
      let _ = simplifile.create_directory_all(paths.meta_learning_dir())
      let state_file = paths.meta_learning_state_file()

      let configs = [
        affect_correlation_config(cfg),
        fabrication_audit_config(cfg),
        voice_drift_config(cfg),
      ]
      let subjects =
        list.map(configs, fn(wc) {
          worker.start(wc, remembrancer_ctx, state_file)
        })
      slog.info(
        "meta_learning/workers",
        "start_all",
        "Started 3 meta-learning BEAM workers (affect_correlation, "
          <> "fabrication_audit, voice_drift)",
        option.None,
      )
      subjects
    }
  }
}

// ---------------------------------------------------------------------------
// Per-worker configs
// ---------------------------------------------------------------------------

fn affect_correlation_config(cfg: AppConfig) -> WorkerConfig {
  let hours =
    option.unwrap(
      cfg.meta_affect_correlation_interval_hours,
      default_affect_correlation_hours,
    )
  WorkerConfig(
    name: "affect_correlation",
    tool_name: "analyze_affect_performance",
    interval_ms: hours_to_ms(hours),
  )
}

fn fabrication_audit_config(cfg: AppConfig) -> WorkerConfig {
  let hours =
    option.unwrap(
      cfg.meta_fabrication_audit_interval_hours,
      default_fabrication_audit_hours,
    )
  WorkerConfig(
    name: "fabrication_audit",
    tool_name: "audit_fabrication",
    interval_ms: hours_to_ms(hours),
  )
}

fn voice_drift_config(cfg: AppConfig) -> WorkerConfig {
  let hours =
    option.unwrap(
      cfg.meta_voice_drift_interval_hours,
      default_voice_drift_hours,
    )
  WorkerConfig(
    name: "voice_drift",
    tool_name: "audit_voice_drift",
    interval_ms: hours_to_ms(hours),
  )
}

fn hours_to_ms(hours: Int) -> Int {
  hours * 60 * 60 * 1000
}
