import classifier
import context
import cycle_log
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
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
import storage
import tools/builtin

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

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
  )
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
    reply_to: Subject(#(Result(LlmResponse, LlmError), String)),
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
    reply_to: Subject(#(Result(LlmResponse, LlmError), String)),
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
  case process.receive_forever(self) {
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
      let complexity = classifier.classify(text)
      let complexity_str = case complexity {
        classifier.Simple -> "simple"
        classifier.Complex -> "complex"
      }
      let #(final_model, prompted, confirmed) = case complexity {
        classifier.Simple -> #(state.model, False, None)
        classifier.Complex ->
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
          )
        let #(result, final_messages) = case react_result {
          Ok(#(resp, msgs)) -> #(Ok(resp), msgs)
          Error(err) -> {
            let err_text = "[Error: " <> response.error_message(err) <> "]"
            let err_msg =
              Message(role: Assistant, content: [TextContent(text: err_text)])
            #(Error(err), list.append(new_state.messages, [err_msg]))
          }
        }
        process.send(
          self,
          LlmComplete(result:, final_messages:, final_model:, reply_to:),
        )
      })
      service_loop(self, new_state)
    }
    LlmComplete(result:, final_messages:, final_model:, reply_to:) -> {
      let new_state = ChatState(..state, messages: final_messages)
      storage.save(new_state.messages)
      process.send(reply_to, #(result, final_model))
      service_loop(self, new_state)
    }
    GetHistory(reply_to:) -> {
      process.send(reply_to, state.messages)
      service_loop(self, state)
    }
    ClearHistory -> {
      storage.clear()
      service_loop(self, ChatState(..state, messages: [], last_cycle_id: None))
    }
    RestoreMessages(messages:) -> {
      storage.save(messages)
      service_loop(self, ChatState(..state, messages:))
    }
    SetModel(model:) -> {
      service_loop(self, ChatState(..state, model:))
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
) -> Result(#(LlmResponse, List(Message)), LlmError) {
  cycle_log.log_llm_request(cycle_id, req)
  case provider.chat_with(req, p) {
    Error(e) -> Error(e)
    Ok(resp) -> {
      cycle_log.log_llm_response(cycle_id, resp)
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
                    "request_human_input" ->
                      execute_human_input(call, question_channel)
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
