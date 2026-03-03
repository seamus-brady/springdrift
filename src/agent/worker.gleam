import agent/types.{
  type CognitiveMessage, ThinkComplete, ThinkError, ThinkWorkerDown,
}
import gleam/erlang/process
import llm/provider.{type Provider}
import llm/response
import llm/types as llm_types

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
      case provider.chat_with(req, provider) {
        Ok(resp) -> process.send(cognitive_self, ThinkComplete(task_id, resp))
        Error(err) ->
          process.send(
            cognitive_self,
            ThinkError(task_id, response.error_message(err)),
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
