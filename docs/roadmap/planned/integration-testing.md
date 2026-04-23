# Integration Testing — Scenario Runner over `--diagnostic`

**Status**: Planned (design 2026-04-23)
**Priority**: Medium — catches a class of bug unit tests structurally can't
**Effort**: Phase 1 ~300 LOC. Phase 2 grows with scenarios. Phase 3 (live-LLM) deferred indefinitely.

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

### Harness = extend `scripts/fresh-instance.sh`

```bash
scripts/fresh-instance.sh --scenario test/scenarios/reply-to-noise.toml
```

The flag implies `--web --diagnostic`. It:

1. Boots the instance in a dedicated process group (reusing the existing
   cleanup trap from `--diagnostic`).
2. Waits for `/health` to respond.
3. Parses the scenario file.
4. Executes the scripted steps.
5. Runs the declared assertions.
6. Tears down via PGID kill.
7. Exits 0 on all-pass, 1 on any-fail.

No new Gleam code required for the MVP — the runner is a bash script
orchestrating `curl` + `jq` + log-pattern checks. Keeps the harness
language-independent and scriptable by the operator.

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

Step types (MVP):
- `send_user_input` — POST to the WebSocket as a scripted user message
- `send_scheduler_job` — enqueue a scheduler job to fire immediately
- `seed_file` — write a file into `.springdrift/` before boot (e.g., a
  polluted scheduler log for migration tests)
- `wait` — allow the instance to settle, with a timeout

Assertion types (MVP):
- `stderr_absent` / `stderr_present` — regex over the log file
- `diagnostic_field` — JSONPath into `/diagnostic` response
- `file_exists` / `file_absent` — relative to `.springdrift/`
- `jsonl_contains` — at least one record in a given JSONL matches a
  predicate (e.g., "artifacts log has an entry with `tool: jina_reader`")
- `narrative_entry_count` — shape-level assertion on narrative output

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

Three reference scenarios to ship in Phase 1, each catching a
regression of a bug from this session:

### `reply-to-noise.toml`

Boot fresh, send two user inputs, assert stderr has no
`Actor discarding unexpected message` patterns. Catches regression of
#113.

### `meta-learning-pollution.toml`

Before boot, write a fake `.springdrift/memory/schedule/2026-04-20-schedule.jsonl`
with 5 `meta_learning_*` `JobAdded` events. Boot. Assert `/diagnostic`
reports `scheduler.legacy_meta_learning_entries == 0`. Assert log
contains `Swept 5 legacy meta_learning_* job(s)`. Catches regression
of the startup sweep in #107.

### `researcher-auto-store-smoke.toml`

Configure mock provider to return a 30KB payload in response to a
`jina_reader` tool call. Send user input triggering a research
delegation. Wait for reply. Assert `.springdrift/memory/artifacts/artifacts-*.jsonl`
has a new record with `tool: jina_reader` and `char_count > 8192`.
Catches regression of #110's auto-store interception.

## Phasing

### Phase 1 — MVP (~300 LOC bash + doc)

1. Extend `scripts/fresh-instance.sh` with `--scenario <file>` flag.
2. TOML scenario parser (probably a small Python or awk helper; bash
   TOML parsing is painful). Or: require `yq` as a dev dependency.
3. Implement the four step types and five assertion types listed above.
4. Ship the three reference scenarios.
5. Document the scenario format in `test/scenarios/README.md`.
6. CI hook: `gleam test && bash scripts/fresh-instance.sh --scenario
   test/scenarios/*.toml`.

**Acceptance**: the three reference scenarios pass against current
main. Running them against a PR that reverts #107, #110, or #113 causes
a relevant scenario to fail.

### Phase 2 — expand as bugs ship (no committed LOC)

Every time a user-visible bug escapes to a running instance, the PR
that fixes it also adds a scenario that would have caught it. Phase 2
is not a planned expansion — it's a policy.

Good scenario candidates visible now:
- Deputy briefing → ask_deputy → hierarchy cleanup
- Meta-learning worker ticks and writes an output file
- D' gate reject → retry path
- Frontdoor source_id isolation (two sinks, one source doesn't leak to the other)

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

1. **TOML parser choice.** `yq` is well-known but adds a dev dependency.
   A small Python helper would work on any Mac/Linux. Gleam has `tom`
   already — worth writing the runner *in* Gleam and using the existing
   parser? That adds ~500 LOC but removes the shell-parsing fragility.
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
