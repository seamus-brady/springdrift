# Level 1: Parallel Agent Dispatch

**Status**: Implemented (2026-04-01)
**Date**: 2026-03-26
**Dependencies**: None
**Effort**: Small (~100 lines)

---

## Current State

The cognitive loop dispatches agents sequentially — send one `StartChild`, wait for `AgentComplete`, then dispatch the next. The `active_delegations` Dict already tracks multiple concurrent delegations, but the dispatch logic sends them one at a time.

## Proposed Change

When the LLM requests multiple agent tool calls in the same response (e.g. `agent_researcher` + `agent_coder`), dispatch them simultaneously if they have no data dependencies.

```gleam
pub type DispatchStrategy {
  Sequential    // Current behaviour — one at a time
  Parallel      // All independent agents at once
  Pipeline      // Output of one feeds input of next
}
```

## Dependency Detection

Two agent calls are independent if:
- Neither references the other's output
- They don't write to the same memory keys
- They don't use the same sandbox slot

The cognitive loop infers independence from the tool call arguments. Conservative default: if unclear, dispatch sequentially.

## Implementation

```
Current flow:
  LLM returns [agent_researcher, agent_coder]
  → dispatch researcher → wait → dispatch coder → wait → synthesise

Parallel flow:
  LLM returns [agent_researcher, agent_coder]
  → dispatch researcher AND coder simultaneously
  → wait for ALL AgentComplete messages
  → synthesise both results
```

Changes:
- `src/agent/cognitive/agents.gleam` — partition agent calls into independent groups, dispatch each group in parallel
- `src/agent/cognitive.gleam` — handle multiple simultaneous `AgentComplete` messages, synthesise when all in a group have completed
- Existing `active_delegations` Dict already supports multiple concurrent entries

## D' Integration

Each parallel agent's tool calls go through D' independently. One agent being blocked doesn't affect the other.
