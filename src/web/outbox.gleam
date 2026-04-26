//// Per-client bounded outbox of server→client WebSocket frames.
////
//// **What this gives the wire protocol.** Every server-pushed frame
//// gets a monotonic `seq`. The client tracks the last `seq` it has
//// applied locally and acks back. The server prunes the outbox up
//// to the acked seq. On reconnect, the client opens with
//// `?since=N`; the server replays from `N + 1`. If `N` is older
//// than the oldest seq still in the outbox the server falls back
//// to a full `session_history` rebuild.
////
//// **Why per-client.** The pre-existing `seq` was per-node monotonic
//// — fine for "detect reordering" diagnostics, useless for replay.
//// A reconnect under the same `client_id` (stable across browser
//// tabs / refreshes / mid-cycle blips) needs to know what the
//// *client* has seen, not what the *node* has emitted. So the seq
//// counter and outbox both key on `client_id`.
////
//// **Bounds.** The outbox is a ring buffer. Default cap is 500
//// frames. We additionally drop entries older than 5 minutes — past
//// that horizon a reconnect is safer with a fresh `session_history`
//// rebuild than with a partial replay.
////
//// **What we deliberately do NOT do here.**
////
////   * No persistence. Process death loses the outbox; the next
////     connect under that client_id starts a fresh seq sequence.
////     A redirected operator who closes the laptop and reconnects
////     a day later gets `session_history`, not replay. That's
////     correct.
////   * No cross-tab fan-out. Each WS process owns its own connection;
////     the outbox is shared across reconnects of the *same* client_id
////     but not across separate browser tabs (which mint distinct
////     client_ids). This is intentional — different tabs are
////     different conversations.
////   * No back-pressure on append. If the client never acks, the
////     outbox fills, hits the cap, and the oldest entries get
////     dropped. The client will fall back to `session_history` on
////     its next reconnect anyway.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{type Option, None, Some}

/// Default cap on outbox length. Past this, the oldest frame is
/// dropped on every append. 500 is generous for a single WS that
/// reconnects within seconds; reconnects after the 500-frame backlog
/// fall back to `session_history`.
pub const default_max_size: Int = 500

/// Default age cap (ms). Frames older than this are dropped on
/// `prune_age/2`. Five minutes covers the long-cycle case (operator
/// laptop sleeps, agent runs for 3 min, operator wakes) while
/// keeping memory bounded under sustained idle.
pub const default_max_age_ms: Int = 300_000

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A single frame held in the outbox. Holds the encoded JSON body
/// (without the `seq` prefix — `replay_since` re-emits seq-prefixed
/// JSON when handing frames back).
pub type Frame {
  Frame(seq: Int, body_json: String, sent_at_ms: Int)
}

/// Result of trying to replay from a particular seq. `TooOld` means
/// the requested `since` is older than anything we still have — the
/// caller should fall back to a `session_history` rebuild.
pub type ReplayResult {
  Replay(frames: List(Frame))
  TooOld(oldest_kept: Int)
  /// Client is current — nothing to replay.
  UpToDate
}

/// Configuration overrides. Pass `default_config()` for the standard
/// behaviour described above.
pub type Config {
  Config(max_size: Int, max_age_ms: Int)
}

pub fn default_config() -> Config {
  Config(max_size: default_max_size, max_age_ms: default_max_age_ms)
}

/// Per-client append-only buffer with bounded retention. `next_seq`
/// is the seq that *will be assigned* on the next `append`. Held
/// chronologically (oldest at head, newest at tail) so prune_age
/// drops from the head.
pub opaque type Outbox {
  Outbox(
    config: Config,
    next_seq: Int,
    /// Chronological order: head = oldest, tail = newest.
    frames: List(Frame),
    /// Monotonic record of the highest seq the client has acked. We
    /// keep frames > acked_seq; anything ≤ acked_seq is pruned on
    /// the next `ack` and is no longer replayable.
    acked_seq: Int,
  )
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

pub fn new() -> Outbox {
  with_config(default_config())
}

pub fn with_config(config: Config) -> Outbox {
  Outbox(config: config, next_seq: 1, frames: [], acked_seq: 0)
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

pub fn last_seq(outbox: Outbox) -> Int {
  outbox.next_seq - 1
}

pub fn acked_seq(outbox: Outbox) -> Int {
  outbox.acked_seq
}

pub fn pending_count(outbox: Outbox) -> Int {
  list.length(outbox.frames)
}

pub fn oldest_kept_seq(outbox: Outbox) -> Option(Int) {
  case outbox.frames {
    [first, ..] -> Some(first.seq)
    [] -> None
  }
}

// ---------------------------------------------------------------------------
// Mutations
// ---------------------------------------------------------------------------

/// Append a fresh frame. Returns the updated outbox + the assigned
/// seq. Caller's responsibility to embed the seq into the JSON it
/// actually emits over the wire.
pub fn append(outbox: Outbox, body_json: String, now_ms: Int) -> #(Outbox, Int) {
  let assigned = outbox.next_seq
  let frame = Frame(seq: assigned, body_json: body_json, sent_at_ms: now_ms)
  let new_frames = list.append(outbox.frames, [frame])
  // Cap-prune: drop oldest while over the size limit.
  let trimmed = trim_to_size(new_frames, outbox.config.max_size)
  #(Outbox(..outbox, next_seq: assigned + 1, frames: trimmed), assigned)
}

/// Mark every frame with seq ≤ `up_to` as acknowledged and drop them
/// from the buffer. Idempotent. `up_to` below the current
/// `acked_seq` is a no-op (a stale ack from a slow network shouldn't
/// rewind the cursor).
pub fn ack(outbox: Outbox, up_to: Int) -> Outbox {
  case up_to <= outbox.acked_seq {
    True -> outbox
    False -> {
      let kept = list.filter(outbox.frames, fn(f) { f.seq > up_to })
      Outbox(..outbox, frames: kept, acked_seq: up_to)
    }
  }
}

/// Drop frames older than `max_age_ms` from the oldest end. Called
/// periodically by the registry's janitor; not on every append.
pub fn prune_age(outbox: Outbox, now_ms: Int) -> Outbox {
  let cutoff = now_ms - outbox.config.max_age_ms
  let kept = list.filter(outbox.frames, fn(f) { f.sent_at_ms >= cutoff })
  Outbox(..outbox, frames: kept)
}

// ---------------------------------------------------------------------------
// Replay on reconnect
// ---------------------------------------------------------------------------

/// Return all frames with seq > `since`. The caller then re-emits
/// each frame's `body_json` with its `seq` to the new WS connection.
/// The contract:
///
///   * `since` ≥ `last_seq` → `UpToDate` (no replay needed)
///   * `since` < `oldest_kept_seq` → `TooOld(oldest_kept)` (caller
///     should fall back to `session_history`)
///   * otherwise → `Replay(frames)` with frames in chronological
///     order
pub fn replay_since(outbox: Outbox, since: Int) -> ReplayResult {
  case since >= last_seq(outbox) {
    True -> UpToDate
    False ->
      case oldest_kept_seq(outbox) {
        None -> UpToDate
        Some(oldest) ->
          case since < oldest - 1 {
            True -> TooOld(oldest_kept: oldest)
            False -> {
              let to_send = list.filter(outbox.frames, fn(f) { f.seq > since })
              Replay(frames: to_send)
            }
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn trim_to_size(frames: List(Frame), max_size: Int) -> List(Frame) {
  case list.length(frames) > max_size {
    True -> list.drop(frames, list.length(frames) - max_size)
    False -> frames
  }
}
