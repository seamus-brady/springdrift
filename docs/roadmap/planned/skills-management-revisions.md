# Skills Management — Revisions

**Date**: 2026-04-17
**Revises**: `skills-management.md`
**Status**: Proposed amendments — not yet merged into the main spec

This document supersedes specific sections of the original skills-management
spec. Read this alongside the original; where they disagree, this doc wins.
Sections not mentioned here stand unchanged.

---

## Summary of changes

| # | Area | Change |
|---|---|---|
| 1 | Effectiveness measurement | Remove Active-state effectiveness score; keep only for Experimental A/B |
| 2 | Auto-proposal ownership | Remembrancer owns proposal generation, not the Archivist |
| 3 | Safety | D' gate + mandatory operator approval for auto-proposals |
| 4 | Pattern detection | Concrete algorithm on structured fields, not keyword overlap |
| 5 | Cost tracking | Add `token_cost_per_inject`; score deprecation by `effectiveness / cost` |
| 6 | Skill conflicts | Explicit conflict detection at proposal time |
| 7 | Context activation | `contexts` source = Intent.domain, not complexity |
| 8 | Persistence split | Separate `skill.toml` (config) from `skill.metrics.jsonl` (metrics) |
| 9 | Versioning retention | Keep last N versions on disk; older archived to JSONL bundle |
| 10 | Provenance | `SkillAuthor::Agent` carries `agent_name`, not just `cycle_id` |
| 11 | Rate limiting | `max_proposals_per_day` config |
| 12 | Scoping semantics | Define `agents = ["all"]` explicitly |
| 13 | Test strategy | Deterministic harness for effectiveness tracking |

---

## 1. Effectiveness measurement — replace §"How It Works"

**Problem with original:** `successes / uses` on an Active skill measures the
agent's success rate while the skill was present. Since the skill is *always*
present (for its scoped agents on matching contexts), there's no counterfactual.
The score correlates skill presence with success but doesn't establish that
the skill caused the success.

**Revised approach:**

- **Active skills: no `effectiveness_score` field at all.** Track only:
  - `usage_count` (times `read_skill` explicitly called — meaningful because
    an agent that reads a skill did so intentionally, unlike passive injection)
  - `last_used` (for dead-skill detection)

- **Experimental skills: Laplace-smoothed A/B score.** When a new skill is
  proposed, it goes Experimental and is injected in parallel with the existing
  skill for N cycles (`experimental_comparison_cycles`). Track outcomes
  separately for cycles that received only-A, only-B, or both. Decide winner
  by two-proportion test on cycle outcome, not raw ratio.

- **Deprecated skills: frozen metrics at time of deprecation**, retained for
  audit; not updated further.

This ends the "effectiveness" vanity metric and keeps the one place where
A/B measurement is legitimate.

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

**Revised flow:**

```
Remembrancer (during consolidation) → mine_patterns finds clusters
  → generate SkillProposal for each qualifying cluster
  → append to .springdrift/memory/skills/YYYY-MM-DD-proposals.jsonl
  → emit sensory event so the agent sees proposals_pending count
  → operator reviews via web GUI → approve/edit/dismiss
  → approved proposals become Draft → Experimental → Active (via A/B)
```

The Archivist continues its existing role (narrative + CBR generation). It
does NOT propose skills.

Implication: `mine_patterns` in `src/tools/remembrancer.gleam` should gain a
`--emit_proposals` flag (or a companion `propose_skill_from_pattern` tool)
that writes to the proposals log rather than only returning text to the LLM.

---

## 3. Safety — add §"Proposal Safety Gate"

Auto-generated skill bodies are a leakage vector: they are *permanent system
prompt content* for all scoped agents. Worse than narrative, which is
consulted on demand via `recall_*` tools.

**Required gates:**

1. **Deterministic pre-filter** (same rules as comms): proposals containing
   credential patterns, internal URLs, absolute file paths, or env var names
   are auto-rejected without LLM cost.
2. **D' output-gate pass** on the proposal body before it becomes Draft.
   Features: credential_exposure, pii_exposure, internal_url_exposure,
   system_internals. Same scorer as comms agent (already in
   `dprime.json` as an override target).
3. **Operator approval is mandatory** for auto-proposed skills. The original
   spec says "or the auto-promotion path via Experimental → effectiveness
   comparison." That path applies to *human-approved* Experimental skills
   only. Auto-proposals never self-promote without operator review.

Add config:

```toml
[skills.safety]
# D' thresholds for proposal gate (inherits from comms defaults if unset)
# proposal_modify_threshold = 0.30
# proposal_reject_threshold = 0.50
```

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

**Required:**

- At proposal time, compare the new proposal's body against existing Active
  skills scoped to the same agents. Use XStructor-validated LLM call to
  classify: Complementary / Redundant / Contradictory.
- Contradictory → block auto-proposal; surface to operator with both
  texts side-by-side for human resolution.
- Redundant → propose as an *update* (new version of existing skill),
  not a new skill.

The manager actor only activates skills that pass this check.

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

Effectiveness tracking depends on cycle outcomes over time. Test deterministically:

- **Mock clock** in the manager actor (`Timekeeper` subject injected; tests
  advance the clock explicitly).
- **Fixture builder** for synthetic CBR cases with controlled utility/tools/agents.
- **Golden-output test** for `mine_patterns → propose` pipeline: feed a known
  set of fixture cases, assert the proposal body matches a snapshot.
- **Property test** for Laplace-smoothed A/B: never outputs 0 or 1 with
  fewer than N observations.
- **D' gate integration test**: known leakage patterns in proposal body are
  rejected before reaching Draft status.

---

## Implementation order — revised

| Phase | What | Effort | Notes |
|---|---|---|---|
| 1 | Enhanced Skill type + skill.toml sidecar (§3 original; §12 here) | Small | Ship independently |
| 2 | Agent-specific scoping (`for_agent`) + context activation (§7 here) | Small | Immediate context-token win |
| 3 | Wire into Curator + agent framework | Medium | |
| 4 | Persistence split: metrics JSONL (§8 here) | Small | |
| 5 | `read_skill` instrumentation → usage_count only | Small | |
| 6 | Versioning + history + retention (§9 here) | Medium | |
| 7 | Remembrancer proposal generation (§2 + §4 here) | Medium | Replaces original Phase 8 |
| 8 | Proposal safety gate — deterministic + D' + approval (§3 here) | Medium | Gate must precede operator review |
| 9 | Operator web GUI: Skills tab, proposals inbox | Large | |
| 10 | Experimental A/B — real effectiveness measurement (§1 here) | Medium | Only Experimental skills get scores |
| 11 | Conflict detection (§6 here) | Small | |
| 12 | Cost tracking + deprecation recommender (§5 here) | Small | |
| 13 | SD Audit skills command | Small | |

Phases 1-6 ship the scoping + versioning wins without the learning loop.
Phases 7-13 enable Remembrancer Phase 11 (skills-proposal integration) and
the full feedback loop.

---

## Open questions

- **Should skills be profile-scoped?** The existing profiles directory has a
  `skills/` subdir. Are auto-proposed skills bound to a profile, or global?
  Current spec is silent. Suggest: auto-proposals default to the active
  profile's skills dir; operator can promote to global.
- **Internationalisation of skill bodies?** Not addressed. Probably defer;
  single-operator, single-language is fine for now.
- **Privacy review of existing pre-ship skills?** When we flip the feature
  on, existing operator-authored skills bypass the D' gate. Is that right?
  I'd argue yes (operator-trusted), but worth flagging.
