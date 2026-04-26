# Cog-Loop Truncation Guard — Don't Ship Half-Sentences as Replies

**Status**: Planned
**Priority**: High — observed in production. The cog loop currently delivers truncated mid-sentence replies as if they were successful outcomes, leaving the operator with no signal that anything went wrong and no actionable recovery path.
**Effort**: Small (~80-120 LOC + tests)
**Source**: 2026-04-26 incident — operator asked for a comparative analysis of two long documents, the writer hit `max_tokens=4096` twice, the orchestrator decided to write directly and hit its own `max_tokens=2048` mid-sentence, and the cycle terminated cleanly with `## Springdrift × The Synthetic` as the visible reply.

## The Symptom

The operator uploaded `The_Synthetic_Mind.pdf` (≈9000 lines) and asked
for a comparative analysis against Springdrift. The agent worked the
right way:

1. Researcher delegations walked the document via the new
   `document_info` → `list_sections` → `read_section_by_id` flow.
2. Material came back to the orchestrator.
3. Orchestrator delegated to the writer for synthesis.
4. Writer hit `max_tokens=4096` mid-write. Draft never saved.
5. Orchestrator retried with another writer delegation. Same result.
6. Orchestrator decided to write the analysis itself. Hit its own
   `max_tokens=2048` mid-sentence with `stop_reason=max_tokens` and
   no tool calls.
7. The cog loop's `handle_think_complete` "no tool calls" branch
   accepted the truncated text as the cycle's final reply, ran the
   archivist, and went `Idle`.

What the operator sees in chat: a paragraph that ends mid-sentence on
"`## Springdrift × The Synthetic`" with no explanation, no retry, no
"I ran out of room" message, and no follow-up activity in the
delegations feed. To the operator the agent looks frozen; in fact it
is `Idle` waiting for the next input.

The slog logged a warning at the truncation point —

> "Response was length-capped at max_tokens with no tool calls — output may be truncated or a tool_use block may have been sliced off"

— but operators don't read the slog in real time, and the warning
doesn't change the cycle's behaviour. The cycle still ships the
half-sentence as if it were a deliverable.

## Why It Happens (Verified Against Code)

In `src/agent/cognitive.gleam:handle_think_complete` (≈line 1117),
the "no tool calls" branch handles the cycle-terminal text response.
The relevant fragment:

```gleam
case response.needs_tool_execution(resp) {
  False -> {
    // Final text response
    let raw_text = response.text(resp)
    case raw_text == "" && !empty_retried {
      True -> /* retry once on empty */
      False -> {
        case resp.stop_reason == Some(llm_types.MaxTokens) {
          True ->
            slog.warn(...,
              "Response was length-capped at max_tokens with no tool calls — output may be truncated or a tool_use block may have been sliced off",
              ...)
          False -> Nil
        }
        // ... ship raw_text as the reply, run archivist, go Idle
      }
    }
  }
}
```

The `MaxTokens` stop reason is *logged* but not *acted on*. There's no
retry, no replacement reply, no scope-down prompt. The truncated text
flows through `check_deterministic_only` (interactive cycles) or
`spawn_output_gate` (autonomous), and out to the operator.

There's already a precedent for "retry once on empty response" right
above this branch — same pattern, different trigger. We're missing
the equivalent for the truncated-output trigger.

## Fix Plan

A single new behavioural branch in `handle_think_complete`, plus a
deterministic admission helper for the case where retry fails.

### Step 1 — Truncation detection

Promote `stop_reason == MaxTokens && no_tool_calls` from a passive
warning to a control-flow signal. Treat it identically to the
existing empty-response-retry path:

- On first hit in a cycle, retry once with a system addendum.
- On second hit (or first hit if `truncation_retried` is already
  true), fall through to the deterministic admission path.

Track this with a new `truncation_retried: Bool` field on
`PendingThink` alongside the existing `empty_retried: Bool`. Both
fields prevent infinite loops on the same failure.

### Step 2 — Retry with scope-down nudge

When a truncation retry fires, prepend a system message to the
existing message history before re-spawning the worker:

```text
Your previous response was cut off at the token cap (output_tokens:
N, limit: M). Two recovery options:

1. Decompose into multiple turns. Use a tool call (delegate to writer
   with `update_draft` per section, or break the work across cycles)
   instead of producing the full output in one response.

2. Tighten scope. Produce a substantially shorter version that fits
   within the cap, calling out explicitly what you would have included
   if more room were available.

Do NOT produce the same output again expecting a different result.
```

This is the same pattern as the empty-response retry's nudge — a
short corrective message inserted into history, followed by a fresh
think.

### Step 3 — Deterministic admission on second failure

If the retry also returns `stop_reason=MaxTokens` (or any subsequent
recovery fails), the cog loop must NOT ship the truncated text.
Instead, replace the reply entirely with a deterministic admission
written by the cog loop itself, not by the LLM:

```text
[truncation_guard] Your last request hit my output budget twice in
this cycle. I have research material in narrative memory but couldn't
fit the full synthesis into a reply.

Last attempt: <model> at output_tokens=<n>, limit=<m>.
Tools used this cycle: <comma-separated list>.

Suggested next steps:
  - Ask for a narrower scope (e.g. "just <subset>")
  - Raise max_tokens in .springdrift/config.toml ([agents.<name>])
  - Ask me to break the work into multiple replies
```

The `[truncation_guard]` prefix is operator-facing only; it tells
them why the reply differs from what the model produced. The
admission is fully deterministic — no LLM call needed — so it can't
itself be truncated.

### Step 4 — Wire the same path through the output gate

The output-gate handlers (`spawn_output_gate` for autonomous,
`check_deterministic_only` for interactive) are called *after* this
branch. The truncation guard runs *before* either of them, so:

- If retry succeeds with a clean response, the new response goes
  through the output gate normally.
- If admission fires, the deterministic admission text goes through
  the output gate. Deterministic rules will pass it (no banned
  patterns), so it ships.

No changes to the output gate itself.

### Step 5 — Telemetry

Log every truncation event to slog at `info` level (currently `warn`
without action — promote to `info` with action since it's now an
expected branch):

```
truncation_guard: cycle <id> max_tokens hit, retrying with scope-down nudge
truncation_guard: cycle <id> retry also hit max_tokens, shipping deterministic admission
```

Tag the cycle's DAG node so the Cycles admin tab can filter for
truncation events. Useful for tuning `max_tokens` config across runs.

## Tests

Five new tests in
`test/agent/cognitive_truncation_guard_test.gleam`:

1. **Single max_tokens triggers retry**: think_complete with
   `MaxTokens` and no tool calls advances `truncation_retried` to
   True and re-spawns the worker. Cycle does NOT yet send a reply.
2. **Successful retry ships clean reply**: after the truncation
   nudge, the LLM returns a normal response. Reply is the new
   response, not the truncated one. Operator sees the good text.
3. **Second max_tokens triggers admission**: when the retry also
   returns `MaxTokens`, the cog loop ships the deterministic
   admission, NOT the truncated text. The admission contains
   "[truncation_guard]" and references the limit and tools used.
4. **Empty response retry still works independently**: existing
   empty-response handling still fires for `stop_reason=end_turn`
   with empty text, regardless of `truncation_retried` state.
5. **Truncation with tool calls is NOT caught**: when
   `MaxTokens` happens alongside a tool_use block (the warning's
   "tool_use block may have been sliced off" case), the guard does
   NOT fire — the agent continues with the partial tool call. This
   is a separate failure class outside this PR's scope.

Plus an integration test that drives a real cog-loop cycle through a
mock provider configured to return `MaxTokens` twice in succession,
asserting the operator sees the admission and not the truncation.

## What's Out of Scope

This PR fixes one specific failure mode: `stop_reason=MaxTokens`
with no tool calls on the cog loop's own thinking. Three things it
does NOT address:

- **Sub-agent truncation** (writer hits its `max_tokens` mid-draft).
  The orchestrator sees the truncated tool result and decides what
  to do. This PR doesn't change sub-agent behaviour. A follow-up
  could add the same guard to the agent framework's react loop.

- **A cycle-stalled watchdog**. Considered and rejected for now —
  no current evidence of genuinely-stuck cycles, only of
  bad-outcome cycles. Polling-based liveness checks are not
  idiomatic OTP; the right fix if real stuck-cycle pathologies
  emerge is to audit every async boundary for monitor + deadline
  coverage, matching the existing `GateTimeout` pattern. See
  conversation log 2026-04-26 for the deliberation.

- **A cycle heartbeat to the WS**. Useful UX polish — periodic
  status pushes so the chat UI never looks frozen during long
  cycles — but orthogonal to this fix. Worth its own small PR
  later.

## Suggested Implementation Order

One PR, three commits:

1. **Add `truncation_retried` field to `PendingThink` and the
   detection branch in `handle_think_complete`.** Tests for
   detection + retry flow. No admission yet — first commit just
   enables the retry path.
2. **Add the deterministic admission path.** Tests for second-hit
   admission text. The admission helper lives in
   `src/agent/cognitive/output.gleam` next to `send_reply` since
   it's a deterministic reply-construction primitive.
3. **Telemetry + DAG tag.** Slog promotions, DAG node tagging so
   the admin Cycles tab can surface truncation events.

## Triggers to Revisit

- If sub-agent truncation becomes a recurring complaint, lift this
  pattern into `agent/framework.gleam` with the same retry +
  admission shape.
- If operators report cycles ending with admissions on tasks that
  *shouldn't* be near the budget, the configured caps are too low —
  investigate `max_tokens` tuning per agent rather than relying on
  the guard as a routine outcome.
- If we see admissions firing on the same task repeatedly across
  sessions, the agent isn't learning from the nudge and we may need
  a stronger decomposition prompt or a CBR case capturing
  "X-shaped tasks need decomposition."
