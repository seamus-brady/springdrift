# User Interface Architecture

Springdrift provides two user interfaces: a terminal TUI and a web-based GUI.
Both connect to the same cognitive loop and display the same data -- they are
alternative frontends, selected at startup via `--gui tui` or `--gui web`.

---

## 1. Overview

```
                 ┌─────────┐
                 │   TUI   │ ── stdin/stdout, alternate screen
                 └────┬────┘
                      │ Subject(CognitiveMessage)
                      ▼
              ┌───────────────┐
              │ Cognitive Loop │
              └───────┬───────┘
                      │ Subject(CognitiveMessage)
                      ▼
                 ┌─────────┐
                 │ Web GUI │ ── HTTP + WebSocket (mist)
                 └─────────┘
```

Both interfaces:
- Send `UserInput` / `UserAnswer` messages to the cognitive loop
- Subscribe to Frontdoor as a `UserSource` sink, keyed by a per-connection
  `source_id`. Replies arrive as `DeliverReply(cycle_id, response, model,
  usage, tools_fired)`, questions as `DeliverQuestion`.
- Subscribe to `Notification` events for tool calls, safety decisions, lifecycle

## 2. Terminal TUI

`src/tui.gleam` provides an alternate-screen terminal interface using the `etch`
package.

### Tabs

| Tab | Content |
|---|---|
| ChatTab | Conversation history with the agent |
| LogTab | Real-time system log entries (from `slog`) |
| NarrativeTab | Recent narrative entries from the agent's memory |

### Key Bindings

- Tab / Shift+Tab: switch between tabs
- Enter: send message (chat tab)
- Up/Down or scroll: navigate history
- Ctrl+C: exit

### Process Model

The TUI runs three concurrent processes:

| Process | Lifetime | Role |
|---|---|---|
| Main TUI loop | App | Render, message dispatch, state management |
| Stdin reader | App | Blocking `read_char` loop → `StdinByte` messages |
| Frontdoor delivery sink | App | Receives `DeliverReply` / `DeliverQuestion` for the TUI's source_id |

The TUI uses a `Selector` that multiplexes stdin bytes, Frontdoor deliveries,
and notification messages into a single event stream.

### State

`TuiState` tracks:
- Cognitive loop subject and reply subject
- Current model, provider name
- Message history and input buffer
- Scroll offsets per tab
- Terminal dimensions (width, height)
- Agent status (Idle, WaitingForLlm, WaitingForInput)
- Log entries and narrative entries
- Last token usage for display

### Input Limits

TUI input buffer is capped at 100KB to prevent memory issues from accidental
paste floods.

### Rendering

The TUI uses `etch` for terminal rendering:
- Alternate screen mode (preserves terminal history)
- ANSI styling for syntax highlighting
- Spinner animation during LLM calls
- Status bar with model name, token usage, and agent status
- Notice area for tool call and safety notifications

## 3. Web GUI

`src/web/gui.gleam` provides an HTTP server + WebSocket bridge using the `mist`
package.

### HTTP Routes

| Route | Purpose |
|---|---|
| `GET /` | Chat page (HTML/CSS/JS) |
| `GET /admin` | Admin dashboard (4 tabs) |
| `GET /ws` | WebSocket upgrade |
| `GET /health` | Health check |

### Admin Dashboard

The admin page (`/admin`) provides four tabs:

| Tab | Data source | Content |
|---|---|---|
| Narrative | Librarian | Recent narrative entries |
| Log | slog | System log entries |
| Scheduler | Scheduler | Job list with status and next-run times |
| Cycles | Cycle log | Scheduler-triggered cycle history |
| Planner | Planner | Tasks and endeavours with progress |
| D' | D' state | Gate decisions and config |
| Comms | Comms log | Sent and received email messages |
| Affect | Affect store | Affect snapshots over time |

### Authentication

When `SPRINGDRIFT_WEB_TOKEN` is set, all HTTP and WebSocket requests require
authentication:
- `Authorization: Bearer <token>` header, or
- `?token=<token>` query parameter

No auth required when the env var is unset.

### WebSocket Protocol

Defined in `src/web/protocol.gleam`. JSON messages over WebSocket:

#### Client → Server

| Type | Fields | Purpose |
|---|---|---|
| `user_message` | `text` | Send a message to the agent |
| `user_answer` | `text` | Answer an agent question |
| `request_log_data` | -- | Request system log entries |
| `request_rewind` | `index` | Rewind conversation to message N |
| `request_narrative_data` | -- | Request narrative entries |
| `request_scheduler_data` | -- | Request scheduler job list |
| `request_scheduler_cycles` | -- | Request scheduler cycle history |
| `request_planner_data` | -- | Request tasks and endeavours |
| `request_dprime_data` | -- | Request D' gate decisions |
| `request_dprime_config` | -- | Request D' configuration |
| `request_comms_data` | -- | Request comms messages |
| `request_affect_data` | -- | Request affect snapshots |
| `ack` | `seq` | Outbox flow control — confirms client has applied every frame through `seq` |
| `pong` | -- | Keepalive reply (server's `ping` echo) |

#### Server → Client

Every server-pushed frame carries a `seq` field as its first key
(monotonic per-client; see §6 below). Client tracks the highest
`seq` it has applied locally and acks back periodically.

| Type | Fields | Purpose |
|---|---|---|
| `assistant_message` | `text`, `model`, `usage` | Agent response |
| `thinking` | -- | Agent is processing |
| `question` | `text`, `source` | Agent question for user |
| `notification` | `kind`, `name`/`message`/etc. | Tool call, save, safety events |
| `ping` | -- | Server keepalive — client must reply `pong` |
| `session_history` | `messages` | Sent on connect (or on reconnect when outbox replay is unavailable); JSON array of role-tagged messages for client to repopulate from |
| Various data types | JSON payloads | Response to data requests |

### Notification Relay

The web GUI supports multiple concurrent WebSocket connections. A relay process
forwards notifications from the cognitive loop to all connected clients:

```
Cognitive Loop ──Notification──→ Relay Process ──→ Connection 1
                                       ├──────→ Connection 2
                                       └──────→ Connection N
```

Connections register/unregister with the relay on open/close.

### Per-Connection State

Each WebSocket connection maintains:
- Cognitive loop subject (shared)
- Reply subject (per-connection)
- Notification subject (per-connection, registered with relay)
- References to scheduler, librarian, narrative_dir

### Size Limits

WebSocket messages are capped at `ws_max_bytes` (configurable, default 1MB).

### Reliability — Outbox + Seq + Ack + Keepalive

Live agent cycles can run several minutes; idle proxies and OS-level
NAT often drop a TCP connection that's seen no traffic for 30–60s.
Without delivery guarantees, three reported symptoms came up
repeatedly through v0.9:

- *Long-running cycle, no live notification, refresh shows the
  reply.* WS dropped silently mid-cycle; the eventual reply went
  to a dead notify_subject.
- *Typed user message disappears.* The early `user_message_ack`
  cleared local in-flight tracking before the cog had persisted
  the message; a reconnect-mid-cycle `session_history` rebuild
  then wiped the bubble.
- *No live `agent_progress` / `thinking` / tool updates during
  work.* Same root cause as the first symptom.

v0.10.0 added a per-client outbox + monotonic seq + client-driven
ack + server-driven keepalive that makes all three symptoms
structurally impossible.

#### The wire contract

- Every server-pushed frame is appended to that client's outbox
  before being sent. The outbox assigns a monotonic `seq` (per
  `client_id`, not per node).
- Client tracks `lastSeenSeq` in `sessionStorage` so a tab refresh
  doesn't lose the cursor. Periodic `{type:"ack", seq:N}` every
  ~5s; server prunes the outbox up to `N`.
- On reconnect, client opens with `?since=N` in the WS URL. Server
  replays everything past `N` from the outbox. If the gap is too
  wide (frames pruned out under the size or age cap), server falls
  back to a full `session_history` rebuild.
- Server emits `{type:"ping"}` every 25s as a keepalive. Client
  replies `{type:"pong"}`. The mere fact that any frame moves over
  the line resets idle timers on both sides.

#### The outbox

`src/web/outbox.gleam` is a pure ring buffer:

| Operation | Purpose |
|---|---|
| `append(body, now_ms) -> #(Outbox, seq)` | Append a frame body; assign a monotonic seq; cap-prune oldest if over size limit |
| `ack(up_to)` | Drop every frame with seq ≤ `up_to`; idempotent against stale acks |
| `prune_age(now_ms)` | Drop frames older than `max_age_ms` from the head |
| `replay_since(since)` | Returns `Replay(frames)`, `UpToDate`, or `TooOld(oldest_kept)` |

Defaults: 500-frame ring, 5-minute age cap. Past either bound,
reconnects fall back to `session_history`.

#### The registry

`src/web/client_registry.gleam` is an OTP actor wrapping
`Dict(ClientId, Outbox)`. It survives WS process death so reconnects
under the same `client_id` see their outbox intact. Hourly janitor
drops outboxes idle for over an hour.

#### The send path

Every `mist.send_text_frame` callsite goes through `ws_send/3` in
`gui.gleam`:

```gleam
fn ws_send(state, conn, msg: ServerMessage) -> Nil {
  case msg {
    Ping -> // seq:0, never enters outbox
    _    -> {
      let body = protocol.encode_server_message_body(msg)
      let seq  = client_registry.append(state.registry, state.client_id, body)
      mist.send_text_frame(conn, protocol.splice_seq(seq, body))
    }
  }
}
```

Direct `mist.send_text_frame` calls without going through the
outbox are now exceptions (just `Ping` and replay frames, which use
their original seq).

#### The reconnect path

`ws_on_init` parses `?since=N` and either:

1. `since == 0` → fresh connect, push full `session_history`
2. `since > 0` AND `replay_since(N)` returns `Replay(frames)` →
   send each frame with its **original** seq via direct
   `mist.send_text_frame` (bypassing outbox so seq doesn't double)
3. `since > 0` AND `replay_since(N)` returns `TooOld` or
   `UpToDate` → fall back to full `session_history`

#### What this kills, structurally

| Symptom (pre-v0.10) | Mechanism (post-v0.10) |
|---|---|
| Lost notifications during silent dropout | Outbox keeps frames until acked; reconnect replays |
| `user_message_ack` race wipes user bubble | Ack is decoupled from in-flight tracking; bubble lives until renderSessionHistory observes the message in server's authoritative view |
| Connection idle-times out mid-cycle | 25s keepalive prevents proxy / NAT close |
| `agent_progress` / `thinking` invisible during long work | Same outbox replay path covers all server-pushed frames |

## 4. Embedded HTML

`src/web/html.gleam` contains embedded HTML, CSS, and JavaScript for both the
chat page and admin dashboard. The admin page uses Chart.js for data visualisation
where appropriate. All assets are served inline -- no external dependencies or
build step required.

## 5. Configuration

| Field | Section | Default | Purpose |
|---|---|---|---|
| `gui` | top-level | `"tui"` | Interface mode: `tui` or `web` |
| `web_port` | `[web]` | 12001 | HTTP server port |

## 6. Key Source Files

| File | Purpose |
|---|---|
| `tui.gleam` | Terminal UI: tabs, rendering, input handling, etch integration |
| `web/gui.gleam` | HTTP server + WebSocket handler, notification relay, `ws_send` outbox helper, keepalive timer |
| `web/html.gleam` | Embedded HTML/CSS/JS for chat and admin pages; per-client `lastSeenSeq` tracking + ack loop + reconnect-with-since |
| `web/protocol.gleam` | WebSocket JSON codec (ClientMessage / ServerMessage); `encode_server_message_with_seq`, `splice_seq` for replay |
| `web/outbox.gleam` | Pure ring buffer — append, ack, prune, replay_since |
| `web/client_registry.gleam` | OTP actor — per-client_id outbox state, survives WS process death |
| `web/auth.gleam` | Bearer token authentication middleware |
