# Cold-Start Onboarding — Fresh Agents Need Less Friction and More Discoverability

**Status**: Planned
**Priority**: High — observed in production. New Curragh instances fumble for hours, and on day one the friction is bad enough to *cause* integrity failures (fabricated coverage, conflated retrievals).
**Effort**: Medium (~150-200 LOC + tests across three small fixes)
**Source**: 2026-04-25 transcript of a fresh instance booting and being asked to read its own skills.

## The Symptom

A fresh agent boots, has 20 skills listed in `<available_skills>`, has a
`how_to` tool with broad guidance, and a sensorium that names which
skill applies to which action class. But the agent has *not read* any
of them. Asked to "go through them and see what's interesting," the
agent:

1. Tries the researcher's `read_skill` tool via delegation. Some files
   work; others fail (path issues, sandbox isolation).
2. Falls back to `fetch_url` and similar to retrieve skill content
   another way. Mixes results.
3. Reports detailed knowledge of skills it has *not actually read in
   this cycle*, conflating prior retrieval methods with current ones.
4. The Archivist catches the divergence post-cycle (good), tags it
   `hallucination` and `unsupported-claims`. The agent now has a CBR
   case marking its own first hour as a failure mode.

Separately, in the same session: the operator uploads a PDF. The
deposit succeeds (PR 12), the synchronous intake.process fails to
normalise it ("unsupported extension or converter missing"). The
agent has *no way to discover* that a file landed — no tool, no
sensorium signal, no notification. Operator says "look in your
intray." Agent searches every channel it knows and reports the
library empty. Bug found by absence.

This is not a "the agent will get better with use" problem alone.
It is a *day-one-actively-dangerous* problem. The fabrication-on-day-
one is downstream of fumbling that's downstream of discoverability.

## Root Causes (Verified Against Code)

### 1. `read_skill` is not on the cognitive loop

In `src/tools/builtin.gleam:28`:

```gleam
pub fn all() -> List(Tool) {
  [calculator_tool(), datetime_tool(), human_input_tool(), read_skill_tool()]
}
```

`read_skill` is in the builtin module's tool list. But in
`src/agent/cognitive.gleam:86-95`:

```gleam
let tools =
  list.flatten([
    [builtin.human_input_tool()],   // ← only this from builtin
    memory.all(),
    planner_tools.all(),
    ...
  ])
```

The cognitive loop pulls *only* `human_input_tool` from builtin. So
the cog loop — which is the agent that *owns* the skills as procedures
— literally cannot read them. It has to delegate to a specialist
agent whose executor includes `builtin.execute(call, skills_dirs)`.

The skills are the cog loop's playbook. Routing reads through a
sub-agent is backwards, introduces extra failure modes (researcher's
own `read_skill` has its own bugs; coder's sandbox can't see host
files), and is exactly the friction the transcript hit.

### 2. No cog-loop dispatch path for `read_skill`

Even if `read_skill_tool()` were added to the tool list at line 87,
the cog loop's dispatch in `src/agent/cognitive/agents.gleam` doesn't
route `read_skill`. The current pattern is:

```gleam
case memory.is_memory_tool(call.name) { True -> ...
case planner_tools.is_planner_tool(call.name) { True -> ...
case strategy_tools.is_strategy_tool(call.name) { True -> ...
```

No branch for builtin tools beyond what's already wired. Adding the
tool to the LLM's affordance without wiring the executor would make
calls fail.

### 3. The intray has no agent-side discovery surface

The PR 12 server-side message ("Deposited X. No files normalised…")
is shown to the *operator* in the chat UI. The agent never sees it.
After upload, there is:

- No `list_intray` tool on the cog loop.
- No sensorium block listing pending intray contents.
- No `recall_recent`-style query that would surface deposits.
- No `QueuedSensoryEvent` emitted on deposit.

So even if unpdf were installed and normalisation worked, the
agent wouldn't *know* a file is there until the operator explicitly
points at it. For a system positioned as an "Artificial Retainer"
that should notice things, this is a meaningful gap.

### 4. Normalisation failure is opaque

The PR 12 message "No files normalised (unsupported extension or
converter missing)" lumps two different problems into one string.
For a `.pdf` upload (extension *is* supported), the only realistic
cause is `unpdf` not on PATH. The operator can't act on the
generic message — they don't know whether to install unpdf,
re-encode the file, or stop trying.

## Fix Plan

Three targeted fixes plus a small ops/docs piece. Each lands
independently. None requires the others.

### Fix 1 — `read_skill` on the cognitive loop

**Effort**: ~10 LOC.

Add `builtin.read_skill_tool()` to the cog loop's tool list and add
a dispatch branch that calls `builtin.execute(call, skills_dirs)`
for it. The `skills_dirs` is already in scope (it's threaded through
agent specs after PR 15). The cog loop becomes self-sufficient for
reading its own playbook.

This alone fixes the transcript's central friction. Curragh would
have read each skill directly, in-cycle, with the actual evidence
in the tool log.

### Fix 2 — Bootstrap skill loading on first cycle of a fresh session

**Effort**: ~50-80 LOC.

When the cog loop starts a session with no narrative entries (or
narrative older than N days, configurable), prepend a one-shot
bootstrap to the first system prompt that *includes the inline
content* of 2–3 critical skills:

- `delegation-strategy` — governs the most-frequent agent decision
- `memory-management` — governs orientation tools (`recall_*`)
- `system-map` — names the territory

The agent doesn't need to *call* `read_skill` for these — they're
already in context. The agent should still call `read_skill` for
others as needed (the bootstrap is a starter set, not a full load).
Configurable via `[bootstrap] critical_skills = [...]` so operators
can tune the set per profile.

The "infancy" framing still applies — the agent will *develop*
better intuition with cycles. Bootstrap doesn't try to make day one
feel like day 30. It tries to make day one not actively dangerous.

### Fix 3 — Intray discovery (tool + sensorium)

**Effort**: ~80-120 LOC across three pieces.

**3a. `list_intray` cog-loop tool.** Returns
`[(filename, size_bytes, deposited_at, normalised: Bool, error: Option(String))]`
for each entry currently in `paths.knowledge_intray_dir()`. Read-only.

**3b. Sensorium block.** Add an `<intray pending="N" failed="N"/>`
section to the sensorium when there's anything there. The Curator
already builds the sensorium block per cycle; this is one more
section.

**3c. Optional: `QueuedSensoryEvent` on deposit.** When `intake.deposit`
succeeds and a Librarian is wired, emit a sensory event so the next
cycle's sensorium picks it up explicitly rather than waiting for the
agent to look. Would also surface to the TUI/web GUI's notification
stream.

After this, an operator uploading a file leaves an unambiguous
breadcrumb: the agent's next cycle starts with "1 file pending in
intray (Services_…pdf, 4.6 MB, deposit failed: unpdf not found)."
The agent can act, ask, or escalate from there.

### Fix 4 — Make the normalisation error specific

**Effort**: ~10 LOC + operator-manual paragraph.

Distinguish `UnsupportedExtension` from `BinaryMissing` in the message
returned by `intake.process`. The `converter.gleam` Error variants
already exist (`BinaryMissing(binary:)`, `UnsupportedExtension(extension:)`,
`ConversionFailed(reason:)`). The summary in `intake.process` collapses
them. Keep them distinct in the operator-facing message so they can
act:

- `BinaryMissing("unpdf")` → "Cannot convert .pdf — unpdf binary
  not found. Install from https://github.com/iyulab/unpdf/releases
  and re-trigger intake."
- `UnsupportedExtension(".xyz")` → "Cannot convert .xyz — extension
  not in our supported set. Convert to markdown / PDF / docx / epub
  / HTML before uploading."

`docs/operators-manual.md` should also call out unpdf as required
in the install section (it currently mentions it but lower in the
doc). And the deployed Curragh probably needs the unpdf binary
(separate ops issue, but worth flagging as part of shipping this).

## Where to Hold Off

The infancy framing is genuinely useful. Some friction in the first
few sessions is *fine* — the agent develops working memory, accumulates
CBR cases, builds threads. Don't:

- **Auto-load all 20 skills.** That's 50+ KB of context every cycle
  forever; defeats the point of skills being on-demand reference.
- **Pre-fill synthetic memory.** A fresh agent should genuinely have
  a fresh narrative; faking it would mislead its own reflection.
- **Add a "first flight checklist" the agent must walk through.**
  The persona already says the agent calls `recall_recent` on first
  message; that's enough. More structure would teach the agent to
  perform onboarding rather than orient itself.

The fixes above are about *removing footguns*, not *adding training
wheels*. The infancy phase still happens; it just isn't dangerous on
day one.

## Triggers to Revisit

- A new operator deployment hits a similar fabrication-on-day-one
  failure (would need to be tracked as a concrete category, not just
  CBR-tagged).
- The bootstrap skill set in Fix 2 needs frequent retuning (suggests
  the wrong skills are loaded at boot, or the boundary between
  "always present" and "on-demand" is wrong).
- Operator support questions cluster around "I uploaded a file and
  the agent can't see it" (Fix 3 didn't go far enough; consider a
  more proactive notification path).

## Suggested Implementation Order

One PR, three commits, in this order:

1. **Fix 1 + Fix 4 together.** Both small, both touch tool-side code,
   both unblock the immediate friction (agent can read its own
   skills; operator gets actionable upload errors). Ships fastest;
   highest ratio of UX value to LOC.
2. **Fix 3 (intray discovery).** Tool + sensorium. New cog-loop
   tool, new sensorium section, optional sensory event. Independent
   of Fix 2 — a useful surface even without bootstrap loading.
3. **Fix 2 (bootstrap).** Last because it's the most opinionated —
   "which skills are critical" is a judgement call. After Fixes 1
   and 3 land, the day-one dangerous behaviour is mostly gone; Fix 2
   is the polish that makes day one *productive* rather than just
   *safe*.

Tests:

- Cog-loop tool dispatch: `read_skill` returns content for a
  legitimate skill, errors with the canonical containment message
  otherwise. (Reuses PR 15's `is_safe_skill_path` discipline.)
- Bootstrap: fresh session (empty narrative dir) gets the configured
  skills inlined; non-fresh session does not.
- `list_intray` returns the right shape; sensorium renders correct
  counts; deposit fires `QueuedSensoryEvent` when a librarian is
  wired.
- Distinct error messages for `BinaryMissing` vs `UnsupportedExtension`
  surface to the operator chat.
