# Integration Testing — Scenario Runner over `--diagnostic`

**Status**: Phase 1 shipped 2026-04-23 (#118). Scope reduced to one reference
scenario; rationale in *Phase 1 — what shipped* below. Phase 2 is ongoing
policy. Phase 3 remains deferred.
**Priority**: Medium — catches a class of bug unit tests structurally can't
**Effort**: Phase 1 ~600 LOC Gleam (runner + parser + tests). Phase 2 grows
with scenarios. Phase 3 (live-LLM) deferred indefinitely.

## Problem

Springdrift's test suite runs ~1815 unit tests, mostly covering pure
logic — decoders, config builders, string rendering, math. This is
valuable and stays. The gap is that the last ten PRs shipped three
bugs that unit tests structurally cannot catch:

1. **Dead `reply_to` channel (#113).** `CognitiveReply` messages were
   being delivered to WebSocket actor mailboxes that had no clause for
   that type. The evidence was `Actor discarding unexpected message`
   warnings in stderr across every user cycle — visible only in a
   running instance, never in unit tests.
2. **Researcher context-trim stubs (#110).** The researcher was
   returning "comprehensive coverage" summaries without substantive
   content because 100KB+ of tool results fell out of its 30-message
   sliding window before the synthesis turn. Visible only under real
   network-fetch payloads; unit tests of the auto-store threshold were
   trivially correct.
3. **Meta-learning scheduler pollution (#107).** Fresh Nemo booted with
   14 legacy `meta_learning_*` entries in its scheduler. Visible only
   by watching sensorium `<schedule>` on boot; unit tests of
   `build_tasks` saw nothing.

All three are *interaction-boundary* bugs — message flow, sliding-window
effects, startup reconciliation — and all three were found by running
the system and watching it, not by unit tests.

The existing `scripts/fresh-instance.sh --diagnostic` (from PR #112) is
already a proto-integration-test: it boots a fresh instance, probes
`/health` + `/diagnostic`, asserts `status == "ok"`, tears down. Extend
this pattern into a scenario runner and we have an integration-test
harness for ~300 LOC.

## Non-goals

Explicitly **not** trying to build:

- **Cross-instance testing.** Not the deployment shape — one operator,
  one instance.
- **Load testing.** Small-scale ethos.
- **LLM quality benchmarks.** Separate concern, different tooling. The
  existing `evals/` directory is the right home for those.
- **Golden-output regression testing.** LLM outputs aren't deterministic
  enough for hash-matching to be useful.

## Proposed solution

### Four levels of test, not all worth building

| Level | What it tests | Cost | Built? |
|---|---|---|---|
| **L1 Actor integration** | One actor + fake dependencies, send messages, assert replies | ms | Informally present in `test/agent/cognitive_test.gleam` |
| **L2 Subsystem integration** | Real cognitive loop + real agents + real librarian, exercise cross-subsystem flow | seconds | Partial — gaps around scheduler, workers, Frontdoor delivery |
| **L3 Full-instance integration** | Boot whole binary, drive via HTTP/WebSocket, assert on endpoints + filesystem | ~10s | `--diagnostic` is a one-shot version; no scenario runner |
| **L4 Live-LLM behavioural** | Real provider, real prompts, assert on agent behaviour | minutes, $$, flaky | Deliberately not built |

**L1 and L2 should grow organically** as developers write them alongside features. No new infrastructure needed — Gleam tests already spin up real processes.

**L3 is the target** for this design. It catches the bugs that shipped.

**L4 is deferred indefinitely.** If L1-L3 prove insufficient after six months of use, revisit.

### Harness = in-process Gleam runner

```bash
gleam run -- --scenario test/scenarios/reply-to-noise.toml
```

The runner (`src/scenario/`) boots a minimal cognitive + Frontdoor
harness in the same VM, drives the scripted steps against it, then
evaluates the assertions against the resulting log / narrative state.

1. Parse the TOML scenario file.
2. Boot `cognitive_config.default_test_config` with a mock provider.
3. For each step: send the message, wait for the reply on a Frontdoor
   sink keyed by `source_id`, or sleep for a fixed duration.
4. Evaluate assertions against the instance's slog output and narrative
   JSONL.
5. Exit 0 on all-pass, 1 on any-fail, 2 on parse/setup failure.

Open question #1 (TOML parser choice) resolved in favour of writing the
runner in Gleam — the `tom` dependency is already present, and keeping
the runner in-VM removes subprocess fragility. The original bash-plus-
`curl`-plus-`jq` sketch was dropped before implementation.

### Scenario format

TOML, readable by operator, not just developer. One scenario = one file.

```toml
# test/scenarios/reply-to-noise.toml

[scenario]
name = "reply_to noise regression"
description = "Verify no Actor discarding unexpected message warnings on first cycles"
owner = "operator"
catches_regression_of = ["PR-113"]

# Each step runs in order. Steps are either `send` (drive the instance)
# or `wait` (allow background work to settle).

[[step]]
type = "send_user_input"
source_id = "scenario:test"
text = "Hello, what can you do?"

[[step]]
type = "wait"
for = "reply_received"
timeout_ms = 30000

[[step]]
type = "send_user_input"
source_id = "scenario:test"
text = "What's the current time?"

[[step]]
type = "wait"
for = "reply_received"
timeout_ms = 30000

# Assertions run after all steps complete.

[[assert]]
type = "stderr_absent"
pattern = "Actor discarding unexpected message"
message = "reply_to channel was delivering to the wrong mailbox"

[[assert]]
type = "stderr_absent"
pattern = "FORMAT ERROR"
message = "Erlang logger format error — implies unhandled message type"

[[assert]]
type = "diagnostic_field"
path = "cognitive.responsive"
equals = true
```

Step types shipped in Phase 1:
- `send_user_input` — send a `UserInput` message to the cognitive loop
  with a given `source_id`
- `wait_for_reply` — block until a `DeliverReply` arrives on the
  Frontdoor sink for the scenario's `source_id`, or the timeout expires
- `wait_duration` — fixed-duration sleep, for scenarios that need
  background work (scheduler ticks, archivist completion) to settle

Dropped before implementation — built only when a scenario needs them:
- `seed_file` (would need pre-boot file writes into `.springdrift/`)
- `send_scheduler_job` (would need scheduler subject threaded into the
  harness)

Assertion types shipped in Phase 1:
- `log_absent` / `log_present` — substring over the instance's slog
  output
- `narrative_entry_count` — count entries written this run; passes when
  the count is in `[min, max]` inclusive

Dropped before implementation — built only when a scenario needs them:
- `diagnostic_field` (would need the web server running)
- `file_exists` / `file_absent`
- `jsonl_contains` (structured query into memory JSONL)

### Mock LLM by default

Integration tests assert on *message flow* and *state transitions*, not
on LLM output quality. Use the mock provider by default:

```bash
scripts/fresh-instance.sh --provider mock --scenario ...
```

Determinism matters more than realism. A scenario asserting "three
user inputs produce three narrative entries" doesn't need a real LLM —
the mock returns a canned text response, the Archivist still runs, the
narrative log still fills. The bugs we're catching (message routing,
persistence, startup state) don't depend on LLM content.

Where LLM behaviour *does* matter — does the researcher cite sources?
does the agent use `introspect` when asked what it can do? — those are
L4 concerns, deferred.

## Example scenarios

### `reply-to-noise.toml` — shipped

Boot fresh, send a user input, wait for reply, assert slog has no
`Actor discarding unexpected message` patterns. Catches regression of
#113.

### `meta-learning-pollution.toml` — dropped from Phase 1

Would seed a pre-boot scheduler JSONL with legacy `meta_learning_*`
entries, boot, and assert the sweep log line fires and the entries are
gone. Dropped because seeding a valid `ScheduledJob` JSONL requires
either a `seed_file` step (plus boot-order partitioning in the runner
so seeds land before the harness starts the scheduler) or a Gleam-side
helper that constructs records via `schedule_log.append`. The sweep
itself is a five-line filter in `scheduler/runner.gleam`; the
infrastructure cost to integration-test it didn't match the value.
Revisit if a future scenario needs pre-boot seeding anyway.

### `researcher-auto-store-smoke.toml` — dropped from Phase 1

Would configure the mock provider to return a 30KB payload for a
`jina_reader` call and assert the artifact store picks it up. Dropped
because the mock provider returns text, not tool-result bodies — the
auto-store interception sits on the real HTTP tool executor, so
integration-testing it needs an HTTP mocking layer (a stub `httpc` or
a test-only jina adapter). Neither exists yet. Out of scope for Phase 1.

## Phasing

### Phase 1 — what shipped (#118)

1. Gleam scenario runner in `src/scenario/` (types, parser, runner).
2. `--scenario <path>` flag on `gleam run`.
3. Three step types: `send_user_input`, `wait_for_reply`,
   `wait_duration`.
4. Three assertion types: `log_absent`, `log_present`,
   `narrative_entry_count`.
5. One reference scenario: `test/scenarios/reply-to-noise.toml`
   (catches regression of #113).
6. A deliberately-failing `test/scenarios/_selftest.toml` to verify the
   runner reports failure when it should.
7. Parser unit tests (`test/scenario/parser_test.gleam`, 13 tests).
8. Format documentation in `test/scenarios/README.md`.

Scope reduction vs the original proposal: two of the three reference
scenarios (`meta-learning-pollution`, `researcher-auto-store-smoke`)
were dropped — rationale in *Example scenarios* above. `seed_file`,
`send_scheduler_job`, and five assertion types were not built; they
cost more than the Phase 1 payoff warranted. Each is small enough to
add when a future scenario actually needs it.

No CI hook yet. Scenarios are run manually against local checkouts.
Wiring into a build step is Phase 2 once there are several scenarios
worth running on every PR.

**Acceptance**: `reply-to-noise.toml` passes against current main;
`_selftest.toml` fails as expected.

### Phase 2 — expand as bugs ship (no committed LOC)

Every time a user-visible bug escapes to a running instance, the PR
that fixes it also adds a scenario that would have caught it. Phase 2
is not a planned expansion — it's a policy.

Good scenario candidates visible now:
- Deputy briefing → ask_deputy → hierarchy cleanup
- Meta-learning worker ticks and writes an output file
- D' gate reject → retry path
- Frontdoor source_id isolation (two sinks, one source doesn't leak to the other)

Queued from doc-library completion (2026-04-25) — both pinned to bugs
already fixed, both within the current single-instance scenario
runner's shape. Add as a focused PR after PRs 7-8 of doc-library
land:

- **`writer-truncation-warning.toml`** — operator asks writer for a
  long report; writer hits `max_tokens`; `AgentSuccess.truncated`
  flips True; cognitive surfaces the WARNING block on the next
  turn. Catches the Nemo "agent lying" pattern (Phase 0 of
  agent-comms-plumbing). Asserts `log_present` for the truncation
  WARNING and `log_absent` for any "Empty response" line.
- **`writer-revise-preserves-content.toml`** — operator asks for a
  draft; second cycle asks for revision via `draft_slug`; draft
  on disk retains unchanged sections. Catches the "writer
  overwrites with create_draft instead of update_draft" failure
  PR 4 fixed. Asserts file-presence + content-substring on the
  drafts dir after the second cycle settles.

Not queued (would need scenario runner extensions or external mock
infra):

- Approval flow (promote → search-empty → approve → search-returns)
  needs multi-cycle operator drive — the runner currently models
  one operator turn cleanly, multi-turn approval needs a `wait_for`
  step that listens for an agent reply before injecting the next
  user input.
- Email attachment scenario needs a mock AgentMail HTTP layer.
- Tier 3 reasoning scenario needs a scripted LLM that returns
  specific tool-call shapes; the mock provider's
  `provider_with_handler` could do it but the wiring through the
  knowledge tools' `reason_fn` field needs threading.

### Phase 3 — live-LLM tier (deferred indefinitely)

If Phase 1-2 prove insufficient, add a `--live-llm` flag that uses the
real provider. These scenarios:
- Run nightly, not per-PR
- Cost real money per run
- Tolerate flakiness (retry-on-flake, report on sustained failure)
- Assert on behaviour patterns, not exact text

Don't build Phase 3 until at least three bugs have shipped that
only a real LLM would catch, *and* the budget for running it makes
sense. The Nemo catalog-response thing (#116 patch) is close to that
category but was caught by operator observation instead.

## Invariants this preserves

- **Existing unit tests stay.** No migration, no replacement. They're
  fast, cheap, and catch pure-logic regressions.
- **The cognitive loop stays testable.** `test/agent/cognitive_test.gleam`
  already does L1-style integration. Scenarios complement, don't
  replace.
- **Auditability.** Scenario runs write to `$FRESH_ROOT/scenario.log`;
  failed runs preserve the whole `.springdrift/` tree for forensic
  inspection.
- **Small-scale ethos.** No new services, no new dependencies beyond
  one TOML parser. Bash + curl + `jq` are already standard.

## Open questions

1. ~~**TOML parser choice.**~~ Resolved 2026-04-23: written in Gleam,
   using the existing `tom` dependency. Keeping the runner in-VM
   removed subprocess fragility entirely.
2. **Assertion language extensibility.** The MVP's assertion types
   cover the reference scenarios. Future scenarios may need queries
   into narrative/CBR/facts — at what point does the assertion language
   need its own grammar rather than growing ad-hoc?
3. **CI environment.** Local developer runs are easy; CI needs
   `gleam build` + scenario runs + teardown. GitHub Actions time-cost
   for scenario runs is ~10s each — fine for a handful, expensive at
   scale.
4. **Flaky-test quarantine.** Scenarios that involve timers or
   background workers can race. Need a convention for marking a
   scenario as "allowed to be flaky, report but don't fail CI" vs
   "must-pass gate."

## What this is not

- A replacement for `gleam test` — those tests stay, run on every
  PR, and cover the logic layer.
- An LLM quality harness — that's `evals/`, separate tooling.
- A performance benchmark — unrelated concern.
- A production monitoring tool — `/diagnostic` is that; scenarios run
  in CI and against fresh instances, not Curragh.

## Related

- PR #112 — `/diagnostic` endpoint and `--diagnostic` flag
- PR #107 — scheduler-log sweep (scenario candidate)
- PR #110 — researcher auto-store (scenario candidate)
- PR #113 — dead `reply_to` removal (scenario candidate)
- `test/agent/cognitive_test.gleam` — existing L1 tests
- `evals/` — separate LLM quality evaluation
