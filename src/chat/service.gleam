import gleam/erlang/process.{type Subject}
import gleam/list
import llm/provider.{type Provider}
import llm/request
import llm/response
import llm/types.{
  type LlmError, type LlmRequest, type LlmResponse, type Message, type Tool,
  Assistant, Message, TextContent, User,
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

pub type ChatMessage {
  SendMessage(text: String, reply_to: Subject(Result(LlmResponse, LlmError)))
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
    SendMessage(text:, reply_to:) -> {
      let new_state = append_user_message(state, text)
      let req = build_request(new_state)
      process.spawn_unlinked(fn() {
        let result = react_loop(req, new_state.provider, 5)
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
) -> Result(LlmResponse, LlmError) {
  case provider.chat_with(req, p) {
    Error(e) -> Error(e)
    Ok(resp) ->
      case response.needs_tool_execution(resp) && max_turns > 0 {
        False -> Ok(resp)
        True -> {
          let calls = response.tool_calls(resp)
          let results = list.map(calls, builtin.execute)
          let next = request.with_tool_results(req, resp.content, results)
          react_loop(next, p, max_turns - 1)
        }
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
