import gleam/erlang/process
import gleeunit/should
import llm/adapters/mock
import llm/request
import llm/response
import llm/retry
import llm/types as llm_types

// ---------------------------------------------------------------------------
// call_with_retry — success on first attempt
// ---------------------------------------------------------------------------

pub fn success_on_first_attempt_test() {
  let provider = mock.provider_with_text("Hello!")
  let req =
    request.new("mock", 256)
    |> request.with_user_message("test")

  let assert Ok(resp) = retry.call_with_retry(req, provider, 3, 100)
  response.text(resp) |> should.equal("Hello!")
}

// ---------------------------------------------------------------------------
// call_with_retry — non-retryable error fails immediately
// ---------------------------------------------------------------------------

pub fn non_retryable_error_fails_immediately_test() {
  let provider = mock.provider_with_error("bad config")
  let req =
    request.new("mock", 256)
    |> request.with_user_message("test")

  let assert Error(_) = retry.call_with_retry(req, provider, 3, 100)
}

// ---------------------------------------------------------------------------
// call_with_retry — retryable error exhausts retries
// ---------------------------------------------------------------------------

pub fn retryable_error_exhausts_retries_test() {
  // 529 is retryable, but with 0 retries it should fail immediately
  let provider =
    mock.provider_with_handler(fn(_req) {
      Error(llm_types.ApiError(status_code: 529, message: "Overloaded"))
    })
  let req =
    request.new("mock", 256)
    |> request.with_user_message("test")

  let assert Error(llm_types.ApiError(status_code: 529, ..)) =
    retry.call_with_retry(req, provider, 0, 100)
}

// ---------------------------------------------------------------------------
// is_retryable — various error types
// ---------------------------------------------------------------------------

pub fn is_retryable_500_test() {
  retry.is_retryable(llm_types.ApiError(status_code: 500, message: ""))
  |> should.be_true
}

pub fn is_retryable_529_test() {
  retry.is_retryable(llm_types.ApiError(status_code: 529, message: ""))
  |> should.be_true
}

pub fn is_retryable_503_test() {
  retry.is_retryable(llm_types.ApiError(status_code: 503, message: ""))
  |> should.be_true
}

pub fn is_retryable_rate_limit_error_test() {
  retry.is_retryable(llm_types.RateLimitError(message: ""))
  |> should.be_true
}

pub fn is_retryable_api_error_429_test() {
  retry.is_retryable(llm_types.ApiError(status_code: 429, message: ""))
  |> should.be_true
}

pub fn is_retryable_network_test() {
  retry.is_retryable(llm_types.NetworkError(reason: ""))
  |> should.be_true
}

pub fn is_retryable_timeout_test() {
  retry.is_retryable(llm_types.TimeoutError)
  |> should.be_true
}

pub fn is_not_retryable_config_test() {
  retry.is_retryable(llm_types.ConfigError(reason: ""))
  |> should.be_false
}

pub fn is_not_retryable_decode_test() {
  retry.is_retryable(llm_types.DecodeError(reason: ""))
  |> should.be_false
}

pub fn is_not_retryable_400_test() {
  retry.is_retryable(llm_types.ApiError(status_code: 400, message: ""))
  |> should.be_false
}

pub fn is_not_retryable_unknown_test() {
  retry.is_retryable(llm_types.UnknownError(reason: ""))
  |> should.be_false
}

// ---------------------------------------------------------------------------
// call_with_retry — retryable error succeeds on retry
// ---------------------------------------------------------------------------

pub fn retryable_error_succeeds_on_retry_test() {
  // Use an Erlang counter via process dictionary to track attempts
  let counter = process.new_subject()
  // Pre-load the counter with 0
  process.send(counter, 0)

  let provider =
    mock.provider_with_handler(fn(_req) {
      let assert Ok(count) = process.receive(counter, 1000)
      case count {
        0 -> {
          process.send(counter, 1)
          Error(llm_types.ApiError(status_code: 529, message: "Overloaded"))
        }
        _ -> {
          process.send(counter, count + 1)
          Ok(mock.text_response("Recovered!"))
        }
      }
    })
  let req =
    request.new("mock", 256)
    |> request.with_user_message("test")

  let assert Ok(resp) = retry.call_with_retry(req, provider, 3, 50)
  response.text(resp) |> should.equal("Recovered!")
}
