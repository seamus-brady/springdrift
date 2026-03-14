import gleam/option
import gleeunit
import gleeunit/should
import tools/rate_limiter

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Token acquisition
// ---------------------------------------------------------------------------

pub fn acquire_token_succeeds_test() {
  let assert Ok(limiter) = rate_limiter.start(5, 1000)
  rate_limiter.acquire(limiter, 1000) |> should.be_ok
}

pub fn acquire_multiple_tokens_test() {
  let assert Ok(limiter) = rate_limiter.start(3, 1000)
  rate_limiter.acquire(limiter, 1000) |> should.be_ok
  rate_limiter.acquire(limiter, 1000) |> should.be_ok
  rate_limiter.acquire(limiter, 1000) |> should.be_ok
}

// ---------------------------------------------------------------------------
// Token exhaustion
// ---------------------------------------------------------------------------

pub fn acquire_fails_when_exhausted_test() {
  let assert Ok(limiter) = rate_limiter.start(1, 60_000)
  // First should succeed
  rate_limiter.acquire(limiter, 1000) |> should.be_ok
  // Second should fail (no refill yet)
  rate_limiter.acquire(limiter, 100) |> should.be_error
}

// ---------------------------------------------------------------------------
// Token refill
// ---------------------------------------------------------------------------

pub fn token_refills_after_interval_test() {
  let assert Ok(limiter) = rate_limiter.start(1, 50)
  // Use the token
  rate_limiter.acquire(limiter, 1000) |> should.be_ok
  // Wait for refill
  sleep(100)
  // Should have a token again
  rate_limiter.acquire(limiter, 1000) |> should.be_ok
}

// ---------------------------------------------------------------------------
// maybe_acquire
// ---------------------------------------------------------------------------

pub fn maybe_acquire_none_always_ok_test() {
  rate_limiter.maybe_acquire(option.None, 1000) |> should.be_ok
}

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil
