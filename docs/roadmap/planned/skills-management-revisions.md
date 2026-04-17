# Skills Management — Revisions

**Date**: 2026-04-17 (updated with agent-led amendments)
**Revises**: `skills-management.md`
**Status**: Proposed amendments — not yet merged into the main spec

This document supersedes specific sections of the original skills-management
spec. Read this alongside the original; where they disagree, this doc wins.
Sections not mentioned here stand unchanged.

---

## Design principle — agent-led, operator-audited

**The agent leads. The operator sets standing policy and audits outcomes.**

This is a first-principles decision, not a cost-cutting one. The operator's
continuous mandate is expressed through three upfront artifacts, not per-item
approval:

1. **`character.json`** — the agent's highest endeavour and virtues. Governs what
   the agent will and will not incorporate into its skill set.
2. **`dprime.json`** — the safety thresholds, deterministic rules, and
   normative calculus configuration. Governs what passes the promotion gate.
3. **Rate-limit config** — the cap on how fast skills/strategies/knowledge can
   evolve. Governs the pace of change.

Once those are set, the agent manages its own development within them. No
approval inbox. No "Draft → Reviewed" queue. D' review gates promotion; the
rate limit caps drift; append-only supersession makes every change
reversible. The operator reads consolidation reports to stay informed and can
revert any change by writing a supersession record.

This matches the "AI retainer" framing. A professional retainer works within
a clear remit, exercises judgment, reports back, gets course-corrected if
they drift — but isn't micro-managed. The approvals happen once, via policy,
not continuously via workflow.

---

## Summary of changes

| # | Area | Change |
|---|---|---|
| 1 | Effectiveness measurement | Drop the Active-state effectiveness score. Track usage only. Be honest about correlation vs. causation. |
| 2 | Auto-proposal ownership | Remembrancer owns proposal generation, not the Archivist. |
| 3 | Safety | D' gate + rate limits + audit trail. **No mandatory operator approval.** |
| 4 | Pattern detection | Concrete algorithm on structured fields, not keyword overlap. |
| 5 | Cost tracking | Add `token_cost_estimate`; score deprecation by cost + staleness + usage. |
| 6 | Skill conflicts | D' blocks contradictory proposals at promotion time. No human-resolution step. |
| 7 | Context activation | `contexts` source = Intent.domain, not complexity. |
| 8 | Persistence split | Separate `skill.toml` (config) from `skill.metrics.jsonl` (metrics). |
| 9 | Versioning retention | Keep last N versions on disk; older archived to JSONL bundle. |
| 10 | Provenance | `SkillAuthor::Agent` carries `agent_name`, not just `cycle_id`. |
| 11 | Rate limiting | `max_proposals_per_day` — primary safety mechanism, not a helper. |
| 12 | Scoping semantics | Define `agents = ["all"]` explicitly. |
| 13 | Test strategy | Deterministic harness for usage tracking and promotion pipeline. |
| 14 | Skill lifecycle | Two states only: `Active` and `Archived`. No Draft / Experimental / Deprecated. |
| 15 | Operator role | Set standing policy upfront; audit consolidation reports; revert via supersession. |

---

## 1. Effectiveness measurement — replace §"How It Works"

**Problem with original:** `successes / uses` on an Active skill measures the
agent's success rate while the skill was present. Since the skill is *always*
present (for its scoped agents on matching contexts), there's no counterfactual.
The score correlates skill presence with success but doesn't establish that
the skill caused the success.

**Revised approach — no effectiveness score. Track usage, report honestly.**

Drop the `effectiveness_score` field entirely. In the agent-led model there
is no Experimental A/B staging, so there is no counterfactual available
anywhere in the system. A metric that looks like effectiveness but doesn't
measure it is worse than no metric.

What we track instead:

- `usage_count` — times `read_skill` was explicitly called. Meaningful because
  an agent that reads a skill did so intentionally.
- `last_used` — for dead-skill detection; feeds decay recommendation.
- `cycles_active_during` (optional) — count of cycles where the skill was
  injected into the system prompt. Reported as context, not as measurement.
- `active_during_success_rate` (optional) — reported in the audit view with
  an explicit caveat that it's a correlation, not an attribution.

The agent can still notice "this skill was present in many successful cycles"
and use that as a signal for whether to keep it. The operator sees the same
signal in audit, with the same honesty. Neither pretends it is measured
effectiveness.

**Archived skills** carry their final `usage_count` and `last_used` frozen at
archival time.

---

## 2. Auto-proposal ownership — revise §"Auto-Generated Skills"

**Problem with original:** The Archivist proposes skills post-cycle (per the
original spec). The Remembrancer's Phase 11 also proposes skills during
consolidation. Both specs claim this pipeline.

**Decision: the Remembrancer owns proposal generation.** Rationale:

- The Archivist is already doing Reflection + Curation in a tight deadline
  after each cycle. Adding pattern-detection-over-N-cases to that path
  increases cycle-completion latency.
- Pattern detection over months is a batch operation. The Remembrancer already
  runs weekly consolidation. Its `mine_patterns` tool is designed for this.
- Batch detection produces higher-quality patterns (more data, less noise)
  than per-cycle detection.

**Revised flow (agent-led):**

```
Remembrancer (during consolidation) → mine_patterns finds clusters
  → generate SkillProposal for each qualifying cluster
  → deterministic pre-filter + D' gate
  → rate limit check
  → accepted proposals become Active skills immediately
  → append entry to .springdrift/memory/skills/YYYY-MM-DD-skills.jsonl
  → consolidation report lists what was added (operator audit trail)
```

The Archivist continues its existing role (narrative + CBR generation). It
does NOT propose skills.

No operator inbox, no approve/reject UI, no waiting. The operator sees what
was added in the next consolidation report and can revert by writing a
supersession record.

Implication: `mine_patterns` in `src/tools/remembrancer.gleam` should gain a
`--emit_proposals` flag (or a companion `propose_skill_from_pattern` tool)
that writes the Active skill directly, having passed through the D' +
rate-limit gate.

---

## 3. Safety — add §"Proposal Safety Gate"

Auto-generated skill bodies are a leakage vector: they are *permanent system
prompt content* for all scoped agents. Worse than narrative, which is
consulted on demand via `recall_*` tools.

**Agent-led safety stack — no operator approval step:**

1. **Deterministic pre-filter** (same rules as comms): proposals containing
   credential patterns, internal URLs, absolute file paths, or env var names
   are auto-rejected without LLM cost.
2. **D' gate** on the proposal body with skill-specific features:
   `credential_exposure`, `pii_exposure`, `internal_url_exposure`,
   `system_internals`, `character_violation` (maps to `character.json`
   highest endeavour), `contradiction_with_active_skill` (see §6). Same
   scorer infrastructure as comms, different feature set.
3. **Rate limit** (see §11) — hard cap on promotions per window. Drops
   excess proposals silently (logged in consolidation report).
4. **Append-only supersession** — every promotion is reversible. If the
   operator reviews a consolidation report and dislikes a new skill, they
   write a supersession record that archives it. No time pressure, no
   "approve before agent uses it" ceremony.

Add config:

```toml
[skills.safety]
# D' thresholds for proposal gate (inherits from comms defaults if unset)
# proposal_modify_threshold = 0.30
# proposal_reject_threshold = 0.50
```

**Where the operator's approval actually lives:** in `character.json` (the
agent's highest endeavour governs what skills can teach) and in the D'
configuration (the thresholds and rules govern what passes the gate). Those
are the operator's continuous mandate. Per-item approval is not required
because the policy is already expressed.

**What the operator can still do at any time:**
- Read consolidation reports (lists all new skills with evidence).
- Archive any active skill via `memory_clear_key` equivalent — the next
  Archivist-replay drops it from prompts.
- Tighten rate limits or D' thresholds if drift is too fast.
- Edit or remove entries in `character.json` and the system realigns on
  next consolidation.

---

## 4. Pattern detection — replace §"Pattern detection criteria"

**Problem with original:** "Keyword overlap > 0.6" is computed on what? If
it's free text (solution.approach), the threshold is meaningless.

**Revised criteria:**

A cluster qualifies for proposal when all hold:

| Criterion | Measure |
|---|---|
| Minimum cluster size | ≥ `min_cases_for_proposal` cases (default 5) |
| Cases per category | All cases share `CbrCategory` (Strategy, Pitfall, etc.) |
| Tool overlap | Jaccard similarity of `solution.tools_used` ≥ 0.50 (averaged pairwise) |
| Agent overlap | Jaccard of `solution.agents_used` ≥ 0.50 (averaged pairwise) |
| Domain coherence | All cases share `problem.domain` or share ≥ 2 keywords |
| Utility floor | Mean `outcome.confidence` × Laplace-smoothed utility ≥ `min_utility_for_proposal` (default 0.70) |
| Novelty | No existing Active or Experimental skill scoped to the same agents+domain |

Dedup against existing skills uses a second Jaccard on the proposed-skill
body's keywords against existing skills' bodies, threshold 0.40 → treat as
"update existing skill" rather than "propose new."

---

## 5. Cost tracking — add §"Cost-Adjusted Scoring"

Skills eat context tokens. A skill that costs 500 tokens per inject and
shows mild benefit is worse than a 100-token skill with similar benefit.

Add to `Skill`:

```gleam
token_cost_estimate: Int   // Computed at save time: tokenize(body) approximate
```

The deprecation recommender uses:

```
deprecation_priority =
  (1.0 - effectiveness_score) * 0.7
  + (token_cost_estimate / 1000.0) * 0.2
  + days_since_last_used * 0.1
```

SD Audit's skills command surfaces tokens_per_cycle and total_tokens_burned
across the audit window.

---

## 6. Skill conflicts — add §"Conflict Detection"

The original spec assumes skills are complementary. They might not be.
Example: existing `web-research` says "try web_search first"; auto-proposed
`search-tool-selection` says "prefer brave_answer". Both Active for the
researcher → agent gets contradictory guidance.

**Agent-led resolution:**

- At proposal time, compare the new proposal's body against existing Active
  skills scoped to the same agents. Use XStructor-validated LLM call to
  classify: Complementary / Redundant / Contradictory / Supersedes.
- **Contradictory** → the D' gate rejects the proposal. Logged in the
  consolidation report as "proposal X rejected: contradicts active skill Y."
  No human resolution step. If the agent wants to replace Y, it must
  propose a new version of Y (Supersedes), not a contradictory separate
  skill.
- **Redundant** → auto-merge as an update (supersession) of the existing
  skill, preserving version history.
- **Supersedes** → the new proposal replaces the older skill; the older
  skill moves to Archived.
- **Complementary** → accepted as a new skill (subject to D' and rate limit).

The classification becomes a feature in the D' gate, not a separate review
stage. The operator sees all four outcomes in the consolidation report.

---

## 7. Context activation — revise §"Context Activation"

**Problem with original:** Query complexity (Simple/Complex) is not a domain
signal. Active-thread domain exists but not all cycles have threads.

**Revised source of `query_domains` at injection time:**

Priority-ordered fallbacks:
1. Current thread's domain (if a thread is active).
2. `Intent.domain` from the Archivist's per-cycle XStructor output (available
   once the first cycle has run; cached by Librarian).
3. Top-domain from recent narrative entries (last 3 cycles).
4. `"general"` as final fallback.

Complexity stays out of this — it's not a domain, it's a routing signal
for model selection.

---

## 8. Persistence split — revise §"Persistence"

**Problem with original:** `skill.toml` holds both operator-editable config
AND manager-written metrics. Concurrent writes collide.

**Revised layout:**

```
.springdrift/skills/web-research/
├── SKILL.md                       # Operator-owned: markdown body
├── skill.toml                     # Operator-owned: id, name, description,
│                                  #   version, status, agents, contexts, author
├── skill.metrics.jsonl            # Manager-owned: append-only usage events
│                                  #   {timestamp, cycle_id, event: read|inject|outcome}
└── history/
    ├── v1.md + v1.toml            # Immutable snapshots of earlier versions
    └── v2.md + v2.toml
```

Manager never writes to `skill.toml`. Operator never writes to
`skill.metrics.jsonl`. Effectiveness and usage_count are computed from the
metrics log at read time (Librarian cache). This also eliminates the
versioning write race described in §9.

---

## 9. Versioning retention — add §"Version Pruning"

Keep the most recent `skill_version_retention` versions (default 5) on disk
in `history/`. Older versions are compacted into
`history/archive.jsonl` with schema:

```json
{"version": 1, "archived_at": "...", "skill_md": "...", "skill_toml": "..."}
```

Allows unbounded history without unbounded working-directory bloat. Rollback
works from either location (reads archive if version not in `history/`).

---

## 10. Provenance — revise `SkillAuthor`

```gleam
pub type SkillAuthor {
  Operator
  Agent(agent_name: String, cycle_id: String)
  System
}
```

`agent_name` records which agent produced the proposal ("remembrancer",
"archivist" if we change our mind later, etc.). `cycle_id` locates the
originating cycle for audit trail.

---

## 11. Rate limiting — add config

```toml
[skills.proposals]
# Max auto-proposals accepted per rolling 24h window (default: 3)
# max_proposals_per_day = 3

# Min hours between proposals for the same agent scope (default: 6)
# min_hours_between_same_scope = 6
```

Exceeding the limit silently drops additional proposals for the window. The
Remembrancer logs the drop so the operator can raise limits if they're being
hit legitimately.

---

## 12. Scoping semantics — clarify §"Agent-Specific Skills"

`agents` field semantics:

| Value | Meaning |
|---|---|
| `["cognitive"]` | Injected only into the cognitive loop's system prompt |
| `["researcher", "writer"]` | Injected into these specialist agents only |
| `["all"]` | Shorthand for every registered specialist agent + the cognitive loop |
| `["all_specialists"]` | Every registered specialist agent, but NOT the cognitive loop |

Omitting `agents` in `skill.toml` defaults to `["cognitive"]` (conservative:
don't leak skill into an agent that didn't declare it needs the skill).

---

## 13. Test strategy — new §"Testing"

Test deterministically:

- **Mock clock** for the manager actor (`Timekeeper` subject injected;
  tests advance the clock explicitly).
- **Fixture builder** for synthetic CBR cases with controlled
  utility/tools/agents.
- **Golden-output test** for `mine_patterns → promote` pipeline: feed a
  known set of fixture cases, assert the promoted skill body matches a
  snapshot.
- **D' gate integration test**: known leakage patterns in proposal body
  are rejected before promotion.
- **Rate-limit test**: N+1 proposals in a window → Nth is accepted,
  (N+1)th is dropped with a log entry.
- **Supersession test**: write a skill, write a supersession, confirm the
  skill no longer injects on next Curator build.

---

## 14. Skill lifecycle — simplify to Active + Archived

**Drop Draft, Experimental, Deprecated.** Two states only:

| State | Meaning |
|---|---|
| `Active` | Injected into scoped agent prompts. Usage and outcome correlations tracked. |
| `Archived` | Removed from discovery. Retained in history for audit. No injection, no metrics updates. |

Transitions:
- Promoted to Active by the Remembrancer after D' and rate-limit pass, OR
  by the operator writing a `skill.toml` directly.
- Moved to Archived by (a) the operator, (b) a Remembrancer supersession
  when a better version is promoted, or (c) the decay recommender if the
  skill is stale and cost-heavy.

No intermediate states means no staging area, no "waiting for review"
queue, no Experimental A/B. The system is simpler and matches the
agent-led model directly.

Existing skills (operator-authored `SKILL.md` files) start in Active on
migration — they have the operator's implicit blessing.

---

## 15. Operator role — new §"Principal's Standing Mandate"

The operator's role in the agent-led model has three components, all
expressed through durable artifacts rather than runtime interventions.

### 15.1 Set standing policy (upfront)

Three files express the operator's continuous mandate:

| Artifact | Governs |
|---|---|
| `identity/character.json` | What the agent will and will not incorporate — its highest endeavour and virtues. D' normative calculus maps proposals against it. |
| `dprime.json` | The safety thresholds, deterministic rules, and feature weights. Governs what passes the promotion gate. |
| Rate-limit config (`[skills.proposals]`) | How fast the skill set can evolve. Governs pace of change. |

When the operator wants to change the agent's trajectory, they change
these. The agent picks up the new policy on the next consolidation.

### 15.2 Audit retrospectively (continuous)

Consolidation reports (markdown in
`.springdrift/knowledge/consolidation/YYYY-MM-DD-*.md`) list every skill
/ strategy / goal promoted in the period, with evidence chains. The
operator reads them to stay informed. No blocking on approval.

The web GUI Skills panel (Phase 10) surfaces the same data as a live view
with filters and a timeline, but is strictly read-only.

### 15.3 Revert by supersession (any time)

Every store is append-only with supersession semantics. To retract a
skill, the operator writes a supersession record (via CLI, web GUI, or
directly editing — doesn't matter). The next Curator build drops the
skill from the system prompt.

There is no "undo window" — the ability to revert is permanent.

### What the operator does NOT do

- Review and approve each auto-generated skill before it activates.
- Wait for an inbox to empty before the agent progresses.
- Micro-manage skill bodies or wording (unless they choose to).

If the operator wants more control, they tighten the rate limit or
tighten the character spec. Both are standing-policy levers.

---

## Implementation order — revised (agent-led)

| Phase | What | Effort | Notes |
|---|---|---|---|
| 1 | Enhanced Skill type + skill.toml sidecar (§12 here) | Small | Ship independently |
| 2 | Agent-specific scoping (`for_agent`) + context activation (§7 here) | Small | Immediate context-token win |
| 3 | Wire into Curator + agent framework | Medium | |
| 4 | Persistence split: metrics JSONL (§8 here) | Small | |
| 5 | `read_skill` instrumentation → usage_count only | Small | |
| 6 | Versioning + history + retention (§9 here) | Medium | |
| 7 | Remembrancer proposal generation (§2 + §4 here) | Medium | Replaces original Phase 8 |
| 8 | Promotion safety gate — deterministic + D' + rate limit (§3 + §11 here) | Medium | Sole gate; no operator review stage |
| 9 | Conflict detection (§6 here) | Small | D' feature, not a separate UI |
| 10 | Operator web GUI: Skills audit panel (read-only) | Medium | Audit view, not approval inbox |
| 11 | Cost tracking + decay recommender (§5 here) | Small | |
| 12 | SD Audit skills command | Small | |

Phases 1-6 ship the scoping + versioning wins without the learning loop.
Phases 7-9 enable the agent-led proposal pipeline (which unblocks Remembrancer
Phase 11 — skills-proposal integration). Phase 10 gives the operator the
audit surface to review and revert. Phases 11-12 are analytic add-ons.

Dropped from original: Experimental A/B phase (no counterfactual available),
approval inbox UI (replaced by audit panel).

---

## Open questions

- **Should skills be profile-scoped?** The existing profiles directory has
  a `skills/` subdir. Are auto-promoted skills bound to a profile, or
  global? Suggest: auto-promotions default to the active profile's skills
  dir. If the operator wants them global, they manually move the files.
- **Internationalisation of skill bodies?** Not addressed. Defer;
  single-operator, single-language is fine for now.
- **Privacy review of existing pre-ship skills?** Existing
  operator-authored skills bypass the D' gate on migration (they were
  already approved by virtue of being written). Flagging for awareness.
- **What triggers character-spec re-evaluation of existing skills?**
  If the operator edits `character.json` to tighten the highest endeavour,
  should previously-promoted skills be re-checked against the new spec?
  Suggest: the next consolidation run does a background re-scan of
  Active skills and archives any that would no longer pass D'. The
  report lists what was archived and why.
