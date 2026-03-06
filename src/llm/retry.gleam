import gleam/erlang/process
import llm/provider.{type Provider}
import llm/types.{
  type LlmError, type LlmRequest, type LlmResponse, ApiError, NetworkError,
  RateLimitError, TimeoutError,
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

/// Call the provider with retry logic (exponential backoff).
/// `max_retries` is the number of retries (not total attempts).
/// `initial_delay_ms` is the delay before the first retry.
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
  delay_ms: Int,
) -> Result(LlmResponse, LlmError) {
  case provider.chat_with(req, provider) {
    Ok(resp) -> Ok(resp)
    Error(err) ->
      case is_retryable(err) && attempt < max_retries {
        True -> {
          process.sleep(delay_ms)
          do_call_with_retry(
            req,
            provider,
            attempt + 1,
            max_retries,
            delay_ms * 2,
          )
        }
        False -> Error(err)
      }
  }
}
