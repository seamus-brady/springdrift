//// Email inbox poller — OTP actor that polls AgentMail for new messages
//// and routes them to the cognitive loop as user input.
////
//// Uses process.send_after for self-ticking, same pattern as the Forecaster.
//// Tracks the last seen message timestamp to avoid re-processing.
//// Fail-safe: if polling fails, it logs and retries next tick.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import comms/email
import comms/log as comms_log
import comms/types as comms_types
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import paths
import scheduler/types as scheduler_types
import slog

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type PollerConfig {
  PollerConfig(
    inbox_id: String,
    api_key_env: String,
    poll_interval_ms: Int,
    from_address: String,
  )
}

pub type PollerMessage {
  Tick
  Shutdown
}

type PollerState {
  PollerState(
    config: PollerConfig,
    cognitive: Subject(agent_types.CognitiveMessage),
    self: Subject(PollerMessage),
    seen_ids: Set(String),
    last_poll_timestamp: Option(String),
    consecutive_failures: Int,
  )
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

/// Start the inbox poller. Returns the poller subject for shutdown.
pub fn start(
  config: PollerConfig,
  cognitive: Subject(agent_types.CognitiveMessage),
) -> Subject(PollerMessage) {
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(PollerMessage) = process.new_subject()
    process.send(setup, self)
    // Seed seen_ids from ALL messages in the comms log — every message ID
    // that appears in the log has already been delivered to the cognitive loop.
    // No re-processing on restart. The narrative log is the durable record.
    let existing = comms_log.load_recent(paths.comms_dir(), 30)
    let seed_ids =
      list.map(existing, fn(m) { m.message_id })
      |> set.from_list
    slog.info(
      "comms/poller",
      "start",
      "Seeded "
        <> int.to_string(set.size(seed_ids))
        <> " seen message IDs from comms log",
      None,
    )
    let state =
      PollerState(
        config:,
        cognitive:,
        self:,
        seen_ids: seed_ids,
        last_poll_timestamp: None,
        consecutive_failures: 0,
      )
    // Initial poll after a short delay (let system settle)
    schedule_tick(self, 5000)
    loop(state)
  })
  let assert Ok(self) = process.receive(setup, 5000)
  self
}

// ---------------------------------------------------------------------------
// Loop
// ---------------------------------------------------------------------------

fn loop(state: PollerState) -> Nil {
  case process.receive(state.self, 120_000) {
    Error(_) -> loop(state)
    Ok(Shutdown) -> {
      slog.info("comms/poller", "loop", "Shutting down", None)
      Nil
    }
    Ok(Tick) -> {
      let new_state = handle_tick(state)
      // Exponential backoff on consecutive failures: 2x per failure, cap at 5 min
      let delay = case new_state.consecutive_failures {
        0 -> state.config.poll_interval_ms
        n -> {
          let backoff = state.config.poll_interval_ms * pow2(n)
          int.min(backoff, 300_000)
        }
      }
      schedule_tick(state.self, delay)
      loop(new_state)
    }
  }
}

fn schedule_tick(self: Subject(PollerMessage), delay_ms: Int) -> Nil {
  process.send_after(self, delay_ms, Tick)
  Nil
}

// ---------------------------------------------------------------------------
// Poll
// ---------------------------------------------------------------------------

fn handle_tick(state: PollerState) -> PollerState {
  let result =
    email.list_messages(
      state.config.inbox_id,
      state.config.api_key_env,
      20,
      state.last_poll_timestamp,
    )
  case result {
    Error(reason) -> {
      let failures = state.consecutive_failures + 1
      slog.warn(
        "comms/poller",
        "handle_tick",
        "Poll failed ("
          <> int.to_string(failures)
          <> " consecutive): "
          <> reason,
        None,
      )
      // After 3 consecutive failures, alert the cognitive loop
      case failures >= 3 {
        True ->
          process.send(
            state.cognitive,
            agent_types.QueuedSensoryEvent(event: agent_types.SensoryEvent(
              name: "email_degraded",
              title: "Email polling degraded",
              body: "AgentMail API has failed "
                <> int.to_string(failures)
                <> " consecutive polls. Last error: "
                <> reason,
              fired_at: "",
            )),
          )
        False -> Nil
      }
      PollerState(..state, consecutive_failures: failures)
    }
    Ok(messages) -> {
      // Filter out messages we've already seen (by ID) and our own outbound
      let new_messages =
        messages
        |> list.filter(fn(m) { !set.contains(state.seen_ids, m.message_id) })
        |> list.filter(fn(m) {
          // Exact match — extract email from "Name <email>" format if present
          let from_lower = string.lowercase(string.trim(m.from))
          let own_lower = string.lowercase(state.config.from_address)
          // Check both raw match and angle-bracket format
          from_lower != own_lower
          && !string.ends_with(from_lower, "<" <> own_lower <> ">")
        })
        |> list.reverse

      // Process each new message
      list.each(new_messages, fn(m) {
        slog.info(
          "comms/poller",
          "handle_tick",
          "New email from " <> m.from <> ": " <> m.subject,
          None,
        )

        // Fetch full message body first, then log with full text
        // Cap at 50KB to prevent memory/storage issues from huge emails
        let max_body_chars = 50_000
        let body = case
          email.get_message(
            state.config.inbox_id,
            state.config.api_key_env,
            m.message_id,
          )
        {
          Ok(full) -> string.slice(full.text, 0, max_body_chars)
          Error(reason) -> {
            slog.warn(
              "comms/poller",
              "handle_tick",
              "Failed to fetch full body for "
                <> m.message_id
                <> ": "
                <> reason
                <> " — using preview",
              None,
            )
            m.preview
          }
        }

        // Log inbound message with full body
        comms_log.append(
          paths.comms_dir(),
          comms_types.CommsMessage(
            message_id: m.message_id,
            thread_id: m.thread_id,
            channel: comms_types.Email,
            direction: comms_types.Inbound,
            from: m.from,
            to: state.config.from_address,
            subject: m.subject,
            body_text: body,
            timestamp: m.timestamp,
            status: comms_types.Delivered,
            cycle_id: None,
          ),
        )

        // Route to cognitive loop as SchedulerInput (not UserInput)
        // so the agent knows this is an inbound email, not operator typing
        let reply_to = process.new_subject()
        process.send(
          state.cognitive,
          agent_types.SchedulerInput(
            job_name: "email-inbound-" <> m.message_id,
            query: body,
            kind: scheduler_types.Reminder,
            for_: scheduler_types.ForAgent,
            title: "Email from " <> m.from,
            body: "Subject: "
              <> m.subject
              <> "\nFrom: "
              <> m.from
              <> "\n\n"
              <> body,
            tags: ["email", "inbound"],
            reply_to:,
          ),
        )
        // Don't block waiting for reply — fire and forget
        Nil
      })

      // Add ALL message IDs from this poll to seen set (including our own)
      // to prevent re-processing on next poll
      let all_ids = list.map(messages, fn(m) { m.message_id })
      let new_seen = list.fold(all_ids, state.seen_ids, set.insert)
      // No cap — the set grows bounded by poll window (last 7 days on restart)
      // and the `after` timestamp parameter limits what AgentMail returns.
      // Previous cap at 200 caused random ID drops and re-injection loops.
      // Update timestamp for the `after` query param
      let new_timestamp = case list.last(messages) {
        Ok(latest) -> Some(latest.timestamp)
        Error(_) -> state.last_poll_timestamp
      }
      PollerState(
        ..state,
        seen_ids: new_seen,
        last_poll_timestamp: new_timestamp,
        consecutive_failures: 0,
      )
    }
  }
}

/// Simple 2^n for backoff (capped at reasonable values by caller).
fn pow2(n: Int) -> Int {
  case n {
    0 -> 1
    1 -> 2
    2 -> 4
    3 -> 8
    4 -> 16
    _ -> 32
  }
}
