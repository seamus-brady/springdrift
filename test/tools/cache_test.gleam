// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option
import gleeunit
import gleeunit/should
import tools/cache

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Get/Put
// ---------------------------------------------------------------------------

pub fn cache_miss_test() {
  let assert Ok(c) = cache.start()
  cache.get(c, "missing", 1000) |> should.be_error
}

pub fn cache_put_and_get_test() {
  let assert Ok(c) = cache.start()
  cache.put(c, "key1", "value1", 60_000)
  // Small delay for actor to process
  sleep(10)
  cache.get(c, "key1", 1000) |> should.equal(Ok("value1"))
}

pub fn cache_overwrite_test() {
  let assert Ok(c) = cache.start()
  cache.put(c, "key1", "old", 60_000)
  sleep(10)
  cache.put(c, "key1", "new", 60_000)
  sleep(10)
  cache.get(c, "key1", 1000) |> should.equal(Ok("new"))
}

// ---------------------------------------------------------------------------
// TTL expiry
// ---------------------------------------------------------------------------

pub fn cache_ttl_expiry_test() {
  let assert Ok(c) = cache.start()
  cache.put(c, "ephemeral", "data", 50)
  sleep(10)
  // Should still be there
  cache.get(c, "ephemeral", 1000) |> should.be_ok
  // Wait for TTL
  sleep(100)
  // Should be expired
  cache.get(c, "ephemeral", 1000) |> should.be_error
}

// ---------------------------------------------------------------------------
// maybe_get / maybe_put
// ---------------------------------------------------------------------------

pub fn maybe_get_none_returns_error_test() {
  cache.maybe_get(option.None, "key", 1000) |> should.be_error
}

pub fn maybe_put_none_is_noop_test() {
  cache.maybe_put(option.None, "key", "val", 1000)
}

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil
