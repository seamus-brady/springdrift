import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import llm/provider.{type Provider}
import llm/request
import llm/response
import llm/types.{
  type LlmError, type LlmRequest, type LlmResponse, type Message, type Tool,
  type ToolCall, type ToolResult, Assistant, Message, TextContent, ToolFailure,
  ToolSuccess, User,
}
import tools/builtin

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type ChatState {
  ChatState(
    provider: Provider,
    model: String,
    system: String,
    max_tokens: Int,
    messages: List(Message),
    tools: List(Tool),
  )
}

pub type AgentQuestion {
  AgentQuestion(question: String, reply_to: Subject(String))
}

pub type ChatMessage {
  SendMessage(
    text: String,
    reply_to: Subject(Result(LlmResponse, LlmError)),
    question_channel: Subject(AgentQuestion),
  )
  GetHistory(reply_to: Subject(List(Message)))
  ClearHistory
  // Internal — sent back from the spawned HTTP worker
  LlmComplete(
    result: Result(LlmResponse, LlmError),
    reply_to: Subject(Result(LlmResponse, LlmError)),
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn start(
  provider: Provider,
  model: String,
  system: String,
  max_tokens: Int,
  tools: List(Tool),
) -> Subject(ChatMessage) {
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let self = process.new_subject()
    process.send(setup, self)
    service_loop(
      self,
      ChatState(provider:, model:, system:, max_tokens:, messages: [], tools:),
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
    SendMessage(text:, reply_to:, question_channel:) -> {
      let new_state = append_user_message(state, text)
      let req = build_request(new_state)
      process.spawn_unlinked(fn() {
        let result = react_loop(req, new_state.provider, 5, question_channel)
        process.send(self, LlmComplete(result:, reply_to:))
      })
      service_loop(self, new_state)
    }
    LlmComplete(result:, reply_to:) -> {
      let new_state = append_assistant_message(state, result)
      process.send(reply_to, result)
      service_loop(self, new_state)
    }
    GetHistory(reply_to:) -> {
      process.send(reply_to, state.messages)
      service_loop(self, state)
    }
    ClearHistory -> service_loop(self, ChatState(..state, messages: []))
  }
}

fn react_loop(
  req: LlmRequest,
  p: Provider,
  max_turns: Int,
  question_channel: Subject(AgentQuestion),
) -> Result(LlmResponse, LlmError) {
  case provider.chat_with(req, p) {
    Error(e) -> Error(e)
    Ok(resp) ->
      case response.needs_tool_execution(resp) && max_turns > 0 {
        False -> Ok(resp)
        True -> {
          let calls = response.tool_calls(resp)
          let results =
            list.map(calls, fn(call) {
              case call.name {
                "request_human_input" ->
                  execute_human_input(call, question_channel)
                _ -> builtin.execute(call)
              }
            })
          let next = request.with_tool_results(req, resp.content, results)
          react_loop(next, p, max_turns - 1, question_channel)
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

fn append_assistant_message(
  state: ChatState,
  result: Result(LlmResponse, LlmError),
) -> ChatState {
  let text = case result {
    Ok(resp) -> response.text(resp)
    Error(err) -> "[Error: " <> response.error_message(err) <> "]"
  }
  let msg = Message(role: Assistant, content: [TextContent(text:)])
  ChatState(..state, messages: list.append(state.messages, [msg]))
}

fn build_request(state: ChatState) -> LlmRequest {
  let base =
    request.new(state.model, state.max_tokens)
    |> request.with_system(state.system)
    |> request.with_messages(state.messages)
  case state.tools {
    [] -> base
    tools -> request.with_tools(base, tools)
  }
}
