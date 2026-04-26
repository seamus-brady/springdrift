//// Coder agent types — embedded OpenCode session lifecycle.
////
//// Phase 2 of the real-coder roadmap. See
//// docs/roadmap/planned/real-coder-opencode.md for the architecture.
////
//// These types model Springdrift's view of an OpenCode session. The
//// wire-level encoding from OpenCode's HTTP API is decoded into these
//// shapes by src/coder/client.gleam; downstream consumers (the
//// supervisor, CBR ingest, the coder agent's tools) only see these
//// types — they do not depend on OpenCode's response schema.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// ---------------------------------------------------------------------------
// Identifiers
// ---------------------------------------------------------------------------

/// An OpenCode-issued session identifier. Opaque to Springdrift —
/// produced by `POST /session` (or whatever the discovered session-
/// creation endpoint turns out to be).
pub type SessionId =
  String

/// Container ID returned by `podman run`. Used by the supervisor for
/// lifecycle control; never exposed to the coder agent's tools.
pub type ContainerId =
  String

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub type CoderConfig {
  CoderConfig(
    /// Image tag, e.g. "springdrift-coder:0.4.7". Operator's pinned
    /// version. Image must exist locally — supervisor does not pull.
    image: String,
    /// Host path bind-mounted into the slot at /workspace/project.
    /// Slot acquisition refuses if this contains or equals the
    /// .springdrift/ directory; the agent must not edit its own memory.
    project_root: String,
    /// Hard ceiling on a single coding task's wall time. Beyond this
    /// the supervisor force-kills the slot regardless of token state.
    session_timeout_ms: Int,
    /// Max tokens (prompt + completion) one task may consume before
    /// the circuit breaker terminates it.
    max_tokens_per_task: Int,
    /// Max cost (USD) one task may consume.
    max_cost_per_task_usd: Float,
    /// Max cost (USD) all coder tasks may consume in a rolling hour.
    max_cost_per_hour_usd: Float,
    /// Interval at which the supervisor polls session usage to feed
    /// the circuit breaker.
    cost_poll_interval_ms: Int,
    /// Provider id passed to OpenCode on every send_message
    /// (e.g. "anthropic"). Must match a provider OpenCode knows.
    provider_id: String,
    /// Model id passed to OpenCode on every send_message
    /// (e.g. "claude-sonnet-4-20250514"). Operator-set — must be in
    /// BOTH OpenCode's bundled models.dev catalog AND the API key's
    /// allowed list. See `real-coder-opencode-phase2-notes.md` §1.
    model_id: String,
  )
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Every operator-actionable failure mode the supervisor or client can
/// surface. Error messages are constructed by the formatter (see
/// format_error/1) so the coder agent's prompt sees consistent
/// wording across the codebase.
pub type CoderError {
  /// Configured image tag is not present locally. Operator should run
  /// scripts/build-coder-image.sh.
  ImageMissing(image: String)
  /// project_root resolves to or contains the .springdrift directory.
  ProjectRootForbidden(reason: String)
  /// project_root is not a directory or is unreadable.
  ProjectRootInvalid(path: String, reason: String)
  /// `podman run` returned a non-zero exit. Stderr passed through.
  ContainerStartFailed(reason: String)
  /// No ANTHROPIC_API_KEY (or any other configured provider key) was
  /// available at slot acquisition time. OpenCode cannot serve without
  /// at least one provider configured.
  AuthMissing
  /// `opencode serve` failed to bind. Log tail attached for forensics.
  ServeStartFailed(log_tail: String)
  /// Server did not answer any probe path within the readiness window.
  HealthTimeout(elapsed_ms: Int)
  /// OpenCode process exited mid-session. Exit code from the container,
  /// log tail from /tmp/opencode.log.
  SessionCrashed(exit_code: Int, log_tail: String)
  /// session_id does not match a tracked session. Indicates a bug in
  /// the supervisor or a session that was already torn down.
  SessionNotFound(session_id: SessionId)
  /// Circuit breaker fired on per-task token cap.
  TokenBudgetExceeded(consumed: Int, cap: Int)
  /// Circuit breaker fired on per-task cost cap.
  CostBudgetExceeded(consumed_usd: Float, cap_usd: Float)
  /// Circuit breaker fired on rolling-hour aggregate cost cap.
  HourlyBudgetExceeded(consumed_usd: Float, cap_usd: Float)
  /// HTTP-level failure talking to the in-container server (timeout,
  /// connection refused, malformed response).
  NetworkError(reason: String)
}

// ---------------------------------------------------------------------------
// Usage and events
// ---------------------------------------------------------------------------

/// A snapshot of how many tokens and dollars a session has consumed.
/// Polled from OpenCode at cost_poll_interval_ms cadence; fed into the
/// circuit breaker; persisted onto the resulting CBR case.
pub type SessionUsage {
  SessionUsage(
    prompt_tokens: Int,
    completion_tokens: Int,
    total_tokens: Int,
    cost_usd: Float,
    message_count: Int,
  )
}

/// Events surfaced from OpenCode's SSE stream. Intentionally narrower
/// than OpenCode's wire-level Part union — Springdrift only models the
/// shapes it acts on. Unknown part types from a future OpenCode version
/// are decoded into EventUnknown so they don't crash the consumer.
pub type CoderEvent {
  /// Natural-language output from the agent.
  EventText(content: String)
  /// Agent invoked a tool. params_json is the raw JSON-encoded params
  /// (preserved as-is for CBR fidelity; specific tools are interpreted
  /// downstream, not here).
  EventToolUse(tool: String, params_json: String)
  /// Tool returned a result. is_error reflects OpenCode's own
  /// classification, not Springdrift's verification.
  EventToolResult(tool: String, result_json: String, is_error: Bool)
  /// Session reached a natural completion point. The accompanying
  /// usage snapshot is the supervisor's last-seen state.
  EventCompletion(usage: SessionUsage)
  /// OpenCode collapsed older messages into a summary. Critical for
  /// CBR ingestion — a compacted session is lower-fidelity.
  EventCompacted(messages_before: Int, messages_after: Int)
  /// In-stream error.
  EventError(reason: String)
  /// Catch-all for unrecognised part shapes. The raw JSON is preserved
  /// so future code can decode them without re-running the session.
  EventUnknown(raw_json: String)
}

// ---------------------------------------------------------------------------
// Per-task budget — caps applied to one coder dispatch
// ---------------------------------------------------------------------------

/// A resolved per-task budget. Defaults filled in from CoderConfig,
/// caller can override (and the manager clamps each field against the
/// configured ceilings).
pub type TaskBudget {
  TaskBudget(
    max_tokens: Int,
    max_cost_usd: Float,
    max_minutes: Int,
    max_turns: Int,
  )
}

/// Reports from the manager when the operator's dispatch request was
/// clamped against a ceiling. Returned to the caller alongside the
/// dispatch result so they know what budget actually applied vs. what
/// they asked for.
pub type BudgetClamp {
  BudgetClamp(field: String, requested: String, clamped: String)
}

// ---------------------------------------------------------------------------
// Dispatch result — what the manager returns when a task completes
// ---------------------------------------------------------------------------

/// Reported back to the caller of `dispatch_task`. Captures everything
/// they need to record the outcome and decide what to do next.
pub type DispatchResult {
  DispatchResult(
    session_id: SessionId,
    stop_reason: String,
    response_text: String,
    total_tokens: Int,
    input_tokens: Int,
    output_tokens: Int,
    cost_usd: Float,
    duration_ms: Int,
    budget_clamps: List(BudgetClamp),
  )
}

/// Lightweight projection of an active session for `list_sessions`.
pub type SessionSummary {
  SessionSummary(
    session_id: SessionId,
    container_id: ContainerId,
    started_at_ms: Int,
    cost_usd_so_far: Float,
    tokens_so_far: Int,
  )
}

// ---------------------------------------------------------------------------
// Slot bookkeeping (used by the supervisor)
// ---------------------------------------------------------------------------

pub type SlotStatus {
  /// Container running, no session bound. Available for acquisition.
  Idle
  /// Session in progress. Carries the OpenCode session_id and the
  /// host port the in-container server is reachable on.
  Active(session_id: SessionId, host_port: Int)
  /// Container failed to start, exited unexpectedly, or was killed by
  /// the circuit breaker.
  SlotFailed(reason: String)
}

pub type CoderSlot {
  CoderSlot(
    slot_id: Int,
    container_id: ContainerId,
    host_port: Int,
    status: SlotStatus,
  )
}

// ---------------------------------------------------------------------------
// Error formatting
// ---------------------------------------------------------------------------

/// Render a CoderError into operator-actionable text. Same pattern as
/// intake.format_failure (cold-start) and pdf-export error formatting:
/// the coder agent's prompt sees consistent wording so it can map a
/// failure to the right next step without parsing structure.
pub fn format_error(err: CoderError) -> String {
  case err {
    ImageMissing(image) ->
      "Coder image '"
      <> image
      <> "' is not present locally. Run scripts/build-coder-image.sh "
      <> "to build it, then scripts/smoke-coder-image.sh to verify."

    ProjectRootForbidden(reason) -> "Coder project_root forbidden: " <> reason

    ProjectRootInvalid(path, reason) ->
      "Coder project_root '" <> path <> "' is not usable: " <> reason

    ContainerStartFailed(reason) ->
      "Failed to start coder container: " <> reason

    AuthMissing ->
      "No provider keys available for the coder. Set ANTHROPIC_API_KEY "
      <> "in .env (or another supported provider) before dispatching "
      <> "to the coder."

    ServeStartFailed(log_tail) ->
      "OpenCode serve failed to bind. Recent log:\n" <> log_tail

    HealthTimeout(elapsed_ms) ->
      "OpenCode did not become reachable within "
      <> int_to_seconds_string(elapsed_ms)
      <> " seconds."

    SessionCrashed(exit_code, log_tail) ->
      "Coder session crashed (exit "
      <> int_to_string(exit_code)
      <> "). Recent log:\n"
      <> log_tail

    SessionNotFound(session_id) ->
      "No tracked coder session matches id '" <> session_id <> "'."

    TokenBudgetExceeded(consumed, cap) ->
      "Coder task aborted: token budget exceeded ("
      <> int_to_string(consumed)
      <> " > "
      <> int_to_string(cap)
      <> ")."

    CostBudgetExceeded(consumed_usd, cap_usd) ->
      "Coder task aborted: cost budget exceeded ($"
      <> float_to_string(consumed_usd)
      <> " > $"
      <> float_to_string(cap_usd)
      <> ")."

    HourlyBudgetExceeded(consumed_usd, cap_usd) ->
      "Coder hourly budget exhausted ($"
      <> float_to_string(consumed_usd)
      <> " > $"
      <> float_to_string(cap_usd)
      <> "). Wait for the window to roll, or raise "
      <> "coder_max_cost_per_hour_usd."

    NetworkError(reason) -> "Coder HTTP failure: " <> reason
  }
}

// ---------------------------------------------------------------------------
// Small helpers (avoid pulling gleam/int + gleam/float into the public API)
// ---------------------------------------------------------------------------

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String

@external(erlang, "erlang", "float_to_binary")
fn float_to_binary(f: Float, opts: List(FloatFormatOpt)) -> String

type FloatFormatOpt {
  Decimals(Int)
  Compact
}

fn float_to_string(f: Float) -> String {
  float_to_binary(f, [Decimals(2), Compact])
}

fn int_to_seconds_string(ms: Int) -> String {
  int_to_string(ms / 1000)
}
