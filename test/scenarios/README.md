# Scenario-based integration tests

Scenarios are scripted integration tests that boot a minimal Springdrift
harness (cognitive loop + Frontdoor + mock provider), drive it with a
sequence of steps, and evaluate a set of assertions against the
resulting state.

Design spec: [`docs/roadmap/planned/integration-testing.md`](../../docs/roadmap/planned/integration-testing.md).

## Running

Single scenario:

```sh
gleam run -- --scenario test/scenarios/reply-to-noise.toml
```

Exit codes:

- `0` — all assertions passed
- `1` — one or more assertions failed
- `2` — scenario file could not be parsed or the harness could not boot

## TOML format

```toml
[scenario]
name = "..."                          # required
description = "..."                   # optional
catches_regression_of = ["PR-NNN"]    # optional, for audit

[[step]]
type = "send_user_input"
source_id = "scenario:<name>"
text = "..."

[[step]]
type = "wait_for_reply"
timeout_ms = 30000

[[assert]]
type = "log_absent"
pattern = "regex-free substring to search for"
message = "human-readable failure reason"
```

## Step types

| Type | Fields | Purpose |
|---|---|---|
| `send_user_input` | `source_id`, `text` | Send a `UserInput` message to the cognitive loop. The source_id claims a Frontdoor cycle so the reply routes back to the scenario's sink. |
| `wait_for_reply` | `timeout_ms` (default 30000) | Block until any scenario sink receives a `DeliverReply`, or the timeout expires. |
| `wait_duration` | `duration_ms` | Block for a fixed duration. Useful when the scenario needs background work (scheduler ticks, archivist) to settle. |

## Assertion types

| Type | Fields | Passes when |
|---|---|---|
| `log_absent` | `pattern`, `message?` | No line in `.springdrift/logs/YYYY-MM-DD.jsonl` contains the pattern as a substring. |
| `log_present` | `pattern`, `message?` | At least one line contains the pattern. |
| `narrative_entry_count` | `min`, `max?`, `message?` | Count of narrative entries written today is in `[min, max]` inclusive. No upper bound if `max` is omitted. |

## Harness behaviour

The runner boots a minimal harness, not the full instance:

- Real cognitive loop with `cognitive_config.default_test_config`
- Real Frontdoor (for reply routing)
- **Mock provider** (deterministic canned reply)
- No agents, sandbox, scheduler, web GUI, TUI

This is deliberate. Scenarios assert on message-flow and state-
transition behaviour, not LLM quality. Boot is milliseconds; teardown
is automatic when the VM exits.

If a future scenario needs the full subsystem set (agents, scheduler,
workers), the runner will need to be extended with a `[scenario]
boot_mode = "full"` option. Not needed yet.

## Writing a new scenario

Start from an existing scenario file. The minimum useful scenario is:

1. A `send_user_input` step
2. A `wait_for_reply` step
3. One or more assertions on the resulting state

## Selftest

`_selftest.toml` is a scenario that deliberately fails every assertion.
Run it to verify the runner actually fails scenarios that should fail,
rather than silently reporting success:

```sh
gleam run -- --scenario test/scenarios/_selftest.toml
# Expected: exit 1, both assertions reported failed
```

## What this catches

Scenarios catch interaction-boundary bugs that unit tests structurally
can't:

- **Message routing** — `CognitiveReply` landing in wrong mailbox (#113)
- **Startup state** — polluted scheduler log not swept (#107)
- **Behaviour under load** — researcher context-trim eating tool results (#110)

See the design spec for the full rationale and the four-level taxonomy
of integration testing.

## What this does NOT cover

- LLM quality benchmarks — that's `evals/`
- Load or performance testing — out of scope
- Cross-instance scenarios — not the deployment shape
