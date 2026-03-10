# Springdrift — Engineering Log

A running record of design decisions, implementation notes, and changes made during development.
The project is a Gleam/OTP terminal-UI chatbot exploring the [12-Factor Agents](https://github.com/humanlayer/12-factor-agents) principles.

---

## Stack

| Layer | Technology |
|---|---|
| Language | Gleam 1.x (compiled to Erlang/OTP) |
| Runtime | Erlang/BEAM |
| Terminal UI | `etch` package |
| LLM providers | Anthropic (`anthropic_gleam`), OpenAI / OpenRouter (`gllm`) |
| File I/O | `simplifile` |
| JSON | `gleam_json` v3 |
| Concurrency | OTP actors via `gleam_erlang` process/subject model |

---

## Commit History & Implementation Notes

### `e69f833` · `45c5518` — Bootstrap (Feb 15)

Initial repo skeleton. README and dependency pinning in `gleam.toml`:

```toml
gleam_stdlib    >= 0.44.0
gleam_erlang    >= 1.3.0
etch            >= 1.3.0
anthropic_gleam >= 0.1.1
gleam_json      >= 3.0.0
gllm            >= 1.0.0
simplifile      >= 2.0.0
```

No source code yet — just the project scaffolding and README stub.

---

### `fc61916` — UI + LLM provider integration (Feb 20)

**Files added:** `src/config.gleam`, `src/llm/types.gleam`, `src/llm/request.gleam`,
`src/llm/response.gleam`, `src/llm/tool.gleam`, `src/llm/provider.gleam`,
`src/llm/adapters/anthropic.gleam`, `src/llm/adapters/openai.gleam`,
`src/llm/adapters/mock.gleam`, `src/springdrift.gleam`, `src/tui.gleam`,
`src/springdrift_ffi.erl`, and a full test suite.

#### LLM type system (`src/llm/`)

A provider-agnostic type layer that all adapters translate to/from:

- `ContentBlock` — four variants: `TextContent`, `ImageContent`, `ToolUseContent`,
  `ToolResultContent`. Matches the Anthropic message block model.
- `Message(role, content)` — `User` or `Assistant` role, list of content blocks.
- `LlmRequest` / `LlmResponse` — request builder pattern via `request.gleam` pipe
  functions; response helpers in `response.gleam`.
- `LlmError` — typed error variants covering API errors, network failures, config
  issues, decode failures, timeouts, and rate limits.

#### Provider abstraction

`Provider` is a record with a `name: String` and a `chat: fn(LlmRequest) -> Result(LlmResponse, LlmError)` field. The adapters (`anthropic.gleam`, `openai.gleam`, `mock.gleam`) each translate between internal types and their respective SDK types. `mock.gleam` allows tests to inject fixed responses or custom handler functions.

**Auto-detect precedence:** `ANTHROPIC_API_KEY` → `OPENROUTER_API_KEY` → `OPENAI_API_KEY` → mock fallback.

#### Config (`src/config.gleam`)

Three-layer config merge (highest wins):
1. CLI flags (`--provider`, `--model`, `--system`, `--max-tokens`)
2. Local `.springdrift.json` in CWD
3. User `~/.config/springdrift/config.json`

Uses `simplifile.read` + `gleam_json` decoder. Unknown flags are silently ignored.

#### TUI (`src/tui.gleam`)

Full alternate-screen terminal UI via `etch`. Key design points:

- **Raw mode**: `terminal.enter_raw()` / `terminal.exit_raw()` bracket the session.
- **Stdin reader**: runs in its own `process.spawn_unlinked` process, sends
  `StdinByte` messages to the selector.
- **Selector**: multiplexes stdin, LLM reply channel, and (later) agent question
  channel into a single `TuiMessage` type using `process.new_selector`.
- **Escape sequences**: handled by reading the next 1–2 bytes with a short timeout
  (`process.receive(subj, 50)`) to disambiguate arrow keys and page keys from bare Escape.
- **Markdown renderer**: inline scanner (`scan_inline`) plus block-level renderer
  (`render_md_block` → `render_md_leaf`) handles headers, fenced code, lists,
  blockquotes, horizontal rules, bold, italic, and inline code.
- **Text wrapping**: word-wrap algorithm that handles single words exceeding `max_width`
  by forcing them onto their own line.

#### Erlang FFI (`src/springdrift_ffi.erl`)

Three functions bridging Gleam to Erlang:
- `get_env(Name)` — wraps `os:getenv/1`, returning `{ok, Val}` or `{error, nil}`.
- `get_args()` — wraps `init:get_plain_arguments()`, returning startup args as a list.
- `read_char()` — blocking read of one grapheme cluster from stdin using
  `file:read(standard_io, 1)`.

---

### `54e3009` — React loop + tool use (Feb 23)

**Files changed:** `src/chat/service.gleam` (new), `src/tools/builtin.gleam` (new),
`src/springdrift.gleam`, `src/tui.gleam`.

#### Chat service actor (`src/chat/service.gleam`)

The core concurrency design: an OTP actor (`process.spawn_unlinked`) that owns all
conversation state. The TUI sends messages to it; it sends replies back via a
one-shot `reply_to` subject.

```
TUI ──SendMessage(text, reply_to)──► Service actor
                                         │
                                         ├── spawns HTTP worker
                                         │       │ react_loop (sync)
                                         │       └──LlmComplete──► Service actor
                                         │                              │
TUI ◄──ChatResponse(result)───────────────────────────────────────────┘
```

**Why a separate HTTP worker?** The service actor must remain responsive (e.g. to `GetHistory` queries) while the LLM call blocks. Spawning a worker keeps the actor's message queue from stalling.

**`react_loop`** — iterative tool-execution loop (max 5 turns):
1. `provider.chat_with(req)` — blocking LLM call.
2. If `response.needs_tool_execution(resp)` → extract `ToolCall` list, execute each,
   build a new request with `request.with_tool_results`, recurse.
3. If not → return `Ok(resp)`.

#### Built-in tools (`src/tools/builtin.gleam`)

Three tools registered at startup:

| Tool | Name | Notes |
|---|---|---|
| Calculator | `calculator` | Parses JSON `{a, operator, b}`; handles float/int via `decode.one_of`; division-by-zero guard |
| Datetime | `get_current_datetime` | Calls `springdrift_ffi:get_datetime/0` via FFI; returns `YYYY-MM-DDTHH:MM:SS` |
| Human input | `request_human_input` | Sends question through OTP channel; blocks worker until TUI reply arrives |

#### TUI changes

- Added `WaitingForLlm` / `Idle` agent status and spinner animation (8-frame braille
  spinner, advances on 100 ms poll timeout).
- Spinner uses `process.selector_receive(selector, 100)` — non-blocking check so the
  frame counter increments even when no messages arrive.

---

### `94f2c6b` — Human-in-the-loop (Factor 7) (Feb 23)

**Files changed:** `src/chat/service.gleam`, `src/tools/builtin.gleam`, `src/tui.gleam`.

**12-Factor Agents principle:** *Factor 7 — Contact humans with tools, not interrupts.*

#### Implementation

- New `AgentQuestion(question, reply_to: Subject(String))` type in `service.gleam`.
- `execute_human_input` in `react_loop` sends an `AgentQuestion` to a
  `question_channel: Subject(AgentQuestion)` subject and then blocks on
  `process.receive_forever(reply_subj)` waiting for the human's answer.
- The `question_channel` is threaded from the TUI → `SendMessage` → HTTP worker →
  `react_loop` so the agent can suspend mid-loop without any special interrupt mechanism.
- TUI adds `question_channel` to its selector, mapping `AgentQuestion` →
  `AgentQuestionReceived`. This triggers `WaitingForInput` status: the footer shows
  "Enter: answer question", the question is rendered in yellow, and the next `Enter`
  keystroke sends the answer back via `process.send(reply_to, input_text)`.

#### Design note — why channels instead of polling

The HTTP worker process blocks on `process.receive_forever`, which is fine because
it's a dedicated lightweight Erlang process (not the TUI event loop or the service
actor). The TUI event loop remains responsive to stdin during the wait because the
question arrives as a normal selector message.

---

### `44f2db6` — Session persistence + resume + control flow (Feb 23)

**Factors addressed:** 5 (Unify Execution & Business State), 6 (Launch / Pause /
Resume), 8 (Own Your Control Flow).

**Files changed:** `src/storage.gleam` (new), `src/chat/service.gleam`,
`src/springdrift.gleam`, `src/tui.gleam`.

---

#### Factor 5 — Unify Execution State and Business State

**Principle:** The message thread *is* the agent's durable state. There is no separate
"agent state" object — the conversation history is the only state that matters across
runs.

**`src/storage.gleam`** — new module with three public functions:

```
save(messages: List(Message)) -> Nil
load() -> List(Message)
clear() -> Nil
```

Path resolution uses the `get_env("HOME")` FFI (same pattern as `config.gleam`):
- Default path: `~/.config/springdrift/session.json`
- Fallback (no `$HOME`): `.springdrift_session.json` in CWD

`save` calls `simplifile.create_directory_all` before writing so the config dir is
created automatically on first use.

**JSON schema:**

```json
[
  {"role": "user", "content": [{"type": "text", "text": "hello"}]},
  {"role": "assistant", "content": [
    {"type": "text", "text": "hi"},
    {"type": "tool_use", "id": "tu_1", "name": "calculator", "input": "{\"a\":5,\"operator\":\"*\",\"b\":7}"}
  ]},
  {"role": "user", "content": [
    {"type": "tool_result", "tool_use_id": "tu_1", "content": "35.0", "is_error": false}
  ]}
]
```

All four `ContentBlock` variants are encoded. The `input` field of `tool_use` blocks is
stored as a raw JSON string (double-serialised), keeping the encoder/decoder symmetric
without needing to handle arbitrary nested structures.

**Decoder design** — discriminated union via `decode.field` continuation chaining:

```gleam
fn content_block_decoder() -> decode.Decoder(ContentBlock) {
  use type_str <- decode.field("type", decode.string)
  case type_str {
    "text"        -> { use text <- decode.field("text", decode.string); ... }
    "tool_use"    -> { use id <- ...; use name <- ...; use input_json <- ...; ... }
    "tool_result" -> { use tool_use_id <- ...; use content <- ...; use is_error <- ...; ... }
    "image"       -> { use media_type <- ...; use data <- ...; ... }
    _             -> decode.failure(TextContent(""), "Unknown block type")
  }
}
```

The `use x <- decode.field(name, decoder)` desugars to
`decode.field(name, decoder, fn(x) { ... })`. Because `Decoder(a)` is a
`fn(Dynamic) -> Result(a, ...)`, the continuation's result decoder is applied to the
**same** dynamic value as the outer decoder — so each field accessor in a `case` arm
reaches into the same JSON object. This is the standard monadic-decoder pattern.

**Auto-save in service** — `LlmComplete` handler now calls `storage.save` after
`append_assistant_message`:

```gleam
LlmComplete(result:, reply_to:) -> {
  let new_state = append_assistant_message(state, result)
  storage.save(new_state.messages)
  process.send(reply_to, result)
  service_loop(self, new_state)
}
```

The save is synchronous (in the service actor) but cheap — the actor is idle between
turns so there is no contention.

---

#### Factor 6 — Launch / Pause / Resume

**Principle:** Agents should be resumable from a saved state. The existing Factor-7
channel mechanism already handles mid-loop suspension; this factor adds persistent
cross-process resume.

**`--resume` flag** in `springdrift.gleam`:

```gleam
let initial_messages = case list.contains(get_startup_args(), "--resume") {
  True  -> storage.load()
  False -> []
}
let chat = service.start(p, model, system, max_tokens, builtin.all(), initial_messages)
tui.start(chat, p.name, model, initial_messages)
```

`service.start` gains an `initial_messages: List(Message)` parameter. The `ChatState`
is initialised with these messages instead of `[]`, so the LLM receives the full prior
conversation as context on the next turn.

**TUI resume notice** — shown as the initial `notice` string when messages are loaded:

```
  Resumed: 12 messages loaded
```

This uses the notice system (yellow footer text, cleared after one render) rather than
injecting a synthetic message into the history, keeping the saved thread clean.

**`/clear` command** — resets both the service state and the saved file:

```gleam
"/clear" -> {
  process.send(state.chat, service.ClearHistory)
  let notice = style.dim("  Conversation cleared")
  continue_loop(TuiState(..state, messages: [], scroll_offset: 0, notice:))
}
```

`ClearHistory` in the service now calls `storage.clear()` before resetting `messages`:

```gleam
ClearHistory -> {
  storage.clear()
  service_loop(self, ChatState(..state, messages: []))
}
```

`simplifile.delete` ignores errors (file may not exist on first clear).

---

#### Factor 8 — Own Your Control Flow

**Principle:** The agent loop should be explicit about what it is doing and why it
stops. Implicit fall-through and silent partial results are bugs.

**`ToolEvent` type** — new public type in `service.gleam`:

```gleam
pub type ToolEvent {
  ToolCalling(name: String)
}
```

Sent from `react_loop` to the TUI before each tool execution via a
`tool_channel: Subject(ToolEvent)` threaded through `SendMessage`:

```gleam
list.map(calls, fn(call) {
  process.send(tool_channel, ToolCalling(name: call.name))
  case call.name { ... }
})
```

The TUI maps incoming `ToolEvent` messages to `ToolEventReceived(name)` via its
selector, stores the name in `spinner_label: String`, and renders:

```
  ⣾ Using: calculator
```

When the LLM response arrives, `handle_chat_response` resets `spinner_label: ""` so
the next thinking phase reverts to "Thinking…".

**Explicit max-turns exhaustion** — restructured from a boolean conjunction:

```gleam
// Before (silent fall-through on max_turns == 0 + needs_tool == True):
case response.needs_tool_execution(resp) && max_turns > 0 {
  False -> Ok(resp)   // ambiguous: could be "done" OR "stuck"
  True  -> ...
}

// After (explicit error):
case response.needs_tool_execution(resp) {
  False -> Ok(resp)
  True  ->
    case max_turns {
      0 -> Error(UnknownError("Agent loop: maximum turns reached"))
      _ -> { ... recurse ... }
    }
}
```

The `UnknownError` bubbles up through `LlmComplete` → `handle_chat_response`, which
renders it as `[Error: Agent loop: maximum turns reached]` in the message list — a
visible, unambiguous failure rather than a confused partial response.

**Empty-text message filtering** — messages that have no `TextContent` blocks (e.g.
pure `ToolUseContent` / `ToolResultContent` rows) produce an empty string from
`extract_text`. The renderer now skips them:

```gleam
case text {
  "" -> []
  _  -> list.flatten([[""], [label], content_lines])
}
```

This matters on resume: the saved JSON can contain tool-use/tool-result blocks that
would otherwise render as blank labelled sections in the TUI.

---

## Architecture Overview (current)

```
springdrift.gleam  (main)
│
├── config.gleam          CLI flags + JSON file config
├── storage.gleam         session.json save / load / clear
│
├── chat/service.gleam    OTP actor — owns ChatState
│   ├── react_loop        iterative tool execution (max 5 turns)
│   └── types             ChatMessage, AgentQuestion, ToolEvent, ChatState
│
├── tools/builtin.gleam   calculator, get_current_datetime, request_human_input
│
├── tui.gleam             alternate-screen TUI event loop
│   ├── TuiState          all render + interaction state
│   ├── event_loop        selector with 100 ms poll when WaitingForLlm
│   └── render_*          header / messages / input / footer
│
└── llm/
    ├── types.gleam        ContentBlock, Message, LlmRequest/Response/Error, Tool*
    ├── request.gleam      builder API (pipe-friendly)
    ├── response.gleam     helpers (text, needs_tool_execution, tool_calls, …)
    ├── tool.gleam         ToolBuilder builder API
    ├── provider.gleam     Provider record abstraction
    └── adapters/
        ├── anthropic.gleam   anthropic_gleam SDK translation
        ├── openai.gleam      gllm SDK translation (OpenAI + OpenRouter)
        └── mock.gleam        test/fallback provider
```

### Message flow for a normal turn

```
User types → handle_enter (Idle)
  → append user Message to TUI state (optimistic display)
  → send service.SendMessage(text, reply_to, question_channel, tool_channel)
  → status: WaitingForLlm, spinner starts

Service actor (SendMessage handler)
  → append_user_message → ChatState
  → build_request (with full message history + tools)
  → spawn HTTP worker: react_loop → LlmComplete

react_loop (HTTP worker)
  → provider.chat_with (blocking)
  → if tool needed: send ToolCalling, execute tool, recurse
  → if done: send LlmComplete to service actor

Service actor (LlmComplete handler)
  → append_assistant_message → new ChatState
  → storage.save(messages)
  → send result to reply_to

TUI selector (ChatResponse)
  → handle_chat_response
  → append assistant Message, status: Idle, spinner_label: ""
  → render
```

### Concurrency model

| Process | Lifetime | Responsibility |
|---|---|---|
| Main / TUI | app lifetime | render, input, dispatch |
| Service actor | app lifetime | owns ChatState, serialises writes |
| HTTP worker | per-turn | blocking LLM calls + tool execution |
| Stdin reader | app lifetime | forwards keystrokes to selector |

All inter-process communication uses typed `Subject(T)` channels — no shared mutable
state, no locks.

---

### `immutable-log` branch — Cycle logging + Log tab (Feb 24)

**Files changed:** `src/springdrift_ffi.erl`, `src/cycle_log.gleam` (new),
`src/chat/service.gleam`, `src/tui.gleam`.

---

#### Cycle logging (`src/cycle_log.gleam`)

Every conversation cycle (user message → react loop → final response) is assigned a
UUID v4 and logged as JSON-L to `cycle-log/YYYY-MM-DD.jsonl` in the project root.
The log is complete enough to replay any LLM call offline.

**Five event types per cycle:**

| Type | Payload |
|---|---|
| `human_input` | `text` |
| `llm_request` | `model`, `system`, `max_tokens`, `messages[]`, `tools[]` |
| `llm_response` | `response_id`, `model`, `stop_reason`, `content[]`, token counts |
| `tool_call` | `tool_use_id`, `name`, `input` (raw JSON string) |
| `tool_result` | `tool_use_id`, `success`, `content` |

All entries share `cycle_id` (UUID v4) and `timestamp` (ISO 8601 local time).

**Why JSON-L?** One JSON object per line means `tail -f` works, `grep` works, and
partial writes from a crash leave all prior lines intact. A single JSON array would
require reading the whole file to append.

**`cycle_id` propagation path:**

```
SendMessage
  → cycle_log.generate_uuid()          // new UUID per user message
  → cycle_log.log_human_input(id, text)
  → react_loop(..., cycle_id)           // threaded through all turns
      → log_llm_request / log_llm_response  // around each LLM call
      → log_tool_call / log_tool_result     // around each tool execution
```

**Log directory** is `cycle-log/` relative to CWD (project root), not buried in
`~/.config`. This keeps logs inspectable alongside the source tree and avoids
path-resolution complexity.

**New Erlang FFI (`src/springdrift_ffi.erl`):**

Three functions added to support logging:

- `generate_uuid/0` — UUID v4 via `crypto:strong_rand_bytes(16)`. Bit extraction:
  `<<A:32, B:16, _:4, C:12, _:2, YBits:2, D:12, E:48>>`. Version nibble hardcoded
  as literal `"4"`; variant nibble = `8 + YBits` (gives `8`–`b`). Formatted with a
  local `Hex/2` fun using `string:to_lower(integer_to_list(N, 16))` + `string:right`
  for zero-padding.
- `get_datetime/0` — ISO 8601 local datetime via `calendar:local_time/0`, zero-padded
  with `string:right(integer_to_list(N), W, $0)`.
- `get_date/0` — date-only string from the same call, used as the log filename.

**Encoders in `cycle_log.gleam`** are self-contained (not imported from `storage.gleam`)
so the logging module has no coupling to session-persistence internals. Encoders cover
all `ContentBlock` variants, `Tool` schemas (with `ParameterSchema` and `PropertyType`),
and `StopReason`.

---

#### Log tab + cycle rewind (`src/tui.gleam`)

A second tab added to the TUI, switchable with the **Tab** key.

**Tab type:**

```gleam
type Tab { ChatTab | LogTab }
```

Three new fields on `TuiState`: `tab`, `log_cycles: List(CycleData)`,
`log_selected: Int`.

**Log tab interaction:**

| Key | Action |
|---|---|
| Tab | Switch between Chat and Log tabs |
| ↑ / ↓ | Select previous / next cycle |
| Enter | Rewind conversation to selected cycle |

Switching to the Log tab calls `cycle_log.load_cycles()` to refresh from disk,
and defaults selection to the most recent cycle.

**Cycle list rendering** — 3 lines per cycle:
1. `▶ #N  HH:MM:SS  [tool1, tool2]` (bold if selected, dimmed otherwise)
2. `    You: <truncated input>`
3. `    Asst: <truncated response>`

The time is sliced from the ISO 8601 timestamp with `string.slice(ts, 11, 8)`.

**Log reading pipeline (`cycle_log.load_cycles`):**

```
simplifile.read(log_path())
  → string.split("\n")
  → list.filter_map(json.parse(line, event_decoder()))
  → build_cycles(events)   // fold over events, group by cycle_id
```

`event_decoder` uses `gleam/dynamic/decode` continuation chaining:
```gleam
use type_str <- decode.field("type", decode.string)
case type_str {
  "human_input"  -> { use cycle_id <- ...; use text <- ...; ... }
  "llm_response" -> { use cycle_id <- ...; use parts <- decode.field("content", decode.list(content_block_text_decoder())); ... }
  "tool_call"    -> { use cycle_id <- ...; use name <- ...; ... }
  _              -> decode.success(OtherEvent)
}
```

`content_block_text_decoder` extracts text from `{"type":"text","text":"..."}` blocks
and returns `""` for all other block types. Joining the list concatenates multi-block
responses.

**Rewind mechanism:**

`cycle_log.messages_for_rewind(cycles, up_to_index)` reconstructs a flat
`List(Message)` by folding over cycles 0..N:

```gleam
[User(human_input_0), Assistant(response_text_0),
 User(human_input_1), Assistant(response_text_1), ...]
```

This matches the format `append_user_message` / `append_assistant_message` produce,
so the restored state is indistinguishable from a live session at that point.

On rewind:
1. `service.RestoreMessages(messages:)` is sent to the service actor, which calls
   `storage.save(messages)` and replaces `ChatState.messages`.
2. The TUI's own `state.messages` is updated to match (for immediate render).
3. Tab switches back to Chat with a `"  Rewound to cycle #N"` notice.

**`RestoreMessages` in `service.gleam`** — new `ChatMessage` variant alongside
`ClearHistory`:

```gleam
RestoreMessages(messages:) -> {
  storage.save(messages)
  service_loop(self, ChatState(..state, messages:))
}
```

---

---

### `immutable-log` branch (continued) — 12-Factor compliance pass (Feb 25)

**Factors addressed:** 3 (Own Your Context Window), 9 (Compact Errors into Context
Window), 12 (Make Your Agent a Stateless Reducer — full session fidelity).

**Files changed:** `src/config.gleam`, `src/cycle_log.gleam`, `src/context.gleam`
(new), `src/chat/service.gleam`, `src/springdrift.gleam`, `src/tui.gleam`.

---

#### Numeric constants promoted to config (all factors)

Previously several operational limits were hard-coded magic numbers. All are now
`Option(Int)` fields on `AppConfig` with CLI flags and JSON config keys, falling back
to sensible defaults in `springdrift.gleam`:

| Config key | CLI flag | Default | Purpose |
|---|---|---|---|
| `max_turns` | `--max-turns` | `5` | Maximum react-loop iterations per user message |
| `max_consecutive_errors` | `--max-errors` | `3` | Consecutive tool-failure limit before aborting |
| `max_context_messages` | `--max-context` | unlimited | Sliding-window message cap |

The three config fields thread through `service.start()` and are stored in `ChatState`
so the HTTP worker closure can access them without additional indirection.

---

#### Factor 9 — Consecutive error circuit breaker

`react_loop` now tracks `consecutive_errors: Int` across tool-execution rounds:

```gleam
let has_any_failure = list.any(results, fn(r) { case r { ToolFailure(..) -> True _ -> False } })
let new_consecutive = case has_any_failure { True -> consecutive_errors + 1  False -> 0 }
case new_consecutive >= max_consecutive_errors {
  True  -> Error(UnknownError("Agent loop: too many consecutive tool errors"))
  False -> react_loop(next, p, max_turns - 1, new_consecutive, ...)
}
```

Any turn where at least one tool returns `ToolFailure` increments the counter; a clean
turn (all `ToolSuccess`) resets it to `0`. If the count reaches `max_consecutive_errors`
(default 3), the loop aborts with a clear error rather than continuing to spin.

This complements the existing `max_turns` cap: turns guards against infinite loops,
errors guards against loops that technically progress (decrement turns) but keep
failing the same way.

---

#### Factor 12 — Full tool-round fidelity in session persistence

Previously `append_assistant_message` collapsed the entire react-loop output to a
single `TextContent` message, discarding all `ToolUseContent` and `ToolResultContent`
blocks. On `--resume`, the LLM could not see which tools it had invoked in prior
sessions.

**Fix:** `react_loop` now returns `Result(#(LlmResponse, List(Message)), LlmError)`
where `List(Message)` is the **complete accumulated message history** including all
intermediate tool-use and tool-result turns, plus the final assistant response:

```gleam
// Base case (no tools needed):
False -> {
  let final_msg = Message(role: Assistant, content: resp.content)
  Ok(#(resp, list.append(req.messages, [final_msg])))
}
// Recursive case: thread through the accumulated req.messages
react_loop(next, p, max_turns - 1, ...) // next.messages already has tool rounds
```

The HTTP worker unpacks this result and sends the pre-built `final_messages` list to
the service actor via the updated `LlmComplete` variant:

```gleam
LlmComplete(
  result: Result(LlmResponse, LlmError),
  final_messages: List(Message),          // complete history
  reply_to: Subject(Result(LlmResponse, LlmError)),
)
```

`LlmComplete` handler replaces the old `append_assistant_message` call:

```gleam
LlmComplete(result:, final_messages:, reply_to:) -> {
  let new_state = ChatState(..state, messages: final_messages)
  storage.save(new_state.messages)
  process.send(reply_to, result)
  service_loop(self, new_state)
}
```

`storage.gleam` already encoded/decoded all `ContentBlock` variants, so no changes
were needed there.

---

#### Factor 3 — Context window management (`src/context.gleam`)

New module with a single public function:

```gleam
pub fn trim(messages: List(Message), max_messages: Int) -> List(Message)
```

Implements a sliding window: `list.drop(messages, total - max_messages)` keeps the
most recent `max_messages` entries. Called from `build_request` when
`state.max_context_messages` is `Some(n)`:

```gleam
let messages = case state.max_context_messages {
  None    -> state.messages
  Some(n) -> context.trim(state.messages, n)
}
```

Trimming happens only at request-build time; `ChatState.messages` always holds the
full history for persistence and potential future use.

---

#### Cycle log enhancements

Three additions to `cycle_log.gleam`:

**1. `parent_id`** — `log_human_input` now accepts `parent_id: Option(String)`.
The service actor stores the previous cycle's UUID in `ChatState.last_cycle_id` and
passes it when logging each new cycle:

```gleam
// ChatState gains:
last_cycle_id: Option(String)

// SendMessage handler:
let parent_id = state.last_cycle_id
cycle_log.log_human_input(cycle_id, parent_id, text)
let new_state = ChatState(..append_user_message(state, text), last_cycle_id: Some(cycle_id))
```

Each `human_input` entry now carries `"parent_id": "uuid-or-null"`, enabling cycle
chains to be reconstructed from the log without relying on line order.

**2. Token accumulation in `CycleData`** — `CycleData` gains `input_tokens: Int` and
`output_tokens: Int`. The `event_decoder` reads these from each `llm_response` event,
and `build_cycles` accumulates them across all LLM calls within a cycle (there can be
multiple in tool-use rounds):

```gleam
LlmResponseEvent(cycle_id:, content_text:, input_tokens:, output_tokens:) ->
  list.map(acc, fn(c) {
    case c.cycle_id == cycle_id {
      True -> CycleAcc(..c,
        response_text: content_text,
        input_tokens: c.input_tokens + input_tokens,
        output_tokens: c.output_tokens + output_tokens)
      False -> c
    }
  })
```

**3. Token display in TUI** — the Log tab cycle header shows per-cycle token counts:

```
▶ #3  14:23:45  [calculator]  ↑234t ↓89t
```

The Chat tab footer shows last-turn token usage when idle:

```
↑1204t ↓87t   Enter: send   PgUp/PgDn: scroll   ...
```

`TuiState` gains `last_usage: Option(Usage)`, populated from `resp.usage` in
`handle_chat_response` on `Ok(resp)`.

---

### PR #5 (`model-choice` branch) — Query complexity routing + model switching (Feb 26)

**Files added:** `src/query_complexity.gleam` (replaces stub `src/classifier.gleam`).
**Files changed:** `src/config.gleam`, `src/chat/service.gleam`, `src/tui.gleam`,
`src/springdrift.gleam`.

---

#### Query complexity classification (`src/query_complexity.gleam`)

Every user message is classified as **Simple** or **Complex** before the main LLM
call using a two-stage strategy:

**Stage 1 — LLM classifier:**

```gleam
let req =
  request.new(model, 10)
  |> request.with_system(system_prompt)
  |> request.with_user_message(query)
```

The classification system prompt instructs the model to reply with exactly one word:
`simple` or `complex`. `max_tokens: 10` keeps the call cheap. The response is parsed
case-insensitively with `string.contains`.

**Stage 2 — Heuristic fallback** (used when the LLM call fails or returns an
unrecognised response):

```gleam
string.length(query) > 200
|| has_complexity_keyword(lower)
|| has_multiple_questions(lower)
|| has_numbered_list(lower)
```

Complexity keywords include `explain`, `compare`, `analyze`, `design`, `implement`,
`debug`, `refactor`, and ~20 others. Multiple `?` characters signal a compound
question; `1.` / `1)` signals a numbered list.

The classifier runs synchronously in the service actor on the `task_model` (cheap
and fast), adding latency only for the first LLM hop before the main call. If the
classification call fails, latency is zero (heuristic is local).

---

#### Model routing in `service.gleam`

`ChatState` gains three fields: `task_model`, `reasoning_model`, `prompt_on_complex`.

On each `SendMessage`, the service:

1. Calls `query_complexity.classify(text, provider, task_model)`.
2. Logs a `classification` event to the cycle log (complexity, reasoning model,
   whether prompted, whether confirmed).
3. On `Complex`, if the current model is already the reasoning model, skips the
   switch. Otherwise:
   - If `prompt_on_complex: True` → sends a `ModelSwitchQuestion` to the TUI via
     `model_question_channel: Subject(ModelSwitchQuestion)` and blocks on
     `process.receive_forever` for `AcceptModelSwitch | DeclineModelSwitch`.
   - If `prompt_on_complex: False` → silently switches.
4. Passes the resolved model as `final_model` through `LlmComplete` so the TUI can
   display which model was actually used.

The `SetModel(model:)` `ChatMessage` variant allows the TUI to force a model switch
without sending a message (used by `/model`).

---

#### TUI changes for model routing

- New `WaitingForModelSwitch` agent status — shown while the switch prompt is displayed.
- The model switch prompt appears inline above the input area, asking the user to
  confirm switching from `task_model` to `reasoning_model`.
- `/model` slash command: toggles `ChatState.model` between `task_model` and
  `reasoning_model` by sending `service.SetModel`.
- The footer and header show which model was used for the last completed turn.
- Log tab shows `⚡complex` / `·simple` badge per cycle using the `complexity` field
  in `CycleData`.

---

#### Config changes

Three new `AppConfig` fields (`Option` types, all default to `None`):

| Field | CLI flag | Behaviour |
|---|---|---|
| `task_model` | `--task-model` | Model for Simple queries |
| `reasoning_model` | `--reasoning-model` | Model for Complex queries |
| `prompt_on_complex` | `--no-model-prompt` sets `False` | Whether to ask before switching |

`--no-model-prompt` is a boolean flag (no value argument) that sets
`prompt_on_complex: Some(False)`.

---

#### `classification` cycle log event

New fifth event type logged by the service before spawning the HTTP worker:

```json
{
  "type": "classification",
  "cycle_id": "uuid",
  "timestamp": "...",
  "complexity": "complex",
  "reasoning_model": "claude-opus-4-6",
  "prompted": true,
  "confirmed": true
}
```

`prompted` is `true` when the user was asked, `confirmed` is `true/false/null`
depending on their answer.

---

#### Design decisions

**Why classify on `task_model`, not a dedicated tiny model?** The task model is
already configured and available. Using a separate third model would require another
config field and another API key check, for marginal gain.

**Why `max_tokens: 10` for the classifier call?** One word (`simple` or `complex`)
needs 1 token. `10` gives headroom for any whitespace or punctuation the model adds
while keeping cost negligible.

**Why is classification synchronous in the service actor rather than the HTTP
worker?** The classification result determines which model to pass into the HTTP
worker. It cannot be deferred to the worker without restructuring the model-selection
logic. The cost is one small, fast LLM call before spawning the worker.

---

### `use-skills` branch — Agent Skills integration (Feb 26)

**Files added:** `src/skills.gleam`, `test/skills_test.gleam`.
**Files changed:** `src/tools/builtin.gleam`, `src/config.gleam`, `src/springdrift.gleam`,
`test/config_test.gleam`.

Implements the [agentskills.io](https://agentskills.io/) open standard for giving
agents reusable, portable capabilities.

---

#### `src/skills.gleam` (new)

Three public functions:

**`discover(dirs: List(String)) -> List(SkillMeta)`**

Scans each directory for subdirectories containing a `SKILL.md` file. For each
found file it calls `parse_frontmatter`; only skills with both `name` and
`description` fields are returned. `~/` prefixes are expanded using the `HOME`
environment variable (same FFI call as `config.gleam`). Missing or unreadable
directories are silently skipped — discovery is best-effort.

**`parse_frontmatter(content: String) -> Result(#(String, String), Nil)`**

Parses the YAML frontmatter section of a `SKILL.md` file. The parser:
1. Strips a leading `---\n` fence if present.
2. Takes everything before the next `\n---` occurrence as the frontmatter body.
3. Splits line-by-line and extracts `key: value` pairs using `string.split(line, ": ")`.
4. Returns `Ok(#(name, description))` or `Error(Nil)` if either required field is
   missing.

Values that contain `: ` are handled correctly by splitting on the first occurrence
and rejoining the remainder. Extra fields (`license`, `version`, etc.) are silently
ignored. This function is `pub` so it can be unit-tested without touching the
filesystem.

**`to_system_prompt_xml(skills: List(SkillMeta)) -> String`**

Produces the `<available_skills>` XML block injected into the system prompt:

```xml
<available_skills>
  <skill>
    <name>my-skill</name>
    <description>What this skill does.</description>
    <location>/abs/path/my-skill/SKILL.md</location>
  </skill>
</available_skills>
```

Returns `""` for an empty list so callers never need to special-case it.

---

#### `read_skill` tool

Added to `src/tools/builtin.gleam`. The tool:

1. Decodes the `path` string from the tool call JSON input.
2. Validates that `path` ends with `"SKILL.md"` — rejects anything else with a
   descriptive `ToolFailure`. This prevents the model from using `read_skill` as a
   general file reader.
3. Calls `simplifile.read(path)` and returns the content as `ToolSuccess`, or
   a `ToolFailure` with the human-readable `simplifile.describe_error` message.

---

#### System prompt injection in `springdrift.gleam`

`run(cfg)` now:

1. Computes `skill_dirs` — either `cfg.skills_dirs` (if set) or
   `default_skill_dirs()` which returns `[home <> "/.config/springdrift/skills", ".skills"]`.
2. Calls `skills.discover(skill_dirs)`.
3. If any skills were found, appends `"\n\n" <> to_system_prompt_xml(discovered)`
   to the base system prompt.

This means the model always knows what skills are available without needing to
call any tool to find out.

---

#### Config: `skills_dirs: Option(List(String))`

New `AppConfig` field. The `--skills-dir <path>` CLI flag is repeatable — each
occurrence appends to the accumulated list:

```gleam
["--skills-dir", path, ..rest] ->
  case acc.skills_dirs {
    None    -> do_parse_args(rest, AppConfig(..acc, skills_dirs: Some([path])))
    Some(existing) ->
      do_parse_args(rest, AppConfig(..acc, skills_dirs: Some(list.append(existing, [path]))))
  }
```

The JSON config field accepts an array: `"skills_dirs": ["/path/a", "/path/b"]`.
`merge` applies `option.or` (override wins wholesale), consistent with all other
list-valued config fields.

---

#### Test coverage (`test/skills_test.gleam`)

Seven pure unit tests covering:

| Test | Verifies |
|---|---|
| `parse_valid_frontmatter_test` | `name` and `description` extracted correctly |
| `parse_missing_name_test` | Returns `Error(Nil)` |
| `parse_missing_description_test` | Returns `Error(Nil)` |
| `parse_extra_fields_ignored_test` | `license`, `metadata` lines don't affect result |
| `to_system_prompt_xml_empty_test` | Returns `""` |
| `to_system_prompt_xml_single_skill_test` | All four XML elements present |
| `to_system_prompt_xml_multiple_skills_test` | Both `<skill>` blocks present |

No filesystem setup is required — `parse_frontmatter` and `to_system_prompt_xml`
are pure functions. Discovery is tested indirectly through end-to-end runs.

---

### `main` branch — Decoupled notification channel + cognitive `request_human_input` (Mar 3)

**Files changed:** `src/agent/types.gleam`, `src/agent/cognitive.gleam`,
`test/agent/cognitive_test.gleam`, `src/tui.gleam`, `src/springdrift.gleam`.

**Factors addressed:** 7 (Contact humans via tool calls — now in cognitive loop too),
10 (Small focused agents — cognitive mode orchestrates planner/researcher/coder),
11 (Trigger from anywhere — decoupled notification channel).

---

#### Problem statement

The agent substrate (types, registry, worker, supervisor, framework, cognitive loop,
agent specs) was built and tested, but two gaps remained:

1. The cognitive loop had no `request_human_input` tool — it could dispatch to agents
   but couldn't ask the human questions directly.
2. The notification channel (`TuiNotification`) was TUI-coupled — it contained
   `reply_to: Subject(String)`, forcing any consumer to be an Erlang process with a
   typed Subject. A websocket handler or HTTP endpoint couldn't hold one.

---

#### Decoupled notification types (`src/agent/types.gleam`)

Replaced `TuiNotification` (which embedded `Subject(String)`) with pure-data types:

```gleam
pub type QuestionSource {
  CognitiveQuestion
  AgentQuestionSource(agent: String)
}

pub type Notification {
  QuestionForHuman(question: String, source: QuestionSource)
  SaveWarning(message: String)
  ToolCalling(name: String)
}
```

No `Subject` references in `Notification` — it's fully serialisable. The answer
flow goes through `UserAnswer(answer)` sent to the cognitive loop's `Subject`,
which routes based on stashed `WaitingContext`.

**`WaitingContext`** — dual-purpose stash for what to do when the human answers:

```gleam
pub type WaitingContext {
  OwnToolWaiting(
    tool_use_id: String,
    assistant_content: List(ContentBlock),
    reply_to: Subject(CognitiveReply),
  )
  AgentWaiting(reply_to: Subject(String))
}
```

`WaitingForUser` now holds `context: WaitingContext` instead of
`agent_reply_to: Option(Subject(String))`.

---

#### Cognitive loop `request_human_input` (`src/agent/cognitive.gleam`)

Renamed `tui_notify` → `notify` (type `Subject(Notification)`).

`start()` now auto-prepends `builtin.human_input_tool()` to the agent tools list.
The cognitive loop's tools are: one `agent_*` tool per registered agent +
`request_human_input`. All other tools (calculator, file ops, shell, web) are
agent-level only.

**`dispatch_tool_calls` rewrite:**

```gleam
fn dispatch_tool_calls(state, task_id, resp, calls, reply_to) {
  case list.find(calls, fn(c) { c.name == "request_human_input" }) {
    Ok(hi_call) -> handle_own_human_input(state, task_id, resp, hi_call, reply_to)
    Error(_) -> dispatch_agent_calls(state, task_id, resp, calls, reply_to)
  }
}
```

`request_human_input` is checked first. If found:

1. Parse question from tool call JSON.
2. Send `QuestionForHuman(question, CognitiveQuestion)` to notify channel.
3. Add assistant message (with tool-use content) to history.
4. Stash `OwnToolWaiting(tool_use_id, assistant_content, reply_to)`.
5. Set `WaitingForUser(question, context)`.

**`handle_user_answer` rewrite** — dual-purpose based on `WaitingContext`:

- `AgentWaiting(reply_to)` → forward answer to agent's Subject, set Idle.
- `OwnToolWaiting(tool_use_id, .., reply_to)` → build `ToolResultContent` with the
  answer, append to messages, spawn continuation think worker, set Thinking.

The think worker completes and the cycle continues (potentially more tool calls
or a final text response).

---

#### TUI dual-backend support (`src/tui.gleam`)

Introduced `ChatBackend` union to support both the existing service path and the
new cognitive path:

```gleam
type ChatBackend {
  ServiceBackend(chat: Subject(ChatMessage), chat_reply: Subject(ServiceReply))
  CognitiveBackend(
    cognitive: Subject(CognitiveMessage),
    cognitive_reply: Subject(CognitiveReply),
  )
}
```

`TuiState` replaced `chat` and `chat_reply` fields with a single `backend` field.

New `start_cognitive/7` entry point creates a selector that maps:
- `CognitiveReply` → `CognitiveReplyReceived`
- `Notification` → `NotificationReceived`

`WaitingForInput.reply_to` changed from `Subject(String)` to `Option(Subject(String))`:
- `Some(subj)` — service mode, send answer directly to the Subject.
- `None` — cognitive mode, send `UserAnswer` to the cognitive loop's Subject.

All backend-aware operations (`/clear`, `/model`, log rewind, message send) dispatch
through `state.backend`.

---

#### `--cognitive` wiring (`src/springdrift.gleam`)

New `--cognitive` CLI flag. `run()` branches:

```gleam
case list.contains(args, "--cognitive") {
  True -> run_cognitive(cfg)
  False -> run_service(cfg)
}
```

`run_cognitive` builds agent specs (planner, researcher, coder), converts them to
`agent_*` tools via `cognitive.agent_to_tool`, creates a `Subject(Notification)`,
starts the cognitive loop, and calls `tui.start_cognitive`.

---

#### Test coverage

Two new tests in `test/agent/cognitive_test.gleam`:

| Test | Verifies |
|---|---|
| `request_human_input_tool_test` | Full round-trip: LLM calls `request_human_input` → `QuestionForHuman` notification arrives → `UserAnswer` sent back → LLM gets tool result → final text response returned |
| `agent_question_decoupled_test` | `AgentQuestion` produces pure-data `QuestionForHuman(AgentQuestionSource(...))` notification → `UserAnswer` forwards to agent's `Subject(String)` |

All 189 tests pass (187 existing + 2 new).

---

#### Design decisions

| Decision | Rationale |
|---|---|
| `Notification` has no `Subject` fields | Enables non-OTP consumers (websocket, HTTP). The answer path goes through the cognitive loop's own Subject, which is the only process that needs to route answers. |
| `WaitingContext` rather than separate status variants | Keeps `WaitingForUser` as a single status with context-dependent resume logic. Avoids proliferating status variants. |
| `request_human_input` checked before agent tools in dispatch | Human questions are time-sensitive and should take priority over agent dispatch. Also avoids edge cases where the LLM calls both agent and human-input tools. |
| `builtin.human_input_tool()` auto-added in `cognitive.start()` | Callers don't need to know which built-in tools the cognitive loop needs. The cognitive loop's contract is: "give me agent tools, I add my own". |
| Forwarder not needed for `CognitiveReply` | The `cognitive_reply` Subject is registered directly in the selector at `start_cognitive` time, so replies arrive as `CognitiveReplyReceived` without spawning intermediary processes. |
| `ChatBackend` union rather than trait/behaviour | Gleam has no traits. A tagged union is the idiomatic way to dispatch to two different backend protocols from the same TUI code. |

---

## Decisions Log

| Decision | Rationale |
|---|---|
| Full tool-block fidelity via `react_loop` return type | Cleanest way to preserve intermediate messages without changing `ChatState` mid-loop. The final `req.messages` already contains the complete chain; appending only the last assistant block is an O(1) operation. |
| Context trim at request-build time, not at save time | `ChatState.messages` is the durable record; trimming it would make resume less complete. Trimming only when building the LLM request keeps the window small without information loss in storage. |
| Consecutive error counter resets on *any* successful tool turn | A mixed turn (some succeed, some fail) indicates the LLM is making progress rather than stuck in a spin-out, so resetting is the right call. |
| `parent_id: Option(String)` rather than always `String` | First cycle has no parent; `None`/`null` is more honest than a sentinel like `""` or `"root"`. |
| Token counts accumulated across all LLM calls in a cycle | A cycle with tool use makes multiple LLM calls; showing only the last call's token count would undercount actual usage. |
| Auto-save on every completed turn (not batched) | Simplest durability guarantee; a crash mid-turn loses at most one exchange. |
| `ToolEvent` channel separate from `AgentQuestion` channel | Different consumers and semantics — questions block the worker, tool events are fire-and-forget notifications. Merging them would require a sum type and extra matching in both directions. |
| `storage.save` is synchronous in the service actor | The actor is idle (between turns) when `LlmComplete` arrives, so there is no performance cost. Async save would add complexity with no benefit. |
| Spinner uses 100 ms poll, not a separate timer process | Avoids a third process and a third selector mapping. The slight jitter in spinner frame rate (frame advances only when no message arrives within 100 ms) is acceptable for a terminal UI. |
| `decode.failure(TextContent(""), "Unknown block type")` | The placeholder value is never used (the decoder always errors), but Gleam's type system requires a value of the target type. `TextContent("")` is the simplest zero-value for `ContentBlock`. |
| `--resume` is a flag, not default behaviour | Explicit opt-in prevents accidentally loading a stale session from a previous project context. |

---

### `main` branch — Remove service mode, cognitive-only (Mar 3)

**Files deleted:** `src/chat/service.gleam`, `test/service_test.gleam`.

**Files changed:** `src/agent/types.gleam`, `src/agent/cognitive.gleam`,
`src/tui.gleam`, `src/springdrift.gleam`, `test/agent/cognitive_test.gleam`,
`README.md`, `ENGINEERING_LOG.md`.

---

#### Motivation

The service/chat mode (`chat/service.gleam`) was the original single-actor
architecture — one OTP actor owning `ChatState` with a blocking `react_loop`.
The cognitive loop (`agent/cognitive.gleam`) superseded it by orchestrating
specialist sub-agents and handling `request_human_input` directly. Maintaining
two code paths (service mode vs cognitive mode, `--cognitive` flag, dual
`ChatBackend` union in the TUI) added complexity with no benefit.

This change removes service mode entirely. The cognitive loop is now the only
mode.

---

#### Query complexity classification in cognitive loop

Model switching (previously in `service.gleam`) is now wired into
`cognitive.gleam`. Two new `CognitiveState` fields:

- `task_model: String` — model for simple queries
- `reasoning_model: String` — model for complex queries

`handle_user_input` calls `query_complexity.classify` before spawning the
think worker. Simple queries use `task_model`; Complex queries auto-switch to
`reasoning_model`.

New `CognitiveMessage` variants: `SetModel(model)`, `RestoreMessages(messages)`.

---

#### TUI simplification

Removed `ChatBackend` union, `ServiceBackend`, old `start()`, `handle_chat_response`,
and service-specific message variants (`ChatResponse`, `AgentQuestionReceived`,
`ToolEventReceived`, `ModelSwitchReceived`).

`start_cognitive` renamed to `start`. `TuiState` now holds `cognitive` and
`cognitive_reply` directly instead of a `backend` field. Removed
`question_channel`, `tool_channel`, `model_question_channel` fields.

`AgentStatus.WaitingForInput` no longer carries `reply_to` — answers always go
via `UserAnswer` to the cognitive loop.

`/model` sends `SetModel` to cognitive. `/clear` sends `RestoreMessages([])` to
cognitive. Log rewind sends `RestoreMessages` to cognitive.

---

#### springdrift.gleam

Removed `import chat/service`, `run_service()`, and `--cognitive` flag.
`run()` now directly starts the cognitive loop with agents. Three new params
(`task_model`, `reasoning_model`, `prompt_on_complex`) passed to `cognitive.start`.

---

#### Test changes

185 tests pass (4 fewer than before — service tests removed, 1 new `set_model_test`
added to `cognitive_test.gleam`).

---

### `main` branch — Retry, model fallback, usage tracking, /clear, and cleanup (Mar 3)

**Files changed:** `src/agent/types.gleam`, `src/agent/cognitive.gleam`,
`src/agent/worker.gleam`, `src/agent/framework.gleam`, `src/tui.gleam`,
`src/springdrift.gleam`, `src/config.gleam`, `test/agent/cognitive_test.gleam`,
`test/agent/worker_test.gleam`, `test/config_test.gleam`, `README.md`, `CLAUDE.md`.

---

#### Worker retry with exponential backoff (`src/agent/worker.gleam`)

Think workers now retry transient errors before reporting failure. `do_call_with_retry`
attempts up to 3 retries with exponential backoff (500ms → 1s → 2s → 4s).

Retryable errors: 500 (internal server error), 529 (Anthropic overloaded), 503
(service unavailable), 429 (rate limit), network errors, timeouts.

`ThinkError` now carries a `retryable: Bool` flag so the cognitive loop knows whether
fallback is appropriate.

---

#### Automatic model fallback (`src/agent/cognitive.gleam`)

When `handle_think_error` receives a retryable error and the failed model isn't
`task_model`, it automatically falls back:

1. Spawns a new think worker with `task_model`.
2. Tracks the original model in `PendingThink.fallback_from`.
3. When the fallback completes, prefixes the response:
   `[original_model unavailable, used fallback_model]`.

This is provider-agnostic — works identically for Anthropic, OpenAI, and OpenRouter.

New `PendingThink` fields: `model: String` (tracks which model this request uses),
`fallback_from: Option(String)` (tracks the original model if this is a fallback).

---

#### Usage tracking in CognitiveReply

`CognitiveReply` now includes `usage: Option(Usage)`:

- Successful responses: `Some(resp.usage)` with input/output/thinking token counts.
- Error/fallback responses that fail: `None`.

The TUI extracts usage from replies and displays token counts in the footer.

---

#### `/clear` command (`src/tui.gleam`)

New slash command sends `RestoreMessages([])` to the cognitive loop and resets
local `messages` to `[]`.

---

#### Removed `prompt_on_complex`

The entire "prompt user before switching to reasoning model" flow has been removed.
Complex queries now always auto-switch to `reasoning_model` silently.

Removed across all files:
- `prompt_on_complex: Option(Bool)` from `AppConfig`
- `--no-model-prompt` CLI flag
- `ModelSwitchAnswer` message variant
- `WaitingForModelSwitch` status variant
- `ModelSwitchPrompt` notification variant
- `handle_model_switch_answer` handler
- All TUI code for the model-switch prompt flow
- All related tests

184 tests pass (1 fewer — removed `prompt_on_complex` tests, added model fallback test).

---

#### Agent `request_human_input` routing (`src/agent/framework.gleam`)

Sub-agents can now call `request_human_input`. In `do_react`, before calling
`spec.tool_executor(call)`, the framework checks if `call.name == "request_human_input"`.
If so, it:

1. Parses the question from the tool call JSON.
2. Sends `AgentQuestion(question, agent_name, answer_subj)` to the cognitive loop.
3. Blocks until the human answers via `process.receive_forever(answer_subj)`.
4. Returns `ToolSuccess` with the answer.

The cognitive loop already handles `AgentQuestion` → `QuestionForHuman` notification
→ TUI shows it → user answers → `UserAnswer` → cognitive forwards to agent.

---

#### Bug fixes

- **`RestoreMessages` missing `cycle_id` reset**: Now resets `cycle_id: None` so the
  next cycle doesn't chain off a stale parent.
- **`dispatch_agent_calls` dropping assistant message**: The unknown-tools branch now
  adds the assistant message to history before replying.
- **Dead `tool_use_id` in `handle_agent_complete`**: Removed unused extraction from
  `AgentSuccess`/`AgentFailure` — only `task_id` and `result_text` are extracted.
- **`WaitingForModelSwitch` guard**: Added check in `handle_user_input` to ignore
  input when status is not `Idle` (removed with the prompt_on_complex feature).

---

#### Design decisions

| Decision | Rationale |
|---|---|
| Retry in worker, fallback in cognitive | Worker handles transient retries (same model, exponential backoff). Cognitive handles strategic fallback (different model). Clean separation of concerns. |
| `retryable: Bool` in `ThinkError` | Avoids re-parsing error strings in the cognitive loop. The worker already knows if it retried. |
| `fallback_from: Option(String)` in `PendingThink` | Enables response prefixing without extra state in CognitiveState. The pending task already tracks per-request context. |
| Auto-switch (remove prompt_on_complex) | The model switch prompt interrupted the user flow for minimal benefit. Auto-switching with fallback is a better UX. |
| 500 as retryable | Internal server errors from API providers are transient. Not retrying them would surface unnecessary errors to users. |

---

### System-Level Logger + Web/TUI Log Tabs (Mar 5)

**Files added:** `src/slog.gleam`, `test/slog_test.gleam`

**Files modified:** `src/springdrift_ffi.erl`, `src/springdrift.gleam`,
`src/agent/cognitive.gleam`, `src/agent/framework.gleam`, `src/agent/worker.gleam`,
`src/agent/supervisor.gleam`, `src/tools/builtin.gleam`, `src/tools/files.gleam`,
`src/tools/web.gleam`, `src/tools/shell.gleam`, `src/query_complexity.gleam`,
`src/context.gleam`, `src/skills.gleam`, `src/storage.gleam`, `src/config.gleam`,
`src/web/gui.gleam`, `src/web/protocol.gleam`, `src/web/html.gleam`, `src/tui.gleam`,
`test/web/protocol_test.gleam`

#### System logger (`slog`)

Added a ubiquitous system-level logger with three output sinks:

1. **Date-rotated JSON-L files** — `logs/YYYY-MM-DD.jsonl`. Each entry is a JSON
   object with `timestamp`, `level`, `module`, `function`, `message`, `cycle_id`.
   Uses `simplifile.append` (same pattern as `cycle_log.gleam`).

2. **Optional stderr** — when `--verbose` is set, `slog.init(True)` stores the flag
   in `persistent_term` via FFI. Each log call checks the flag and writes a formatted
   one-liner to stderr. Uses stderr (not stdout) to avoid corrupting TUI
   alternate-screen output.

3. **UI log tabs** — `slog.load_entries()` reads today's log file and parses entries
   back into `LogEntry` records. Used by both TUI and Web GUI.

Named `slog` instead of `logger` to avoid collision with Erlang's built-in `logger`
module. The `LogLevel` type uses `LogError` (not `Error`) to avoid shadowing Gleam's
`Result.Error` constructor.

FFI additions to `springdrift_ffi.erl`:
- `log_init/1` — stores stderr-enabled flag in `persistent_term`
- `log_stdout_enabled/0` — reads the flag
- `log_stderr/1` — writes formatted text to stderr via `io:format(standard_error, ...)`

#### Module instrumentation

Every major module now imports `slog` and logs at key decision points:

- **cognitive.gleam** — message dispatch, user input, classify result, model selection,
  think errors, agent events, save operations
- **framework.gleam** — agent start, react turn number, tool execution
- **worker.gleam** — think spawn (model + task_id)
- **supervisor.gleam** — start, child lifecycle, restart attempts
- **tools/** — each tool logs its name and key input parameters
- **query_complexity.gleam** — input length, classification result
- **context.gleam** — trim operation (before/after counts)
- **skills.gleam** — discovery (dirs searched, skills found)
- **storage.gleam** — save/load operations with message counts
- **config.gleam** — config resolution

All log calls use `None` for `cycle_id` unless a cycle context is available (cognitive
loop passes `Some(state.cycle_id)`).

#### TUI log tab overhaul

Replaced the cycle-data log tab with system log entries:

- `TuiState` fields: `log_cycles → log_entries`, `log_selected → log_scroll`
- `switch_tab` calls `slog.load_entries()` instead of `cycle_log.load_cycles()`
- `render_log` displays: timestamp (HH:MM:SS), colored level badge (dim=Debug,
  cyan=Info, yellow=Warn, red=Error), module::function, message, optional cycle ID
- Navigation: ↑/↓ scrolls by 3 lines (no per-cycle selection/rewind)

#### Web GUI log tab

Added a second tab to the web interface:

- **Protocol**: `RequestLogData` client message, `LogData(entries)` server message
- **gui.gleam**: handler loads entries and sends `LogData` back over WebSocket
- **html.gleam**: tab bar (Chat/Log), log container with refresh button, JS for
  rendering log entries as a table with level-colored badges

#### Design decisions

| Decision | Rationale |
|---|---|
| `slog` not `logger` | Erlang has a built-in `logger` module; Gleam compiles to Erlang so the names would collide. |
| `LogError` not `Error` | Gleam's `Error` constructor from `Result` is used pervasively; shadowing it causes type errors in pattern matches. |
| stderr not stdout | TUI alternate-screen mode intercepts stdout. stderr bypasses the TUI and shows up in the terminal. |
| `persistent_term` for flag | Global read-heavy flag checked on every log call. `persistent_term` is optimized for exactly this: very fast reads, rare writes. |
| JSON-L (not structured logs) | Consistent with `cycle_log.gleam` pattern. One entry per line, easy to grep, easy to parse back. |
| `load_entries()` reads full file | Simple and sufficient for single-day files. No index or database needed. |

---

### Prime Narrative — Agent Memory System (Mar 6)

**Files added:** `src/narrative/types.gleam`, `src/narrative/log.gleam`,
`src/narrative/archivist.gleam`, `src/narrative/threading.gleam`,
`src/narrative/summary.gleam`, `src/narrative/cycle_tree.gleam`

**Files modified:** `src/agent/types.gleam`, `src/agent/framework.gleam`,
`src/agent/cognitive.gleam`, `src/config.gleam`, `src/springdrift.gleam`,
`src/tui.gleam`, `src/agents/planner.gleam`, `src/agents/researcher.gleam`,
`src/agents/coder.gleam`

Implemented in 11 steps following the dependency order from the Prime Narrative spec.

#### Agent identity and completion tracking (Steps 1-3)

Added `AgentIdentity` (human_name + GUID → agent_id like `researcher_e5f67890`) to
`agent/types.gleam`. The framework generates identity at startup and propagates
`agent_cycle_id` through outcomes. `AgentCompletionRecord` captures per-agent results
for the Archivist.

`AgentOutcome` gained three new fields: `agent_id`, `agent_human_name`, `agent_cycle_id`.
All three agent specs (`planner`, `researcher`, `coder`) now carry `human_name`.

Config extended with 6 narrative fields: `narrative_enabled`, `narrative_dir`,
`archivist_model`, `narrative_threading`, `narrative_summaries`,
`narrative_summary_schedule`. CLI flags: `--narrative`, `--no-narrative`, `--narrative-dir`.
TOML: `[narrative]` section.

#### NarrativeEntry schema (Step 4)

`narrative/types.gleam` defines the complete entry schema: `NarrativeEntry` with 16
fields covering `schema_version`, `cycle_id`, `parent_cycle_id`, `timestamp`,
`entry_type` (Narrative/Amendment/Summary/Observation), `summary`, `intent`
(9 classifications), `outcome` (Success/Partial/Failure + confidence),
`delegation_chain` (per-agent steps with tools/tokens/duration), `decisions`,
`keywords`, `entities` (locations/organisations/data_points/temporal_references),
`sources`, `thread`, `metrics`, and `observations`.

Thread state types (`ThreadState`, `ThreadIndex`) track active narrative threads
for overlap-based assignment.

#### Append-only log (Step 5)

`narrative/log.gleam` implements append-only JSON-L storage with full encode/decode
for every type in the schema. Query functions: `load_date`, `load_entries` (date
range via string comparison), `load_thread`, `search` (case-insensitive keyword
match against summary + keywords), `thread_heads` (latest entry per thread),
`load_all`. Thread index persisted as `thread_index.json` with atomic write
(temp file + rename).

#### Archivist (Step 6)

`narrative/archivist.gleam` generates a `NarrativeEntry` from an `ArchivistContext`
via a single LLM call. The system prompt enforces first-person past tense with
controlled vocabulary. Parse failure falls back to a minimal entry built directly
from `AgentCompletionRecords`. `spawn()` runs via `process.spawn_unlinked` — the
Archivist is never visible to the user and cannot crash the conversation.

#### Cognitive loop integration (Step 7)

`CognitiveState` gained 5 new fields: `narrative_enabled`, `narrative_dir`,
`archivist_model`, `agent_completions` (accumulated per cycle), `last_user_input`.
`handle_user_input` resets completions; `handle_agent_complete` builds an
`AgentCompletionRecord` from each `AgentOutcome`. `maybe_spawn_archivist` fires
after the main final-reply path in `handle_think_complete`.

`cognitive.start()` now takes 15 parameters (was 12). `springdrift.gleam` resolves
narrative config and passes it through. Startup prints narrative status.

#### Thread assignment (Step 8)

`narrative/threading.gleam` implements overlap scoring with configurable weights:
location=3, domain=2, keyword=1, threshold=4. `do_assign` is pure (no I/O) for
testing. `assign_thread` loads the thread index, assigns, and persists.

When an entry matches an existing thread above threshold, it joins with a continuity
note that mentions shared locations and compares data points (e.g. "Temperature
changed from 12 to 15"). New threads are named from domain + location.

Thread state merges keywords, locations, and domains incrementally (capped at 20
keywords). The Archivist calls `threading.assign_thread` between generation and
append.

#### Session summaries (Step 9)

`narrative/summary.gleam` generates Summary-type entries by feeding recent narratives
to the LLM for distillation. `weekly_range`/`monthly_range` compute date ranges with
proper month/year boundary handling. Aggregates metrics (tokens, tool calls,
delegations) across entries. Fallback summary on LLM parse failure.

#### CycleTree (Step 10)

`narrative/cycle_tree.gleam` builds a forest of `CycleNode` trees from flat entries
using `parent_cycle_id` links. Orphans (parent not in set) become roots. Supports
`flatten` (pre-order traversal), `depth`, and `find` by cycle ID.

#### Narrative tab (Step 11)

Added `NarrativeTab` to the TUI's tab cycle (Chat → Log → Narrative → Chat). The
narrative tab loads all entries via `narrative_log.load_all` and renders each with:
cycle ID (8-char), timestamp, status badge (green OK / yellow ~~ / red !!), thread
info, summary text, and delegation chain with agent names and outcomes.

`tui.start` gained a `narrative_dir` parameter. `springdrift.gleam` passes it through.

#### Design decisions

| Decision | Rationale |
|---|---|
| `spawn_unlinked` for Archivist | Archivist failure must never affect the user's conversation. Fire-and-forget is the correct model. |
| Single LLM call (not multi-turn) | Narrative generation is a summarization task, not a reasoning task. One call with a good system prompt suffices. |
| Overlap scoring (not LLM classification) | Thread assignment runs on every cycle. LLM calls would add latency and cost. Simple weighted overlap is fast and deterministic. |
| Threshold=4 | Matches "1 location + 1 keyword" or "1 domain + 2 keywords" — reasonable for grouping related queries. |
| JSON-L (not SQLite) | Consistent with cycle_log pattern. Append-only, grep-friendly, no external dependencies. |
| Pure `do_assign` + I/O `assign_thread` | Testable core logic separated from file I/O. All 14 threading tests are pure. |
| `AgentCompletionRecord` with zeros | Framework doesn't currently track per-agent tokens/duration. Zeros are acceptable placeholders; the Archivist still gets useful data from agent_id, human_name, and result. |
| Tab cycle (not numbered tabs) | Three tabs still fit a simple Tab-key cycle. F-key shortcuts would add complexity without value at this scale. |

---

### Profile System + Knowledge Agent (Mar 7)

**Files added:** `src/profile.gleam`, `src/profile/types.gleam`, `src/agents/writer.gleam`,
`profiles/analyst/config.toml`, `profiles/analyst/dprime.json`,
`profiles/analyst/skills/{cite-sources,fact-check,summarize}/SKILL.md`

**Files modified:** `src/config.gleam`, `src/agent/types.gleam`, `src/agent/cognitive.gleam`,
`src/springdrift.gleam`, `src/tui.gleam`, `src/web/gui.gleam`, `src/web/html.gleam`,
`src/web/protocol.gleam`

#### Profile types and discovery

`profile/types.gleam` defines the complete profile schema:
- `Profile` — name, description, dir, models, agents, dprime_path, schedule_path, skills_dir
- `ProfileModels` — optional task_model and reasoning_model overrides
- `AgentDef` — name, description, tools, max_turns, system_prompt
- `DeliveryConfig` — FileDelivery | WebhookDelivery | WebSocketDelivery
- `ScheduleTaskConfig` — name, query, interval_ms, start_at, delivery, only_if_changed

`profile.gleam` handles discovery (`discover/1`), loading (`load/2`), and schedule
parsing (`parse_schedule/1`). Profiles are TOML-based. Schedule tasks use human-friendly
interval parsing (e.g. `"1h"`, `"30m"`, `"2d"`).

#### Hot-swappable profile loading

`CognitiveMessage` gained `LoadProfile(name, reply_to)` variant. The cognitive loop
handles it via `do_load_profile`, which swaps models, D' state, and output gate state
at runtime. `ProfileNotification(name)` signals the UI.

#### Dual-gate D' config

`dprime/config.gleam` gained `load_dual/1` — tries dual-gate format first
(`{"tool_gate": {...}, "output_gate": {...}}`), falls back to single-gate.
Returns `#(DprimeConfig, Option(DprimeConfig))`.

---

### D' Output Gate (Mar 7)

**Files added:** `src/dprime/output_gate.gleam`

**Files modified:** `src/agent/cognitive.gleam`

Second evaluation point checking finished reports for quality before delivery.
Uses same D' scoring infrastructure but with output-focused prompts targeting:
unsourced claims, causal overreach, stale data, certainty overstatement.

`evaluate/7` runs the full D' pipeline (scorer → engine → gate_decision) with
output-specific features. `build_output_scoring_prompt` uses calibration examples
tuned for report quality rather than tool safety.

Cognitive loop integration: `handle_think_complete` checks `output_dprime_state`;
if Some, spawns output gate instead of replying immediately. `OutputGateComplete`
message carries result + report text + modification count. Bounded modification
loop (max 2 iterations) — Accept delivers, Modify re-prompts, Reject returns error.

---

### BEAM-Native Task Scheduler (Mar 7)

**Files added:** `src/scheduler/types.gleam`, `src/scheduler/runner.gleam`,
`src/scheduler/delivery.gleam`, `src/scheduler/persist.gleam`

#### Scheduler process

`scheduler/runner.gleam` implements an OTP process that:
1. Converts `ScheduleTaskConfig` list to `ScheduledJob` state
2. Schedules initial ticks via `process.send_after`
3. Event loop handles: `Tick` → spawn job, `JobComplete` → deliver + reschedule,
   `JobFailed` → increment error count + reschedule, `StopAll`, `GetStatus`

Named `runner.gleam` (not `scheduler.gleam`) to avoid collision with Erlang's built-in
`scheduler` module.

#### Delivery

`scheduler/delivery.gleam` handles report delivery:
- **File**: creates directory, generates timestamped filename (sanitized), writes content
- **Webhook/WebSocket**: stubs returning Error (not yet implemented)

#### Checkpoint persistence

`scheduler/persist.gleam` provides atomic state persistence:
- `save/2` — encodes jobs as JSON, writes to tmp file, renames atomically via FFI
- `load/1` — decodes checkpoint with full status serialization
- `reconcile/2` — aligns checkpoint jobs with current config names (removes obsolete,
  preserves run state for matching jobs)

#### Design decisions

| Decision | Rationale |
|---|---|
| `process.send_after` not cron | BEAM-native timing avoids external dependencies. Jobs fire at interval after completion, not wall-clock aligned. |
| Atomic checkpoint writes | tmp + rename prevents half-written state on crash. Uses existing `file_rename` FFI. |
| `reconcile` not merge | Config is source of truth. Checkpoint preserves run counts/status but config defines what jobs exist. |
| Module name `runner` | Gleam compiles to Erlang; `scheduler.gleam` would collide with Erlang's `scheduler` module. |

---

### Production Hardening (Mar 7)

Implemented recommendations from commercial evaluation review. 503 tests, zero warnings.

#### Input boundary protection

- **TUI input buffer**: capped at 100KB (102,400 bytes) in `handle_stdin_byte`. Characters
  silently dropped at limit. Prevents paste-bombing memory exhaustion.
- **read_file size limit**: 10MB max via `file_size` FFI (`filelib:file_size/1`). Pre-read
  check returns `ToolFailure` before loading content into memory.
- **WebSocket message limit**: 1MB max on incoming `mist.Text` frames. Oversized messages
  silently dropped with `mist.continue`.

#### Config file validation

`parse_config_toml` now calls `validate_toml_keys` and `validate_config_values` after
successful TOML parsing. Validation is warning-only — configs still load, but issues
are logged via `slog.warn`:

- Unknown top-level TOML keys flagged (catches typos like `provder`)
- Unknown `[narrative]` sub-keys flagged
- Numeric values range-checked (max_tokens, max_turns, etc. must be positive)
- Provider validated against known options (anthropic, openrouter, openai, mistral, local, mock)
- GUI mode validated against tui/web
- `load_from_path` logs warning on TOML parse failure (was silent)

#### Session integrity and versioning

`storage.save` wraps messages in a JSON envelope:
```json
{"version": 1, "saved_at": "2026-03-07T14:30:00", "messages": [...]}
```

`storage.load` tries envelope format first, falls back to legacy plain-array format
(backward compatible). Staleness detection: logs info message when resuming sessions
from a different date. Corruption detection: logs warning and returns empty list.

#### XML escaping in skills

`skills.xml_escape` escapes `& < > " '` before injecting skill names, descriptions,
and paths into the `<available_skills>` XML block. Prevents XML injection from
untrusted skill metadata.

#### Symlink resolution in path validation

`is_within_cwd` in `tools/files.gleam` now resolves symlinks via `resolve_symlinks`
FFI before checking CWD boundaries. The FFI function (`springdrift_ffi:resolve_symlinks/1`)
recursively walks path components, following symlinks via `file:read_link/1` at each
level. Both the target path and CWD are resolved, preventing symlink-based escape.

#### Log retention policies

- **Size rotation**: `slog.append_to_file` checks file size before appending. Files
  exceeding 10MB are renamed to `.1` suffix before writing.
- **Age cleanup**: `slog.cleanup_old_logs` removes `.jsonl` files older than 30 days.
  Called once at startup after `slog.init`. Uses `days_ago_date` FFI for proper
  calendar arithmetic.

#### Web GUI authentication

Bearer token authentication gated by `SPRINGDRIFT_WEB_TOKEN` environment variable:
- If set: all HTTP requests and WebSocket upgrades must authenticate
- Supports `Authorization: Bearer <token>` header or `?token=<token>` query parameter
- WebSocket connection URL auto-includes token from page URL parameters
- If unset: no auth required (suitable for localhost-only use)
- Unauthenticated requests receive HTTP 401

#### JSON sanitization (from prior session)

`sanitize_json` FFI function in `springdrift_ffi.erl` fixes LLM-generated JSON with
unescaped control characters inside string values. Binary pattern matching walks the
JSON tracking in-string and escape state:
- `\n` → `\\n`, `\r` → `\\r`, `\t` → `\\t` inside strings
- Other control chars (< 0x20) → `\\uXXXX` escape
- Already-escaped sequences preserved (no double-escaping)
- Characters outside strings pass through unchanged

Applied in both `narrative/archivist.gleam` (narrative entry parsing) and
`dprime/scorer.gleam` (forecast parsing).

#### Design decisions

| Decision | Rationale |
|---|---|
| Warning-only config validation | Breaking on unknown keys would be hostile to users experimenting with config. Logging warnings lets them see the issue without being blocked. |
| Envelope session format | Version field enables future migrations. `saved_at` enables staleness detection. Legacy fallback ensures smooth upgrade. |
| Pre-read file size check | Checking after read still loads the file into memory. FFI `filelib:file_size` is O(1) stat call. |
| Silent drop on buffer overflow | Alert noise (beep, error message) would be worse than silently stopping input at a reasonable limit. |
| Query param auth for WebSocket | Browsers don't support custom headers on WebSocket upgrade requests. Query param is the standard workaround. |
| 30-day log retention | Balances disk space with reasonable audit trail. Date arithmetic via Erlang `calendar` module for correctness. |

---

### Session 8 — CBR Memory Architecture + Identity & Profiles (2026-03-08)

#### CBR (Case-Based Reasoning) memory

Implemented a full CBR subsystem for experience-based learning:

- **`src/cbr/types.gleam`** — `CbrCase` type with problem (user_input, intent, domain,
  entities, keywords, query_complexity), solution (approach, agents_used, tools_used, steps),
  outcome (status, confidence, assessment, pitfalls), embedding vector, source_narrative_id,
  and optional profile field. Also defines `CbrQuery` for retrieval and `CbrMatch` with
  relevance scoring.

- **`src/cbr/log.gleam`** — Append-only JSON-L persistence (`YYYY-MM-DD.jsonl`). Full
  encode/decode roundtrip with lenient decoders (null → sensible defaults). Functions:
  `append`, `load_date`, `load_all`, `encode_case`, `case_decoder`.

- **Librarian CBR integration** — The Librarian actor (`narrative/librarian.gleam`)
  expanded to index CBR cases in ETS alongside narrative entries. New messages:
  `IndexCase`, `NotifyNewCase`, `QueryCbrRetrieve`, `LoadAllCases`, `QueryCaseCount`.
  CBR retrieval uses multi-signal scoring: intent match (0.3), domain match (0.2),
  keyword Jaccard overlap (0.2), entity Jaccard overlap (0.2), recency bonus (0.1).
  Threshold filtering at 0.1 minimum score.

- **Archivist CBR generation** — After writing a narrative entry, the Archivist extracts
  a `CbrCase` from the same cycle data, persists it via `cbr/log.append`, and notifies
  the Librarian.

#### Facts store

- **`src/facts/types.gleam`** — `MemoryFact` type with `FactScope` (Session/Persistent/Global),
  `FactOperation` (Write/Delete/Superseded), confidence score, supersedes chain.

- **`src/facts/log.gleam`** — Append-only JSON-L persistence for facts. Encode/decode
  with full roundtrip fidelity.

- **Librarian facts integration** — ETS-backed fact storage with read/write/delete
  operations and count queries.

#### Housekeeping

`narrative/housekeeping.gleam` provides three maintenance operations:

- **CBR deduplication** — `find_duplicate_cases` compares embedding vectors via cosine
  similarity. Pairs above threshold (default 0.92) are flagged; newer case is kept,
  older superseded.

- **Case pruning** — `find_prunable_cases` identifies old failures (>90 days) with low
  confidence (<0.4) and no pitfalls. These have no learning value and can be removed.

- **Fact conflict resolution** — `find_fact_conflicts` detects same-key different-value
  facts. The higher-confidence fact is kept; the other gets a `Superseded` operation.

- **`HousekeepingReport`** — summary type with `format_report` for human-readable output.

- **`make_superseded_fact`** — builder for creating superseded fact entries.

#### Curator system prompt assembly

`narrative/curator.gleam` extended with `BuildSystemPrompt` message:

1. Loads `persona.md` and `session_preamble.md` from identity directories
2. Queries Librarian for thread count, persistent fact count, and CBR case count
3. Builds `SlotValue` list for preamble template substitution
4. Renders preamble with `{{slot}}` replacement and `[OMIT IF]` rule processing
5. Assembles final system prompt: persona text + `<memory>` wrapped preamble
6. Falls back to provided fallback prompt when no identity files exist

New state fields: `identity_dirs`, `memory_tag`, `active_profile`.
New public API: `start_with_identity()`, `build_system_prompt()`.

#### Identity system

`src/identity.gleam` — pure functional module for persona and preamble handling:

- **Persona loading** — `load_persona(dirs)` scans directories for `persona.md`,
  returns `Some(content)` or `None`.

- **Preamble templating** — `render_preamble(template, slots)` processes two phases:
  1. `{{slot}}` substitution from `SlotValue` list
  2. `[OMIT IF X]` rule evaluation — removes lines matching conditions:
     - `EMPTY` — line value is empty after substitution
     - `ZERO` — line contains a zero count (starts with "0 " or contains " 0 ")
     - `NO PROFILE` — no active profile set
     - `THREADS EXIST` / `FACTS EXIST` — conditional visibility

- **System prompt assembly** — `assemble_system_prompt(persona, preamble, tag)` wraps
  preamble in configurable XML tags (default `<memory>`), prepends persona text.

- **Relative dates** — `format_relative_date(days_ago)` produces human-friendly strings:
  today, yesterday, N days ago, last week, 2 weeks ago, ISO date for 30+ days.

- **Slot formatters** — `format_thread_lines` and `format_fact_lines` produce structured
  text for preamble injection with relative date annotations.

#### Identity paths

`src/paths.gleam` extended with identity directory helpers:
- `persona_filename`, `preamble_filename` constants
- `local_identity_dir()`, `user_identity_dir()`, `default_identity_dirs()`

#### CbrCase profile field

Added `profile: Option(String)` to `CbrCase` type as a retrieval hint. The field is:
- Encoded as JSON string or null in `cbr/log.gleam`
- Decoded with `decode.optional(decode.string)` for backward compatibility
- Set to `None` by default in the Archivist

#### Librarian count queries

Three new synchronous query messages for preamble slot population:
- `QueryThreadCount` → count of active threads in thread index
- `QueryPersistentFactCount` → count of persistent-scope facts
- `QueryCaseCount` → count of indexed CBR cases

#### Profile UI cleanup

Removed runtime profile switching from TUI and web GUI since profiles are now
startup-only ("uniforms not personalities"):

- **TUI** — removed `/profile` command handler and `ProfileNotification` dispatch
- **Web GUI** — removed `SendProfiles`, `available_profiles` parameter, profile selector
  HTML/CSS/JS, `RequestLoadProfile` handler
- **Protocol** — removed `RequestLoadProfile`, `ProfilesAvailable`, `ProfileLoaded`
  message types and their encoders/decoders
- **springdrift.gleam** — removed `available_profiles` parameter from `web_gui.start()`

#### Test coverage

675 tests passing. New test files:
- `test/identity_test.gleam` — 29 tests covering persona loading, slot substitution,
  preamble rendering with OMIT IF rules, system prompt assembly, relative dates
- `test/narrative/curator_test.gleam` — extended with 2 identity integration tests
- `test/narrative/housekeeping_test.gleam` — 18 tests for cosine similarity, CBR dedup,
  pruning, fact conflicts, report formatting
- `test/cbr/log_test.gleam` — 7 tests for encode/decode roundtrip, JSONL loading
- `test/cbr/librarian_cbr_test.gleam` — 9 tests for Librarian CBR indexing and retrieval

#### Design decisions

| Decision | Rationale |
|---|---|
| CBR as separate module from narrative | CBR cases are derived artifacts with different lifecycle (dedup, pruning) vs immutable narrative entries |
| Multi-signal CBR scoring | Single-dimension matching (e.g. just keywords) produces too many false positives. Weighted combination of intent, domain, keywords, entities, and recency gives robust retrieval |
| Cosine similarity for dedup | Standard approach for vector comparison. Threshold-based (0.92) avoids aggressive merging while catching near-duplicates |
| OMIT IF rules in preamble | Prevents empty/zero lines from cluttering the system prompt. Rules are inline `[OMIT IF X]` comments — no separate config |
| Persona + preamble separation | Persona is fixed character text (rarely changes). Preamble is dynamic session context (changes every turn). Separate files enable independent editing |
| Curator as orchestrator | Single point of coordination for identity + memory → system prompt. Avoids scattering assembly logic across cognitive loop |
| Profile field on CbrCase | Lightweight retrieval hint — no hard coupling. Optional field with null default for backward compatibility |
| Startup-only profiles | Runtime switching added complexity with no clear benefit. Profiles configure agent roster + D' — things that shouldn't change mid-conversation |

---

### Oikeiosis — Agent Self-Model (Mar 10)

Five interconnected changes giving the agent a stable identity, richer self-perception,
and dynamic system prompt assembly from memory state.

#### Change A — Fold `agent_status` into `introspect` tool

Replaced the simple `agent_status` tool (name + status list) with a richer `introspect`
tool that exposes the agent's full self-model in a single call.

**Files modified:**
- `src/tools/memory.gleam` — replaced `agent_status_tool()` with `introspect_tool()`,
  added `IntrospectContext` type (agent_uuid, session_since, active_profile, agents,
  dprime_enabled, thresholds, current_cycle_id), updated `execute` signature (last param
  changed from `List(AgentStatusEntry)` to `Option(IntrospectContext)`), replaced
  `run_agent_status` with `run_introspect` (renders identity, agents, and D' sections)
- `src/agent/cognitive/agents.gleam` — builds `IntrospectContext` from `CognitiveState`,
  reads D' thresholds from `dprime_state`
- `test/tools/memory_test.gleam` — replaced 2 `agent_status` tests with 5 `introspect`
  tests (no context error, full context, no agents, is_memory_tool checks)

#### Change B — Stable Agent Identity

Every Springdrift instance gets a stable UUID persisted in `.springdrift/identity.json`.

**Files added:**
- `src/agent_identity.gleam` — `AgentIdentity` type with `load_or_create()` and `save()`,
  JSON encoding/decoding, `generate_uuid` and `get_datetime` FFI

**Files modified:**
- `src/agent/cognitive_config.gleam` — added `agent_uuid: String`, `session_since: String`
- `src/agent/cognitive_state.gleam` — added `agent_uuid: String`, `session_since: String`
- `src/agent/cognitive.gleam` — threads uuid/session from config to state
- `src/springdrift.gleam` — loads identity before cognitive loop, passes to config

#### Change C — Curator Constitution Slot with Caching

Added a `ConstitutionSlot` to the Curator's virtual memory, pushed by the Archivist
after each cycle and by agent lifecycle events.

**Files modified:**
- `src/narrative/virtual_memory.gleam` — added `ConstitutionSlot` type (today_cycles,
  today_success_rate, agent_health), `set_constitution()`, `render_constitution()`
- `src/narrative/curator.gleam` — added `UpdateConstitution` and `UpdateAgentHealth`
  messages, `agent_name`/`agent_version` state fields, constitution preamble slots
- `src/narrative/archivist.gleam` — `spawn` gains `curator` parameter; after writing
  entries, loads today's entries and pushes `update_constitution` to Curator
- `src/agent/cognitive/agents.gleam` — `handle_agent_event` pushes `update_agent_health`
  to Curator on crash/restart/stop events
- `src/agent/cognitive/memory.gleam` — passes `state.curator` to `archivist.spawn`

#### Change D — Replace `system_prompt` with `agent_name`/`agent_version`

Removed the `system_prompt` config field entirely. The system prompt is now assembled
by the Curator from identity files. Agent naming moves to `[agent] name`/`version`.

**Files modified:**
- `src/config.gleam` — removed `system_prompt: Option(String)`, added `agent_name`
  and `agent_version`, removed `--system` CLI flag, added `--agent-name`/`--agent-version`,
  updated TOML parsing for `[agent]` table
- `src/springdrift.gleam` — removed system prompt fallback logic, passes agent_name/version
  to Curator, updated help text
- `test/config_test.gleam` — updated all ~20 AppConfig constructors

#### Change E — Default identity files

Shipped default `persona.md` and `session_preamble.md` in `.springdrift_example/identity/`.

**Files added:**
- `.springdrift_example/identity/persona.md` — first-person character text with
  `{{agent_name}}` slot
- `.springdrift_example/identity/session_preamble.md` — dynamic template with all
  Curator slots and `[OMIT IF]` rules

**Files modified:**
- `src/paths.gleam` — removed `priv_dir` FFI and `priv_identity_dir()`, simplified
  `default_identity_dirs()` to search local project then user global only
- `src/springdrift_ffi.erl` — removed `priv_dir/0` export and implementation
- `.springdrift_example/README.md` — updated directory layout with identity, CBR, facts
- `.springdrift_example/config.toml` — replaced `system_prompt` with `[agent]` section

#### Test coverage

789 tests passing (up from 786 baseline). Net +3 tests from introspect additions
minus agent_status removals.

#### Design decisions

| Decision | Rationale |
|---|---|
| `IntrospectContext` as Option param | Avoids tight coupling between memory tools and cognitive state. Tests pass None for non-introspect calls |
| Identity files in `.springdrift_example/` not `priv/` | Avoids Erlang `code:priv_dir/1` dependency; files are user-facing templates meant to be copied and customised, not embedded in the release |
| Archivist pushes constitution | Fire-and-forget after each cycle. Curator caches values; preamble always has fresh stats without blocking |
| Agent health pushed on lifecycle events | Crash/restart/stop events update Curator immediately. Started events don't push (nominal state is implicit) |
| `system_prompt` removed entirely | System prompt is now assembled from identity files by the Curator. No config field needed — falls back to empty when no identity exists |

---

### Artifact Store & ETS Startup (Mar 10)

Four-part implementation adding artifact storage, agent context windowing, facts daily
rotation, and ETS startup optimisations. 800 tests passing.

#### Change 1 — Facts daily rotation

Migrated facts from a single `facts.jsonl` to daily-rotated `YYYY-MM-DD-facts.jsonl` files,
matching the pattern used by narrative and cycle-log stores.

**Files modified:**
- `src/facts/log.gleam` — rewritten for daily rotation; `append()` writes to dated files,
  `load_all()` scans directory for all `*-facts.jsonl` files, `migrate_legacy()` moves
  old `facts.jsonl` entries to dated format
- `src/narrative/librarian.gleam` — calls `facts_log.migrate_legacy()` at startup before
  replaying facts into ETS

#### Change 2 — Librarian artifact ETS tables

Extended the Librarian actor with two new ETS tables (`artifacts` set and
`artifacts_by_cycle` bag) for fast artifact metadata lookups.

**Files modified:**
- `src/narrative/librarian.gleam` — added `artifacts_dir`, `artifacts`, `artifacts_by_cycle`
  to `LibrarianState`; added 4 new messages (`IndexArtifact`, `QueryArtifactsByCycle`,
  `QueryArtifactById`, `RetrieveArtifactContent`); added `replay_artifacts_from_disk()`
  at startup; added artifact ETS FFI calls; updated `start()`/`start_supervised()` signatures
- `src/narrative/store_ffi.erl` — artifact-specific ETS insert/lookup FFI functions
- All Librarian test files — updated `start()` calls with `artifacts_dir` parameter

#### Change 3 — Artifact tools (store_result / retrieve_result)

Two new tools for the researcher agent to offload large web content to disk and retrieve
it by compact artifact ID, keeping the agent's context window lean.

**Files added:**
- `src/artifacts/types.gleam` — `ArtifactRecord` (full on-disk record) and `ArtifactMeta`
  (metadata-only projection)
- `src/artifacts/log.gleam` — daily-rotated JSONL storage with 50KB truncation; `append()`,
  `load_date_meta()`, `read_content()`
- `src/tools/artifacts.gleam` — `store_result` and `retrieve_result` tool definitions +
  execution; uses closure to capture `artifacts_dir` and `librarian` subject
- `test/artifacts/log_test.gleam` — 6 tests for JSONL storage
- `test/artifacts/librarian_artifact_test.gleam` — 5 tests for ETS indexing and replay

**Files modified:**
- `src/agents/researcher.gleam` — updated `spec()` to accept `artifacts_dir` and `lib`;
  added artifact tools to tool list; updated `researcher_executor()` closure
- `src/springdrift.gleam` — moved Librarian startup before agent spec construction;
  updated `default_agent_specs()` to pass librarian subject; added `paths.artifacts_dir()`
- `src/paths.gleam` — added `artifacts_dir()` returning `.springdrift/memory/artifacts`

#### Change 4 — Agent context windowing

Added `max_context_messages: Option(Int)` to `AgentSpec` for per-agent sliding-window
context trimming. The researcher agent uses 30 messages to stay lean during multi-turn
web research.

**Files modified:**
- `src/agent/types.gleam` — added `max_context_messages` field to `AgentSpec`
- `src/agent/framework.gleam` — applies `context.trim()` in the react loop when the
  spec has a `max_context_messages` limit
- All agent specs (`planner.gleam`, `researcher.gleam`, `coder.gleam`, `writer.gleam`) —
  added `max_context_messages` field

#### Design decisions

| Decision | Rationale |
|---|---|
| Closure-based tool executors | `AgentSpec.tool_executor` is `fn(ToolCall) -> ToolResult` — no room for extra params. Closure captures `artifacts_dir` and `librarian` at spec construction time |
| Two-step retrieve (lookup meta → read content) | `retrieve_result` needs `stored_at` date to find the right JSONL file. Looks up metadata first via `QueryArtifactById`, then uses `stored_at` for content read |
| Librarian starts before agent specs | `researcher.spec()` needs the librarian subject. Reorganised `springdrift.gleam` boot sequence accordingly |
| 50KB truncation limit | Balances content preservation with disk usage. `truncated: True` flag in metadata lets agents know content was capped |
| Daily rotation for facts | Consistency with narrative/artifact stores. Legacy `facts.jsonl` auto-migrated at startup |
| Per-agent context windowing | Researcher's multi-turn web research can generate many messages. 30-message window prevents context overflow without affecting other agents |
