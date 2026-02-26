import app_log
import context
import cycle_log
import gleam/dynamic/decode
import gleam/erlang/process.{type Down, type Monitor, type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import llm/provider.{type Provider}
import llm/request
import llm/response
import llm/types.{
  type LlmError, type LlmRequest, type LlmResponse, type Message, type Tool,
  type ToolCall, type ToolResult, Assistant, Message, TextContent, ToolFailure,
  ToolSuccess, UnknownError, User,
}
import query_complexity
import sandbox.{type SandboxMessage}
import storage
import tools/builtin
import tools/files
import tools/sandbox_mgmt
import tools/shell
import tools/web

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type ServiceReply {
  ServiceReply(
    llm_result: Result(LlmResponse, LlmError),
    final_model: String,
    save_error: Option(String),
  )
}

pub type ModelSwitchAnswer {
  AcceptModelSwitch
  DeclineModelSwitch
}

pub type ModelSwitchQuestion {
  ModelSwitchQuestion(
    current_model: String,
    suggested_model: String,
    reply_to: Subject(ModelSwitchAnswer),
  )
}

pub type ChatState {
  ChatState(
    provider: Provider,
    model: String,
    system: String,
    max_tokens: Int,
    max_turns: Int,
    max_consecutive_errors: Int,
    max_context_messages: Option(Int),
    messages: List(Message),
    tools: List(Tool),
    last_cycle_id: Option(String),
    task_model: String,
    reasoning_model: String,
    prompt_on_complex: Bool,
    verbose: Bool,
    sandbox: Option(Subject(SandboxMessage)),
    write_anywhere: Bool,
    // Active request tracking — used to detect and recover from worker crashes
    active_reply: Option(Subject(ServiceReply)),
    worker_monitor: Option(Monitor),
  )
}

// Internal selector event type — either a normal ChatMessage or a worker DOWN.
type ServiceEvent {
  ServiceMsg(ChatMessage)
  WorkerDied(Down)
}

pub type AgentQuestion {
  AgentQuestion(question: String, reply_to: Subject(String))
}

pub type ToolEvent {
  ToolCalling(name: String)
}

pub type ChatMessage {
  SendMessage(
    text: String,
    reply_to: Subject(ServiceReply),
    question_channel: Subject(AgentQuestion),
    tool_channel: Subject(ToolEvent),
    model_question_channel: Subject(ModelSwitchQuestion),
  )
  GetHistory(reply_to: Subject(List(Message)))
  ClearHistory
  RestoreMessages(messages: List(Message))
  // Internal — sent back from the spawned HTTP worker
  LlmComplete(
    result: Result(LlmResponse, LlmError),
    final_messages: List(Message),
    final_model: String,
    reply_to: Subject(ServiceReply),
  )
  SetModel(model: String)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn start(
  provider: Provider,
  model: String,
  system: String,
  max_tokens: Int,
  max_turns: Int,
  max_consecutive_errors: Int,
  max_context_messages: Option(Int),
  tools: List(Tool),
  initial_messages: List(Message),
  task_model: String,
  reasoning_model: String,
  prompt_on_complex: Bool,
  verbose: Bool,
  sandbox: Option(Subject(SandboxMessage)),
  write_anywhere: Bool,
) -> Subject(ChatMessage) {
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let self = process.new_subject()
    process.send(setup, self)
    service_loop(
      self,
      ChatState(
        provider:,
        model:,
        system:,
        max_tokens:,
        max_turns:,
        max_consecutive_errors:,
        max_context_messages:,
        messages: initial_messages,
        tools:,
        last_cycle_id: None,
        task_model:,
        reasoning_model:,
        prompt_on_complex:,
        verbose:,
        sandbox:,
        write_anywhere:,
        active_reply: None,
        worker_monitor: None,
      ),
    )
  })
  let assert Ok(subj) = process.receive(setup, 1000)
  subj
}

// ---------------------------------------------------------------------------
// Internal loop
// ---------------------------------------------------------------------------

fn service_loop(self: Subject(ChatMessage), state: ChatState) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(self, ServiceMsg)
  let selector = case state.worker_monitor {
    None -> selector
    Some(mon) -> process.select_specific_monitor(selector, mon, WorkerDied)
  }
  case process.selector_receive_forever(selector) {
    WorkerDied(_) -> {
      app_log.err("llm_worker_crashed", [])
      case state.active_reply {
        Some(reply_to) ->
          process.send(
            reply_to,
            ServiceReply(
              llm_result: Error(UnknownError("LLM worker crashed unexpectedly")),
              final_model: state.model,
              save_error: None,
            ),
          )
        None -> Nil
      }
      service_loop(
        self,
        ChatState(..state, active_reply: None, worker_monitor: None),
      )
    }
    ServiceMsg(msg) ->
      case msg {
        SendMessage(
          text:,
          reply_to:,
          question_channel:,
          tool_channel:,
          model_question_channel:,
        ) -> {
          let cycle_id = cycle_log.generate_uuid()
          let parent_id = state.last_cycle_id
          cycle_log.log_human_input(cycle_id, parent_id, text)

          // Classify complexity and determine the model to use for this cycle
          let complexity =
            query_complexity.classify(text, state.provider, state.task_model)
          let complexity_str = case complexity {
            query_complexity.Simple -> "simple"
            query_complexity.Complex -> "complex"
          }
          let #(final_model, prompted, confirmed) = case complexity {
            query_complexity.Simple -> #(state.model, False, None)
            query_complexity.Complex ->
              case state.model == state.reasoning_model {
                True -> #(state.model, False, None)
                False ->
                  case state.prompt_on_complex {
                    True -> {
                      let reply_subj = process.new_subject()
                      process.send(
                        model_question_channel,
                        ModelSwitchQuestion(
                          current_model: state.model,
                          suggested_model: state.reasoning_model,
                          reply_to: reply_subj,
                        ),
                      )
                      let answer = process.receive_forever(reply_subj)
                      case answer {
                        AcceptModelSwitch -> #(
                          state.reasoning_model,
                          True,
                          Some(True),
                        )
                        DeclineModelSwitch -> #(state.model, True, Some(False))
                      }
                    }
                    False -> #(state.reasoning_model, False, None)
                  }
              }
          }
          cycle_log.log_classification(
            cycle_id,
            complexity_str,
            state.reasoning_model,
            prompted,
            confirmed,
          )

          let new_state =
            ChatState(
              ..append_user_message(state, text),
              last_cycle_id: Some(cycle_id),
              model: final_model,
            )
          let req = build_request(new_state)
          let worker_pid =
            process.spawn_unlinked(fn() {
              let react_result =
                react_loop(
                  req,
                  new_state.provider,
                  new_state.max_turns,
                  0,
                  new_state.max_consecutive_errors,
                  question_channel,
                  tool_channel,
                  cycle_id,
                  new_state.verbose,
                  new_state.sandbox,
                  new_state.write_anywhere,
                )
              let #(result, final_messages) = case react_result {
                Ok(#(resp, msgs)) -> #(Ok(resp), msgs)
                Error(err) -> {
                  let err_text =
                    "[Error: " <> response.error_message(err) <> "]"
                  let err_msg =
                    Message(role: Assistant, content: [
                      TextContent(text: err_text),
                    ])
                  #(Error(err), list.append(new_state.messages, [err_msg]))
                }
              }
              process.send(
                self,
                LlmComplete(result:, final_messages:, final_model:, reply_to:),
              )
            })
          let mon = process.monitor(worker_pid)
          service_loop(
            self,
            ChatState(
              ..new_state,
              active_reply: Some(reply_to),
              worker_monitor: Some(mon),
            ),
          )
        }
        LlmComplete(result:, final_messages:, final_model:, reply_to:) -> {
          // Worker completed normally — demonitor (with flush) so no stale DOWN arrives.
          case state.worker_monitor {
            Some(mon) -> process.demonitor_process(mon)
            None -> Nil
          }
          // Log any LLM-level error to the app log for visibility.
          case result {
            Error(e) ->
              app_log.err("llm_request_failed", [
                #("reason", response.error_message(e)),
              ])
            Ok(_) -> Nil
          }
          let new_state =
            ChatState(
              ..state,
              messages: final_messages,
              active_reply: None,
              worker_monitor: None,
            )
          let save_error = case storage.save(new_state.messages) {
            Ok(_) -> {
              app_log.info("session_saved", [])
              None
            }
            Error(msg) -> {
              app_log.err("session_save_failed", [#("reason", msg)])
              Some(msg)
            }
          }
          process.send(
            reply_to,
            ServiceReply(llm_result: result, final_model:, save_error:),
          )
          service_loop(self, new_state)
        }
        GetHistory(reply_to:) -> {
          process.send(reply_to, state.messages)
          service_loop(self, state)
        }
        ClearHistory -> {
          case storage.clear() {
            Ok(_) -> Nil
            Error(msg) ->
              app_log.warn("session_clear_failed", [#("reason", msg)])
          }
          service_loop(
            self,
            ChatState(..state, messages: [], last_cycle_id: None),
          )
        }
        RestoreMessages(messages:) -> {
          case storage.save(messages) {
            Ok(_) -> Nil
            Error(msg) ->
              app_log.warn("session_restore_save_failed", [#("reason", msg)])
          }
          service_loop(self, ChatState(..state, messages:))
        }
        SetModel(model:) -> {
          service_loop(self, ChatState(..state, model:))
        }
      }
  }
}

fn react_loop(
  req: LlmRequest,
  p: Provider,
  max_turns: Int,
  consecutive_errors: Int,
  max_consecutive_errors: Int,
  question_channel: Subject(AgentQuestion),
  tool_channel: Subject(ToolEvent),
  cycle_id: String,
  verbose: Bool,
  sandbox: Option(Subject(SandboxMessage)),
  write_anywhere: Bool,
) -> Result(#(LlmResponse, List(Message)), LlmError) {
  case verbose {
    True -> cycle_log.log_llm_request(cycle_id, req)
    False -> Nil
  }
  case provider.chat_with(req, p) {
    Error(e) -> Error(e)
    Ok(resp) -> {
      case verbose {
        True -> cycle_log.log_llm_response(cycle_id, resp)
        False -> Nil
      }
      case response.needs_tool_execution(resp) {
        False -> {
          let final_msg = Message(role: Assistant, content: resp.content)
          Ok(#(resp, list.append(req.messages, [final_msg])))
        }
        True ->
          case max_turns {
            0 -> Error(UnknownError("Agent loop: maximum turns reached"))
            _ -> {
              let calls = response.tool_calls(resp)
              let results =
                list.map(calls, fn(call) {
                  process.send(tool_channel, ToolCalling(name: call.name))
                  cycle_log.log_tool_call(cycle_id, call)
                  let result = case call.name {
                    "run_shell" -> shell.execute(call, sandbox)
                    "read_file" | "write_file" | "list_directory" ->
                      files.execute(call, write_anywhere)
                    "fetch_url" -> web.execute(call)
                    "request_human_input" ->
                      execute_human_input(call, question_channel)
                    "sandbox_status"
                    | "sandbox_logs"
                    | "restart_sandbox"
                    | "copy_from_sandbox"
                    | "copy_to_sandbox" -> sandbox_mgmt.execute(call, sandbox)
                    _ -> builtin.execute(call)
                  }
                  cycle_log.log_tool_result(cycle_id, result)
                  result
                })
              let has_any_failure =
                list.any(results, fn(r) {
                  case r {
                    ToolFailure(..) -> True
                    _ -> False
                  }
                })
              let new_consecutive = case has_any_failure {
                True -> consecutive_errors + 1
                False -> 0
              }
              case new_consecutive >= max_consecutive_errors {
                True ->
                  Error(UnknownError(
                    "Agent loop: too many consecutive tool errors",
                  ))
                False -> {
                  let next =
                    request.with_tool_results(req, resp.content, results)
                  react_loop(
                    next,
                    p,
                    max_turns - 1,
                    new_consecutive,
                    max_consecutive_errors,
                    question_channel,
                    tool_channel,
                    cycle_id,
                    verbose,
                    sandbox,
                    write_anywhere,
                  )
                }
              }
            }
          }
      }
    }
  }
}

fn execute_human_input(
  call: ToolCall,
  question_channel: Subject(AgentQuestion),
) -> ToolResult {
  let decoder = {
    use question <- decode.field("question", decode.string)
    decode.success(question)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid request_human_input arguments",
      )
    Ok(question) -> {
      let reply_subj = process.new_subject()
      process.send(
        question_channel,
        AgentQuestion(question:, reply_to: reply_subj),
      )
      let answer = process.receive_forever(reply_subj)
      ToolSuccess(tool_use_id: call.id, content: answer)
    }
  }
}

fn append_user_message(state: ChatState, text: String) -> ChatState {
  let msg = Message(role: User, content: [TextContent(text:)])
  ChatState(..state, messages: list.append(state.messages, [msg]))
}

fn build_request(state: ChatState) -> LlmRequest {
  let messages = case state.max_context_messages {
    None -> state.messages
    Some(max) -> context.trim(state.messages, max)
  }
  let base =
    request.new(state.model, state.max_tokens)
    |> request.with_system(state.system)
    |> request.with_messages(messages)
  case state.tools {
    [] -> base
    tools -> request.with_tools(base, tools)
  }
}
