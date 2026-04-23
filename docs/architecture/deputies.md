# Deputies — Delegated Attention

Ephemeral restricted cog-loop variants that hold delegated attention on a
specialist agent's work tree. One deputy per root delegation hierarchy.
Read-only. Parallel to the agent, never in its path.

Full design spec: [`docs/roadmap/planned/deputy-agents.md`](../roadmap/planned/deputy-agents.md).

## One-sentence summary

Before a specialist agent starts, a deputy reads memory and produces a
`<briefing>` block (relevant CBR cases, facts, known pitfalls) that is
prepended to the agent's instruction — then the deputy dies.

## Why

The cognitive loop carries all the agent's intelligence: CBR retrieval, fact
recall, sensorium synthesis, skill consultation. Specialist agents historically
received only a plain instruction string and their own tool set — they reasoned
with dramatically less context than the cog loop had. The metaphor: "a tribe of
Einsteins who use Mr Bean as a valet." Deputies close that gap.

## Architecture

### Per-hierarchy lifetime

A deputy is scoped to a **hierarchy**, not an individual agent. When cog
delegates work to agent A, a deputy spawns. If A then delegates to B, B
inherits the same deputy — no new spawn. The deputy sees the whole tree of
work rooted at cog's initial delegation. Parallel root delegations from cog
spawn parallel deputies — they're independent work trees.

### Read-only by construction

Deputies get a dedicated restricted tool subset: narrative / CBR / facts
reads, `introspect`, `read_skill`. No mutating tools. No `agent_*` (no
recursion). No `team_*`. No human-input, no frontdoor output. The restriction
is structural, not behavioural — the tool registry itself excludes write
paths.

### Lifecycle controls

- **Spawn** — implicit when cog delegates to a root agent, subject to
  `deputies_enabled` config.
- **Kill** — `kill_deputy(deputy_id, reason)` tool. Cog can terminate a
  deputy that's hanging on a slow LLM call or misbehaving. The hierarchy
  continues without a briefing.
- **Recall** (deferred to Phase 2) — snapshot the deputy's current state
  without killing it.
- **Replace** — explicitly not built. Kill + respawn suffices.

## Data flow

### Briefing path (Phase 1)

```
cog delegates → spawn deputy → deputy runs Haiku call with briefing schema
             → deputy returns DeputyBriefing or Error
             → if Ok: prepend <briefing> XML to agent's instruction
             → agent's react loop starts with the briefing in its user message
             → deputy dies
```

Failure is benign — if the deputy LLM fails or times out, the agent proceeds
without a briefing. Fire-and-forget pattern, same as the Archivist.

### DAG integration

Every deputy creates a cycle node:

- `CycleNodeType::DeputyCycle` variant in the DAG
- Deputy's cycle has `parent_cycle_id = root_delegation_cycle_id`
- `list_recent_cycles` returns deputies with `node_type="deputy"` so operators can filter
- Web GUI DAG renders deputy branches distinctly

### Sensorium integration

The `<deputies>` block gives cog ambient awareness:

```xml
<deputies active="2" completed_recent="3">
  <deputy id="dep-ab12cd34" agent="coder" signal="high_novelty" cases="2" facts="1" outcome="ok"/>
  <deputy id="dep-ef56gh78" agent="writer" signal="routine" cases="1" facts="0" outcome="ok"/>
  <more count="1"/>
</deputies>
```

Omitted entirely when no deputies are active and no recent records exist.
Top 3 recent deputies rendered; overflow collapsed to `<more count="N"/>`.

## Impact on invariants

- **Immutability** — preserved by construction. Deputies cannot write memory.
  The writer set does not grow with this feature.
- **Auditability** — preserved. Deputy reasoning is logged to the same
  append-only cycle-log surface as cog reasoning, attributed by cycle_id.
  Agent actions retain attribution to the agent, with deputy context cited as
  source when relevant.
- **Introspection** — strengthened. `introspect` surfaces active deputies;
  the `<deputies>` sensorium block provides ambient awareness; the DAG renders
  deputy branches inspectable via `inspect_cycle`.

## Implementation locations

| Component | File |
|---|---|
| Types (Deputy, DeputyMessage, DeputyBriefing) | `src/deputy/types.gleam` |
| Briefing generator (LLM + XStructor) | `src/deputy/briefing.gleam` |
| Actor framework (spawn, lifecycle, kill) | `src/deputy/framework.gleam` |
| XSD schema | `src/xstructor/schemas.gleam` (section 11) |
| DAG cycle type | `src/dag/types.gleam` (`DeputyCycle`) |
| Librarian registry | `src/narrative/librarian.gleam` (active_deputies, recent_deputies) |
| Delegation integration | `src/agent/cognitive/agents.gleam` (`maybe_prepend_deputy_briefing`) |
| Sensorium block | `src/narrative/curator.gleam` (`render_sensorium_deputies`) |
| Kill / recall tools | `src/tools/memory.gleam` (`kill_deputy_tool`, `recall_deputy_tool`) |
| Ask-for-help | `src/deputy/ask.gleam`, `src/deputy/tool.gleam` (ask_deputy) |
| Agent-framework integration | `src/agent/framework.gleam` (ask_deputy injection + execute_tool routing) |
| `system-map` skill | `.springdrift_example/skills/system-map/SKILL.md` |
| Deputy-scope skills | `.springdrift_example/skills/deputy-*/SKILL.md` |

## Configuration

```toml
[deputies]
enabled = false               # default: false — opt in to measure
model = "claude-haiku-4-5"    # default: same as task_model
max_tokens = 800              # default: 800
timeout_ms = 15000            # default: 15000
```

## MVP scope — what ships

All four phases from the design spec:

- **Phase 1 (briefing)** — deputies spawn on root delegation, produce a
  `<briefing>` XML prepended to the specialist's instruction.
- **Phase 2 (ask-for-help)** — deputies stay alive for the hierarchy's
  lifetime. Specialist agents (and any agents they delegate to) gain
  `ask_deputy(question, context?)` to consult from memory. Cog has
  `recall_deputy(deputy_id)` for non-destructive snapshots. Deputies are
  shut down automatically when the root delegation completes.
- **Phase 3 Tier 1 (sensory event escalation)** — when the deputy can't
  answer an `ask_deputy` call, it emits a `deputy_unanswered` sensory
  event to cog. Cog sees it in the `<events>` block on its next cycle.
- **Phase 4 (sensorium + introspection)** — `<deputies>` block shows
  active deputies and recent completions; `introspect` lists active
  deputies; DAG includes `DeputyCycle` nodes linked to root delegations.

### Hierarchy inheritance (Phase 2)

`AgentTask` carries `deputy_subject: Option(Subject(DeputyMessage))`. When
cog delegates to a root agent, the subject is populated with the new
deputy. When that agent delegates to a sub-agent via `agent_*`, the task
construction inherits the parent's deputy_subject rather than spawning
a new deputy. The deputy sees the whole hierarchy's work.

### ask_deputy tool registration (Phase 2)

`ask_deputy` is not on any specific AgentSpec's tool list. It's injected
at `build_agent_request` time when `task.deputy_subject` is Some. This
keeps the 26+ AgentSpec construction sites unchanged and means agents
without a deputy don't see a tool they can't use.

## Deferred

- **Phase 3 Tier 2 (wakeup)** — `DeputyWakeup` scheduler variant plumbing
  is specced but not wired. Wakeups require pattern-watching the agent's
  turn-by-turn activity, which is a meaningful new channel deserving its
  own design iteration. Plumbing becomes useful when a detector triggers it.

Explicitly NOT planned:
- Deputy autonomous response (two reasoners producing output breaks
  auditability in practice)
- Per-agent deputy prompt specialisation before data justifies it

## System-map upkeep

The `system-map` skill (scoped to `all`) is the system's shared self-model. Any
architectural change that adds or removes a subsystem — deputies included —
should update the `system-map` skill in the same PR. Otherwise the agents' self-model desyncs
from reality.
