import agent/types.{
  type CognitiveMessage, ThinkComplete, ThinkError, ThinkWorkerDown,
}
import gleam/erlang/process
import gleam/option
import llm/provider.{type Provider}
import llm/response
import llm/retry
import llm/types as llm_types
import slog

/// Spawn an unlinked think worker that makes an LLM call and sends the result
/// back to the cognitive loop. A monitor forwarder detects crashes.
pub fn spawn_think(
  task_id: String,
  req: llm_types.LlmRequest,
  provider: Provider,
  cognitive_self: process.Subject(CognitiveMessage),
) -> Nil {
  slog.debug(
    "worker",
    "spawn_think",
    "model=" <> req.model <> " task=" <> task_id,
    option.Some(task_id),
  )
  let pid =
    process.spawn_unlinked(fn() {
      case retry.call_with_retry(req, provider, 3, 500) {
        Ok(resp) -> process.send(cognitive_self, ThinkComplete(task_id, resp))
        Error(err) ->
          process.send(
            cognitive_self,
            ThinkError(
              task_id,
              response.error_message(err),
              retry.is_retryable(err),
            ),
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
