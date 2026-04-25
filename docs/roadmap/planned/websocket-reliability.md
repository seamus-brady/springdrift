# WebSocket Reliability — Stable Conversation Identity + Pending Buffer

**Status**: Planned
**Priority**: High — observed real loss of in-flight chat replies during
long-running operations and connection blips
**Effort**: Medium (~150-250 lines + tests)

## The Symptom

Chat queries occasionally vanish — the operator sees no reply, ever. Most
common during long-running operations (multi-agent delegation, large
research cycles), but also reproducible by tab-refresh-mid-cycle, network
hiccup, idle proxy timeout, or laptop sleep.

## Root Causes (Verified Against Current Code)

### 1. `source_id` is per-WebSocket, not per-conversation

In `src/web/gui.gleam:392`:

```gleam
let source_id = "ws:" <> generate_uuid()
```

A new UUID per connection means every refresh / reconnect produces a new
`source_id`. Cycles claimed by the *old* `source_id` cannot be routed to
the *new* connection.

### 2. `Unsubscribe` is unconditional

In `src/frontdoor.gleam:118-124`:

```gleam
Unsubscribe(source_id:) -> {
  case dict.get(state.destinations, source_id) {
    Ok(dest) -> process.send(dest.sink, DeliverClosed)
    Error(_) -> Nil
  }
  State(..state, destinations: dict.delete(state.destinations, source_id))
}
```

No check that the unsubscribing sink matches the registered sink. If a
late close from an old socket arrives after a new socket has subscribed
under the same `source_id` (which happens once we adopt stable IDs from
fix 1), the late close silently disconnects the new socket.

### 3. Replies with no destination are dropped

In `src/frontdoor.gleam:178-186`:

```gleam
case dict.get(state.destinations, source_id) {
  Error(_) -> {
    slog.debug("frontdoor", "route_output",
      "no destination registered for " <> source_id, Some(cycle_id))
    Nil
  }
  Ok(dest) -> deliver(state, dest, output)
}
```

When the cycle finishes and finds no destination (because the socket
disconnected during the long run), the reply is logged at debug level and
discarded. No buffering, no retry, no surfacing to the operator.

### 4. Conversation ownership is coupled to socket liveness

These three together produce the same fundamental error: the WebSocket
is treated as the *owner* of the conversation. It should be treated as
a *transport* — one of potentially many delivery sinks for a conversation
that outlives any individual connection.

## Fix Plan

Three fixes are needed for the symptom to stop. The fourth is the
conceptual cleanup that makes the first three coherent.

### Fix 1 — Stable `client_id`

Browser persists a UUID in `localStorage`:

```javascript
function getClientId() {
  var key = 'springdrift_client_id';
  var id = localStorage.getItem(key);
  if (!id) {
    id = crypto.randomUUID();
    localStorage.setItem(key, id);
  }
  return id;
}
ws = new WebSocket('/ws?client_id=' + clientId);
```

Server-side: derive `source_id` from the supplied `client_id` (with a
fallback for legacy clients that don't supply one):

```gleam
let source_id = case client_id {
  Some(id) -> "ws:" <> id
  None -> "ws:" <> generate_uuid()
}
```

A refresh, reconnect, or new tab from the same browser yields the same
`source_id`. Cycles routed to that `source_id` find their way home.

**Priority**: High — but only useful if Fix 2 lands too, otherwise late
unsubscribes from old sockets break the new ones.

### Fix 2 — Conditional `Unsubscribe` (Critical)

Change the message variant to carry the sink:

```gleam
Unsubscribe(source_id: SourceId, sink: Subject(Delivery))
```

Frontdoor only deletes when the registered sink matches:

```gleam
Unsubscribe(source_id:, sink:) -> {
  case dict.get(state.destinations, source_id) {
    Ok(dest) if dest.sink == sink -> {
      // Real close from the registered sink
      process.send(dest.sink, DeliverClosed)
      State(..state, destinations: dict.delete(state.destinations, source_id))
    }
    _ -> {
      // Stale unsubscribe from a previous sink — ignore
      slog.debug("frontdoor", "unsubscribe",
        "ignoring stale unsubscribe for " <> source_id, None)
      state
    }
  }
}
```

Caller passes the sink it owns:

```gleam
process.send(frontdoor, Unsubscribe(state.source_id, state.delivery_subject))
```

**Priority**: Critical — without this, Fix 1 actively makes things worse
because old sockets now share a `source_id` with new ones.

### Fix 3 — Buffer Undelivered Replies (Critical)

Extend Frontdoor `State`:

```gleam
type State {
  State(
    destinations: Dict(SourceId, Destination),
    cycle_owners: Dict(String, SourceId),
    pending: Dict(SourceId, List(Delivery)),  // new
    ...
  )
}
```

In `route_output`, replace the drop with a buffer write:

```gleam
case dict.get(state.destinations, source_id) {
  Error(_) -> {
    let delivery = output_to_delivery(output)
    let existing =
      dict.get(state.pending, source_id) |> result.unwrap([])
    State(..state, pending:
      dict.insert(state.pending, source_id, [delivery, ..existing]))
  }
  Ok(dest) -> {
    deliver(state, dest, output)
    state
  }
}
```

On `Subscribe`, flush any pending deliveries for that `source_id`:

```gleam
Subscribe(source_id:, kind:, sink:) -> {
  let state =
    State(..state, destinations:
      dict.insert(state.destinations, source_id, Destination(kind:, sink:)))
  case dict.get(state.pending, source_id) {
    Ok(deliveries) -> {
      list.reverse(deliveries) |> list.each(fn(d) { process.send(sink, d) })
      State(..state, pending: dict.delete(state.pending, source_id))
    }
    Error(_) -> state
  }
}
```

This is what makes long-running replies actually survive a disconnect.

**Priority**: Critical — even with stable IDs and conditional unsubscribe,
without buffering the reply still gets lost the moment the socket is gone
when the cycle finishes.

### Fix 4 — Decouple Conversation from WebSocket (conceptual cleanup)

The mental model the above fixes converge on:

```
conversation_id (stable, browser-persisted)
        │ owns
        ▼
    cycle_id
        │ routes via
        ▼
    source_id (stable client_id)
        │ delivered to
        ▼
   websocket sink (ephemeral, may not exist)
```

The websocket is just the *current* delivery transport, not the owner of
state. Replies are addressed to a `source_id`; if the socket exists, they
flow; if it doesn't, they buffer until one connects.

This isn't a separate code change — it's the principle the first three
fixes encode. Documenting it here so the next reader understands *why*
the three fixes exist as a coherent set.

## Optional Hardening

Not part of the minimum reliable fix. Worth adding once the core lands.

### Message acknowledgement

Client acks each delivery on receipt. Server retains buffered messages
until ack'd, so a delivery that gets a TCP-level success but is lost in
the browser (tab crash mid-render) can be redelivered on next subscribe.

### Pending buffer expiry

Without a TTL, a `source_id` whose browser is permanently gone (laptop
thrown in a lake) accumulates deliveries forever. Cap by either:

- TTL per delivery (~24h)
- Max queue depth per `source_id` (~50)
- Both

### Question correlation

When the agent emits a `request_human_input` mid-cycle, the
`question_id` is already part of the protocol. Make sure question
delivery and answer routing both use it explicitly so a reconnect
mid-question doesn't cross-thread answers between concurrent queries.

## Priority Summary

| Priority | Fix | Why |
|---|---|---|
| 🔴 Critical | Fix 2 — Conditional `Unsubscribe` | Without this, Fix 1 makes things worse |
| 🔴 Critical | Fix 3 — Pending buffer | Stops drops on socket disconnect mid-cycle |
| 🟠 High | Fix 1 — Stable `client_id` | Necessary for Fix 2/3 to identify the right buffer |
| 🟡 Medium | Question correlation | Avoids cross-threading on tab/reconnect |
| 🟡 Medium | Message ACKs | Catches the rare lost-after-deliver case |
| 🟡 Medium | Pending buffer expiry | Prevents unbounded growth from dead browsers |

## Suggested Implementation Order

One PR, three commits, in this order so each commit leaves the system
working:

1. **Fix 2 first** — conditional `Unsubscribe`. Standalone, no behaviour
   change with current per-socket UUIDs (always-fresh source_ids never
   match across closes anyway). Establishes the sink-equality discipline.
2. **Fix 3 second** — pending buffer. Standalone improvement: late
   replies on a still-disconnected socket now survive until next
   subscribe instead of vanishing.
3. **Fix 1 last** — stable `client_id`. Now safe to land because Fix 2
   prevents stale-unsubscribe footguns and Fix 3 handles the post-refresh
   buffering. End result: refreshes / reconnects / long runs all reliably
   deliver.

Tests:

- Frontdoor unit test: late `Unsubscribe` from non-matching sink is a no-op.
- Frontdoor unit test: reply with no registered destination lands in `pending`.
- Frontdoor unit test: subscribe drains `pending` for the matching `source_id`.
- Integration: simulate disconnect-mid-cycle, confirm reply delivers on reconnect.
