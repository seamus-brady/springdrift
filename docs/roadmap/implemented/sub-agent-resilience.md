# Sub-Agent Resilience — Truncation Recovery, Auto-Save, Context Bundles, and Checkpointing

**Status**: Implemented (2026-04-26)
**Priority**: High — observed in production.
**Effort**: ~1500 LOC across three PRs (#166 truncation guard + auto-save, #167 referenced_artifacts + checkpoint, this branch's PR for skills + Strategy Registry seeding) plus 33 new tests.
**Source**: 2026-04-26 Nemo session — operator asked for a comparative analysis of two large documents (a 467-line spec and a 9,110-line book with 309 sections). Researcher and writer agents repeatedly hit `max_tokens` while assembling output. 13 researcher delegations and 1 writer delegation, all output-capped. Total: ~772k tokens spent, partial findings produced, no clean deliverable until the orchestrator gave up on delegation and synthesised directly.

## What Shipped

All five fixes landed across three PRs:

- **Fix 1 — Sub-agent truncation guard** (PR #166). React loop in `src/agent/framework.gleam` detects MaxTokens-with-no-tool-calls. First hit retries with scope-down nudge without burning a turn; second hit ships a deterministic admission via `framework.build_truncation_admission`. `[truncation_guard:<agent>]` prefix is the load-bearing signal.
- **Fix 2 — Auto-save partial output** (PR #166). Design deviation from the original plan: instead of writing partial work to a separate artifact via the artifacts subsystem, the admission text **embeds** the agent's accumulated text (across all turns of the failing react loop) with head/tail elision when over 4KB. Keeps the framework decoupled from artifact infrastructure; the orchestrator's LLM can still call `store_result` on the admission content if it wants persistence.
- **Fix 3 — Delegation context bundle** (PR #167). New `referenced_artifacts` parameter on every `agent_*` tool call (comma-separated artifact IDs). Framework intercepts in `dispatch_single_agent`, retrieves each artifact's content via the librarian, and prepends as `<reference_artifact id="...">CONTENT</reference_artifact>` blocks. Resolution failures render `status="not_found"` markers; over-50KB bundles render `status="elided"` markers. New helpers `parse_referenced_artifacts_csv` and `render_referenced_artifacts_bundle` are public for testability.
- **Fix 4 — Checkpoint tool + skill discipline** (PR #167). New `checkpoint(label, content)` tool in `src/tools/artifacts.gleam` — lighter sibling of `store_result` with sensible defaults. Wired into writer and researcher routing. `.springdrift_example/skills/document-library/SKILL.md` updated with explicit guidance on the checkpoint pattern and the reconnaissance-then-followups pattern using `referenced_artifacts`.
- **Fix 5 — Codify Nemo's strategies as skills + Strategy Registry seeding** (this PR). Two new skill files: `orchestration-large-inputs/SKILL.md` covers reconnaissance-first / search-then-read / parallel-after-reconnaissance; `when-to-use-writer/SKILL.md` covers synthesise-in-root judgment. New `SkillSeeded` variant on `StrategySource`. `strategy/seed.gleam` writes the four floor strategies to an empty registry at instance boot — idempotent, no-op when the registry has any events, never overwrites operator-curated or CBR-mined strategies.

Test counts across the three PRs: framework_truncation_guard_test (10), referenced_artifacts_test (9), checkpoint_tool_test (6), strategy seed_test (9), plus updates to existing framework_test. Total 33+ new tests, suite at 2083 passing.

The original plan is preserved below for context.

## The Symptom

A single root cycle dispatched 14 specialist-agent delegations across about 16 minutes. Every one of them emitted truncated final output because each agent's `max_tokens` budget (writer: 4096, researcher: 2048) was exhausted by the time the agent attempted to format its synthesis. Several of the truncated outputs were genuinely useful — research had been done, comparisons had been drawn — but the work was returned to the orchestrator as half-finished strings rather than retrievable artifacts.

The orchestrator (Nemo) noticed the pattern and adapted, registering three meta-learning strategies for future runs (`reconnaissance-first`, `search-then-read`, `synthesise-in-root`). But the underlying architectural gaps remained:

1. **Sub-agents have no truncation recovery path.** When an agent's LLM response hits `MaxTokens` with no tool calls, the agent emits whatever truncated text it has and returns control to the parent with `truncated: True`. There's no automatic retry with a scope-down nudge, no deterministic admission, and no salvage of the partial work — the same pattern we shipped for the cog loop on 2026-04-26 has not been lifted to the framework layer.

2. **No partial-output durability.** Even when an agent does substantive work, if it's capped during the formatting/synthesis phase, the work that was generated lives only in the truncated response string. There's no mechanism to write it to disk *as it's produced*, so each capping event is a clean loss.

3. **No context inheritance between delegations.** Every researcher delegation independently called `document_info` and `list_sections`, re-discovering the structure of a 309-section book from scratch. ~10 of the 14 delegations spent significant token budget on this redundant bootstrapping.

4. **No discipline around checkpointing.** Even though `store_result` exists and would solve the durability problem, agents reflexively wait until end-of-cycle to call it. By then the budget is gone. There's no skill-level guidance saying "save in chunks as you produce them."

## Why It Happens (Verified Against Code)

### 1. Sub-agent react loop has no MaxTokens handler

In `src/agent/framework.gleam`, the react loop calls the LLM, dispatches tools, and loops. When the LLM response carries `stop_reason == MaxTokens && no tool calls`, the framework returns an `AgentSuccess` with `truncated: True` and the raw text. Verified at the test level — `agent_success_surfaces_truncation_test` (`test/agent/framework_test.gleam:91`) confirms the framework correctly *flags* the truncation, but does nothing to recover from it.

The cog-loop guard from 2026-04-26's PR #165 lives in `src/agent/cognitive.gleam:handle_think_complete` and only catches truncations on the cog loop's own thinking — not on sub-agents.

### 2. Auto-save infrastructure exists but is opt-in by the agent

`tools/artifacts.gleam` provides `store_result` and `retrieve_result`. The researcher already has `should_auto_store` / `maybe_auto_store` for *tool results* (e.g. fetched web pages over 50KB). But there's no analogue for *agent output* — content the agent itself generates is never auto-saved, so it has to fit inside one final LLM response or it's lost.

### 3. Delegations can't pass artifact references

`agent_*` tool calls accept a single `instruction: String` parameter. Orchestrators that want to pass structured prior context (a section outline, a prior agent's findings, a CBR case) have to inline that content in the instruction text — paying tokens both on the dispatching side (instruction string size) and on the receiving side (the agent's first input message). For the 309-section section tree this is hundreds of tokens *per delegation*, paid 14 times in Nemo's session.

The framework already handles operator-uploaded files via `<operator_attachments>` XML in the user's first message. There's no parallel mechanism for parent → child artifact handoff.

### 4. Skill files don't teach checkpointing

`.springdrift_example/skills/document-library/SKILL.md` describes the document-library tools. Neither it nor the writer's and researcher's skills explicitly direct agents to checkpoint partial work via `store_result` during long synthesis tasks. Agents learn this pattern (or fail to) through CBR over many cycles, which is too slow given the failure cost.

## Fix Plan

Four targeted changes. The first two ship together (same code path). The third and fourth are independent.

### Fix 1 — Sub-agent truncation guard

Lift the cog-loop truncation guard pattern from `handle_think_complete` into the framework's react loop in `src/agent/framework.gleam`.

- Track `truncation_retried: Bool` per react-loop iteration. The retry must NOT consume one of the agent's `max_turns` — it's the same logical turn re-attempted, so a single MaxTokens hit shouldn't eat two of the agent's allowed turns.
- On first detection of `stop_reason == MaxTokens && no tool calls`, append a scope-down nudge to the agent's message history and re-invoke the LLM. The nudge prose is agent-aware: a sub-agent can't recursively delegate, so the recovery options are "tighten scope" or "return a structured summary of findings rather than full prose," not "decompose into multiple turns."
- On second detection in the same react-loop iteration, replace the truncated text with a deterministic admission via a new `framework.build_agent_truncation_admission(agent_name, model, output_tokens, limit, partial_text_preview)` helper. The admission carries an `[truncation_guard:<agent>]` prefix so operators recognise the failure mode at a glance.
- The `AgentSuccess.truncated: Bool` flag remains; the new admission text replaces the truncated raw output.

### Fix 2 — Auto-save partial output on truncation

Same code path as Fix 1, runs immediately before the framework returns to the parent.

- When the framework decides to ship an admission (Fix 1's second-hit path), it first writes whatever text the agent produced — across all turns of the failing react loop, not just the final response — to an artifact via `artifacts.store_result`. The artifact is tagged `truncation_partial` and labelled with the agent name, parent cycle id, and timestamp.
- The artifact_id is embedded in the admission text in a structured form: `[truncation_guard:writer] artifact=truncation-2026-04-26-abc123. Cap exhausted twice. Last 500 chars: ...`
- The orchestrator can call `retrieve_result(truncation-2026-04-26-abc123)` to inspect the full partial work and decide whether to retry with narrower scope, build on what's there, or escalate to the operator.
- This is the "no work is ever silently lost on truncation" guarantee. Cheap (~50 LOC on top of Fix 1) and high-impact: of Nemo's 14 capped delegations, 14 partial outputs would now be recoverable.

### Fix 3 — Delegation context bundle

Allow `agent_*` tool calls to reference prior artifacts so children don't re-bootstrap.

- New optional parameter on every `agent_*` tool call: `referenced_artifacts: List(String)` (a list of artifact ids).
- Framework intercepts on dispatch in `agent/cognitive/agents.gleam:dispatch_single_agent`. For each id, retrieve the artifact, render its content as a `<reference_artifact id="..." label="...">...</reference_artifact>` XML block, and prepend the bundle to the agent's first user message — same shape as the existing `<operator_attachments>` mechanism for files.
- Validation: artifact_ids must exist and must have been written by the same instance (no cross-instance leakage). Total bundle size capped at a configurable limit (default 50KB, mirroring the artifact truncation cap) so a parent can't crush a child's context with megabytes of references.
- The orchestrator's mental model becomes: "do reconnaissance once, store the result, pass the artifact_id to every downstream agent." Eliminates the redundant-bootstrap waste Nemo identified.

This is the most architectural of the four changes. It needs careful thought about scoping (which agents can read which artifacts), security (preventing instruction smuggling via crafted artifact content), and the interaction with the existing artifact lifecycle. Recommend its own PR with a focused review.

### Fix 4 — Skill guidance for checkpointing

Update `.springdrift_example/skills/document-library/SKILL.md` and the writer's and researcher's skill files to make checkpointing explicit:

> When producing structured output (multi-section drafts, multi-topic comparisons, any synthesis over ~500 words), call `store_result` after each major section. Don't try to assemble the whole final output in one response — that's how you blow your token cap and lose all the work. Checkpoint, then either continue or hand the artifact_id back to your orchestrator.

Pair this with a new leaner tool, `checkpoint(label, content)`, that's `store_result` with sensible defaults (auto-generated slug from the label, agent name + cycle id auto-stamped, `tag: "in-progress"`). Lower friction than full `store_result`, encourages frequent saves.

This is purely behavioural — agents already have `store_result`, they just don't reach for it during synthesis. The skill update + lighter tool reduces the friction enough that the discipline becomes natural.

### Fix 5 — Codify Nemo's emergent orchestration strategies as skill content

The 2026-04-26 Nemo session ended with three strategies registered in Nemo's Strategy Registry (Phase A meta-learning):

1. **reconnaissance-first** — for large documents, do one cheap delegation to map the structure, store as an artifact, pass the artifact_id to subsequent agents. Subsequent agents don't re-bootstrap.
2. **search-then-read** — for any document over a few hundred lines, use `search_library` first to find relevant passages, then `read_range` for targeted line spans. Sequential `list_sections` → `read_section_by_id` walks are inherently expensive on large books.
3. **synthesise-in-root** — when researcher outputs are already well-structured (tables, comparisons, bullet points), the cog loop should synthesise directly rather than delegating to the writer. The writer is for unstructured-to-narrative translation, not for re-presenting structured findings. Reflexive writer delegation adds a token-starved layer with no benefit.

A fourth pattern is implicit in the above and worth making explicit because Nemo *did* try parallel dispatch in the session ("dispatch two parallel researchers, one per document") and it didn't help — both parallel agents capped for the same reason. The pattern only works when paired with reconnaissance-first:

4. **parallel-after-reconnaissance** — parallel dispatch is a force multiplier *after* the structural-context cost has been paid once. Sequence: one reconnaissance delegation → store artifact → parallel dispatch of N specialised follow-ups, each carrying the reconnaissance artifact via `referenced_artifacts` (Fix 3). Without reconnaissance-first, parallel dispatch just multiplies the redundant-bootstrap cost N-fold instead of saving time. Without `referenced_artifacts`, even sequential dispatch can't share the recon. The two are paired.

Both `orchestration-large-inputs/SKILL.md` and the seeded Strategy Registry entries should call this out explicitly, with a worked example showing the difference between "5 parallel researchers each rediscovering the section tree" (Nemo's attempted approach, didn't help) and "1 recon → 5 parallel informed researchers" (the working pattern).

These are durable in Nemo's local Strategy Registry — they'll surface in its sensorium across sessions. But they're instance-local; a fresh instance won't have them and will re-learn the same lessons the hard way.

The fix is to encode the same patterns as orchestration-skill content so every instance has them at boot:

- New skill: `.springdrift/skills/orchestration-large-inputs/SKILL.md` covering reconnaissance-first and search-then-read for the cog loop.
- New skill: `.springdrift/skills/when-to-use-writer/SKILL.md` covering the synthesise-in-root judgment — explicit "use writer when:" / "synthesise directly when:" criteria.
- Both skills tagged with `agents: cognitive` so the cog loop reads them when relevant action classes (delegation, document tasks) come up.
- Cross-reference from `document-library/SKILL.md` so the discoverability is good.

The skills DO NOT replace the Strategy Registry — they're the floor that every instance starts with. Instance-specific strategies still emerge and refine through CBR. Skills are common knowledge; strategies are local experience. This fix gives instances the floor.

Pair with a small Strategy Registry seeding step at `springdrift.gleam` boot: when the registry is empty AND the skills exist, automatically seed the three strategies from the skills so they surface in the sensorium even before the agent has read the skill explicitly. (This is bootstrapping Phase A's intended workflow — strategies emerge naturally over time, but the floor strategies don't need to be discovered the hard way.)

This is the difference between Nemo's session being a one-time learning experience for one instance vs. a permanent codebase-level improvement.

## How the Five Compose

The fixes layer from prevention to recovery to inheritance to codified discipline:

| Layer | What it ensures | Without it |
|---|---|---|
| **Fix 5** (orchestration skills) | Cog loop knows reconnaissance-first / search-then-read / synthesise-in-root from boot | Each fresh instance re-learns the lessons; Nemo's wisdom doesn't propagate |
| **Fix 4** (checkpoint discipline) | Specialist agents save in chunks as they produce | All work concentrated in one final response that may not fit |
| **Fix 2** (auto-save on truncation) | Even if Fix 4 is skipped, partial work survives | Agent's truncated text is gone after the cycle |
| **Fix 1** (truncation guard) | Even if Fix 2 fires, the parent gets a clean admission with retry-already-attempted | Parent gets an undifferentiated truncated string and has to figure out what happened |
| **Fix 3** (context bundle) | Subsequent agents inherit prior structural work | Each delegation starts from scratch |

Together they convert the failure mode "14 capped, 0 recoverable, 0 contextual reuse, all lessons local to one instance" into "agents that know to use search-first, instances that share the discipline, delegations that build on prior work, and runtime guards that catch what slips through."

Fix 5 is the prevention layer (good orchestration avoids the cap). Fixes 1-2 are the recovery layer (when prevention fails). Fixes 3-4 are the propagation layer (work accumulates across delegations).

## Tests

### Fix 1 — Truncation guard

Mirror the cog-loop guard's test shape:

1. **First MaxTokens triggers retry**: agent's LLM returns MaxTokens then a clean response. Parent receives the clean result, NOT the truncated text.
2. **Second MaxTokens ships admission**: agent's LLM returns MaxTokens twice. Parent receives an `AgentSuccess` whose result starts with `[truncation_guard:<agent>]`, NOT either truncated string.
3. **Retry doesn't burn `max_turns`**: agent with `max_turns=2` hits one truncation. The retry doesn't count as a turn; the agent has its full second turn for tool dispatch or a final response.
4. **Truncation with tool_use is NOT caught by this guard**: the existing tool-use-truncation warning still fires; this guard explicitly only handles the no-tool-call case.

### Fix 2 — Auto-save

5. **Capped agent leaves an artifact behind**: when a truncation admission ships, an artifact with the partial content exists on disk and the artifact_id is embedded in the admission.
6. **Successful retry does NOT leave a partial artifact**: when Fix 1 retries successfully, no truncation artifact is created — the clean response is shipped without disk noise.

### Fix 3 — Context bundle

7. **Referenced artifacts prepend to agent's first message**: dispatch with `referenced_artifacts: ["abc"]` and assert the agent's first message contains `<reference_artifact id="abc">`.
8. **Missing artifact_id returns clean ToolFailure**: dispatching with a non-existent artifact id produces a clear "artifact not found" error, not a silent fallthrough.
9. **Bundle size cap**: dispatching with artifacts whose combined size exceeds the cap returns an error and refuses to dispatch.
10. **Multiple referenced artifacts compose in order**: `referenced_artifacts: ["a", "b"]` produces two `<reference_artifact>` blocks in deterministic order.

### Fix 4 — Skill / checkpoint tool

11. **`checkpoint` tool stores with agent + cycle metadata**: calling `checkpoint("draft-section-1", "...")` from a writer cycle produces an artifact tagged with the cycle_id and agent_name.
12. **Skill content references the new tool**: a structural assertion that the writer's skill text mentions `store_result` or `checkpoint` and "synthesis" / "section" patterns.

### Fix 5 — Orchestration skills + Strategy Registry seeding

13. **Skills exist and parse**: `orchestration-large-inputs/SKILL.md` and `when-to-use-writer/SKILL.md` exist in `.springdrift_example/skills/`, parse cleanly via `skills.parse_frontmatter`, and carry the expected agent scoping (`agents: cognitive`).
14. **Skill content covers the four patterns**: structural assertion that `orchestration-large-inputs` mentions reconnaissance, search-then-read, AND parallel-after-reconnaissance (with explicit contrast to "naive parallel dispatch"); that `when-to-use-writer` mentions both "use writer when" and "synthesise directly when" decision criteria.
15. **Strategy Registry seeds on empty registry**: at instance boot, when the strategy log is empty AND the skill files are present, all four strategies (reconnaissance-first, search-then-read, synthesise-in-root, parallel-after-reconnaissance) are written to the strategy log with `source: SkillSeeded`. Sensorium renders them in the first cycle.
16. **No re-seeding on populated registry**: when the registry already has any entries, the seeding step is a no-op — operator-curated and CBR-mined strategies are not overwritten.

## What's Out of Scope

- **Cog-loop truncation guard.** Already shipped on 2026-04-26 in PR #165.
- **Token-budget tuning.** Bumping `max_tokens` per agent in `config.toml` is an operator decision; this plan provides the resilience around whatever budget is set, not the budget itself.
- **Async-boundary audit / liveness watchdog.** Separate concern; covered by `cog-loop-async-boundary-audit.md` and explicitly deferred there.
- **Restoring an interrupted cycle from artifacts.** Fix 2 ensures artifacts exist; the orchestrator gets to decide whether to retrieve and continue. A "resume from artifact" automation is a richer feature for later.
- **Multi-instance artifact sharing.** Fix 3 explicitly bounds `referenced_artifacts` to artifacts written by the same instance. Cross-instance handoff is a federation concern.

## Suggested Implementation Order

Three PRs:

### PR 1 — Truncation guard + auto-save (Fixes 1 + 2)

Single change to `src/agent/framework.gleam` and `src/agent/cognitive/output.gleam` (or a sibling helper module).

- **Commit 1**: `truncation_retried` field on the react-loop pending state + detection branch + retry-with-nudge. Tests 1, 2, 3, 4.
- **Commit 2**: auto-save on truncation. New `framework.build_agent_truncation_admission` helper that writes the artifact and returns the admission text. Tests 5, 6.

This PR fixes the specific failure that capped Nemo's 14 delegations. Highest leverage, smallest blast radius.

### PR 2 — Context bundle + checkpoint discipline (Fixes 3 + 4)

- **Commit 3**: `referenced_artifacts` parameter on `agent_*` tool calls. Framework intercept in `dispatch_single_agent`. New artifact-bundle render helper. Tests 7, 8, 9, 10.
- **Commit 4**: `checkpoint` tool definition + executor + skill updates for writer, researcher, document-library. Tests 11, 12.

This PR can land independently of PR 1 — the two address different failure surfaces. Recommend PR 1 first since it's smaller and more contained.

### PR 3 — Orchestration strategy skills (Fix 5)

- **Commit 5**: New skills `orchestration-large-inputs/SKILL.md` and `when-to-use-writer/SKILL.md` with the three Nemo-derived patterns. Cross-references from `document-library/SKILL.md`.
- **Commit 6**: Strategy Registry seeding at boot — when the registry is empty AND the skill files exist, seed reconnaissance-first / search-then-read / synthesise-in-root from the skills so they surface in the sensorium immediately. Test: empty-registry instance shows the three strategies in its first sensorium render.

This PR is purely additive — no code path changes, just new skills and a small boot-time seeding step. Lowest risk, can ship first if appetite favours quick wins. But the practical value is highest *after* Fixes 1-4 land, because the strategies reference the mechanisms (artifacts, checkpoint tool, referenced_artifacts) that those PRs introduce.

## Triggers to Revisit

- **If a sub-agent gets capped repeatedly on the same task across sessions**, the budget is genuinely too small for that task class — bump it in config rather than relying on the guard as routine recovery.
- **If `referenced_artifacts` becomes the dominant way orchestrators pass context**, consider whether the artifact lifecycle needs richer scoping (TTL, cycle-bound, agent-bound). The current model is "all artifacts visible to all agents on the same instance"; that may need refinement once agents start producing many short-lived references.
- **If `checkpoint` tool calls dominate agent activity**, that's a sign synthesis tasks are routinely too big for one cycle — consider letting the writer agent run across multiple cycles by default, or surface "this task is too big for one agent" as a sensorium signal so the orchestrator decomposes earlier.
- **If a future incident shows Fix 2's auto-save artifact wasn't recoverable** (corrupted, too large, missing metadata), the artifact-write path needs hardening — possibly a small pre-truncation streaming write rather than one big write at admission time.

## Open Questions

- Should the `truncation_partial` artifact tag be scrubbed after a configurable retention window? Otherwise the artifacts dir accumulates capping evidence indefinitely. Probably yes; mirrors the existing artifact retention policy.
- Should `referenced_artifacts` support glob/tag matching (e.g. `tag: "section-outline"`) in addition to explicit ids? The explicit-id form is simpler and safer; the tag form is more flexible. Start with ids; add tags only if a real workflow demands it.
- Should a sub-agent's truncation admission be logged to the parent cycle's DAG node so the admin Cycles tab can show "delegation truncated → admission shipped → artifact id" inline? Probably yes — falls out of the existing cycle_log instrumentation if we add a `truncation_admission` cycle_log event type.
