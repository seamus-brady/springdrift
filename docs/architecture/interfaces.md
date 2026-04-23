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

#### Server → Client

| Type | Fields | Purpose |
|---|---|---|
| `assistant_message` | `text`, `model`, `usage` | Agent response |
| `thinking` | -- | Agent is processing |
| `question` | `text`, `source` | Agent question for user |
| `notification` | `kind`, `name`/`message`/etc. | Tool call, save, safety events |
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
| `web/gui.gleam` | HTTP server + WebSocket handler, notification relay |
| `web/html.gleam` | Embedded HTML/CSS/JS for chat and admin pages |
| `web/protocol.gleam` | WebSocket JSON codec (ClientMessage / ServerMessage) |
| `web/auth.gleam` | Bearer token authentication middleware |
