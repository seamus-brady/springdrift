import agent/types.{
  type CognitiveMessage, ThinkComplete, ThinkError, ThinkWorkerDown,
}
import gleam/erlang/process
import llm/provider.{type Provider}
import llm/response
import llm/types as llm_types

/// Max retry attempts for transient errors (529, 429, network, timeout).
const max_retries = 3

/// Spawn an unlinked think worker that makes an LLM call and sends the result
/// back to the cognitive loop. A monitor forwarder detects crashes.
pub fn spawn_think(
  task_id: String,
  req: llm_types.LlmRequest,
  provider: Provider,
  cognitive_self: process.Subject(CognitiveMessage),
) -> Nil {
  let pid =
    process.spawn_unlinked(fn() {
      case do_call_with_retry(req, provider, 0, 500) {
        Ok(resp) -> process.send(cognitive_self, ThinkComplete(task_id, resp))
        Error(err) ->
          process.send(
            cognitive_self,
            ThinkError(task_id, response.error_message(err), is_retryable(err)),
          )
      }
    })
  // Monitor forwarder: if the worker crashes before sending a message,
  // it sends ThinkWorkerDown to the cognitive loop.
  let monitor = process.monitor(pid)
  process.spawn_unlinked(fn() {
    let sel =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(_down) { Nil })
    process.selector_receive_forever(sel)
    process.send(
      cognitive_self,
      ThinkWorkerDown(task_id, "worker process exited"),
    )
  })
  Nil
}

fn do_call_with_retry(
  req: llm_types.LlmRequest,
  provider: Provider,
  attempt: Int,
  delay_ms: Int,
) -> Result(llm_types.LlmResponse, llm_types.LlmError) {
  case provider.chat_with(req, provider) {
    Ok(resp) -> Ok(resp)
    Error(err) ->
      case is_retryable(err) && attempt < max_retries {
        True -> {
          process.sleep(delay_ms)
          do_call_with_retry(req, provider, attempt + 1, delay_ms * 2)
        }
        False -> Error(err)
      }
  }
}

fn is_retryable(err: llm_types.LlmError) -> Bool {
  case err {
    // 529 = Anthropic overloaded
    llm_types.ApiError(status_code: 529, ..) -> True
    // 503 = service unavailable
    llm_types.ApiError(status_code: 503, ..) -> True
    // 429 handled as RateLimitError by the adapter
    llm_types.RateLimitError(..) -> True
    // Transient network / timeout
    llm_types.NetworkError(..) -> True
    llm_types.TimeoutError -> True
    _ -> False
  }
}
