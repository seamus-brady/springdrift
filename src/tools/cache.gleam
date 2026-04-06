// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

/// In-session query cache actor.
/// Prevents redundant API calls during research loops.
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option

/// A cached entry with a value and expiry timestamp.
pub type CacheEntry {
  CacheEntry(value: String, expires_at_ms: Int)
}

/// Messages accepted by the cache actor.
pub type CacheMessage {
  Get(key: String, reply_to: Subject(Result(String, Nil)))
  Put(key: String, value: String, ttl_ms: Int)
}

/// Start a cache actor. Returns the subject for sending messages.
pub fn start() -> Result(Subject(CacheMessage), Nil) {
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(CacheMessage) = process.new_subject()
    process.send(setup, self)
    loop(self, dict.new())
  })
  case process.receive(setup, 5000) {
    Ok(subj) -> Ok(subj)
    Error(_) -> Error(Nil)
  }
}

fn loop(self: Subject(CacheMessage), entries: Dict(String, CacheEntry)) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(self)

  case process.selector_receive_forever(selector) {
    Get(key:, reply_to:) -> {
      let now = monotonic_now_ms()
      case dict.get(entries, key) {
        Ok(entry) if entry.expires_at_ms > now -> {
          process.send(reply_to, Ok(entry.value))
          loop(self, entries)
        }
        Ok(_) -> {
          // Expired — remove and return miss
          process.send(reply_to, Error(Nil))
          loop(self, dict.delete(entries, key))
        }
        Error(_) -> {
          process.send(reply_to, Error(Nil))
          loop(self, entries)
        }
      }
    }
    Put(key:, value:, ttl_ms:) -> {
      let now = monotonic_now_ms()
      let entry = CacheEntry(value:, expires_at_ms: now + ttl_ms)
      loop(self, dict.insert(entries, key, entry))
    }
  }
}

/// Look up a key in the cache.
pub fn get(
  cache: Subject(CacheMessage),
  key: String,
  timeout_ms: Int,
) -> Result(String, Nil) {
  let reply = process.new_subject()
  process.send(cache, Get(key:, reply_to: reply))
  case process.receive(reply, timeout_ms) {
    Ok(result) -> result
    Error(_) -> Error(Nil)
  }
}

/// Store a value in the cache with a TTL.
pub fn put(
  cache: Subject(CacheMessage),
  key: String,
  value: String,
  ttl_ms: Int,
) -> Nil {
  process.send(cache, Put(key:, value:, ttl_ms:))
}

/// Optionally look up a key if a cache is available.
pub fn maybe_get(
  cache: option.Option(Subject(CacheMessage)),
  key: String,
  timeout_ms: Int,
) -> Result(String, Nil) {
  case cache {
    option.None -> Error(Nil)
    option.Some(c) -> get(c, key, timeout_ms)
  }
}

/// Optionally store a value if a cache is available.
pub fn maybe_put(
  cache: option.Option(Subject(CacheMessage)),
  key: String,
  value: String,
  ttl_ms: Int,
) -> Nil {
  case cache {
    option.None -> Nil
    option.Some(c) -> put(c, key, value, ttl_ms)
  }
}

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms() -> Int
