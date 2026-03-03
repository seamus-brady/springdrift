import agent/types.{
  type AgentOutcome, type AgentSpec, type AgentTask, type CognitiveMessage,
  AgentComplete, AgentFailure, AgentSuccess,
}
import cycle_log
import gleam/erlang/process.{type ExitMessage, type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import llm/provider
import llm/request
import llm/response
import llm/types as llm_types

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

type ActiveTask {
  ActiveTask(task_id: String, pid: Pid, reply_to: Subject(CognitiveMessage))
}

type AgentState {
  AgentState(active: List(ActiveTask))
}

type AgentEvent {
  NewTask(AgentTask)
  TaskDone(task_id: String, result: Result(String, String))
  WorkerExited(ExitMessage)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start an agent gen-server process. Returns the pid (linked to caller,
/// i.e. the supervisor) and a Subject for sending tasks.
pub fn start_agent(
  spec: AgentSpec,
) -> Result(#(Pid, Subject(types.AgentTask)), String) {
  let setup = process.new_subject()
  let pid =
    process.spawn(fn() {
      process.trap_exits(True)
      let task_subj = process.new_subject()
      let done_subj = process.new_subject()
      process.send(setup, Ok(task_subj))
      agent_loop(spec, task_subj, done_subj, AgentState(active: []))
    })
  case process.receive(setup, 5000) {
    Ok(Ok(subj)) -> Ok(#(pid, subj))
    Ok(Error(reason)) -> Error(reason)
    Error(_) -> Error("Agent failed to start: " <> spec.name)
  }
}

// ---------------------------------------------------------------------------
// Agent gen-server loop
// ---------------------------------------------------------------------------

fn agent_loop(
  spec: AgentSpec,
  task_subj: Subject(AgentTask),
  done_subj: Subject(#(String, Result(String, String))),
  state: AgentState,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(task_subj, fn(task) { NewTask(task) })
    |> process.select_map(done_subj, fn(done) { TaskDone(done.0, done.1) })
    |> process.select_trapped_exits(WorkerExited)

  case process.selector_receive_forever(selector) {
    NewTask(task) -> {
      let captured_done_subj = done_subj
      let worker_pid =
        process.spawn(fn() {
          let result = do_react_loop(spec, task)
          process.send(captured_done_subj, #(task.task_id, result))
        })
      let active_task =
        ActiveTask(
          task_id: task.task_id,
          pid: worker_pid,
          reply_to: task.reply_to,
        )
      agent_loop(
        spec,
        task_subj,
        done_subj,
        AgentState(active: [active_task, ..state.active]),
      )
    }

    TaskDone(task_id, result) -> {
      case find_active(state.active, task_id) {
        None -> agent_loop(spec, task_subj, done_subj, state)
        Some(active) -> {
          let outcome = outcome_from_result(task_id, spec.name, result)
          process.send(active.reply_to, AgentComplete(outcome:))
          agent_loop(
            spec,
            task_subj,
            done_subj,
            AgentState(active: remove_active(state.active, task_id)),
          )
        }
      }
    }

    WorkerExited(exit_msg) -> {
      case find_active_by_pid(state.active, exit_msg.pid) {
        None -> agent_loop(spec, task_subj, done_subj, state)
        Some(active) -> {
          let outcome =
            AgentFailure(
              task_id: active.task_id,
              agent: spec.name,
              error: "Worker crashed",
            )
          process.send(active.reply_to, AgentComplete(outcome:))
          agent_loop(
            spec,
            task_subj,
            done_subj,
            AgentState(active: remove_active(state.active, active.task_id)),
          )
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Inner react loop (runs in task worker process)
// ---------------------------------------------------------------------------

fn do_react_loop(spec: AgentSpec, task: AgentTask) -> Result(String, String) {
  let agent_cycle_id = cycle_log.generate_uuid()
  let req = build_agent_request(spec, task)
  do_react(req, spec, spec.max_turns, 0, agent_cycle_id)
}

fn do_react(
  req: llm_types.LlmRequest,
  spec: AgentSpec,
  remaining: Int,
  consecutive_errors: Int,
  cycle_id: String,
) -> Result(String, String) {
  case remaining {
    0 -> Error("max turns reached")
    _ ->
      case provider.chat_with(req, spec.provider) {
        Error(e) -> Error(response.error_message(e))
        Ok(resp) -> {
          case response.needs_tool_execution(resp) {
            False -> Ok(response.text(resp))
            True -> {
              let calls = response.tool_calls(resp)
              let results =
                list.map(calls, fn(call) {
                  cycle_log.log_tool_call(cycle_id, call)
                  let result = spec.tool_executor(call)
                  cycle_log.log_tool_result(cycle_id, result)
                  result
                })
              let has_failure =
                list.any(results, fn(r) {
                  case r {
                    llm_types.ToolFailure(..) -> True
                    _ -> False
                  }
                })
              let new_consecutive = case has_failure {
                True -> consecutive_errors + 1
                False -> 0
              }
              case new_consecutive >= spec.max_consecutive_errors {
                True -> Error("too many consecutive tool errors")
                False -> {
                  let next =
                    request.with_tool_results(req, resp.content, results)
                  do_react(next, spec, remaining - 1, new_consecutive, cycle_id)
                }
              }
            }
          }
        }
      }
  }
}

fn build_agent_request(spec: AgentSpec, task: AgentTask) -> llm_types.LlmRequest {
  let user_content = case task.context {
    "" -> task.instruction
    ctx -> task.instruction <> "\n\nContext:\n" <> ctx
  }
  let base =
    request.new(spec.model, spec.max_tokens)
    |> request.with_system(spec.system_prompt)
    |> request.with_user_message(user_content)
  case spec.tools {
    [] -> base
    tools -> request.with_tools(base, tools)
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn outcome_from_result(
  task_id: String,
  agent: String,
  result: Result(String, String),
) -> AgentOutcome {
  case result {
    Ok(text) -> AgentSuccess(task_id:, agent:, result: text)
    Error(err) -> AgentFailure(task_id:, agent:, error: err)
  }
}

fn find_active(
  tasks: List(ActiveTask),
  task_id: String,
) -> option.Option(ActiveTask) {
  case list.find(tasks, fn(t) { t.task_id == task_id }) {
    Ok(t) -> Some(t)
    Error(_) -> None
  }
}

fn find_active_by_pid(
  tasks: List(ActiveTask),
  pid: Pid,
) -> option.Option(ActiveTask) {
  case list.find(tasks, fn(t) { t.pid == pid }) {
    Ok(t) -> Some(t)
    Error(_) -> None
  }
}

fn remove_active(tasks: List(ActiveTask), task_id: String) -> List(ActiveTask) {
  list.filter(tasks, fn(t) { t.task_id != task_id })
}
