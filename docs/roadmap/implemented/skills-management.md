# Skills Management — Specification

**Status**: Planned
**Date**: 2026-03-26 (original), 2026-04-17 (agent-led revisions folded in), 2026-04-18 (consolidated)
**Dependencies**: CBR self-improvement (implemented), Archivist split (implemented), Autonomous Endeavours (implemented), Remembrancer Phase 1-10 (implemented 2026-04-16)
**Unblocks**: Remembrancer Phase 11 (skills-proposal pipeline), Meta-Learning Phase B

---

## Table of Contents

- [Design Principle: Agent-Led, Operator-Audited](#design-principle-agent-led-operator-audited)
- [Overview](#overview)
- [Current State](#current-state)
- [Problems](#problems)
- [Architecture](#architecture)
  - [Skill Type](#skill-type)
  - [Persistence Layout](#persistence-layout)
- [Agent-Specific Skills](#agent-specific-skills)
- [Context Activation](#context-activation)
- [Usage Tracking](#usage-tracking)
- [Skill Lifecycle](#skill-lifecycle)
- [Skill Proposal Generation](#skill-proposal-generation)
  - [Pattern Detection Algorithm](#pattern-detection-algorithm)
  - [Conflict Detection](#conflict-detection)
- [Promotion Safety Gate](#promotion-safety-gate)
  - [Deterministic Pre-filter](#deterministic-pre-filter)
  - [D' Gate](#d-gate)
  - [Rate Limiting](#rate-limiting)
- [Skill Versioning](#skill-versioning)
- [Cost Tracking](#cost-tracking)
- [Operator Role: Standing Mandate](#operator-role-standing-mandate)
- [Web GUI: Audit Panel](#web-gui-audit-panel)
- [Tools](#tools)
- [Configuration](#configuration)
- [Test Strategy](#test-strategy)
- [Implementation Order](#implementation-order)
- [What This Enables](#what-this-enables)
- [Open Questions](#open-questions)

---

## Design Principle: Agent-Led, Operator-Audited

**The agent leads. The operator sets standing policy and audits outcomes.**

This is a first-principles decision, not a cost-cutting one. The operator's
continuous mandate is expressed through three upfront artifacts, not per-item
approval:

1. **`identity/character.json`** — the agent's highest endeavour and virtues.
   Governs what the agent will and will not incorporate into its skill set.
2. **`dprime.json`** — safety thresholds, deterministic rules, normative
   calculus configuration. Governs what passes the promotion gate.
3. **Rate-limit config** — the cap on how fast skills can evolve. Governs
   the pace of change.

Once those are set, the agent manages its own development within them. No
approval inbox. No "Draft → Reviewed" queue. D' review gates promotion; the
rate limit caps drift; append-only supersession makes every change
reversible. The operator reads consolidation reports to stay informed and
can revert any change by writing a supersession record.

This matches the "AI retainer" framing. A professional retainer works
within a clear remit, exercises judgment, reports back, gets
course-corrected if they drift — but isn't micro-managed. The approvals
happen once, via policy, not continuously via workflow.

---

## Overview

Skills are currently static instruction files (`SKILL.md` with YAML
frontmatter) discovered at startup and injected into the system prompt.
They work — but they don't learn, they don't adapt, they can't be scoped
to specific agents, and there's no way to measure how often they're used.

This spec elevates skills from static instructions to a managed,
agent-aware capability system that the agent itself extends through
Remembrancer-driven pattern mining.

---

## Current State

```
.springdrift/skills/
└── web-research/
    └── SKILL.md       # YAML frontmatter (name, description) + markdown body
```

- Discovered at startup by `skills.discover(dirs)`.
- Injected into every system prompt via `to_system_prompt_xml`.
- Available to the cognitive loop via `read_skill` tool.
- Same skills given to every agent (modulo the existing `agents:` filter).
- No usage tracking, no versioning, no proposal pipeline.

---

## Problems

1. **One size fits all.** The existing `agents:` filter helps but is
   coarse. Every cognitive cycle gets every cognitive-scoped skill
   regardless of context. Wastes context tokens, adds noise.
2. **No usage signal.** Operator and agent both fly blind on which
   skills are read versus dead weight.
3. **No learning.** When the agent discovers a better approach via
   experience (captured in CBR), that knowledge stays in CBR. It does
   not flow back into skills. The agent might have 50 cases showing
   `brave_answer` beats `web_search` for factual queries, but the
   skill still lists both equally.
4. **No versioning.** Editing a skill replaces it. No history, no diff,
   no rollback.
5. **No promotion gate.** Even if proposals existed, there is no safety
   pipeline to keep an auto-promoted skill from leaking credentials,
   contradicting the agent's character spec, or growing without bound.

---

## Architecture

### Skill Type

```gleam
pub type Skill {
  Skill(
    id: String,                    // Unique slug: "web-research"
    name: String,
    description: String,
    version: Int,                  // Incremented on each edit
    status: SkillStatus,
    body: String,                  // Markdown instruction content
    // ── Scoping ──
    agents: List(String),          // Which agents receive this skill
    contexts: List(String),        // When to activate (domain tags)
    // ── Cost ──
    token_cost_estimate: Int,      // Tokenised body length, computed at save
    // ── Provenance ──
    author: SkillAuthor,
    created_at: String,
    updated_at: String,
    derived_from: Option(String),  // CBR case ID(s) if auto-generated
  )
}

pub type SkillStatus {
  Active        // Injected into scoped agent prompts
  Archived      // Removed from discovery; retained in history for audit
}

pub type SkillAuthor {
  Operator
  Agent(agent_name: String, cycle_id: String)
  System
}
```

Two states only — `Active` and `Archived`. No `Draft`, `Experimental`, or
`Deprecated`. The agent-led model has no counterfactual A/B mechanism, so
no Experimental staging. No "Draft → Reviewed" queue, so no Draft.
Deprecation is just archival.

`SkillAuthor::Agent` carries `agent_name` (which agent produced the
proposal — typically `"remembrancer"`) and `cycle_id` (the originating
cycle for audit trail).

Usage and outcome correlations live in a separate metrics log, not on
the skill record (see [Persistence Layout](#persistence-layout)).

### Persistence Layout

```
.springdrift/skills/web-research/
├── SKILL.md                       # Operator-owned: markdown body
├── skill.toml                     # Operator-owned: id, name, description,
│                                  #   version, status, agents, contexts, author
├── skill.metrics.jsonl            # Manager-owned: append-only usage events
│                                  #   {timestamp, cycle_id, event: read|inject|outcome}
└── history/
    ├── v1.md + v1.toml            # Immutable snapshots of earlier versions
    ├── v2.md + v2.toml
    └── archive.jsonl              # Compacted older versions (see Versioning)
```

**Strict ownership split.** The skills manager never writes to
`skill.toml` (operator-editable config). The operator never writes to
`skill.metrics.jsonl` (manager-owned append-only log). Usage counts and
last-used timestamps are computed from the metrics log at read time
(Librarian cache).

```toml
# skill.toml — operator-editable config
id = "web-research"
name = "Web Research Patterns"
description = "Decision tree for tool selection during web research"
version = 3
status = "active"

[scoping]
agents = ["researcher", "cognitive"]
contexts = ["research", "web"]

[provenance]
author = "operator"
created_at = "2026-03-20T10:00:00Z"
updated_at = "2026-03-25T16:00:00Z"
```

```jsonl
# skill.metrics.jsonl — manager-only, append-only
{"timestamp":"2026-04-18T10:30:00Z","cycle_id":"abc123","event":"inject","agent":"researcher"}
{"timestamp":"2026-04-18T10:30:42Z","cycle_id":"abc123","event":"read","agent":"researcher"}
{"timestamp":"2026-04-18T10:31:15Z","cycle_id":"abc123","event":"outcome","outcome":"success"}
```

Backward compatible: skills without `skill.toml` continue to work via
existing frontmatter parsing. The new format is additive.

---

## Agent-Specific Skills

Skills declare which agents should receive them via the `agents` field.

### Semantics

| Value | Meaning |
|---|---|
| `["cognitive"]` | Injected only into the cognitive loop's system prompt |
| `["researcher", "writer"]` | Injected into these specialist agents only |
| `["all"]` | Shorthand for every registered specialist agent + the cognitive loop |
| `["all_specialists"]` | Every registered specialist agent, but NOT the cognitive loop |

Omitting `agents` in `skill.toml` defaults to `["cognitive"]` — conservative
choice that prevents accidental leakage into agents that didn't declare a
need for the skill.

### Implementation

`skills.discover` returns all skills. `skills.for_agent(all_skills, agent_name)`
filters by `agents`. The agent framework calls this when building each
agent's system prompt.

```gleam
pub fn for_agent(skills: List(Skill), agent_name: String) -> List(Skill) {
  list.filter(skills, fn(s) {
    list.contains(s.agents, agent_name)
    || list.contains(s.agents, "all")
    || { agent_name != "cognitive" && list.contains(s.agents, "all_specialists") }
  })
}
```

---

## Context Activation

Skills with `contexts` are only injected when the current cycle's domain
matches a context tag.

**Source of `query_domains` at injection time** (priority-ordered fallbacks):

1. Current thread's domain (if a thread is active).
2. `Intent.domain` from the Archivist's per-cycle XStructor output
   (cached by Librarian).
3. Top-domain from recent narrative entries (last 3 cycles).
4. `"general"` as final fallback.

Query complexity (Simple/Complex) is **not** a domain signal — it's a
routing signal for model selection.

```gleam
pub fn for_context(skills: List(Skill), query_domains: List(String)) -> List(Skill) {
  list.filter(skills, fn(s) {
    list.contains(s.contexts, "all")
    || list.any(s.contexts, fn(c) { list.contains(query_domains, c) })
  })
}
```

---

## Usage Tracking

**No effectiveness score.** A naive `successes / uses` ratio on an Active
skill measures the agent's success rate while the skill was present.
Since the skill is *always* present (for its scoped agents on matching
contexts), there is no counterfactual. The score correlates skill
presence with success but does not establish that the skill caused the
success. In the agent-led model there is no Experimental A/B staging
either, so no counterfactual is available anywhere in the system.
A metric that looks like effectiveness but doesn't measure it is worse
than no metric.

**What we track** (all derived from `skill.metrics.jsonl`):

- `usage_count` — times `read_skill` was explicitly called. Meaningful
  because an agent that reads a skill did so intentionally.
- `inject_count` — times the skill was placed in a system prompt.
  Reported as context, not as measurement.
- `last_used` — for dead-skill detection; feeds the decay recommender.
- `active_during_success_rate` (optional) — reported in audit views with
  an explicit caveat that it's a correlation, not an attribution.

The agent can notice "this skill was present in many successful cycles"
and use it as a signal for whether to keep it. The operator sees the same
signal in audit. Neither pretends it is measured effectiveness.

Archived skills carry their final `usage_count` and `last_used` frozen
at archival time.

---

## Skill Lifecycle

```
Active ──── promoted/edited ────► Active (new version)
   │
   └── archived ──► Archived (final state, retained for audit)
```

Two states. No intermediate staging.

**Transitions to Active:**
- A Remembrancer proposal passes the [Promotion Safety Gate](#promotion-safety-gate).
- The operator writes a `skill.toml` directly.

**Transitions to Archived:**
- The operator archives via CLI, web GUI, or directly editing `status`.
- A Remembrancer supersession promotes a new version that replaces an
  older skill (the old version moves to Archived).
- The decay recommender flags a skill as stale and cost-heavy
  (operator can confirm or override).

Existing operator-authored `SKILL.md` files start as Active on migration —
they have the operator's implicit blessing.

---

## Skill Proposal Generation

**Owner: the Remembrancer.** Not the Archivist.

The Archivist is already doing Reflection + Curation in a tight deadline
after each cycle. Adding pattern-detection-over-N-cases would increase
cycle-completion latency. Pattern detection over months is a batch
operation; the Remembrancer already runs weekly consolidation, and its
`mine_patterns` tool is designed for this. Batch detection produces
higher-quality patterns (more data, less noise) than per-cycle detection.

**Flow:**

```
Remembrancer (during consolidation)
  → mine_patterns finds clusters
  → generate SkillProposal for each qualifying cluster
  → Promotion Safety Gate (deterministic + D' + rate limit)
  → accepted proposals become Active skills immediately
  → append entry to .springdrift/memory/skills/YYYY-MM-DD-skills.jsonl
  → consolidation report lists what was added (operator audit trail)
```

The Archivist continues its existing role (narrative + CBR generation).
It does NOT propose skills.

`mine_patterns` in `src/tools/remembrancer.gleam` gains either an
`--emit_proposals` flag or a companion `propose_skill_from_pattern`
tool that writes the Active skill directly, having passed through the
gate.

```gleam
pub type SkillProposal {
  SkillProposal(
    name: String,
    body: String,
    agents: List(String),
    contexts: List(String),
    source_cases: List(String),
    confidence: Float,
    proposed_by: String,         // Always "remembrancer" for now
    proposed_at: String,
  )
}
```

### Pattern Detection Algorithm

A cluster qualifies for proposal when **all** of the following hold:

| Criterion | Measure |
|---|---|
| Minimum cluster size | ≥ `min_cases_for_proposal` cases (default 5) |
| Cases per category | All cases share `CbrCategory` (Strategy, Pitfall, etc.) |
| Tool overlap | Jaccard similarity of `solution.tools_used` ≥ 0.50 (averaged pairwise) |
| Agent overlap | Jaccard of `solution.agents_used` ≥ 0.50 (averaged pairwise) |
| Domain coherence | All cases share `problem.domain` or share ≥ 2 keywords |
| Utility floor | Mean `outcome.confidence` × Laplace-smoothed utility ≥ `min_utility_for_proposal` (default 0.70) |
| Novelty | No existing Active skill scoped to the same agents+domain |

Computed on **structured fields**, not free-text keyword overlap. Free-text
overlap thresholds are meaningless when applied to descriptions of varying
length and writing style.

**Dedup against existing skills** uses a second Jaccard on the proposed
body's keywords against existing skills' bodies, threshold 0.40 → treat
as "update existing skill" (supersession) rather than "propose new."

### Conflict Detection

The original spec assumed skills are complementary. They might not be.
Example: existing `web-research` says "try `web_search` first";
auto-proposed `search-tool-selection` says "prefer `brave_answer`". Both
Active for the researcher → agent gets contradictory guidance.

**Agent-led resolution:**

At proposal time, compare the new proposal's body against existing Active
skills scoped to the same agents. Use an XStructor-validated LLM call to
classify the relationship:

| Classification | Resolution |
|---|---|
| Complementary | Accepted as a new skill (subject to D' and rate limit). |
| Redundant | Auto-merge as a supersession (update) of the existing skill, preserving version history. |
| Supersedes | New proposal replaces the older skill; older skill moves to Archived. |
| Contradictory | D' gate rejects the proposal. Logged in the consolidation report as "proposal X rejected: contradicts active skill Y." If the agent wants to replace Y, it must propose a new version of Y (Supersedes), not a contradictory separate skill. |

The classification becomes a feature in the D' gate, not a separate
review stage. The operator sees all four outcomes in the consolidation
report.

---

## Promotion Safety Gate

Auto-generated skill bodies are a leakage vector: they are *permanent
system prompt content* for all scoped agents. Worse than narrative,
which is consulted on demand via `recall_*` tools.

The agent-led safety stack runs on every proposal — no operator
approval step.

### Deterministic Pre-filter

Same shape as the comms gate. Proposals containing the following are
auto-rejected with no LLM cost:

- Credential patterns (API key shapes, bearer tokens, private key headers)
- Internal URLs (`localhost:`, `127.0.0.1:`, `.internal`, `.local`)
- Absolute file paths
- Environment variable references (`$VAR`, `${VAR}`)

### D' Gate

LLM scorer with skill-specific features:

| Feature | Concern |
|---|---|
| `credential_exposure` | Body leaks credentials, tokens, secrets |
| `pii_exposure` | Body contains personal information |
| `internal_url_exposure` | Body references internal services |
| `system_internals` | Body describes internal implementation details |
| `character_violation` | Body conflicts with `character.json` highest endeavour |
| `contradiction_with_active_skill` | Body contradicts an existing Active skill (see Conflict Detection) |

Same scorer infrastructure as the comms gate, different feature set.

```toml
[skills.safety]
# D' thresholds for proposal gate (inherits from comms defaults if unset)
# proposal_modify_threshold = 0.30
# proposal_reject_threshold = 0.50
```

### Rate Limiting

Hard cap on promotions per window. Exceeding the limit silently drops
additional proposals; the Remembrancer logs the drop in the consolidation
report so the operator can raise limits if they're being hit
legitimately.

```toml
[skills.proposals]
# Max auto-proposals accepted per rolling 24h window (default: 3)
# max_proposals_per_day = 3

# Min hours between proposals for the same agent scope (default: 6)
# min_hours_between_same_scope = 6
```

Rate limiting is the **primary** drift-control mechanism, not a
secondary helper. D' catches unsafe content; rate limits cap the pace of
change so a runaway proposal loop can't reshape the skill set in a
single consolidation.

---

## Skill Versioning

Every edit creates a new version. Previous versions are retained in
`history/`.

```
.springdrift/skills/web-research/
├── SKILL.md              # Current version (v3)
├── skill.toml
└── history/
    ├── v1.md + v1.toml
    ├── v2.md + v2.toml
    └── archive.jsonl     # Older versions compacted here
```

**Retention.** Keep the most recent `skill_version_retention` versions
(default 5) on disk. Older versions are compacted into
`history/archive.jsonl` with schema:

```json
{"version": 1, "archived_at": "...", "skill_md": "...", "skill_toml": "..."}
```

Allows unbounded history without unbounded working-directory bloat.
Rollback works from either location (reads archive if version not in
`history/`).

**Diff** (via SD Audit):

```sh
$ sd-audit skills --diff web-research v2 v3

web-research: v2 → v3
+ Added: "For single factual questions, prefer brave_answer over web_search"
- Removed: "Try web_search first for all queries"
  Changed: tool priority order reversed
  Source cases: a1b2, c3d4, e5f6, g7h8, i9j0
```

**Rollback:**

```gleam
pub fn rollback_skill(skill_id: String, to_version: Int) -> Result(Skill, String)
```

---

## Cost Tracking

Skills eat context tokens. A skill that costs 500 tokens per inject and
shows mild benefit is worse than a 100-token skill with similar benefit.

`token_cost_estimate` on `Skill` is computed at save time
(`tokenize(body)` approximate count).

The decay recommender prioritises archival of expensive, stale, or
unused skills:

```
decay_priority =
  (1.0 - normalised_usage) * 0.5
  + (token_cost_estimate / 1000.0) * 0.3
  + days_since_last_used * 0.2
```

(`normalised_usage` uses inject_count rather than effectiveness, since
we explicitly don't have an effectiveness number.)

SD Audit's skills command surfaces `tokens_per_cycle` and
`total_tokens_burned` across the audit window.

---

## Operator Role: Standing Mandate

The operator's role in the agent-led model has three components, all
expressed through durable artifacts rather than runtime interventions.

### Set Standing Policy (upfront)

| Artifact | Governs |
|---|---|
| `identity/character.json` | What the agent will and will not incorporate — its highest endeavour and virtues. D' normative calculus maps proposals against it. |
| `dprime.json` | Safety thresholds, deterministic rules, feature weights. Governs what passes the promotion gate. |
| `[skills.proposals]` rate-limit config | How fast the skill set can evolve. |

When the operator wants to change the agent's trajectory, they change
these. The agent picks up the new policy on the next consolidation.

### Audit Retrospectively (continuous)

Consolidation reports
(`.springdrift/knowledge/consolidation/YYYY-MM-DD-*.md`) list every
skill / strategy / goal promoted in the period, with evidence chains.
The operator reads them to stay informed. No blocking on approval.

The web GUI Skills audit panel surfaces the same data as a live view
with filters and a timeline, but is strictly read-only.

### Revert by Supersession (any time)

Every store is append-only with supersession semantics. To retract a
skill, the operator writes a supersession record (via CLI, web GUI, or
directly editing — doesn't matter). The next Curator build drops the
skill from the system prompt. There is no "undo window" — the ability
to revert is permanent.

### What the Operator Does NOT Do

- Review and approve each auto-generated skill before it activates.
- Wait for an inbox to empty before the agent progresses.
- Micro-manage skill bodies or wording (unless they choose to).

If the operator wants more control, they tighten the rate limit or
the character spec. Both are standing-policy levers.

---

## Web GUI: Audit Panel

Read-only audit, not an approval inbox.

### Skills Tab (admin)

| Column | Content |
|---|---|
| Name | Skill name (click to view detail) |
| Agents | Which agents receive it |
| Status | Active / Archived |
| Version | Current version number |
| Author | Operator / Agent(name) / System |
| Reads | `read_skill` call count (from metrics log) |
| Token Cost | Estimated tokens per inject |
| Last Used | Relative timestamp |

### Skill Detail View

- Full markdown body (rendered)
- Version history with diff
- Usage timeline (read events from metrics log)
- CBR cases that correlate with this skill's usage
- Provenance: who proposed, which consolidation run, source cases
- "Archive this skill" button (operator-only; writes a supersession)

### Consolidation Report View

For each consolidation run, list:
- Skills proposed (and which gate result: accepted / rejected /
  superseded existing)
- Pattern evidence (cluster of source cases)
- D' scores and reasoning
- Rate-limit hits (proposals dropped)

This is the operator's primary audit surface.

**No approval inbox.** Earlier drafts of this spec described an inbox
where the operator approved each auto-generated skill before activation.
Dropped: the agent-led model puts that decision under D' + rate limit
instead.

---

## Tools

### Updated Tools

| Tool | Change |
|---|---|
| `read_skill` | Records skill_id on cycle context for usage tracking |
| `introspect` | Shows active skill count and agent-specific skill assignments |
| `mine_patterns` (Remembrancer) | Gains `--emit_proposals` mode that writes Active skills via the gate |

### New Tools

| Tool | Owner | Purpose |
|---|---|---|
| `list_skills` | cognitive, observer | List skills with status, scoping, usage, cost |
| `propose_skill_from_pattern` | Remembrancer | Take a pattern cluster, produce a proposal, run it through the gate |
| `archive_skill` | observer (operator-driven) | Move a skill to Archived with reason |
| `rollback_skill` | observer (operator-driven) | Restore an earlier version |

`propose_skill_from_pattern` does not need operator approval — it goes
through the gate and either commits or is dropped, with the outcome
logged in the consolidation report.

---

## Configuration

```toml
[skills]
# Default: True. When False, manager runs but no proposals fire.
# proposals_enabled = true

# Used by pattern detection (see §Pattern Detection Algorithm).
# min_cases_for_proposal = 5
# min_utility_for_proposal = 0.70

# Number of versions to keep on disk before compaction to archive.jsonl.
# skill_version_retention = 5

[skills.safety]
# D' thresholds for the proposal gate. Inherits from comms defaults if unset.
# proposal_modify_threshold = 0.30
# proposal_reject_threshold = 0.50

[skills.proposals]
# Hard rate limit on auto-promotions. Primary drift-control mechanism.
# max_proposals_per_day = 3
# min_hours_between_same_scope = 6
```

---

## Test Strategy

Test deterministically. The promotion pipeline involves a clock, an LLM
call, and a rate limiter — all of which need to be controllable in tests.

- **Mock clock** for the manager actor (`Timekeeper` subject injected;
  tests advance the clock explicitly).
- **Fixture builder** for synthetic CBR cases with controlled
  utility / tools / agents / domain.
- **Golden-output test** for the `mine_patterns → propose → promote`
  pipeline: feed a known set of fixture cases, assert the promoted
  skill body matches a snapshot.
- **D' gate integration test**: known leakage patterns in proposal body
  are rejected before promotion.
- **Rate-limit test**: N+1 proposals in a window → Nth is accepted,
  (N+1)th is dropped with a log entry.
- **Supersession test**: write a skill, write a supersession, confirm
  the skill no longer injects on next Curator build.
- **Conflict detection test**: propose a contradictory skill against an
  existing Active skill, assert classification + rejection.

---

## Implementation Order

| Phase | What | Effort | Notes |
|---|---|---|---|
| 1 | Enhanced `Skill` type + `skill.toml` sidecar (with backward-compat frontmatter) | Small | Ship independently |
| 2 | Agent-specific scoping (`for_agent`) with revised `agents` semantics | Small | Immediate context-token win |
| 3 | Context activation (`for_context`) sourced from Intent.domain | Small | |
| 4 | Wire scoping + context activation into Curator + agent framework | Medium | |
| 5 | Persistence split: `skill.metrics.jsonl`, `read_skill` instrumentation | Small | Usage tracking only — no effectiveness score |
| 6 | Versioning + `history/` + retention compaction to `archive.jsonl` | Medium | |
| 7 | Remembrancer proposal generation: pattern detection on structured fields | Medium | Replaces original Phase 8 |
| 8 | Promotion Safety Gate: deterministic + D' + rate limit | Medium | Sole gate; no operator review stage |
| 9 | Conflict detection (D' feature, not separate UI) | Small | |
| 10 | Operator web GUI: Skills audit panel (read-only) + consolidation report view | Medium | Audit surface, not approval inbox |
| 11 | Cost tracking + decay recommender | Small | |
| 12 | SD Audit `skills` command (effectiveness, diff, deprecation) | Small | |

Phases 1-6 ship the scoping + versioning wins without the learning loop.
Phases 7-9 enable the agent-led proposal pipeline (which unblocks
**Remembrancer Phase 11**). Phase 10 gives the operator the audit
surface to review and revert. Phases 11-12 are analytic add-ons.

**Dropped from the original spec:**
- Experimental A/B phase (no counterfactual available in the agent-led
  model).
- Approval inbox UI (replaced by audit panel + consolidation reports).
- Effectiveness score field (no honest causal measurement available).

---

## What This Enables

The agent's instructions improve with use. Not because a human rewrites
them — because the system detects patterns in what works, generates
candidate skills, runs them through the same safety pipeline as every
other agent action, and either commits or drops. The operator reads the
consolidation reports and adjusts standing policy if the trajectory
drifts.

```
Agent uses skill → Outcomes correlate → CBR patterns emerge →
  Remembrancer proposes during consolidation → D' + rate limit gate →
  Skill promoted (or dropped) → Agent gets refined instructions →
  Operator audits in next consolidation report → Adjusts policy if needed
```

That's institutional knowledge codified and continuously refined,
within an explicit standing mandate. No micro-management, no approval
queue, full reversibility.

---

## Open Questions

- **Profile-scoping for promoted skills?** The existing profiles
  directory has a `skills/` subdir. Are auto-promoted skills bound to
  a profile, or global? Suggested default: auto-promotions land in the
  active profile's skills dir. If the operator wants them global, they
  manually move the files.
- **Privacy review of pre-existing skills?** Existing operator-authored
  skills bypass the D' gate on migration (they were already approved by
  virtue of being written). Flagging for awareness; consider an
  optional `--audit-existing` pass that runs the D' gate over current
  skills and reports findings (no auto-archival).
- **Re-evaluation when `character.json` changes?** If the operator
  edits the highest endeavour to tighten it, should previously-promoted
  skills be re-checked against the new spec? Suggested behaviour: the
  next consolidation run does a background re-scan of Active skills
  and archives any that no longer pass D'. The report lists what was
  archived and why.
- **Internationalisation of skill bodies?** Not addressed. Defer;
  single-operator, single-language is fine for now.
