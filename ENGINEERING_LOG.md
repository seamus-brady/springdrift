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

## Decisions Log

| Decision | Rationale |
|---|---|
| `append_assistant_message` stores only `TextContent` | Keeps saved JSON human-readable; tool-use round-trips are reconstructed by the LLM from text context on resume. Full fidelity would require storing the entire `resp.content` block list. |
| Auto-save on every completed turn (not batched) | Simplest durability guarantee; a crash mid-turn loses at most one exchange. |
| `ToolEvent` channel separate from `AgentQuestion` channel | Different consumers and semantics — questions block the worker, tool events are fire-and-forget notifications. Merging them would require a sum type and extra matching in both directions. |
| `storage.save` is synchronous in the service actor | The actor is idle (between turns) when `LlmComplete` arrives, so there is no performance cost. Async save would add complexity with no benefit. |
| Spinner uses 100 ms poll, not a separate timer process | Avoids a third process and a third selector mapping. The slight jitter in spinner frame rate (frame advances only when no message arrives within 100 ms) is acceptable for a terminal UI. |
| `decode.failure(TextContent(""), "Unknown block type")` | The placeholder value is never used (the decoder always errors), but Gleam's type system requires a value of the target type. `TextContent("")` is the simplest zero-value for `ContentBlock`. |
| `--resume` is a flag, not default behaviour | Explicit opt-in prevents accidentally loading a stale session from a previous project context. |
