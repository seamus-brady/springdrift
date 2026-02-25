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
| Date | `get_today_date` | Calls `erlang:date()` via FFI; formats as `YYYY-MM-DD` with zero-padding |
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
├── tools/builtin.gleam   calculator, get_today_date, request_human_input
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
