//// Email inbox poller — OTP actor that polls AgentMail for new messages
//// and routes them to the cognitive loop as user input.
////
//// Uses process.send_after for self-ticking, same pattern as the Forecaster.
//// Tracks the last seen message timestamp to avoid re-processing.
//// Fail-safe: if polling fails, it logs and retries next tick.

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
    // Seed seen_ids from existing JSONL log to avoid re-processing
    let existing = comms_log.load_recent(paths.comms_dir(), 7)
    let seed_ids =
      list.map(existing, fn(m) { m.message_id })
      |> set.from_list
    slog.info(
      "comms/poller",
      "start",
      "Seeded "
        <> int.to_string(set.size(seed_ids))
        <> " seen message IDs from log",
      None,
    )
    let state =
      PollerState(
        config:,
        cognitive:,
        self:,
        seen_ids: seed_ids,
        last_poll_timestamp: None,
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
      schedule_tick(state.self, state.config.poll_interval_ms)
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
      slog.warn("comms/poller", "handle_tick", "Poll failed: " <> reason, None)
      state
    }
    Ok(messages) -> {
      // Filter out messages we've already seen (by ID) and our own outbound
      let new_messages =
        messages
        |> list.filter(fn(m) { !set.contains(state.seen_ids, m.message_id) })
        |> list.filter(fn(m) {
          !string.contains(
            string.lowercase(m.from),
            string.lowercase(state.config.from_address),
          )
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

        // Log inbound message
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
            body_text: m.preview,
            timestamp: m.timestamp,
            status: comms_types.Delivered,
            cycle_id: None,
          ),
        )

        // Fetch full message body
        let body = case
          email.get_message(
            state.config.inbox_id,
            state.config.api_key_env,
            m.message_id,
          )
        {
          Ok(full) -> full.text
          Error(_) -> m.preview
        }

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
      // Cap the seen set at 200 to prevent unbounded growth
      let capped_seen = case set.size(new_seen) > 200 {
        True -> set.from_list(list.take(set.to_list(new_seen), 150))
        False -> new_seen
      }
      // Update timestamp for the `after` query param
      let new_timestamp = case list.last(messages) {
        Ok(latest) -> Some(latest.timestamp)
        Error(_) -> state.last_poll_timestamp
      }
      PollerState(
        ..state,
        seen_ids: capped_seen,
        last_poll_timestamp: new_timestamp,
      )
    }
  }
}
