// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import web/outbox

// ── Construction ──────────────────────────────────────────────────────────

pub fn new_starts_at_seq_zero_test() {
  let o = outbox.new()
  outbox.last_seq(o) |> should.equal(0)
  outbox.acked_seq(o) |> should.equal(0)
  outbox.pending_count(o) |> should.equal(0)
  outbox.oldest_kept_seq(o) |> should.equal(None)
}

// ── Append assigns monotonic seq ──────────────────────────────────────────

pub fn append_returns_monotonic_seq_test() {
  let o = outbox.new()
  let #(o, s1) = outbox.append(o, "{\"type\":\"a\"}", 1000)
  let #(o, s2) = outbox.append(o, "{\"type\":\"b\"}", 1001)
  let #(_o, s3) = outbox.append(o, "{\"type\":\"c\"}", 1002)
  s1 |> should.equal(1)
  s2 |> should.equal(2)
  s3 |> should.equal(3)
}

pub fn append_grows_pending_count_test() {
  let o = outbox.new()
  let #(o, _) = outbox.append(o, "x", 0)
  let #(o, _) = outbox.append(o, "y", 0)
  outbox.pending_count(o) |> should.equal(2)
  outbox.last_seq(o) |> should.equal(2)
}

// ── Ack prunes from below ─────────────────────────────────────────────────

pub fn ack_prunes_acked_frames_test() {
  let o = outbox.new()
  let #(o, _) = outbox.append(o, "a", 0)
  let #(o, _) = outbox.append(o, "b", 0)
  let #(o, _) = outbox.append(o, "c", 0)
  let o = outbox.ack(o, 2)
  outbox.pending_count(o) |> should.equal(1)
  outbox.acked_seq(o) |> should.equal(2)
  // Oldest remaining should be seq 3.
  outbox.oldest_kept_seq(o) |> should.equal(Some(3))
}

pub fn ack_at_or_below_current_is_noop_test() {
  let o = outbox.new()
  let #(o, _) = outbox.append(o, "a", 0)
  let #(o, _) = outbox.append(o, "b", 0)
  let o = outbox.ack(o, 2)
  // Stale ack — shouldn't rewind anything.
  let o2 = outbox.ack(o, 1)
  outbox.acked_seq(o2) |> should.equal(2)
  outbox.pending_count(o2) |> should.equal(0)
}

// ── Replay semantics ──────────────────────────────────────────────────────

pub fn replay_up_to_date_when_since_is_current_test() {
  let o = outbox.new()
  let #(o, _) = outbox.append(o, "a", 0)
  // Client says it has seq 1 — we have seq 1 — no replay.
  case outbox.replay_since(o, 1) {
    outbox.UpToDate -> Nil
    _ -> {
      should.fail()
      Nil
    }
  }
}

pub fn replay_returns_frames_after_since_test() {
  let o = outbox.new()
  let #(o, _) = outbox.append(o, "a", 0)
  let #(o, _) = outbox.append(o, "b", 0)
  let #(o, _) = outbox.append(o, "c", 0)
  // Client has 1, asks for everything after — should get 2 + 3.
  case outbox.replay_since(o, 1) {
    outbox.Replay(frames) -> {
      list.length(frames) |> should.equal(2)
      case frames {
        [f2, f3] -> {
          f2.seq |> should.equal(2)
          f3.seq |> should.equal(3)
          f2.body_json |> should.equal("b")
          f3.body_json |> should.equal("c")
        }
        _ -> {
          should.fail()
          Nil
        }
      }
    }
    _ -> {
      should.fail()
      Nil
    }
  }
}

pub fn replay_too_old_when_since_below_oldest_kept_test() {
  // Append 3 frames, ack the first two so they prune. Client comes
  // back asking for since=0 → its requested cursor is older than
  // anything we have, return TooOld.
  let o = outbox.new()
  let #(o, _) = outbox.append(o, "a", 0)
  let #(o, _) = outbox.append(o, "b", 0)
  let #(o, _) = outbox.append(o, "c", 0)
  let o = outbox.ack(o, 2)
  case outbox.replay_since(o, 0) {
    outbox.TooOld(oldest_kept) -> oldest_kept |> should.equal(3)
    _ -> {
      should.fail()
      Nil
    }
  }
}

pub fn replay_at_oldest_kept_minus_one_returns_replay_test() {
  // Boundary: client cursor is exactly oldest_kept - 1 → still
  // replayable (no gap).
  let o = outbox.new()
  let #(o, _) = outbox.append(o, "a", 0)
  let #(o, _) = outbox.append(o, "b", 0)
  let #(o, _) = outbox.append(o, "c", 0)
  // No ack yet; oldest_kept is 1.
  case outbox.replay_since(o, 0) {
    outbox.Replay(frames) -> list.length(frames) |> should.equal(3)
    _ -> {
      should.fail()
      Nil
    }
  }
}

// ── Size cap drops oldest on overflow ─────────────────────────────────────

pub fn append_respects_max_size_cap_test() {
  let small =
    outbox.with_config(outbox.Config(max_size: 3, max_age_ms: 1_000_000))
  let small =
    list.fold([1, 2, 3, 4, 5], small, fn(o, _) {
      let #(o, _) = outbox.append(o, "x", 0)
      o
    })
  outbox.pending_count(small) |> should.equal(3)
  // The oldest kept should be seq 3 (1 and 2 dropped).
  outbox.oldest_kept_seq(small) |> should.equal(Some(3))
  outbox.last_seq(small) |> should.equal(5)
}

// ── Age prune drops stale frames from the head ────────────────────────────

pub fn prune_age_drops_old_frames_test() {
  let o = outbox.with_config(outbox.Config(max_size: 100, max_age_ms: 1000))
  let #(o, _) = outbox.append(o, "a", 0)
  // 500ms passes — a still inside window
  let #(o, _) = outbox.append(o, "b", 500)
  // 1500ms passes — first frame ages out
  let #(o, _) = outbox.append(o, "c", 1500)
  let pruned = outbox.prune_age(o, 1500)
  // Frames at sent_at < 500ms have aged out (cutoff = 1500 - 1000 = 500).
  // Frame 'a' (sent_at=0) drops; 'b' (500) and 'c' (1500) survive.
  outbox.pending_count(pruned) |> should.equal(2)
  outbox.oldest_kept_seq(pruned) |> should.equal(Some(2))
}

// ── End-to-end: typical reconnect flow ────────────────────────────────────

pub fn reconnect_flow_replays_missed_frames_test() {
  // Simulate: client connects, server sends 3 frames, client acks 2,
  // connection drops, server sends 2 more, client reconnects with
  // since=2, expects 2 frames replayed.
  let o = outbox.new()
  let #(o, s1) = outbox.append(o, "msg1", 0)
  let #(o, s2) = outbox.append(o, "msg2", 0)
  let #(o, _s3) = outbox.append(o, "msg3", 0)
  // Client ack: "I have through seq 2".
  let o = outbox.ack(o, s2)
  // Connection drops; server keeps publishing.
  let #(o, _s4) = outbox.append(o, "msg4", 0)
  let #(o, _s5) = outbox.append(o, "msg5", 0)
  // Client reconnects with since=2 (last acked).
  case outbox.replay_since(o, s2) {
    outbox.Replay(frames) -> {
      list.length(frames) |> should.equal(3)
      case frames {
        [f3, f4, f5] -> {
          f3.seq |> should.equal(3)
          f3.body_json |> should.equal("msg3")
          f4.seq |> should.equal(4)
          f5.seq |> should.equal(5)
        }
        _ -> {
          should.fail()
          Nil
        }
      }
    }
    _ -> {
      should.fail()
      Nil
    }
  }
  s1 |> should.equal(1)
}
