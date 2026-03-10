import gleam/erlang/process
import gleam/int
import gleam/option.{None}
import llm/provider.{type Provider}
import llm/types.{
  type LlmError, type LlmRequest, type LlmResponse, ApiError, NetworkError,
  RateLimitError, TimeoutError,
}
import slog

/// Whether an LLM error is transient and worth retrying.
pub fn is_retryable(err: LlmError) -> Bool {
  case err {
    ApiError(status_code: 429, ..) -> True
    ApiError(status_code: 500, ..) -> True
    ApiError(status_code: 503, ..) -> True
    ApiError(status_code: 529, ..) -> True
    RateLimitError(..) -> True
    NetworkError(..) -> True
    TimeoutError -> True
    _ -> False
  }
}

/// Whether an error is specifically a rate limit (needs longer backoff).
pub fn is_rate_limit(err: LlmError) -> Bool {
  case err {
    ApiError(status_code: 429, ..) -> True
    RateLimitError(..) -> True
    _ -> False
  }
}

/// Initial backoff delay for an error type.
/// Rate limits: 5s (APIs typically enforce windows of 60s+).
/// Server errors / network: 500ms.
fn initial_delay_for(err: LlmError) -> Int {
  case is_rate_limit(err) {
    True -> 5000
    False -> 500
  }
}

/// Call the provider with retry logic (exponential backoff).
/// `max_retries` is the number of retries (not total attempts).
/// `initial_delay_ms` is the delay before the first retry for server errors.
/// Rate limit errors automatically use a longer backoff (5s base).
pub fn call_with_retry(
  req: LlmRequest,
  provider: Provider,
  max_retries: Int,
  initial_delay_ms: Int,
) -> Result(LlmResponse, LlmError) {
  do_call_with_retry(req, provider, 0, max_retries, initial_delay_ms)
}

fn do_call_with_retry(
  req: LlmRequest,
  provider: Provider,
  attempt: Int,
  max_retries: Int,
  base_delay_ms: Int,
) -> Result(LlmResponse, LlmError) {
  case provider.chat_with(req, provider) {
    Ok(resp) -> Ok(resp)
    Error(err) ->
      case is_retryable(err) && attempt < max_retries {
        True -> {
          // Rate limits get their own longer backoff; server errors use base
          let delay = case is_rate_limit(err) {
            True -> initial_delay_for(err) * pow2(attempt)
            False -> base_delay_ms * pow2(attempt)
          }
          // Cap at 60s to avoid absurdly long waits
          let capped = int.min(delay, 60_000)
          slog.warn(
            "llm/retry",
            "backoff",
            "Attempt "
              <> int.to_string(attempt + 1)
              <> "/"
              <> int.to_string(max_retries)
              <> " failed, waiting "
              <> int.to_string(capped)
              <> "ms before retry",
            None,
          )
          process.sleep(capped)
          do_call_with_retry(
            req,
            provider,
            attempt + 1,
            max_retries,
            base_delay_ms,
          )
        }
        False -> Error(err)
      }
  }
}

/// 2^n (integer power of 2) for backoff multiplier.
fn pow2(n: Int) -> Int {
  case n {
    0 -> 1
    1 -> 2
    2 -> 4
    3 -> 8
    _ -> 16
  }
}
