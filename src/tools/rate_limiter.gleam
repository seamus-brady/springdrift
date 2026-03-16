/// Token-bucket rate limiter actor.
/// Prevents exceeding API rate limits for Brave Search and Answers.
import gleam/erlang/process.{type Subject}
import gleam/option

/// Messages accepted by the rate limiter actor.
pub type RateLimiterMessage {
  RequestToken(reply_to: Subject(Result(Nil, Nil)))
  Tick
}

/// Internal state for the token bucket.
pub type RateLimiterState {
  RateLimiterState(tokens: Int, capacity: Int, refill_rate_ms: Int)
}

/// Start a rate limiter actor with the given capacity and refill rate.
/// Returns the subject for sending messages.
pub fn start(
  capacity: Int,
  refill_rate_ms: Int,
) -> Result(Subject(RateLimiterMessage), Nil) {
  let state =
    RateLimiterState(tokens: capacity, capacity: capacity, refill_rate_ms:)
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(RateLimiterMessage) = process.new_subject()
    process.send(setup, self)
    // Schedule the first tick
    process.send_after(self, refill_rate_ms, Tick)
    loop(self, state)
  })
  case process.receive(setup, 5000) {
    Ok(subj) -> Ok(subj)
    Error(_) -> Error(Nil)
  }
}

fn loop(self: Subject(RateLimiterMessage), state: RateLimiterState) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(self)

  case process.selector_receive_forever(selector) {
    RequestToken(reply_to:) -> {
      case state.tokens > 0 {
        True -> {
          process.send(reply_to, Ok(Nil))
          loop(self, RateLimiterState(..state, tokens: state.tokens - 1))
        }
        False -> {
          process.send(reply_to, Error(Nil))
          loop(self, state)
        }
      }
    }
    Tick -> {
      let new_tokens = case state.tokens + 1 > state.capacity {
        True -> state.capacity
        False -> state.tokens + 1
      }
      process.send_after(self, state.refill_rate_ms, Tick)
      loop(self, RateLimiterState(..state, tokens: new_tokens))
    }
  }
}

/// Try to acquire a token, waiting up to timeout_ms.
/// Returns Ok(Nil) if acquired, Error(Nil) if rate limited.
pub fn acquire(
  limiter: Subject(RateLimiterMessage),
  timeout_ms: Int,
) -> Result(Nil, Nil) {
  let reply = process.new_subject()
  process.send(limiter, RequestToken(reply_to: reply))
  case process.receive(reply, timeout_ms) {
    Ok(result) -> result
    Error(_) -> Error(Nil)
  }
}

/// Optionally acquire a token if a limiter is available.
/// Returns Ok(Nil) always when limiter is None.
pub fn maybe_acquire(
  limiter: option.Option(Subject(RateLimiterMessage)),
  timeout_ms: Int,
) -> Result(Nil, Nil) {
  case limiter {
    option.None -> Ok(Nil)
    option.Some(l) -> acquire(l, timeout_ms)
  }
}
