//// Web chat GUI — HTTP server + WebSocket bridge to the cognitive loop.

import agent/types as agent_types
import cycle_log
import gleam/bytes_tree
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import llm/types.{type Message, Assistant, TextContent, User}
import mist.{type Connection, type ResponseData}
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
// Per-connection state
// ---------------------------------------------------------------------------

type WsState {
  WsState(
    cognitive: Subject(agent_types.CognitiveMessage),
    reply_subject: Subject(agent_types.CognitiveReply),
  )
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
) -> Nil {
  slog.info(
    "gui",
    "start",
    "Starting web GUI on port " <> int.to_string(port),
    None,
  )
  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      handle_request(req, cognitive, notify, initial_messages)
    }
    |> mist.new
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}

// ---------------------------------------------------------------------------
// HTTP request handler
// ---------------------------------------------------------------------------

fn handle_request(
  req: Request(Connection),
  cognitive: Subject(agent_types.CognitiveMessage),
  notify: Subject(agent_types.Notification),
  initial_messages: List(Message),
) -> Response(ResponseData) {
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
        on_init: fn(_conn) { ws_on_init(cognitive, notify, initial_messages) },
        on_close: fn(_state) { Nil },
        handler: ws_handler,
      )

    // 404 for everything else
    _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

// ---------------------------------------------------------------------------
// WebSocket lifecycle
// ---------------------------------------------------------------------------

fn ws_on_init(
  cognitive: Subject(agent_types.CognitiveMessage),
  notify: Subject(agent_types.Notification),
  initial_messages: List(Message),
) -> #(WsState, option.Option(Selector(WsMsg))) {
  // Create a reply subject for this connection
  let reply_subject: Subject(agent_types.CognitiveReply) = process.new_subject()

  // Build selector that bridges cognitive replies + notifications into WsMsg
  let selector: Selector(WsMsg) =
    process.new_selector()
    |> process.select_map(reply_subject, fn(cr) { GotReply(cr) })
    |> process.select_map(notify, fn(n) { GotNotification(n) })

  let state = WsState(cognitive:, reply_subject:)

  // We'll replay initial messages after init via a Custom message hack —
  // but mist calls on_init before the handler is ready. Instead, we send
  // initial messages as a side effect that will arrive as GotReply messages.
  // Actually, the simplest approach: send synthetic replies to the reply_subject
  // from a spawned process after a brief delay.
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
          process.send(state.cognitive, agent_types.UserAnswer(answer: text))
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
        Ok(protocol.RequestRewind(index:)) -> {
          let cycles = cycle_log.load_cycles()
          let messages = cycle_log.messages_for_rewind(cycles, index)
          process.send(state.cognitive, agent_types.RestoreMessages(messages:))
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
