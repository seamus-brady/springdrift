//// ACP (Agent Client Protocol) client for OpenCode.
////
//// JSON-RPC over stdio against `podman exec -i <container> opencode acp`.
//// One actor per session — owns the subprocess controller (Erlang FFI),
//// dispatches initialize/session_new/session_prompt/session_cancel,
//// streams session/update notifications back via a caller-supplied
//// Subject.
////
//// Reference:
////   - https://opencode.ai/docs/acp/
////   - https://agentclientprotocol.com/protocol/{initialization,prompt-turn}.md
////
//// Scope: minimum viable for R3. session_load / session_list /
//// session_fork are scaffolded as method names but the Gleam-side
//// helpers ship in R7 when CBR-driven resume lands.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A running ACP session — opaque handle. Internally wraps the Subject
/// callers send messages to.
pub type AcpHandle {
  AcpHandle(subject: Subject(AcpControlMsg))
}

/// Control messages the ACP actor processes. Public because R4's
/// manager constructs them; not for direct consumer use.
pub type AcpControlMsg {
  /// Send the initialize handshake.
  CtlInitialize(reply_to: Subject(Result(AgentCapabilities, AcpError)))
  /// Create a new session in the subprocess.
  CtlSessionNew(
    cwd: String,
    model_id: Option(String),
    reply_to: Subject(Result(String, AcpError)),
  )
  /// Send a prompt and stream events to `event_sink` until the
  /// session/prompt response arrives.
  CtlSessionPrompt(
    session_id: String,
    prompt_text: String,
    event_sink: Subject(AcpEvent),
    reply_to: Subject(Result(PromptResult, AcpError)),
  )
  /// Cancel an in-flight prompt. Best-effort — the subprocess responds
  /// to the original prompt with stopReason: "cancelled".
  CtlSessionCancel(session_id: String, reply_to: Subject(Result(Nil, AcpError)))
  /// Tear down the subprocess and exit the actor.
  CtlClose
  /// Internal: arrives from the FFI controller when a JSON-RPC line
  /// is read from the subprocess stdout.
  CtlInbound(line: String)
  /// Internal: subprocess exited (clean or otherwise).
  CtlSubprocessExited(status: Int)
}

/// What the agent reports about itself at initialize time.
pub type AgentCapabilities {
  AgentCapabilities(
    protocol_version: Int,
    can_load_session: Bool,
    can_fork: Bool,
    can_resume: Bool,
    can_list: Bool,
    auth_methods: List(String),
    agent_name: String,
    agent_version: String,
  )
}

/// Result of a completed prompt turn.
pub type PromptResult {
  PromptResult(
    stop_reason: StopReason,
    total_tokens: Int,
    input_tokens: Int,
    output_tokens: Int,
    cached_read_tokens: Int,
  )
}

pub type StopReason {
  StopEndTurn
  StopMaxTokens
  StopMaxTurnRequests
  StopRefusal
  StopCancelled
  StopUnknown(raw: String)
}

/// Streaming events arriving as session/update notifications.
/// Intentionally narrow — Springdrift consumes a subset; everything
/// else lands as AcpUnknown so future shape additions don't crash.
pub type AcpEvent {
  /// Model's chain of thought (when reasoning models surface it).
  AcpThoughtChunk(message_id: String, text: String)
  /// Model's natural-language output to the operator.
  AcpMessageChunk(message_id: String, text: String)
  /// Agent invoked a tool. Shape per ACP spec.
  AcpToolCall(tool_call_id: String, title: String, kind: String)
  /// Tool call status changed (in_progress, completed, cancelled).
  AcpToolCallUpdate(tool_call_id: String, status: String)
  /// Cost / token usage update — fed to circuit breaker.
  AcpUsageUpdate(used_tokens: Int, total_size: Int, cost_usd: Float)
  /// Catch-all for unrecognised event types so future OpenCode
  /// versions don't crash older Springdrift builds.
  AcpUnknown(raw_json: String)
}

pub type AcpError {
  /// Spawn / port open failed.
  AcpOpenFailed(reason: String)
  /// Subprocess exited before the operation completed.
  AcpSubprocessExit(status: Int)
  /// A JSON-RPC request received an `error` response.
  AcpRpcError(code: Int, message: String, data: Option(String))
  /// Response decode failed (schema mismatch).
  AcpDecodeError(reason: String)
  /// Operation timed out waiting for a response.
  AcpTimeout(operation: String, ms: Int)
  /// Internal protocol violation (id collision, double-reply, etc).
  AcpProtocolError(reason: String)
  /// Caller used the handle after close.
  AcpClosed
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

/// Erlang controller pid that owns the actual port. Internal — the
/// public API uses AcpHandle.
type ControllerPid =
  Pid

@external(erlang, "springdrift_ffi", "acp_open")
fn ffi_open(
  container_id: String,
  client: Subject(AcpControlMsg),
) -> Result(ControllerPid, String)

@external(erlang, "springdrift_ffi", "acp_send")
fn ffi_send(controller: ControllerPid, line: String) -> Nil

@external(erlang, "springdrift_ffi", "acp_close")
fn ffi_close(controller: ControllerPid) -> Nil

// ---------------------------------------------------------------------------
// Actor — one per session
// ---------------------------------------------------------------------------

type ActorState {
  ActorState(
    self: Subject(AcpControlMsg),
    controller: ControllerPid,
    next_id: Int,
    /// Awaiting a response: id → reply_target. The reply_target is the
    /// Subject the caller passed in their CtlInitialize/CtlSessionNew
    /// /etc message; we store it as Dynamic since the response type
    /// varies by request and we route through a uniform mailbox.
    pending: dict.Dict(Int, PendingReply),
    /// Active prompt's event sink. None when no prompt is in flight.
    active_prompt_sink: Option(Subject(AcpEvent)),
    /// True after CtlClose / subprocess exit. Further calls fail with
    /// AcpClosed.
    closed: Bool,
  )
}

type PendingReply {
  PendingInitialize(reply_to: Subject(Result(AgentCapabilities, AcpError)))
  PendingSessionNew(reply_to: Subject(Result(String, AcpError)))
  PendingPrompt(reply_to: Subject(Result(PromptResult, AcpError)))
  PendingCancel(reply_to: Subject(Result(Nil, AcpError)))
}

/// Open a new ACP session bound to the given container.
/// The returned handle is the public API the manager uses.
pub fn open(container_id: String) -> Result(AcpHandle, AcpError) {
  let setup: Subject(Result(Subject(AcpControlMsg), String)) =
    process.new_subject()
  process.spawn(fn() {
    let self: Subject(AcpControlMsg) = process.new_subject()
    case ffi_open(container_id, self) {
      Error(reason) -> process.send(setup, Error(reason))
      Ok(controller) -> {
        process.send(setup, Ok(self))
        let state =
          ActorState(
            self: self,
            controller: controller,
            next_id: 1,
            pending: dict.new(),
            active_prompt_sink: None,
            closed: False,
          )
        actor_loop(state)
      }
    }
  })

  case process.receive(setup, 5000) {
    Error(_) -> Error(AcpOpenFailed(reason: "ACP actor setup timeout"))
    Ok(Error(reason)) -> Error(AcpOpenFailed(reason: reason))
    Ok(Ok(self)) -> Ok(AcpHandle(subject: self))
  }
}

fn actor_loop(state: ActorState) -> Nil {
  case state.closed {
    True -> Nil
    False -> {
      let msg = process.receive_forever(state.self)
      let new_state = handle_msg(state, msg)
      actor_loop(new_state)
    }
  }
}

fn handle_msg(state: ActorState, msg: AcpControlMsg) -> ActorState {
  case msg {
    CtlInitialize(reply_to:) -> {
      let id = state.next_id
      let line = build_initialize(id)
      ffi_send(state.controller, line)
      ActorState(
        ..state,
        next_id: id + 1,
        pending: dict.insert(state.pending, id, PendingInitialize(reply_to)),
      )
    }
    CtlSessionNew(cwd:, model_id: _, reply_to:) -> {
      let id = state.next_id
      let line = build_session_new(id, cwd)
      ffi_send(state.controller, line)
      ActorState(
        ..state,
        next_id: id + 1,
        pending: dict.insert(state.pending, id, PendingSessionNew(reply_to)),
      )
    }
    CtlSessionPrompt(session_id:, prompt_text:, event_sink:, reply_to:) -> {
      let id = state.next_id
      let line = build_session_prompt(id, session_id, prompt_text)
      ffi_send(state.controller, line)
      ActorState(
        ..state,
        next_id: id + 1,
        pending: dict.insert(state.pending, id, PendingPrompt(reply_to)),
        active_prompt_sink: Some(event_sink),
      )
    }
    CtlSessionCancel(session_id:, reply_to:) -> {
      let id = state.next_id
      let line = build_session_cancel(id, session_id)
      ffi_send(state.controller, line)
      // session/cancel is fire-and-forget per spec — most agents don't
      // reply with a JSON-RPC response; the active prompt's response
      // arrives with stopReason: "cancelled". Reply Ok immediately so
      // the caller can move on.
      process.send(reply_to, Ok(Nil))
      ActorState(..state, next_id: id + 1)
    }
    CtlClose -> {
      ffi_close(state.controller)
      // Fail any pending replies so callers don't hang.
      dict.each(state.pending, fn(_id, pending) {
        fail_pending(pending, AcpClosed)
      })
      ActorState(..state, pending: dict.new(), closed: True)
    }
    CtlInbound(line:) -> handle_inbound(state, line)
    CtlSubprocessExited(status:) -> {
      let err = AcpSubprocessExit(status: status)
      dict.each(state.pending, fn(_id, pending) { fail_pending(pending, err) })
      ActorState(..state, pending: dict.new(), closed: True)
    }
  }
}

fn handle_inbound(state: ActorState, line: String) -> ActorState {
  case extract_response_id(line) {
    Some(id) -> dispatch_response(state, id, line)
    None -> dispatch_notification(state, line)
  }
}

fn dispatch_response(state: ActorState, id: Int, line: String) -> ActorState {
  case dict.get(state.pending, id) {
    Error(_) -> {
      // Unknown id — protocol bug or late reply after timeout. Drop.
      state
    }
    Ok(pending) -> {
      let new_pending = dict.delete(state.pending, id)
      reply_to_pending(pending, line)
      let new_active_sink = case pending {
        // After a prompt response, clear the active sink — the turn
        // is over.
        PendingPrompt(_) -> None
        _ -> state.active_prompt_sink
      }
      ActorState(
        ..state,
        pending: new_pending,
        active_prompt_sink: new_active_sink,
      )
    }
  }
}

fn dispatch_notification(state: ActorState, line: String) -> ActorState {
  case state.active_prompt_sink {
    None -> state
    // No prompt in flight — drop. (Could log; not noisy in practice.)
    Some(sink) -> {
      let event = decode_event(line)
      process.send(sink, event)
      state
    }
  }
}

fn reply_to_pending(pending: PendingReply, line: String) -> Nil {
  case extract_rpc_error(line) {
    Some(err) -> fail_pending(pending, err)
    None -> succeed_pending(pending, line)
  }
}

fn succeed_pending(pending: PendingReply, line: String) -> Nil {
  case pending {
    PendingInitialize(reply_to:) ->
      process.send(
        reply_to,
        decode_initialize(line)
          |> result.map_error(AcpDecodeError),
      )
    PendingSessionNew(reply_to:) ->
      process.send(
        reply_to,
        decode_session_new(line)
          |> result.map_error(AcpDecodeError),
      )
    PendingPrompt(reply_to:) ->
      process.send(
        reply_to,
        decode_prompt_result(line)
          |> result.map_error(AcpDecodeError),
      )
    PendingCancel(reply_to:) -> process.send(reply_to, Ok(Nil))
  }
}

fn fail_pending(pending: PendingReply, err: AcpError) -> Nil {
  case pending {
    PendingInitialize(reply_to:) -> process.send(reply_to, Error(err))
    PendingSessionNew(reply_to:) -> process.send(reply_to, Error(err))
    PendingPrompt(reply_to:) -> process.send(reply_to, Error(err))
    PendingCancel(reply_to:) -> process.send(reply_to, Error(err))
  }
}

// ---------------------------------------------------------------------------
// Public API — typed, blocking helpers
// ---------------------------------------------------------------------------

pub fn initialize(handle: AcpHandle) -> Result(AgentCapabilities, AcpError) {
  let reply = process.new_subject()
  process.send(handle.subject, CtlInitialize(reply_to: reply))
  case process.receive(reply, default_initialize_timeout_ms) {
    Ok(r) -> r
    Error(_) ->
      Error(AcpTimeout(
        operation: "initialize",
        ms: default_initialize_timeout_ms,
      ))
  }
}

pub fn session_new(
  handle: AcpHandle,
  cwd: String,
  model_id: Option(String),
) -> Result(String, AcpError) {
  let reply = process.new_subject()
  process.send(
    handle.subject,
    CtlSessionNew(cwd: cwd, model_id: model_id, reply_to: reply),
  )
  case process.receive(reply, default_session_new_timeout_ms) {
    Ok(r) -> r
    Error(_) ->
      Error(AcpTimeout(
        operation: "session/new",
        ms: default_session_new_timeout_ms,
      ))
  }
}

/// Async variant — returns the reply Subject without blocking. Caller
/// uses `process.receive` (or a Selector merging this with the
/// event_sink) to wait. Needed by the manager's driver process: while
/// the prompt is in flight the driver also wants to consume events
/// from event_sink, so it can't sit blocked in `process.receive`.
pub fn session_prompt_async(
  handle: AcpHandle,
  session_id: String,
  prompt_text: String,
  event_sink: Subject(AcpEvent),
) -> Subject(Result(PromptResult, AcpError)) {
  let reply = process.new_subject()
  process.send(
    handle.subject,
    CtlSessionPrompt(
      session_id: session_id,
      prompt_text: prompt_text,
      event_sink: event_sink,
      reply_to: reply,
    ),
  )
  reply
}

pub fn session_prompt(
  handle: AcpHandle,
  session_id: String,
  prompt_text: String,
  event_sink: Subject(AcpEvent),
) -> Result(PromptResult, AcpError) {
  let reply = session_prompt_async(handle, session_id, prompt_text, event_sink)
  case process.receive(reply, default_prompt_timeout_ms) {
    Ok(r) -> r
    Error(_) ->
      Error(AcpTimeout(
        operation: "session/prompt",
        ms: default_prompt_timeout_ms,
      ))
  }
}

pub fn session_cancel(
  handle: AcpHandle,
  session_id: String,
) -> Result(Nil, AcpError) {
  let reply = process.new_subject()
  process.send(
    handle.subject,
    CtlSessionCancel(session_id: session_id, reply_to: reply),
  )
  case process.receive(reply, default_cancel_timeout_ms) {
    Ok(r) -> r
    Error(_) ->
      Error(AcpTimeout(
        operation: "session/cancel",
        ms: default_cancel_timeout_ms,
      ))
  }
}

pub fn close(handle: AcpHandle) -> Nil {
  process.send(handle.subject, CtlClose)
  Nil
}

// ---------------------------------------------------------------------------
// Public API — convenience wrappers
// ---------------------------------------------------------------------------

/// Default request timeouts. Configurable later if needed.
pub const default_initialize_timeout_ms: Int = 10_000

pub const default_session_new_timeout_ms: Int = 10_000

pub const default_prompt_timeout_ms: Int = 600_000

pub const default_cancel_timeout_ms: Int = 10_000

/// Format an AcpError for operator-actionable display. Same pattern
/// as types.format_error/1.
pub fn format_error(err: AcpError) -> String {
  case err {
    AcpOpenFailed(reason) -> "ACP subprocess open failed: " <> reason
    AcpSubprocessExit(status) ->
      "ACP subprocess exited (status " <> int.to_string(status) <> ")"
    AcpRpcError(code, message, _data) ->
      "ACP RPC error " <> int.to_string(code) <> ": " <> message
    AcpDecodeError(reason) -> "ACP decode failed: " <> reason
    AcpTimeout(operation, ms) ->
      "ACP " <> operation <> " timed out after " <> int.to_string(ms) <> "ms"
    AcpProtocolError(reason) -> "ACP protocol error: " <> reason
    AcpClosed -> "ACP handle is closed"
  }
}

// ---------------------------------------------------------------------------
// JSON-RPC body builders (pure)
// ---------------------------------------------------------------------------

/// `initialize` request body. Springdrift advertises minimal client
/// capabilities — we don't act as a full editor; ACP can use the
/// agent's own filesystem and terminal.
pub fn build_initialize(id: Int) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(id)),
    #("method", json.string("initialize")),
    #(
      "params",
      json.object([
        #("protocolVersion", json.int(1)),
        #(
          "clientCapabilities",
          json.object([
            #(
              "fs",
              json.object([
                #("readTextFile", json.bool(False)),
                #("writeTextFile", json.bool(False)),
              ]),
            ),
            #("terminal", json.bool(False)),
          ]),
        ),
        #(
          "clientInfo",
          json.object([
            #("name", json.string("springdrift")),
            #("version", json.string("0.1.0")),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

/// `session/new` request body. cwd is the in-container working
/// directory (typically /workspace/project). model_id, when supplied,
/// is set on the session via configOptions update later — for R3 we
/// just create with the agent's default and let R5's dispatch tool
/// override per-task if needed.
pub fn build_session_new(id: Int, cwd: String) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(id)),
    #("method", json.string("session/new")),
    #(
      "params",
      json.object([
        #("cwd", json.string(cwd)),
        #("mcpServers", json.array([], of: json.string)),
      ]),
    ),
  ])
  |> json.to_string
}

/// `session/prompt` request body — sends the user prompt as a single
/// text content block. R7 may extend with image / embedded-context
/// content for richer dispatches.
pub fn build_session_prompt(
  id: Int,
  session_id: String,
  prompt_text: String,
) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(id)),
    #("method", json.string("session/prompt")),
    #(
      "params",
      json.object([
        #("sessionId", json.string(session_id)),
        #(
          "prompt",
          json.array(
            [
              json.object([
                #("type", json.string("text")),
                #("text", json.string(prompt_text)),
              ]),
            ],
            of: fn(j) { j },
          ),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

/// `session/cancel` notification (no response expected).
pub fn build_session_cancel(id: Int, session_id: String) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(id)),
    #("method", json.string("session/cancel")),
    #("params", json.object([#("sessionId", json.string(session_id))])),
  ])
  |> json.to_string
}

// ---------------------------------------------------------------------------
// Response decoders (pure)
// ---------------------------------------------------------------------------

/// Decode the initialize response into AgentCapabilities. Tolerates
/// missing optional fields (loadSession, fork, list, resume) by
/// defaulting to False/empty.
pub fn decode_initialize(body: String) -> Result(AgentCapabilities, String) {
  let decoder = {
    use result <- decode.field("result", caps_decoder())
    decode.success(result)
  }
  json.parse(body, decoder)
  |> result.replace_error("decode_initialize: " <> body)
}

fn caps_decoder() -> decode.Decoder(AgentCapabilities) {
  use protocol_version <- decode.optional_field(
    "protocolVersion",
    1,
    decode.int,
  )
  use agent_caps <- decode.optional_field(
    "agentCapabilities",
    default_caps_inner(),
    caps_inner_decoder(),
  )
  use info_pair <- decode.optional_field(
    "agentInfo",
    #("", ""),
    agent_info_decoder(),
  )
  decode.success(AgentCapabilities(
    protocol_version: protocol_version,
    can_load_session: agent_caps.0,
    can_fork: agent_caps.1,
    can_resume: agent_caps.2,
    can_list: agent_caps.3,
    auth_methods: agent_caps.4,
    agent_name: info_pair.0,
    agent_version: info_pair.1,
  ))
}

fn default_caps_inner() -> #(Bool, Bool, Bool, Bool, List(String)) {
  #(False, False, False, False, [])
}

fn caps_inner_decoder() -> decode.Decoder(
  #(Bool, Bool, Bool, Bool, List(String)),
) {
  use load <- decode.optional_field("loadSession", False, decode.bool)
  use session_caps <- decode.optional_field(
    "sessionCapabilities",
    #(False, False, False),
    session_caps_decoder(),
  )
  decode.success(#(load, session_caps.0, session_caps.1, session_caps.2, []))
}

fn session_caps_decoder() -> decode.Decoder(#(Bool, Bool, Bool)) {
  use fork <- decode.optional_field("fork", False, decode.success(True))
  use list <- decode.optional_field("list", False, decode.success(True))
  use resume <- decode.optional_field("resume", False, decode.success(True))
  decode.success(#(fork, list, resume))
}

fn agent_info_decoder() -> decode.Decoder(#(String, String)) {
  use name <- decode.optional_field("name", "", decode.string)
  use version <- decode.optional_field("version", "", decode.string)
  decode.success(#(name, version))
}

/// Decode the session/new response into the new session_id.
pub fn decode_session_new(body: String) -> Result(String, String) {
  let decoder = {
    use session_id <- decode.subfield(["result", "sessionId"], decode.string)
    decode.success(session_id)
  }
  json.parse(body, decoder)
  |> result.replace_error("decode_session_new: " <> body)
}

/// Decode the session/prompt response — terminal message of a turn.
pub fn decode_prompt_result(body: String) -> Result(PromptResult, String) {
  let decoder = {
    use stop <- decode.subfield(["result", "stopReason"], decode.string)
    use usage <- decode.optional_field(
      "result",
      default_usage(),
      usage_outer_decoder(),
    )
    decode.success(PromptResult(
      stop_reason: stop_reason_from_string(stop),
      total_tokens: usage.0,
      input_tokens: usage.1,
      output_tokens: usage.2,
      cached_read_tokens: usage.3,
    ))
  }
  json.parse(body, decoder)
  |> result.replace_error("decode_prompt_result: " <> body)
}

fn default_usage() -> #(Int, Int, Int, Int) {
  #(0, 0, 0, 0)
}

fn usage_outer_decoder() -> decode.Decoder(#(Int, Int, Int, Int)) {
  use usage <- decode.optional_field(
    "usage",
    default_usage(),
    usage_inner_decoder(),
  )
  decode.success(usage)
}

fn usage_inner_decoder() -> decode.Decoder(#(Int, Int, Int, Int)) {
  use total <- decode.optional_field("totalTokens", 0, decode.int)
  use input <- decode.optional_field("inputTokens", 0, decode.int)
  use output <- decode.optional_field("outputTokens", 0, decode.int)
  use cached <- decode.optional_field("cachedReadTokens", 0, decode.int)
  decode.success(#(total, input, output, cached))
}

pub fn stop_reason_from_string(s: String) -> StopReason {
  case s {
    "end_turn" -> StopEndTurn
    "max_tokens" -> StopMaxTokens
    "max_turn_requests" -> StopMaxTurnRequests
    "refusal" -> StopRefusal
    "cancelled" -> StopCancelled
    other -> StopUnknown(raw: other)
  }
}

/// Decode a session/update notification line into an AcpEvent.
/// Unknown sessionUpdate types decode as AcpUnknown carrying the raw
/// JSON — caller can still log / archive the event without crashing.
pub fn decode_event(body: String) -> AcpEvent {
  let decoder = {
    use update_type <- decode.subfield(
      ["params", "update", "sessionUpdate"],
      decode.string,
    )
    decode.success(update_type)
  }
  case json.parse(body, decoder) {
    Error(_) -> AcpUnknown(raw_json: body)
    Ok("agent_thought_chunk") -> decode_text_chunk(body, "thought")
    Ok("agent_message_chunk") -> decode_text_chunk(body, "message")
    Ok("tool_call") -> decode_tool_call(body)
    Ok("tool_call_update") -> decode_tool_call_update(body)
    Ok("usage_update") -> decode_usage_update(body)
    Ok(_) -> AcpUnknown(raw_json: body)
  }
}

fn decode_text_chunk(body: String, kind: String) -> AcpEvent {
  let decoder = {
    use msg_id <- decode.subfield(
      ["params", "update", "messageId"],
      decode.string,
    )
    use text <- decode.subfield(
      ["params", "update", "content", "text"],
      decode.string,
    )
    decode.success(#(msg_id, text))
  }
  case json.parse(body, decoder) {
    Ok(#(id, text)) ->
      case kind {
        "thought" -> AcpThoughtChunk(message_id: id, text: text)
        _ -> AcpMessageChunk(message_id: id, text: text)
      }
    Error(_) -> AcpUnknown(raw_json: body)
  }
}

fn decode_tool_call(body: String) -> AcpEvent {
  let decoder = {
    use id <- decode.subfield(["params", "update", "toolCallId"], decode.string)
    use title <- decode.optional_field("params", "", decode_tool_title())
    use kind <- decode.optional_field("params", "", decode_tool_kind())
    decode.success(#(id, title, kind))
  }
  case json.parse(body, decoder) {
    Ok(#(id, title, kind)) ->
      AcpToolCall(tool_call_id: id, title: title, kind: kind)
    Error(_) -> AcpUnknown(raw_json: body)
  }
}

fn decode_tool_title() -> decode.Decoder(String) {
  use t <- decode.subfield(["update", "title"], decode.string)
  decode.success(t)
}

fn decode_tool_kind() -> decode.Decoder(String) {
  use k <- decode.subfield(["update", "kind"], decode.string)
  decode.success(k)
}

fn decode_tool_call_update(body: String) -> AcpEvent {
  let decoder = {
    use id <- decode.subfield(["params", "update", "toolCallId"], decode.string)
    use status <- decode.optional_field("params", "", decode_tool_status())
    decode.success(#(id, status))
  }
  case json.parse(body, decoder) {
    Ok(#(id, status)) -> AcpToolCallUpdate(tool_call_id: id, status: status)
    Error(_) -> AcpUnknown(raw_json: body)
  }
}

fn decode_tool_status() -> decode.Decoder(String) {
  use s <- decode.subfield(["update", "status"], decode.string)
  decode.success(s)
}

fn decode_usage_update(body: String) -> AcpEvent {
  let decoder = {
    use used <- decode.subfield(["params", "update", "used"], decode.int)
    use size <- decode.optional_field("params", 0, decode_usage_size())
    use cost <- decode.optional_field("params", 0.0, decode_usage_cost())
    decode.success(#(used, size, cost))
  }
  case json.parse(body, decoder) {
    Ok(#(used, size, cost)) ->
      AcpUsageUpdate(used_tokens: used, total_size: size, cost_usd: cost)
    Error(_) -> AcpUnknown(raw_json: body)
  }
}

fn decode_usage_size() -> decode.Decoder(Int) {
  use s <- decode.subfield(["update", "size"], decode.int)
  decode.success(s)
}

fn decode_usage_cost() -> decode.Decoder(Float) {
  use amount <- decode.subfield(["update", "cost", "amount"], decode_number())
  decode.success(amount)
}

/// Permissive number decoder — accepts JSON int or float, returns Float.
fn decode_number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

// ---------------------------------------------------------------------------
// Helpers used by R4 manager
// ---------------------------------------------------------------------------

/// Determine if a JSON-RPC line is a response (has top-level "id")
/// vs a notification (top-level "method", no "id"). Returns the id
/// when it's a response, None otherwise.
pub fn extract_response_id(line: String) -> Option(Int) {
  let decoder = {
    use id <- decode.field("id", decode.int)
    decode.success(id)
  }
  case json.parse(line, decoder) {
    Ok(id) -> Some(id)
    Error(_) -> None
  }
}

/// Detect a JSON-RPC error response. Returns the rpc-error variant
/// when one is present.
pub fn extract_rpc_error(line: String) -> Option(AcpError) {
  let decoder = {
    use code <- decode.subfield(["error", "code"], decode.int)
    use message <- decode.subfield(["error", "message"], decode.string)
    decode.success(#(code, message))
  }
  case json.parse(line, decoder) {
    Ok(#(code, message)) ->
      Some(AcpRpcError(code: code, message: message, data: None))
    Error(_) -> None
  }
}
