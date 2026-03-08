//// Web chat GUI — HTTP server + WebSocket bridge to the cognitive loop.

import agent/types as agent_types
import cycle_log
import gleam/bytes_tree
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/types.{type Message, Assistant, TextContent, User}
import mist.{type Connection, type ResponseData}
import narrative/librarian.{type LibrarianMessage}
import narrative/log as narrative_log
import slog
import web/html
import web/protocol

// ---------------------------------------------------------------------------
// Custom WebSocket message type
// ---------------------------------------------------------------------------

type WsMsg {
  GotReply(agent_types.CognitiveReply)
  GotNotification(agent_types.Notification)
}

// ---------------------------------------------------------------------------
// Notification relay — main process forwards to per-connection subjects
// ---------------------------------------------------------------------------

type RelayMsg {
  Register(Subject(agent_types.Notification))
  Unregister(Subject(agent_types.Notification))
}

type ForwardMsg {
  FwdNotification(agent_types.Notification)
  FwdRelay(RelayMsg)
}

// ---------------------------------------------------------------------------
// Per-connection state
// ---------------------------------------------------------------------------

type WsState {
  WsState(
    cognitive: Subject(agent_types.CognitiveMessage),
    reply_subject: Subject(agent_types.CognitiveReply),
    notify_subject: Subject(agent_types.Notification),
    relay: Subject(RelayMsg),
    narrative_dir: String,
    librarian: Option(Subject(LibrarianMessage)),
  )
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

fn get_auth_token() -> Option(String) {
  case get_env("SPRINGDRIFT_WEB_TOKEN") {
    Ok(token) -> Some(token)
    Error(_) -> None
  }
}

fn check_auth(req: Request(Connection), token: Option(String)) -> Bool {
  case token {
    None -> True
    Some(expected) ->
      case request.get_header(req, "authorization") {
        Ok(header) -> header == "Bearer " <> expected
        Error(_) ->
          case request.get_query(req) {
            Ok(params) ->
              case list.key_find(params, "token") {
                Ok(t) -> t == expected
                Error(_) -> False
              }
            Error(_) -> False
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn start(
  cognitive: Subject(agent_types.CognitiveMessage),
  notify: Subject(agent_types.Notification),
  _provider_name: String,
  _task_model: String,
  _reasoning_model: String,
  initial_messages: List(Message),
  port: Int,
  narrative_dir: String,
  lib: Option(Subject(LibrarianMessage)),
) -> Nil {
  let auth_token = get_auth_token()
  let relay: Subject(RelayMsg) = process.new_subject()
  slog.info(
    "gui",
    "start",
    "Starting web GUI on port " <> int.to_string(port),
    None,
  )
  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      handle_request(
        req,
        cognitive,
        relay,
        initial_messages,
        narrative_dir,
        auth_token,
        lib,
      )
    }
    |> mist.new
    |> mist.port(port)
    |> mist.start

  // Run forwarding loop — receives from `notify` and broadcasts to all
  // registered WebSocket connections
  forward_loop(notify, relay, [])
}

// ---------------------------------------------------------------------------
// HTTP request handler
// ---------------------------------------------------------------------------

fn handle_request(
  req: Request(Connection),
  cognitive: Subject(agent_types.CognitiveMessage),
  relay: Subject(RelayMsg),
  initial_messages: List(Message),
  narrative_dir: String,
  auth_token: Option(String),
  lib: Option(Subject(LibrarianMessage)),
) -> Response(ResponseData) {
  case check_auth(req, auth_token) {
    False ->
      response.new(401)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(
          "Unauthorized — provide token via ?token= query parameter or Authorization: Bearer header",
        )),
      )
    True ->
      case request.path_segments(req) {
        // Serve the HTML page
        [] ->
          response.new(200)
          |> response.set_header("content-type", "text/html; charset=utf-8")
          |> response.set_body(mist.Bytes(bytes_tree.from_string(html.page())))

        // WebSocket upgrade
        ["ws"] ->
          mist.websocket(
            request: req,
            on_init: fn(_conn) {
              ws_on_init(cognitive, relay, initial_messages, narrative_dir, lib)
            },
            on_close: fn(state) {
              process.send(state.relay, Unregister(state.notify_subject))
            },
            handler: ws_handler,
          )

        // 404 for everything else
        _ ->
          response.new(404)
          |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
  }
}

// ---------------------------------------------------------------------------
// WebSocket lifecycle
// ---------------------------------------------------------------------------

fn ws_on_init(
  cognitive: Subject(agent_types.CognitiveMessage),
  relay: Subject(RelayMsg),
  initial_messages: List(Message),
  narrative_dir: String,
  lib: Option(Subject(LibrarianMessage)),
) -> #(WsState, option.Option(Selector(WsMsg))) {
  // Create per-connection subjects (owned by this WebSocket handler process)
  let reply_subject: Subject(agent_types.CognitiveReply) = process.new_subject()
  let notify_subject: Subject(agent_types.Notification) = process.new_subject()

  // Register with the relay so the main process forwards notifications here
  process.send(relay, Register(notify_subject))

  // Build selector that bridges cognitive replies + notifications into WsMsg
  let selector: Selector(WsMsg) =
    process.new_selector()
    |> process.select_map(reply_subject, fn(cr) { GotReply(cr) })
    |> process.select_map(notify_subject, fn(n) { GotNotification(n) })

  let state =
    WsState(
      cognitive:,
      reply_subject:,
      notify_subject:,
      relay:,
      narrative_dir:,
      librarian: lib,
    )

  // Replay initial messages after init
  let replay_msgs = initial_messages
  process.spawn_unlinked(fn() {
    // Small delay to ensure the WS handler is ready to receive Custom messages
    process.sleep(50)
    list.each(replay_msgs, fn(msg) {
      case msg.role {
        Assistant -> {
          let text = extract_text(msg)
          process.send(
            reply_subject,
            agent_types.CognitiveReply(
              response: text,
              model: "history",
              usage: None,
            ),
          )
        }
        User -> Nil
      }
    })
  })

  #(state, Some(selector))
}

fn ws_handler(
  state: WsState,
  message: mist.WebsocketMessage(WsMsg),
  conn: mist.WebsocketConnection,
) -> mist.Next(WsState, WsMsg) {
  case message {
    // Client sent a text frame
    mist.Text(json_str) -> {
      case string.byte_size(json_str) > 1_048_576 {
        True -> mist.continue(state)
        False ->
          case protocol.decode_client_message(json_str) {
            Ok(protocol.UserMessage(text:)) -> {
              // Send thinking indicator
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.Thinking),
                )
              // Dispatch to cognitive loop
              process.send(
                state.cognitive,
                agent_types.UserInput(text:, reply_to: state.reply_subject),
              )
              mist.continue(state)
            }
            Ok(protocol.UserAnswer(text:)) -> {
              process.send(
                state.cognitive,
                agent_types.UserAnswer(answer: text),
              )
              mist.continue(state)
            }
            Ok(protocol.RequestLogData) -> {
              let entries = slog.load_entries()
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.LogData(entries:)),
                )
              mist.continue(state)
            }
            Ok(protocol.RequestNarrativeData) -> {
              let entries = case state.librarian {
                Some(l) -> librarian.load_all(l)
                None -> narrative_log.load_all(state.narrative_dir)
              }
              let entries_json =
                json.to_string(json.array(entries, narrative_log.encode_entry))
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.NarrativeData(
                    entries_json:,
                  )),
                )
              mist.continue(state)
            }
            Ok(protocol.RequestRewind(index:)) -> {
              let cycles = cycle_log.load_cycles()
              let messages = cycle_log.messages_for_rewind(cycles, index)
              process.send(
                state.cognitive,
                agent_types.RestoreMessages(messages:),
              )
              let confirmation =
                protocol.AssistantMessage(
                  text: "[Rewound to cycle "
                    <> int.to_string(index + 1)
                    <> " of "
                    <> int.to_string(list.length(cycles))
                    <> "]",
                  model: "system",
                  usage: None,
                )
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(confirmation),
                )
              mist.continue(state)
            }
            Error(_) -> mist.continue(state)
          }
      }
    }

    // Cognitive reply arrived via selector
    mist.Custom(GotReply(reply)) -> {
      let msg =
        protocol.AssistantMessage(
          text: reply.response,
          model: reply.model,
          usage: reply.usage,
        )
      let _ = mist.send_text_frame(conn, protocol.encode_server_message(msg))
      mist.continue(state)
    }

    // Notification arrived via selector
    mist.Custom(GotNotification(notification)) -> {
      let server_msg = notification_to_server_message(notification)
      let _ =
        mist.send_text_frame(conn, protocol.encode_server_message(server_msg))
      mist.continue(state)
    }

    // Binary frames ignored
    mist.Binary(_) -> mist.continue(state)

    // Connection closed
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

// ---------------------------------------------------------------------------
// Notification forwarding loop
// ---------------------------------------------------------------------------

/// Runs in the main process. Receives notifications from the cognitive loop
/// (via `notify`) and broadcasts them to all registered WebSocket connections.
fn forward_loop(
  notify: Subject(agent_types.Notification),
  relay: Subject(RelayMsg),
  connections: List(Subject(agent_types.Notification)),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(notify, fn(n) { FwdNotification(n) })
    |> process.select_map(relay, fn(r) { FwdRelay(r) })

  // Block until a message arrives (infinite timeout)
  let msg = process.selector_receive_forever(selector)
  case msg {
    FwdNotification(notification) -> {
      list.each(connections, fn(conn_subj) {
        process.send(conn_subj, notification)
      })
      forward_loop(notify, relay, connections)
    }
    FwdRelay(Register(subj)) -> {
      forward_loop(notify, relay, [subj, ..connections])
    }
    FwdRelay(Unregister(subj)) -> {
      forward_loop(
        notify,
        relay,
        list.filter(connections, fn(s) { s != subj }),
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn notification_to_server_message(
  notification: agent_types.Notification,
) -> protocol.ServerMessage {
  case notification {
    agent_types.QuestionForHuman(question:, source:) -> {
      let source_str = case source {
        agent_types.CognitiveQuestion -> protocol.cognitive_source()
        agent_types.AgentQuestionSource(agent:) -> protocol.agent_source(agent)
      }
      protocol.Question(text: question, source: source_str)
    }
    agent_types.ToolCalling(name:) -> protocol.ToolNotification(name:)
    agent_types.SaveWarning(message:) -> protocol.SaveNotification(message:)
    agent_types.SafetyGateNotice(decision:, score:, explanation:) ->
      protocol.SafetyNotification(decision:, score:, explanation:)
    agent_types.ProfileNotification(_) -> protocol.ToolNotification(name: "")
  }
}

fn extract_text(msg: Message) -> String {
  list.filter_map(msg.content, fn(block) {
    case block {
      TextContent(text:) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> list.first
  |> option.from_result
  |> option.unwrap("")
}
