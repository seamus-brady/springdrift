# Message History State Machine

The cognitive loop's message history (`state.messages`) is an opaque,
invariant-bearing wrapper around the list of `Message` values sent to
the LLM provider. Every mutation goes through a single chokepoint that
maintains the provider-API invariants by construction. The chokepoint
makes entire bug families structurally impossible.

This document describes the design, the invariants, and the migration
path from the v0.9 reactive-sweep model to the v0.10 state-machine
model.

## 1. Why This Exists

Anthropic's API rejects requests whose message history violates one of
four invariants:

1. Every assistant `tool_use` block must be answered by a
   `tool_result` (with matching `tool_use_id`) in the very next user
   message.
2. Conversely, every user `tool_result` block's `tool_use_id` must
   match a `tool_use` in the immediately-prior assistant message — no
   orphan tool_results.
3. Messages must alternate user / assistant.
4. The first message must be user-role.

Violations come back as 400 errors that look like:

```
messages.40.content.0: unexpected `tool_use_id` found in `tool_result`
blocks: toolu_01ENZvGmDNX7ELs1TyBwiohG. Each `tool_result` block must
have a corresponding `tool_use` block in the previous message.
```

These errors **poison every subsequent cycle** until something
repairs the stored history. The cog dies in production. The operator
restarts. It happens again.

## 2. The Pre-v0.10 Model — Reactive Sweep

Through v0.9, `state.messages` was `List(Message)` — a public mutable
list. Every cog handler appended to it directly:

```gleam
let messages = list.append(state.messages, [assistant_msg, user_msg])
```

The provider-API invariants lived only in a reactive sweep at the
LLM boundary (`message_repair.gleam` + `context.gleam`'s
`strip_orphaned_tool_results`). The sweep was incomplete — it covered
orphan-tool_use (assistant emitted a tool_use, no matching
tool_result follows), but **not** orphan-tool_result (user message
contains a tool_result with no matching tool_use in the prior
assistant). And the strip ran only on the trim path, not
unconditionally.

When new code paths appended new shapes, the sweep didn't always
cover them. Each new shape was a new bug, fixed at the boundary, until
the next one. The user's framing on the day of the rewrite: *"are we
patching a turd here?"*

## 3. The v0.10 Model — Opaque Type, Chokepoint, Invariants by Construction

```gleam
pub opaque type MessageHistory {
  MessageHistory(messages: List(Message))
}
```

The constructor `MessageHistory(...)` is not exposed. The only ways to
build one are `new/0`, `from_list/1` (which sanitises), or via the
typed `add` API.

The single chokepoint is `add/2`:

```gleam
pub fn add(h: MessageHistory, msg: Message) -> MessageHistory {
  case h.messages, msg.role {
    [], Assistant       -> h                         // (4) silently dropped
    [], _               -> MessageHistory([msg])
    prior, _ -> {
      let prior_ids = last_assistant_tool_use_ids(prior)
      case clean_msg(msg, prior_ids) {                // (2) strip orphan results
        None    -> h
        Some(c) -> coalesce_or_append(prior, c)       // (3) alternation
      }
    }
  }
}
```

`add/2` enforces:

- **(4) leading-user**: assistant-first appends to an empty history are
  silently dropped
- **(3) alternation**: consecutive same-role messages are coalesced
  into one (content blocks concatenated)
- **(2) no orphan tool_results**: in a user message, any tool_result
  whose `tool_use_id` isn't in the immediately-prior assistant's
  tool_use IDs is dropped; if that empties the message, the message
  itself is dropped

Invariant (1) — orphan tool_use without follow-up tool_result — is
handled by `from_list/1` at ingest time (synthesises stub
tool_results). Append-time enforcement of (1) would require knowing
the next message in advance, which `add/2` doesn't have.

## 4. The API

```gleam
// Construction
pub fn new() -> MessageHistory
pub fn from_list(messages: List(Message)) -> MessageHistory  // sanitises
pub fn from_messages(msgs: List(Message)) -> MessageHistory  // folds add

// Reads
pub fn length(h) -> Int
pub fn is_empty(h) -> Bool
pub fn last(h) -> Option(Message)
pub fn to_list(h) -> List(Message)         // canonical chronological order
pub fn for_send(h) -> List(Message)        // wire-ready

// Mutations (each preserves invariants by construction)
pub fn add(h, msg: Message) -> MessageHistory
pub fn add_all(h, msgs: List(Message)) -> MessageHistory
pub fn add_user_text(h, text: String) -> MessageHistory
pub fn add_assistant(h, content: List(ContentBlock)) -> MessageHistory
pub fn add_user(h, content: List(ContentBlock)) -> MessageHistory
```

Direct `list.append` on `state.messages` is now impossible — the
opaque wrapper makes it a type error.

## 5. The Sanitisation Pipeline (`from_list`)

`from_list/1` is used at ingest time — startup load from disk, test
construction, anywhere a raw `List(Message)` crosses the boundary.
It runs the full repair sequence:

1. **Drop leading assistant** — invariant (4)
2. **Coalesce same-role runs** — invariant (3)
3. **Strip orphan tool_results** — invariant (2). Walk all messages,
   collect every assistant's tool_use IDs into a global set; filter
   user-message tool_results whose `tool_use_id` isn't in the set;
   drop messages emptied by the filter.
4. **Inject stub tool_results** — invariant (1). For each assistant
   tool_use whose immediately-following user message has no matching
   tool_result, prepend a synthetic
   `ToolResultContent(tool_use_id: ..., content: "[internal: tool
   call did not complete]", is_error: True)` to the next user message
   (or insert a fresh user message if no follower exists).

After `from_list/1` returns, every API invariant holds. Subsequent
`add/2` calls preserve them.

## 6. The Boundary the State Machine Doesn't Cover (Yet)

The chokepoint guards `state.messages` (the cognitive loop's
history). Specialist agents have their own per-process message stacks
inside the agent framework (`agent/framework.gleam`'s react loop).
Those stacks are still `List(Message)`.

When an agent's react loop dies mid-iteration with a `tool_use` in
its outgoing assistant message but no follow-up `tool_result` ever
delivered, and when the cog's outgoing message to that agent is in
turn a `tool_use` (e.g. `agent_coder`), the agent's failure can leak
back to the cog as an `AgentSuccess.tool_errors` flag without a
matching `tool_result` ever being appended to the cog's history. The
cog's `MessageHistory` doesn't know about the agent's internal stack
and can't fix what it can't see.

This is a real boundary — the cog↔agent message protocol — that needs
its own chokepoint. Future work: extend the agent framework's react
loop to use `MessageHistory` for its own stack, and harden the
`AgentComplete` handler in `cognitive/agents.gleam` to always emit a
matching `tool_result` for the agent dispatch's `tool_use`, even on
crash / timeout / cancel.

## 7. Send-Path Trims Still Apply

`for_send/1` returns a wire-ready `List(Message)`. The cog's
`build_request_with_model` (in `cognitive/llm.gleam`) then applies
*quantitative* trims that depend on runtime knobs:

- `context.trim/2` — message-count trim if `max_context_messages` is
  configured. Drops oldest messages while preserving tool_use /
  tool_result pairing.
- `context.trim_to_token_budget/2` — hard token cap (default 150k)
  to prevent API 400s from oversized requests.

Both trims preserve invariants — `context.trim` calls
`strip_orphaned_tool_results` and `ensure_alternation` after dropping
messages. So even if the trim accidentally cuts a tool_use ↔
tool_result pair, the cleanup catches it.

## 8. What This Replaces

Deleted in v0.10.0 alongside the new module:

- `src/llm/message_repair.gleam` — its `find_orphans` + `repair`
  functions are now intrinsic to `MessageHistory.from_list`
- `repair_orphans_and_warn/2` in `cognitive/llm.gleam` — the reactive
  boundary sweep. There's nothing left for it to repair.
- ~30 direct `list.append(state.messages, [...])` callsites — all
  rewritten through `add` / `add_user` / `add_assistant` /
  `add_user_text`.

Tests: `test/llm/message_history_test.gleam` covers each invariant
with the exact malformations that caused production bugs in v0.9.

## 9. Source Files

```
src/llm/
└── message_history.gleam   # opaque type, add chokepoint, sanitisation

src/agent/
├── cognitive_state.gleam   # state.messages: MessageHistory
├── cognitive.gleam         # state construction, GetMessages export
├── cognitive/llm.gleam     # build_request, send-path trims
├── cognitive/agents.gleam  # AgentComplete handlers, dispatch flow
└── cognitive/safety.gleam  # output gate MODIFY paths

test/llm/
└── message_history_test.gleam  # 16 invariant tests
```

## 10. Pattern: When to Apply This Elsewhere

The state-machine pattern fits any subsystem where:

- a public mutable structure has invariants the type doesn't enforce
- many handlers append to it
- the bug class is "API rejected the structure because something
  earlier left it malformed"
- a reactive boundary sweep is the current defence

The chokepoint is the smallest unit of code that owns the invariant.
Every other appender goes through it. The reactive sweep becomes
redundant — there's nothing for it to repair. Same pattern was
applied to the WebSocket outbox in v0.10.0; see
[interfaces.md](interfaces.md) §6.
