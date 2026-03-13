import gleam/erlang/process
import gleam/int
import gleam/option.{None}
import llm/provider.{type Provider}
import llm/types.{
  type LlmError, type LlmRequest, type LlmResponse, ApiError, NetworkError,
  RateLimitError, TimeoutError,
}
import slog

/// Retry configuration for LLM calls with exponential backoff.
pub type RetryConfig {
  RetryConfig(
    max_retries: Int,
    initial_delay_ms: Int,
    rate_limit_delay_ms: Int,
    overload_delay_ms: Int,
    max_delay_ms: Int,
  )
}

/// Default retry configuration.
pub fn default_retry_config() -> RetryConfig {
  RetryConfig(
    max_retries: 3,
    initial_delay_ms: 500,
    rate_limit_delay_ms: 5000,
    overload_delay_ms: 2000,
    max_delay_ms: 60_000,
  )
}

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

/// Whether an error needs longer backoff (rate limit or server overload).
/// 429 = rate limited, 529 = Anthropic overloaded — both need breathing room.
pub fn is_rate_limit(err: LlmError) -> Bool {
  case err {
    ApiError(status_code: 429, ..) -> True
    ApiError(status_code: 529, ..) -> True
    RateLimitError(..) -> True
    _ -> False
  }
}

/// Initial backoff delay for an error type, using configurable delays.
fn initial_delay_for(err: LlmError, cfg: RetryConfig) -> Int {
  case err {
    ApiError(status_code: 429, ..) -> cfg.rate_limit_delay_ms
    RateLimitError(..) -> cfg.rate_limit_delay_ms
    ApiError(status_code: 529, ..) -> cfg.overload_delay_ms
    _ -> cfg.initial_delay_ms
  }
}

/// Call the provider with retry logic (exponential backoff).
/// Uses RetryConfig for all retry parameters.
pub fn call_with_retry(
  req: LlmRequest,
  provider: Provider,
  cfg: RetryConfig,
) -> Result(LlmResponse, LlmError) {
  do_call_with_retry(req, provider, 0, cfg)
}

fn do_call_with_retry(
  req: LlmRequest,
  provider: Provider,
  attempt: Int,
  cfg: RetryConfig,
) -> Result(LlmResponse, LlmError) {
  case provider.chat_with(req, provider) {
    Ok(resp) -> Ok(resp)
    Error(err) ->
      case is_retryable(err) && attempt < cfg.max_retries {
        True -> {
          // Rate limits get their own longer backoff; server errors use base
          let delay = case is_rate_limit(err) {
            True -> initial_delay_for(err, cfg) * pow2(attempt)
            False -> cfg.initial_delay_ms * pow2(attempt)
          }
          let capped = int.min(delay, cfg.max_delay_ms)
          slog.warn(
            "llm/retry",
            "backoff",
            "Attempt "
              <> int.to_string(attempt + 1)
              <> "/"
              <> int.to_string(cfg.max_retries)
              <> " failed, waiting "
              <> int.to_string(capped)
              <> "ms before retry",
            None,
          )
          process.sleep(capped)
          do_call_with_retry(req, provider, attempt + 1, cfg)
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
