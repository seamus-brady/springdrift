//// Web chat GUI — HTTP server + WebSocket bridge to the cognitive loop.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import affect/store as affect_store
import affect/types as affect_types
import agent/types as agent_types
import comms/log as comms_log
import comms/types as comms_types
import cycle_log
import dag/types as dag_types
import frontdoor/types.{
  type Delivery, type FrontdoorMessage, AgentOrigin, CognitiveLoopOrigin,
  DeliverClosed, DeliverQuestion, DeliverReply, Subscribe, Unsubscribe,
  UserSource,
} as _frontdoor_types
import gleam/bytes_tree
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
import llm/types.{type Message, Assistant, TextContent, User}
import mist.{type Connection, type ResponseData}
import narrative/librarian.{type LibrarianMessage}
import narrative/log as narrative_log
import narrative/types as narrative_types
import normative/character as normative_character
import paths
import planner/types as planner_types
import remembrancer/consolidation
import scheduler/types as scheduler_types
import simplifile
import skills
import skills/metrics as skills_metrics
import skills/proposal_log
import slog
import web/auth
import web/html
import web/protocol

// ---------------------------------------------------------------------------
// Custom WebSocket message type
// ---------------------------------------------------------------------------

type WsMsg {
  /// Reply / question from Frontdoor delivery sink.
  GotDelivery(Delivery)
  GotNotification(agent_types.Notification)
  SendHistory(String)
}

// ---------------------------------------------------------------------------
// Notification relay — main process forwards to per-connection subjects
// ---------------------------------------------------------------------------

type RelayMsg {
  Register(Subject(agent_types.Notification))
  Unregister(Subject(agent_types.Notification))
  /// Request a one-shot startup greeting routed through Frontdoor for
  /// the given source_id. The relay tracks whether a greeting has
  /// already fired this session and drops duplicates — protects
  /// against every WS reconnect (or a second browser tab) triggering
  /// another "Good morning".
  GreetOnce(source_id: String)
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
    frontdoor: Subject(FrontdoorMessage),
    delivery_subject: Subject(Delivery),
    notify_subject: Subject(agent_types.Notification),
    relay: Subject(RelayMsg),
    narrative_dir: String,
    librarian: Option(Subject(LibrarianMessage)),
    scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
    ws_max_bytes: Int,
    /// Frontdoor source token for this connection. Passed on every
    /// outbound `UserInput` so cognitive claims the cycle with
    /// Frontdoor and the reply routes back to this browser's
    /// delivery sink.
    source_id: String,
  )
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

fn get_auth_token() -> Option(String) {
  case get_env("SPRINGDRIFT_WEB_TOKEN") {
    Ok(token) -> Some(token)
    Error(_) -> None
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
  agent_name: String,
  agent_version: String,
  ws_max_bytes: Int,
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
  frontdoor: Subject(FrontdoorMessage),
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
        agent_name,
        agent_version,
        ws_max_bytes,
        scheduler,
        frontdoor,
      )
    }
    |> mist.new
    |> mist.port(port)
    |> mist.start

  // Run forwarding loop — receives from `notify` and broadcasts to all
  // registered WebSocket connections
  forward_loop(cognitive, notify, relay, [], False)
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
  agent_name: String,
  agent_version: String,
  ws_max_bytes: Int,
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
  frontdoor: Subject(FrontdoorMessage),
) -> Response(ResponseData) {
  // /health is unauthenticated by design — Uptime-Kuma, cron jobs,
  // and similar external pingers don't speak bearer auth, and the
  // information is non-sensitive (status tag, timestamps, pending
  // counts). Anything sensitive stays behind auth on other routes.
  case request.path_segments(req) {
    ["health"] -> health_response(cognitive, scheduler)
    _ ->
      handle_authenticated_request(
        req,
        cognitive,
        relay,
        initial_messages,
        narrative_dir,
        auth_token,
        lib,
        agent_name,
        agent_version,
        ws_max_bytes,
        scheduler,
        frontdoor,
      )
  }
}

fn handle_authenticated_request(
  req: Request(Connection),
  cognitive: Subject(agent_types.CognitiveMessage),
  relay: Subject(RelayMsg),
  initial_messages: List(Message),
  narrative_dir: String,
  auth_token: Option(String),
  lib: Option(Subject(LibrarianMessage)),
  agent_name: String,
  agent_version: String,
  ws_max_bytes: Int,
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
  frontdoor: Subject(FrontdoorMessage),
) -> Response(ResponseData) {
  case auth.check_auth(req, auth_token) {
    False ->
      response.new(401)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(
          "Unauthorized — provide token via ?token= query parameter or Authorization: Bearer header",
        )),
      )
    True ->
      case request.path_segments(req) {
        // Root redirects to /chat
        [] ->
          response.new(302)
          |> response.set_header("location", "/chat")
          |> response.set_body(mist.Bytes(bytes_tree.new()))

        // Chat page
        ["chat"] ->
          response.new(200)
          |> response.set_header("content-type", "text/html; charset=utf-8")
          |> response.set_body(
            mist.Bytes(
              bytes_tree.from_string(html.chat_page(agent_name, agent_version)),
            ),
          )

        // Mobile-first chat page (stripped down for phone screens)
        ["m"] ->
          response.new(200)
          |> response.set_header("content-type", "text/html; charset=utf-8")
          |> response.set_body(
            mist.Bytes(
              bytes_tree.from_string(html.mobile_page(agent_name, agent_version)),
            ),
          )

        // Admin page (narrative + log)
        ["admin"] ->
          response.new(200)
          |> response.set_header("content-type", "text/html; charset=utf-8")
          |> response.set_body(
            mist.Bytes(
              bytes_tree.from_string(html.admin_page(agent_name, agent_version)),
            ),
          )

        // WebSocket upgrade
        ["ws"] ->
          mist.websocket(
            request: req,
            on_init: fn(_conn) {
              ws_on_init(
                cognitive,
                relay,
                initial_messages,
                narrative_dir,
                lib,
                ws_max_bytes,
                scheduler,
                frontdoor,
              )
            },
            on_close: fn(state) {
              process.send(state.relay, Unregister(state.notify_subject))
              process.send(state.frontdoor, Unsubscribe(state.source_id))
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
  ws_max_bytes: Int,
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
  frontdoor: Subject(FrontdoorMessage),
) -> #(WsState, option.Option(Selector(WsMsg))) {
  // Per-connection subjects owned by this WebSocket handler process.
  let delivery_subject: Subject(Delivery) = process.new_subject()
  let notify_subject: Subject(agent_types.Notification) = process.new_subject()
  let history_subject: Subject(String) = process.new_subject()

  let source_id = "ws:" <> generate_uuid()

  // Subscribe this connection with Frontdoor. Every reply / question for
  // a cycle claimed by this source_id will arrive on `delivery_subject`.
  process.send(
    frontdoor,
    Subscribe(source_id:, kind: UserSource, sink: delivery_subject),
  )

  // Register for broadcast notifications (tool-calling, status, affect, etc.).
  process.send(relay, Register(notify_subject))

  let selector: Selector(WsMsg) =
    process.new_selector()
    |> process.select_map(delivery_subject, fn(d) { GotDelivery(d) })
    |> process.select_map(notify_subject, fn(n) { GotNotification(n) })
    |> process.select_map(history_subject, fn(h) { SendHistory(h) })

  let state =
    WsState(
      cognitive:,
      frontdoor:,
      delivery_subject:,
      notify_subject:,
      relay:,
      narrative_dir:,
      librarian: lib,
      scheduler:,
      ws_max_bytes:,
      source_id:,
    )

  // Ask the relay to fire a startup greeting addressed to this connection
  // via Frontdoor. The relay enforces once-per-session semantics.
  process.send(relay, GreetOnce(source_id))

  // Query live messages from the cognitive loop (not the static boot snapshot)
  process.spawn_unlinked(fn() {
    process.sleep(50)
    let msg_subject: Subject(List(Message)) = process.new_subject()
    process.send(cognitive, agent_types.GetMessages(reply_to: msg_subject))
    let selector =
      process.new_selector()
      |> process.select(msg_subject)
    // Wait up to 2s for cognitive loop to respond
    let live_messages = case process.selector_receive(selector, 2000) {
      Ok(msgs) -> msgs
      Error(_) -> initial_messages
    }
    let messages_json =
      json.to_string(
        json.array(live_messages, fn(msg) {
          let role = case msg.role {
            User -> "user"
            Assistant -> "assistant"
          }
          json.object([
            #("role", json.string(role)),
            #("text", json.string(extract_text(msg))),
          ])
        }),
      )
    process.send(history_subject, messages_json)
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
      case string.byte_size(json_str) > state.ws_max_bytes {
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
              // Dispatch to cognitive loop. reply_to is now a
              // throwaway — the real reply path is Frontdoor Delivery
              // keyed on source_id. reply_to will be removed from
              // UserInput entirely in a later commit in this branch.
              let throwaway = process.new_subject()
              process.send(
                state.cognitive,
                agent_types.UserInput(
                  source_id: state.source_id,
                  text:,
                  reply_to: throwaway,
                ),
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
              // Always read from disk — ETS may be stale if entries were
              // written by the Archivist but the Librarian notification was
              // missed or delayed. Disk is the source of truth.
              let all_entries = narrative_log.load_all(state.narrative_dir)
              // Limit to most recent 50 entries to avoid oversized WebSocket frames
              let entries = case list.length(all_entries) > 50 {
                True -> list.take(list.reverse(all_entries), 50) |> list.reverse
                False -> all_entries
              }
              let entries_json =
                json.to_string(json.array(entries, narrative_log.encode_entry))
              let msg =
                protocol.encode_server_message(protocol.NarrativeData(
                  entries_json:,
                ))
              slog.info(
                "web/gui",
                "narrative",
                "Sending "
                  <> int.to_string(list.length(entries))
                  <> " entries ("
                  <> int.to_string(string.byte_size(msg))
                  <> " bytes)",
                None,
              )
              let _ = mist.send_text_frame(conn, msg)
              mist.continue(state)
            }
            Ok(protocol.RequestSchedulerData) -> {
              case state.scheduler {
                Some(sched) -> {
                  let status_subj = process.new_subject()
                  process.send(
                    sched,
                    scheduler_types.GetStatus(reply_to: status_subj),
                  )
                  case process.receive(status_subj, 2000) {
                    Ok(jobs) -> {
                      let jobs_json =
                        json.to_string(json.array(
                          jobs,
                          scheduler_types.encode_job,
                        ))
                      let _ =
                        mist.send_text_frame(
                          conn,
                          protocol.encode_server_message(protocol.SchedulerData(
                            jobs_json:,
                          )),
                        )
                      Nil
                    }
                    Error(_) -> Nil
                  }
                }
                None -> Nil
              }
              mist.continue(state)
            }
            Ok(protocol.RequestSchedulerCycles) -> {
              case state.librarian {
                Some(lib) -> {
                  let reply_subj = process.new_subject()
                  process.send(
                    lib,
                    librarian.QuerySchedulerCycles(
                      date: get_today_date(),
                      reply_to: reply_subj,
                    ),
                  )
                  case process.receive(reply_subj, 2000) {
                    Ok(cycles) -> {
                      let cycles_json =
                        json.to_string(json.array(cycles, encode_cycle_node))
                      let _ =
                        mist.send_text_frame(
                          conn,
                          protocol.encode_server_message(
                            protocol.SchedulerCyclesData(cycles_json:),
                          ),
                        )
                      Nil
                    }
                    Error(_) -> Nil
                  }
                }
                None -> Nil
              }
              mist.continue(state)
            }
            Ok(protocol.RequestPlannerData) -> {
              case state.librarian {
                Some(lib) -> {
                  let tasks = librarian.get_active_tasks(lib)
                  let endeavours = librarian.get_all_endeavours(lib)
                  let tasks_json =
                    json.to_string(json.array(tasks, encode_planner_task))
                  let endeavours_json =
                    json.to_string(json.array(endeavours, encode_endeavour))
                  let _ =
                    mist.send_text_frame(
                      conn,
                      protocol.encode_server_message(protocol.PlannerData(
                        tasks_json:,
                        endeavours_json:,
                      )),
                    )
                  Nil
                }
                None -> Nil
              }
              mist.continue(state)
            }
            Ok(protocol.RequestDprimeData) -> {
              case state.librarian {
                Some(lib) -> {
                  let reply_subj = process.new_subject()
                  process.send(
                    lib,
                    librarian.QueryDayAll(
                      date: get_today_date(),
                      reply_to: reply_subj,
                    ),
                  )
                  case process.receive(reply_subj, 2000) {
                    Ok(nodes) -> {
                      let gates_json =
                        json.to_string(json.array(
                          extract_dprime_gates(nodes),
                          encode_dprime_gate,
                        ))
                      let _ =
                        mist.send_text_frame(
                          conn,
                          protocol.encode_server_message(protocol.DprimeData(
                            gates_json:,
                          )),
                        )
                      Nil
                    }
                    Error(_) -> Nil
                  }
                }
                None -> Nil
              }
              mist.continue(state)
            }
            Ok(protocol.RequestDprimeConfig) -> {
              // Read dprime.json directly from disk
              let base_json = case simplifile.read(".springdrift/dprime.json") {
                Ok(contents) -> contents
                Error(_) -> "{\"error\":\"dprime.json not found\"}"
              }
              // Append normative calculus status from character.json
              let nc_json = build_normative_config_json()
              let config_json = case string.ends_with(base_json, "}") {
                True ->
                  string.drop_end(base_json, 1)
                  <> ",\"normative_calculus\":"
                  <> nc_json
                  <> "}"
                False -> base_json
              }
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.DprimeConfigData(
                    config_json:,
                  )),
                )
              mist.continue(state)
            }
            Ok(protocol.RequestCommsData) -> {
              let raw_messages = comms_log.load_recent(paths.comms_dir(), 7)
              // Deduplicate by message_id (poller bug may have created dupes)
              let messages =
                list.fold(raw_messages, #([], set.new()), fn(acc, m) {
                  case set.contains(acc.1, m.message_id) {
                    True -> acc
                    False -> #([m, ..acc.0], set.insert(acc.1, m.message_id))
                  }
                }).0
                |> list.reverse
              let messages_json =
                json.to_string(
                  json.array(messages, fn(m) {
                    json.object([
                      #("message_id", json.string(m.message_id)),
                      #("direction", case m.direction {
                        comms_types.Outbound -> json.string("outbound")
                        comms_types.Inbound -> json.string("inbound")
                      }),
                      #("from", json.string(m.from)),
                      #("to", json.string(m.to)),
                      #("subject", json.string(m.subject)),
                      #("body", json.string(string.slice(m.body_text, 0, 200))),
                      #("timestamp", json.string(m.timestamp)),
                      #("status", case m.status {
                        comms_types.Sent -> json.string("sent")
                        comms_types.Delivered -> json.string("delivered")
                        comms_types.Failed(r) -> json.string("failed: " <> r)
                        comms_types.Pending -> json.string("pending")
                      }),
                    ])
                  }),
                )
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.CommsData(
                    messages_json:,
                  )),
                )
              mist.continue(state)
            }
            Ok(protocol.RequestAffectData) -> {
              let snapshots = affect_store.load_recent(paths.affect_dir(), 50)
              let snapshots_json =
                json.to_string(json.array(
                  snapshots,
                  affect_types.encode_snapshot,
                ))
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.AffectData(
                    snapshots_json:,
                  )),
                )
              mist.continue(state)
            }
            Ok(protocol.RequestHistoryIndex) -> {
              // Scan the narrative directory for dated JSONL files, build
              // per-day summaries: count, last activity, one-line headline.
              // Newest day first.
              let days_json = history_index_json(state.narrative_dir)
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.HistoryIndex(
                    days_json:,
                  )),
                )
              mist.continue(state)
            }
            Ok(protocol.RequestHistoryDay(date:)) -> {
              let entries = narrative_log.load_date(state.narrative_dir, date)
              let entries_json =
                json.to_string(json.array(entries, narrative_log.encode_entry))
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.HistoryDay(
                    date:,
                    entries_json:,
                  )),
                )
              mist.continue(state)
            }
            Ok(protocol.RequestSkillsData) -> {
              // Discover all skills, then enrich each with usage metrics
              // and the recent proposal-log events. Read-only audit data.
              let dirs = paths.default_skills_dirs()
              let discovered = skills.discover(dirs)
              let skills_json =
                json.to_string(
                  json.array(discovered, fn(s: skills.SkillMeta) {
                    let dir = string.replace(s.path, "/SKILL.md", "")
                    let usage = skills_metrics.usage_count(dir)
                    let injects = skills_metrics.inject_count(dir)
                    let last_used = case skills_metrics.last_used(dir) {
                      Some(ts) -> ts
                      None -> ""
                    }
                    json.object([
                      #("id", json.string(s.id)),
                      #("name", json.string(s.name)),
                      #("description", json.string(s.description)),
                      #("path", json.string(s.path)),
                      #("version", json.int(s.version)),
                      #(
                        "status",
                        json.string(skills.status_to_string(s.status)),
                      ),
                      #("agents", json.array(s.agents, json.string)),
                      #("contexts", json.array(s.contexts, json.string)),
                      #("token_cost_estimate", json.int(s.token_cost_estimate)),
                      #("author", json.string(skill_author_string(s.author))),
                      #("created_at", json.string(s.created_at)),
                      #("updated_at", json.string(s.updated_at)),
                      #("reads", json.int(usage)),
                      #("injects", json.int(injects)),
                      #("last_used", json.string(last_used)),
                    ])
                  }),
                )
              let today = get_today_date()
              let log_lines =
                proposal_log.load_lines_for_date(paths.skills_log_dir(), today)
              let log_json = "[" <> string.join(log_lines, ",") <> "]"
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.SkillsData(
                    skills_json:,
                    log_json:,
                  )),
                )
              mist.continue(state)
            }
            Ok(protocol.RequestMemoryData) -> {
              // Read-only Memory tab — list Remembrancer consolidation
              // runs from .springdrift/memory/consolidation/.
              let runs = consolidation.load_all(paths.consolidation_log_dir())
              let runs_json =
                json.to_string(
                  json.array(runs, fn(r: consolidation.ConsolidationRun) {
                    json.object([
                      #("run_id", json.string(r.run_id)),
                      #("timestamp", json.string(r.timestamp)),
                      #("from_date", json.string(r.from_date)),
                      #("to_date", json.string(r.to_date)),
                      #("summary", json.string(r.summary)),
                      #("entries_reviewed", json.int(r.entries_reviewed)),
                      #("cases_reviewed", json.int(r.cases_reviewed)),
                      #("facts_reviewed", json.int(r.facts_reviewed)),
                      #("patterns_found", json.int(r.patterns_found)),
                      #("facts_restored", json.int(r.facts_restored)),
                      #("threads_resurrected", json.int(r.threads_resurrected)),
                      #("decayed_facts_count", json.int(r.decayed_facts_count)),
                      #(
                        "dormant_threads_count",
                        json.int(r.dormant_threads_count),
                      ),
                      #("report_path", json.string(r.report_path)),
                    ])
                  }),
                )
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.MemoryData(runs_json:)),
                )
              mist.continue(state)
            }
            Ok(protocol.RequestChatHistoryDay(date:)) -> {
              // Read raw user/assistant pairs from the cycle log. This is the
              // actual chat, not the narrative summary. Scheduler cycles are
              // excluded — they aren't operator conversations.
              let cycles = cycle_log.load_cycles_for_date(date)
              let pairs_json =
                json.to_string(
                  json.array(cycles, fn(c: cycle_log.CycleData) {
                    json.object([
                      #("cycle_id", json.string(c.cycle_id)),
                      #("timestamp", json.string(c.timestamp)),
                      #("user", json.string(c.human_input)),
                      #("assistant", json.string(c.response_text)),
                      #("model", json.string(c.model)),
                      #("input_tokens", json.int(c.input_tokens)),
                      #("output_tokens", json.int(c.output_tokens)),
                    ])
                  }),
                )
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.ChatHistoryDay(
                    date:,
                    pairs_json:,
                  )),
                )
              mist.continue(state)
            }
            Ok(protocol.RequestRewind(index: _)) -> {
              // Rewind is no longer supported — agent starts fresh each session
              let _ =
                mist.send_text_frame(
                  conn,
                  protocol.encode_server_message(protocol.AssistantMessage(
                    text: "[Rewind not available — agent starts fresh each session. Use recall_recent to check history.]",
                    model: "system",
                    usage: None,
                  )),
                )
              mist.continue(state)
            }
            Error(_) -> mist.continue(state)
          }
      }
    }

    // Delivery from Frontdoor — reply or question for a cycle claimed
    // by this connection's source_id.
    mist.Custom(GotDelivery(delivery)) -> {
      case delivery {
        DeliverReply(cycle_id: _, response:, model:, usage:, tools_fired: _) -> {
          let msg = protocol.AssistantMessage(text: response, model:, usage:)
          let _ =
            mist.send_text_frame(conn, protocol.encode_server_message(msg))
          mist.continue(state)
        }
        DeliverQuestion(cycle_id: _, question_id: _, question:, origin:) -> {
          let source_str = case origin {
            CognitiveLoopOrigin -> protocol.cognitive_source()
            AgentOrigin(agent_name:) -> protocol.agent_source(agent_name)
          }
          let msg = protocol.Question(text: question, source: source_str)
          let _ =
            mist.send_text_frame(conn, protocol.encode_server_message(msg))
          mist.continue(state)
        }
        DeliverClosed -> mist.stop()
      }
    }

    // Notification arrived via selector
    mist.Custom(GotNotification(notification)) -> {
      let server_msg = notification_to_server_message(notification)
      let _ =
        mist.send_text_frame(conn, protocol.encode_server_message(server_msg))
      mist.continue(state)
    }

    // Session history on connect
    mist.Custom(SendHistory(messages_json)) -> {
      let _ =
        mist.send_text_frame(
          conn,
          protocol.encode_server_message(protocol.SessionHistory(messages_json:)),
        )
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
/// Also gates the once-per-session startup greeting via the `greeted` flag.
fn forward_loop(
  cognitive: Subject(agent_types.CognitiveMessage),
  notify: Subject(agent_types.Notification),
  relay: Subject(RelayMsg),
  connections: List(Subject(agent_types.Notification)),
  greeted: Bool,
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
      forward_loop(cognitive, notify, relay, connections, greeted)
    }
    FwdRelay(Register(subj)) -> {
      forward_loop(cognitive, notify, relay, [subj, ..connections], greeted)
    }
    FwdRelay(Unregister(subj)) -> {
      forward_loop(
        cognitive,
        notify,
        relay,
        list.filter(connections, fn(s) { s != subj }),
        greeted,
      )
    }
    FwdRelay(GreetOnce(source_id:)) -> {
      case greeted {
        True -> forward_loop(cognitive, notify, relay, connections, True)
        False -> {
          // Set greeted=True immediately to close the race window between
          // two near-simultaneous GreetOnce messages from rapid reconnects.
          // The actual cognitive query runs in a spawned task so the relay
          // stays responsive to incoming notifications.
          process.spawn_unlinked(fn() {
            let msg_subject: Subject(List(Message)) = process.new_subject()
            process.send(
              cognitive,
              agent_types.GetMessages(reply_to: msg_subject),
            )
            let inner_selector =
              process.new_selector() |> process.select(msg_subject)
            case process.selector_receive(inner_selector, 2000) {
              Ok([]) | Error(_) -> {
                // Dispatch the greeting UserInput via Frontdoor's
                // source_id. The reply flows back through the
                // delivery sink registered at connect time.
                // reply_to is a throwaway — cognitive still accepts
                // it on the legacy path during the migration.
                let throwaway = process.new_subject()
                process.send(
                  cognitive,
                  agent_types.UserInput(
                    source_id:,
                    text: "[Session started. Greet the operator briefly — one or two sentences. Mention anything notable from your sensorium.]",
                    reply_to: throwaway,
                  ),
                )
              }
              Ok(_) -> Nil
            }
          })
          forward_loop(cognitive, notify, relay, connections, True)
        }
      }
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
    agent_types.AgentLifecycleNotice(event_type:, agent_name:) ->
      protocol.ToolNotification(name: agent_name <> " " <> event_type)
    agent_types.InputQueued(position:, queue_size:) ->
      protocol.QueueNotification(position:, queue_size:)
    agent_types.InputQueueFull(queue_cap:) ->
      protocol.QueueFullNotification(queue_cap:)
    agent_types.SchedulerReminder(name: _, title:, body: _) ->
      protocol.ToolNotification(name: "reminder: " <> title)
    agent_types.SchedulerJobStarted(name:, kind:) ->
      protocol.ToolNotification(
        name: "scheduler:" <> name <> " (" <> kind <> ")",
      )
    agent_types.SchedulerJobCompleted(name:, result_preview: _) ->
      protocol.ToolNotification(name: "scheduler:" <> name <> " done")
    agent_types.SchedulerJobFailed(name:, reason:) ->
      protocol.ToolNotification(
        name: "scheduler:" <> name <> " failed: " <> reason,
      )
    agent_types.PlannerNotification(task_id:, title:, action:) ->
      protocol.ToolNotification(
        name: "planner:" <> task_id <> " " <> action <> " — " <> title,
      )
    agent_types.SandboxStarted(pool_size:, port_range:) ->
      protocol.ToolNotification(
        name: "sandbox:started pool="
        <> int.to_string(pool_size)
        <> " ports="
        <> port_range,
      )
    agent_types.SandboxContainerFailed(slot:, reason:) ->
      protocol.ToolNotification(
        name: "sandbox:slot " <> int.to_string(slot) <> " failed: " <> reason,
      )
    agent_types.SandboxUnavailable(reason:) ->
      protocol.ToolNotification(name: "sandbox:unavailable " <> reason)
    agent_types.ModelEscalation(from_model:, to_model:, reason:) ->
      protocol.SafetyNotification(
        decision: "ESCALATED",
        score: 0.0,
        explanation: from_model <> " -> " <> to_model <> ": " <> reason,
      )
    agent_types.AgentProgressNotice(
      agent_name:,
      turn:,
      max_turns:,
      tokens:,
      current_tool:,
      elapsed_ms:,
    ) ->
      protocol.AgentProgressNotification(
        agent_name:,
        turn:,
        max_turns:,
        tokens:,
        current_tool:,
        elapsed_ms:,
      )
    agent_types.StatusChange(status:, detail:) ->
      protocol.StatusTransition(status:, detail:)
    agent_types.AffectTickNotice(
      desperation:,
      calm:,
      confidence:,
      frustration:,
      pressure:,
      trend:,
      status:,
    ) ->
      protocol.AffectTick(
        desperation:,
        calm:,
        confidence:,
        frustration:,
        pressure:,
        trend:,
        status:,
      )
  }
}

@external(erlang, "springdrift_ffi", "get_date")
fn get_today_date() -> String

fn skill_author_string(author: skills.SkillAuthor) -> String {
  case author {
    skills.Operator -> "operator"
    skills.System -> "system"
    skills.Agent(agent_name:, cycle_id: _) -> "agent:" <> agent_name
  }
}

/// Scan a narrative directory for dated JSONL files, build a per-day
/// summary (date, cycle count, last activity timestamp, one-line
/// headline), return as a JSON array sorted newest-first.
///
/// The headline is the `intent.description` of the most recent entry
/// with a non-empty description, falling back to the summary text
/// truncated to 120 chars.
fn history_index_json(narrative_dir: String) -> String {
  let today = get_today_date()
  let files = case simplifile.read_directory(narrative_dir) {
    Ok(fs) -> fs
    Error(_) -> []
  }
  let days =
    files
    |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
    |> list.filter(fn(f) {
      // Only top-level day files named YYYY-MM-DD.jsonl (10 + 6 = 16 chars)
      // Excludes thread-index files and other sub-files.
      string.length(f) == 16
    })
    // Skip today — the live chat IS today's conversation, so showing it
    // as a separate read-only entry just confuses the operator.
    |> list.filter(fn(f) { string.drop_end(f, 6) != today })
    |> list.sort(fn(a, b) { string.compare(b, a) })
    |> list.map(fn(f: String) -> json.Json {
      let date = string.drop_end(f, 6)
      let entries: List(narrative_types.NarrativeEntry) =
        narrative_log.load_date(narrative_dir, date)
      let reversed = list.reverse(entries)
      let cycle_count = list.length(entries)
      let last = case reversed {
        [latest, ..] -> latest.timestamp
        [] -> ""
      }
      let headline = case
        list.find(reversed, fn(e) { e.intent.description != "" })
      {
        Ok(e) -> e.intent.description
        Error(_) ->
          case reversed {
            [latest, ..] -> truncate(latest.summary, 120)
            [] -> ""
          }
      }
      json.object([
        #("date", json.string(date)),
        #("cycle_count", json.int(cycle_count)),
        #("last_activity", json.string(last)),
        #("headline", json.string(headline)),
      ])
    })
  json.to_string(json.preprocessed_array(days))
}

fn truncate(s: String, n: Int) -> String {
  case string.length(s) <= n {
    True -> s
    False -> string.slice(s, 0, n) <> "\u{2026}"
  }
}

fn encode_cycle_node(node: dag_types.CycleNode) -> json.Json {
  json.object([
    #("cycle_id", json.string(node.cycle_id)),
    #("timestamp", json.string(node.timestamp)),
    #(
      "node_type",
      json.string(case node.node_type {
        dag_types.CognitiveCycle -> "cognitive"
        dag_types.AgentCycle -> "agent"
        dag_types.SchedulerCycle -> "scheduler"
      }),
    ),
    #(
      "outcome",
      json.string(case node.outcome {
        dag_types.NodeSuccess -> "success"
        dag_types.NodePartial -> "partial"
        dag_types.NodeFailure(reason:) -> "failure: " <> reason
        dag_types.NodePending -> "pending"
      }),
    ),
    #("model", json.string(node.model)),
    #("tool_call_count", json.int(list.length(node.tool_calls))),
    #("tokens_in", json.int(node.tokens_in)),
    #("tokens_out", json.int(node.tokens_out)),
    #("duration_ms", json.int(node.duration_ms)),
  ])
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

fn encode_planner_task(task: planner_types.PlannerTask) -> json.Json {
  let completed_steps =
    list.filter(task.plan_steps, fn(s) { s.status == planner_types.Complete })
  let total_steps = list.length(task.plan_steps)
  let completed_count = list.length(completed_steps)
  json.object([
    #("task_id", json.string(task.task_id)),
    #("title", json.string(task.title)),
    #("status", json.string(encode_task_status(task.status))),
    #("complexity", json.string(task.complexity)),
    #("steps_completed", json.int(completed_count)),
    #("steps_total", json.int(total_steps)),
    #("forecast_score", case task.forecast_score {
      Some(s) -> json.float(s)
      None -> json.null()
    }),
    #("endeavour_id", case task.endeavour_id {
      Some(id) -> json.string(id)
      None -> json.null()
    }),
    #("cycle_count", json.int(list.length(task.cycle_ids))),
    #(
      "steps",
      json.array(task.plan_steps, fn(s) {
        json.object([
          #("index", json.int(s.index)),
          #("description", json.string(s.description)),
          #("status", json.string(encode_task_status(s.status))),
          #("completed_at", case s.completed_at {
            Some(at) -> json.string(at)
            None -> json.null()
          }),
        ])
      }),
    ),
    #("description", json.string(task.description)),
    #("created_at", json.string(task.created_at)),
    #("risks", json.array(task.risks, json.string)),
    #("materialised_risks", json.array(task.materialised_risks, json.string)),
  ])
}

fn encode_task_status(status: planner_types.TaskStatus) -> String {
  case status {
    planner_types.Pending -> "pending"
    planner_types.Active -> "active"
    planner_types.Complete -> "complete"
    planner_types.Failed -> "failed"
    planner_types.Abandoned -> "abandoned"
  }
}

fn encode_endeavour(endeavour: planner_types.Endeavour) -> json.Json {
  json.object([
    #("endeavour_id", json.string(endeavour.endeavour_id)),
    #("title", json.string(endeavour.title)),
    #("description", json.string(endeavour.description)),
    #(
      "status",
      json.string(case endeavour.status {
        planner_types.Open -> "open"
        planner_types.Draft -> "draft"
        planner_types.EndeavourActive -> "active"
        planner_types.EndeavourBlocked -> "blocked"
        planner_types.OnHold -> "on_hold"
        planner_types.EndeavourComplete -> "complete"
        planner_types.EndeavourFailed -> "failed"
        planner_types.EndeavourAbandoned -> "abandoned"
      }),
    ),
    #("task_ids", json.array(endeavour.task_ids, json.string)),
    #("task_count", json.int(list.length(endeavour.task_ids))),
    #("created_at", json.string(endeavour.created_at)),
    #("updated_at", json.string(endeavour.updated_at)),
  ])
}

// ---------------------------------------------------------------------------
// D' gate data extraction
// ---------------------------------------------------------------------------

type DprimeGateRecord {
  DprimeGateRecord(
    cycle_id: String,
    timestamp: String,
    node_type: String,
    gate: String,
    decision: String,
    score: Float,
  )
}

fn extract_dprime_gates(
  nodes: List(dag_types.CycleNode),
) -> List(DprimeGateRecord) {
  list.flat_map(nodes, fn(node) {
    let nt = case node.node_type {
      dag_types.CognitiveCycle -> "cognitive"
      dag_types.AgentCycle -> "agent"
      dag_types.SchedulerCycle -> "scheduler"
    }
    list.map(node.dprime_gates, fn(g) {
      DprimeGateRecord(
        cycle_id: node.cycle_id,
        timestamp: node.timestamp,
        node_type: nt,
        gate: g.gate,
        decision: g.decision,
        score: g.score,
      )
    })
  })
}

fn encode_dprime_gate(record: DprimeGateRecord) -> json.Json {
  json.object([
    #("cycle_id", json.string(record.cycle_id)),
    #("timestamp", json.string(record.timestamp)),
    #("node_type", json.string(record.node_type)),
    #("gate", json.string(record.gate)),
    #("decision", json.string(record.decision)),
    #("score", json.float(record.score)),
  ])
}

/// Build JSON for the normative calculus config panel in the web admin.
/// Reads character.json from identity directories and config.toml for enabled flag.
fn build_normative_config_json() -> String {
  // Normative calculus is enabled by default (True).
  // Only disabled if config explicitly says false.
  let enabled = case simplifile.read(paths.local_config()) {
    Ok(contents) ->
      !string.contains(contents, "normative_calculus_enabled = false")
    Error(_) -> True
  }

  let character =
    normative_character.load_character(paths.default_identity_dirs())

  case character {
    Some(spec) -> {
      let endeavours =
        list.map(spec.highest_endeavour, fn(np) {
          json.object([
            #(
              "level",
              json.string(normative_character.level_to_string(np.level)),
            ),
            #(
              "operator",
              json.string(normative_character.operator_to_string(np.operator)),
            ),
            #("description", json.string(np.description)),
          ])
        })
      json.to_string(
        json.object([
          #("enabled", json.bool(enabled)),
          #("character_loaded", json.bool(True)),
          #("virtue_count", json.int(list.length(spec.virtues))),
          #("endeavour_count", json.int(list.length(spec.highest_endeavour))),
          #("endeavours", json.array(endeavours, fn(x) { x })),
        ]),
      )
    }
    None ->
      json.to_string(
        json.object([
          #("enabled", json.bool(enabled)),
          #("character_loaded", json.bool(False)),
        ]),
      )
  }
}

// ---------------------------------------------------------------------------
// /health — unauthenticated liveness endpoint
// ---------------------------------------------------------------------------

/// Build a health-check response. Unauthenticated; designed to be
/// pinged by Uptime Kuma / cron / similar. Reports:
///   - "status": always "ok" if the HTTP server is answering
///   - "timestamp": current ISO-8601 (confirms clock is running)
///   - "cognitive": "responsive" | "unresponsive" (Ping round-trip)
///   - "cognitive_status": Idle / Thinking / WaitingForUser / ...
///     (only populated when cognitive is responsive)
///   - "scheduler_pending": count of jobs the scheduler has in queue
///     (0 when scheduler isn't configured)
///
/// The endpoint never returns 500. If any subsystem is unreachable,
/// the field for that subsystem carries the failure state and the
/// overall response is still 200 — monitoring callers parse the body
/// to decide what counts as unhealthy.
fn health_response(
  cognitive: Subject(agent_types.CognitiveMessage),
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
) -> Response(ResponseData) {
  let #(cog_reachable, cog_status) = probe_cognitive(cognitive)
  let sched_pending = probe_scheduler_pending(scheduler)
  let body =
    json.object([
      #("status", json.string("ok")),
      #("timestamp", json.string(current_iso_timestamp())),
      #(
        "cognitive",
        json.string(case cog_reachable {
          True -> "responsive"
          False -> "unresponsive"
        }),
      ),
      #("cognitive_status", case cog_status {
        Some(tag) -> json.string(tag)
        None -> json.null()
      }),
      #("scheduler_pending", json.int(sched_pending)),
    ])
    |> json.to_string
  response.new(200)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

/// Send a Ping to cognitive with a short timeout. Returns
/// (reachable?, status_tag). Timeout = 500 ms — long enough for any
/// live cog loop to answer, short enough that a jammed loop doesn't
/// block the /health response.
fn probe_cognitive(
  cognitive: Subject(agent_types.CognitiveMessage),
) -> #(Bool, Option(String)) {
  let reply: Subject(agent_types.PingReply) = process.new_subject()
  process.send(cognitive, agent_types.Ping(reply_to: reply))
  case process.receive(reply, 500) {
    Ok(agent_types.PingReply(status_tag:, ..)) -> #(True, Some(status_tag))
    Error(_) -> #(False, None)
  }
}

/// Count pending jobs in the scheduler. Returns 0 when no scheduler
/// is configured or the call times out — health-check callers can
/// treat scheduler_pending=0 as "no backlog" and distinguish a real
/// outage via the "cognitive" field.
fn probe_scheduler_pending(
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
) -> Int {
  case scheduler {
    None -> 0
    Some(sched) -> {
      let reply: Subject(List(scheduler_types.ScheduledJob)) =
        process.new_subject()
      process.send(sched, scheduler_types.GetStatus(reply_to: reply))
      case process.receive(reply, 500) {
        Ok(jobs) ->
          list.count(jobs, fn(j) {
            case j.status {
              scheduler_types.Pending -> True
              _ -> False
            }
          })
        Error(_) -> 0
      }
    }
  }
}

@external(erlang, "springdrift_ffi", "get_datetime")
fn current_iso_timestamp() -> String
