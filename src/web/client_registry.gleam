//// Per-client outbox registry. Owns the `Outbox` for every
//// distinct WebSocket `client_id`, surviving WS process death so
//// reconnects under the same `client_id` can replay frames the
//// previous WS process emitted.
////
//// **Threading model.** Single actor; all reads/writes go through
//// it. Per-client outboxes are mutated in turn. The actor's
//// `Append` / `Ack` / `ReplaySince` are blocking-RPC calls (they
//// `process.call` and the WS handler waits for the result) — fine
//// at single-operator scale; would want sharding past hundreds of
//// concurrent clients.
////
//// **Lifecycle.** A client_id's outbox is created on first
//// `Append` and persists indefinitely. A periodic `Janitor` tick
//// prunes outboxes whose last activity was over an hour ago — no
//// chance the original tab is still listening.
////
//// **What's a "frame".** The opaque JSON body of a server message
//// (without the `seq` prefix). The registry assigns the seq and
//// returns it; the WS handler is responsible for splicing the seq
//// into the wire JSON. This keeps the registry oblivious to
//// protocol shape.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None}
import slog
import web/outbox.{type Outbox, type ReplayResult}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub type ClientId =
  String

pub type RegistryMessage {
  /// Append a server-bound JSON body for a client_id. Reply carries
  /// the assigned seq.
  Append(client_id: ClientId, body_json: String, reply_to: Subject(Int))
  /// Mark a client's frames up to `seq` acked. Best-effort; reply is
  /// just an ack (so the caller can know it landed) but doesn't
  /// carry data.
  Ack(client_id: ClientId, up_to: Int)
  /// Replay everything past `since` for a reconnecting client.
  ReplaySince(client_id: ClientId, since: Int, reply_to: Subject(ReplayResult))
  /// Read the current snapshot for diagnostics: last_seq, acked_seq,
  /// pending_count.
  Stats(client_id: ClientId, reply_to: Subject(StatsSnapshot))
  /// Periodic age-prune across every outbox. Sent by janitor timer.
  JanitorTick
  /// Drop a client's state. Used when the operator's session is
  /// definitively over (tab close on the last connection holding
  /// the id, etc.).
  Forget(client_id: ClientId)
  /// Stop the actor. Tests only.
  Shutdown
}

pub type StatsSnapshot {
  StatsSnapshot(
    exists: Bool,
    last_seq: Int,
    acked_seq: Int,
    pending_count: Int,
    oldest_kept: Option(Int),
  )
}

/// Public handle on the actor.
pub opaque type Registry {
  Registry(subject: Subject(RegistryMessage))
}

pub fn subject(r: Registry) -> Subject(RegistryMessage) {
  r.subject
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

const janitor_tick_ms: Int = 60_000

const idle_drop_age_ms: Int = 3_600_000

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn now_ms() -> Int

pub fn start() -> Registry {
  let setup: Subject(Subject(RegistryMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(RegistryMessage) = process.new_subject()
    process.send(setup, self)
    let _ = process.send_after(self, janitor_tick_ms, JanitorTick)
    loop(self, State(outboxes: dict.new(), last_touch: dict.new()))
  })
  case process.receive(setup, 5000) {
    Ok(s) -> Registry(subject: s)
    Error(_) -> panic as "ClientRegistry failed to start within 5s"
  }
}

pub fn shutdown(r: Registry) -> Nil {
  process.send(r.subject, Shutdown)
}

// ---------------------------------------------------------------------------
// Convenience wrappers — typed RPCs
// ---------------------------------------------------------------------------

/// Append a body, return the assigned seq. Blocks briefly on the
/// registry actor; the WS handler then splices the seq into the
/// JSON it sends over the wire.
pub fn append(r: Registry, client_id: ClientId, body_json: String) -> Int {
  let reply: Subject(Int) = process.new_subject()
  process.send(r.subject, Append(client_id:, body_json:, reply_to: reply))
  case process.receive(reply, 5000) {
    Ok(seq) -> seq
    Error(_) -> 0
  }
}

pub fn ack(r: Registry, client_id: ClientId, up_to: Int) -> Nil {
  process.send(r.subject, Ack(client_id:, up_to:))
}

pub fn replay_since(
  r: Registry,
  client_id: ClientId,
  since: Int,
) -> ReplayResult {
  let reply: Subject(ReplayResult) = process.new_subject()
  process.send(r.subject, ReplaySince(client_id:, since:, reply_to: reply))
  case process.receive(reply, 5000) {
    Ok(r) -> r
    Error(_) -> outbox.UpToDate
  }
}

pub fn stats(r: Registry, client_id: ClientId) -> StatsSnapshot {
  let reply: Subject(StatsSnapshot) = process.new_subject()
  process.send(r.subject, Stats(client_id:, reply_to: reply))
  case process.receive(reply, 5000) {
    Ok(s) -> s
    Error(_) ->
      StatsSnapshot(
        exists: False,
        last_seq: 0,
        acked_seq: 0,
        pending_count: 0,
        oldest_kept: None,
      )
  }
}

pub fn forget(r: Registry, client_id: ClientId) -> Nil {
  process.send(r.subject, Forget(client_id:))
}

// ---------------------------------------------------------------------------
// Internal — actor state + loop
// ---------------------------------------------------------------------------

type State {
  State(outboxes: Dict(ClientId, Outbox), last_touch: Dict(ClientId, Int))
}

fn loop(self: Subject(RegistryMessage), state: State) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(self)
  let msg = process.selector_receive_forever(selector)
  case msg {
    Shutdown -> Nil
    _ -> {
      let next = handle(msg, state, self)
      loop(self, next)
    }
  }
}

fn handle(
  msg: RegistryMessage,
  state: State,
  self: Subject(RegistryMessage),
) -> State {
  case msg {
    Shutdown -> state

    Append(client_id:, body_json:, reply_to:) -> {
      let now = now_ms()
      let existing = case dict.get(state.outboxes, client_id) {
        Ok(o) -> o
        Error(_) -> outbox.new()
      }
      let #(updated, seq) = outbox.append(existing, body_json, now)
      process.send(reply_to, seq)
      State(
        outboxes: dict.insert(state.outboxes, client_id, updated),
        last_touch: dict.insert(state.last_touch, client_id, now),
      )
    }

    Ack(client_id:, up_to:) -> {
      case dict.get(state.outboxes, client_id) {
        Error(_) -> state
        Ok(o) -> {
          let acked = outbox.ack(o, up_to)
          State(
            outboxes: dict.insert(state.outboxes, client_id, acked),
            last_touch: dict.insert(state.last_touch, client_id, now_ms()),
          )
        }
      }
    }

    ReplaySince(client_id:, since:, reply_to:) -> {
      let result = case dict.get(state.outboxes, client_id) {
        Ok(o) -> outbox.replay_since(o, since)
        Error(_) -> outbox.UpToDate
      }
      process.send(reply_to, result)
      State(
        ..state,
        last_touch: dict.insert(state.last_touch, client_id, now_ms()),
      )
    }

    Stats(client_id:, reply_to:) -> {
      let snap = case dict.get(state.outboxes, client_id) {
        Ok(o) ->
          StatsSnapshot(
            exists: True,
            last_seq: outbox.last_seq(o),
            acked_seq: outbox.acked_seq(o),
            pending_count: outbox.pending_count(o),
            oldest_kept: outbox.oldest_kept_seq(o),
          )
        Error(_) ->
          StatsSnapshot(
            exists: False,
            last_seq: 0,
            acked_seq: 0,
            pending_count: 0,
            oldest_kept: None,
          )
      }
      process.send(reply_to, snap)
      state
    }

    JanitorTick -> {
      let now = now_ms()
      let cutoff = now - idle_drop_age_ms
      // Age-prune every outbox.
      let pruned_outboxes =
        dict.map_values(state.outboxes, fn(_, o) { outbox.prune_age(o, now) })
      // Drop clients whose last activity is past the idle cutoff.
      let active_ids =
        dict.fold(state.last_touch, [], fn(acc, k, t) {
          case t < cutoff {
            True -> acc
            False -> [k, ..acc]
          }
        })
      let active_set = active_ids
      let dropped =
        dict.filter(pruned_outboxes, fn(k, _) {
          case list_contains(active_set, k) {
            True -> True
            False -> {
              slog.debug(
                "client_registry",
                "janitor",
                "dropping idle outbox " <> k,
                option.None,
              )
              False
            }
          }
        })
      let kept_touch =
        dict.filter(state.last_touch, fn(k, _) { list_contains(active_set, k) })
      let _ = process.send_after(self, janitor_tick_ms, JanitorTick)
      State(outboxes: dropped, last_touch: kept_touch)
    }

    Forget(client_id:) ->
      State(
        outboxes: dict.delete(state.outboxes, client_id),
        last_touch: dict.delete(state.last_touch, client_id),
      )
  }
}

fn list_contains(xs: List(String), x: String) -> Bool {
  case xs {
    [] -> False
    [h, ..rest] ->
      case h == x {
        True -> True
        False -> list_contains(rest, x)
      }
  }
}
