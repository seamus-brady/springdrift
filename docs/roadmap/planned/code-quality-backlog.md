# Code Quality Backlog — Quick Wins and Postponed Refactors

**Status**: Planned
**Priority**: Medium — none of this is blocking; it's the deferred half of a
2026-04-25 review that surfaced both small footguns and structural smells
**Source**: External code review (recommendations 1, 3–11; recommendation 2
on `run_cmd` was already shipped in PR #144)

## How to read this doc

- **Quick wins** are independent small PRs. Each ~half-day to one day. Do
  them in any order when there's slack between feature work. Each makes
  the codebase noticeably less fragile for low cost.
- **Postponed refactors** are real but expensive. They have explicit
  *triggers* — conditions that should make us revisit. Until a trigger
  fires, the cost outweighs the value.

The discipline: don't refactor on speculation. Refactor when something
forces it. Until then, ship features and let the postponed list age
honestly.

---

## Quick wins

Three independent PRs, each shippable in an afternoon. Suggested first is
PR A (smallest surface, pure cleanup).

### PR A — Mechanical fixes (~half day)

- **`pow2` cap in `retry.gleam`.** Replace the lookup table (which
  silently caps at 16 for n≥4) with `int.bitwise_shift_left` and a
  parametric cap, or document the coupling to `max_retries=3` so a
  future bump to 4+ doesn't silently under-backoff.
- **`stale_input_max_age_ms` configurable.** Currently hardcoded to 60s
  in `cognitive.gleam`. Lift to `AppConfig` + TOML key + default.
  Same pattern as every other tunable — direct violation of the
  "no magic numbers, no invisible settings" rule otherwise.
- **`rescue` FFI boundary docstring.** Module-level comment on
  `springdrift_ffi.erl` (or the appropriate worker module) explaining
  when expected errors return `Result` vs when unexpected panics are
  caught by `rescue` in spawned workers. Trivial; saves the next
  reader twenty minutes of head-scratching.

### PR B — Diagnostics pass (~one day)

- **Startup panic error context.** ~12 sites use
  `panic as "X startup failed"` and discard the underlying `Result`
  error. Audit each site; thread the error reason into the panic
  message (or `slog.log_error` immediately before the panic) so 3am
  ops debugging isn't guessing.
- **`slog` severity audit.** Some genuine errors are logged via
  `slog.warn` rather than `slog.log_error`. One sitting: read every
  call site, classify, fix mismatches. Standardize before ops
  dashboards start mattering.
- **Silent regex compile failures.** `re_replace_all` and
  `re_match_caseless` in the FFI silently swallow invalid patterns
  (return input unchanged or `False`). Intentional for D'
  deterministic rules (a typo'd pattern shouldn't crash the gate),
  but the FFI is general-purpose. Add a one-time `slog.warn` on
  compile failure; keep silent-fail-open at runtime.

### PR C — Performance (~one day)

- **Per-turn D' situation model cache.** TODO at `gate.gleam:392`
  flags that multi-tool-call turns rebuild the situation model (an
  LLM call) for every tool dispatch. Cache it in `DprimeState`,
  keyed by turn id, invalidated at turn end. Hot path on multi-tool
  turns.

---

## Postponed refactors

Each costs more than it pays off today. Each has an explicit trigger —
do not start without one.

### AppConfig sub-configs + startup orchestration extraction

**Couple these.** The two refactors share the same seams.

- *What*: break the flat ~213-field `AppConfig` record into
  domain sub-records (`DprimeConfig`, `CommsConfig`,
  `NarrativeConfig`, `SandboxConfig`, etc.). Many of these
  groupings already exist as runtime types but aren't used at
  the config-parsing level. Then extract the long `run` function
  in `springdrift.gleam` (lines 356–944) into a dedicated
  `startup.gleam` — the natural seams between sub-configs map
  onto the natural seams in startup wiring.

- *Why coupled*: doing them apart churns the same files twice.

- *Triggers to revisit*:
  - Adding a new agent spec needs threading 15+ args.
  - A config rename touches more than 6 files.
  - The flat record becomes physically hard to navigate
    (subjective; trust the discomfort).

- *Shape when ready*: 4–6 focused PRs over a sprint. One
  sub-config (and its startup wiring) per PR, each
  independently mergeable.

### Decompose `narrative/librarian.gleam`

- *What*: 2528 lines down to topic-sized modules. The
  `librarian/` subdir already exists with index modules — push
  query logic down into those sub-modules.

- *Why postponed*: the librarian is load-bearing for narrative,
  facts, CBR, artifacts, DAG, threading, housekeeping. A sloppy
  slice breaks five subsystems at once. Risk profile demands
  discipline.

- *Triggers to revisit*:
  - A librarian change causes a regression in an unrelated
    subsystem (the load-bearing nature actually bites).
  - A new query type needs adding and the file becomes
    physically hard to navigate.

- *Shape when ready*: slice by query type, one PR per slice —
  narrative queries first (most isolated), then facts, then CBR,
  then artifacts, then DAG. ~6 small PRs, each easy to verify
  against the existing test suite.

---

## Not in scope

- The `run_cmd` shell injection / timeout-kill / sandbox compounding
  finding (item 2 in the original review) — already shipped in
  PR #144.
- The web GUI auth fail-open finding — already shipped in PR #145.
- The `read_skill` containment finding — already shipped in PR #146.
- The `redact_secrets` test default + tool-gate timeout findings —
  already shipped in PR #147.
- The `write_anywhere` dead config — already removed in PR #148.

These five PRs (#144–#148) closed everything from the security review
proper. This doc covers only the structural / hygiene findings that
came alongside.
