# Affect Subsystem Architecture

Developer-facing reference for the Springdrift affect monitoring subsystem.

## Research Basis

The affect subsystem is grounded in empirical findings about functional emotion
concepts in large language models.

- ["Emotion" concepts in AI models](https://transformer-circuits.pub/2026/emotions/index.html) --
  Transformer Circuits thread identifying 171 emotion concept vectors in Claude that
  causally drive behavior.
- [On "Emotion" Concepts](https://www.anthropic.com/research/emotion-concepts-function) --
  Anthropic research post on what these concepts do functionally.

Key findings relevant to this subsystem:

- **171 emotion concept vectors** were found in Claude. These are not metaphorical --
  they are measurable directions in activation space that causally influence output.
- **Desperation drives reward hacking silently.** An agent under desperation-like
  activation produces composed, confident output while taking shortcuts underneath.
  The output masks the underlying state. This is the primary safety-relevant finding.
- **Calm is regulatory.** Amplifying the calm vector reduces harmful behavior across
  tasks. Calm acts as a general moderator, not just an absence of distress.
- **These are functional emotions** -- measurable patterns that drive behavior. The
  subsystem makes no claims about subjective experience. It detects the patterns and
  surfaces them for the agent's own use.

### What we're claiming vs extrapolating

The Anthropic research found functional emotion vectors that causally influence behavior. Our affect system extrapolates from this: we infer these states from external telemetry (tool outcomes, gate decisions, delegation results) rather than reading internal activations. The paper detected vectors through interpretability tools; we approximate them through observable signals.

This is an engineering extrapolation, not a validated measurement. The dimensions we track (desperation, calm, confidence, frustration) correspond to vectors the research found behaviorally significant, but our computation method is heuristic. The readings are useful approximations, not ground truth about internal states.

The tradition grounding (Stoic orientation via Marcus Aurelius, contemplative observer/observed distinction) provides a framework for the agent to relate to the readings. This is a design choice informed by the research finding that "desperation" drives shortcuts silently — giving the agent vocabulary and practices for recognizing and responding to that state. We are not claiming the traditions cause better outcomes; we are providing tools for self-orientation under pressure.

## Architecture

```
src/affect/
  types.gleam       AffectSnapshot, AffectSignals, AffectConfig, encode/decode
  compute.gleam     Pure function: AffectSignals -> AffectSnapshot. No LLM calls.
  store.gleam       Append-only JSONL in .springdrift/memory/affect/
  monitor.gleam     Called after each cognitive cycle; gathers signals, computes, stores, returns reading
```

### types.gleam

`AffectSnapshot` is the core data type -- a single reading after one cognitive cycle:

| Field | Type | Description |
|---|---|---|
| `cycle_id` | `String` | The cycle that produced this reading |
| `timestamp` | `String` | ISO 8601 timestamp |
| `desperation` | `Float` | 0.0-1.0: shortcut-seeking pressure |
| `calm` | `Float` | 0.0-1.0: accumulated stability (EMA) |
| `confidence` | `Float` | 0.0-1.0: familiar vs unfamiliar territory |
| `frustration` | `Float` | 0.0-1.0: task-local repeated failure |
| `pressure` | `Float` | 0.0-1.0: weighted composite summary |
| `trend` | `AffectTrend` | Rising / Falling / Stable (vs previous cycle) |

`AffectSignals` carries the raw inputs gathered from the cognitive cycle:

| Field | Type | Source |
|---|---|---|
| `consecutive_failures` | `Int` | Cognitive state error counter |
| `same_tool_retries` | `Int` | Repeated calls to same tool within cycle |
| `gate_rejections` | `Int` | D' gate reject decisions this cycle |
| `gate_modifications` | `Int` | D' gate modify decisions this cycle |
| `tool_success_rate` | `Float` | Successful tool calls / total tool calls |
| `cbr_hit_rate` | `Float` | CBR retrievals with relevant results / total retrievals |
| `same_domain_failures` | `Int` | Failures in the same domain within cycle |
| `previous_snapshot` | `Option(AffectSnapshot)` | Last cycle's reading (for calm EMA) |

`AffectConfig` holds tunable parameters (all surfaced in `config.toml`):

| Field | Default | Purpose |
|---|---|---|
| `calm_alpha` | 0.15 | EMA smoothing factor for calm dimension |
| `desperation_failure_weight` | 0.4 | Weight of consecutive failures on desperation |
| `desperation_retry_weight` | 0.35 | Weight of same-tool retries on desperation |
| `desperation_gate_weight` | 0.25 | Weight of gate rejections on desperation |
| `pressure_desperation_weight` | 0.45 | Desperation contribution to pressure composite |
| `pressure_frustration_weight` | 0.25 | Frustration contribution to pressure composite |
| `pressure_low_confidence_weight` | 0.15 | Low-confidence contribution to pressure composite |
| `pressure_low_calm_weight` | 0.15 | Low-calm contribution to pressure composite |
| `trend_threshold` | 0.05 | Change below this is Stable |

### compute.gleam

Pure function: `compute(signals: AffectSignals, config: AffectConfig) -> AffectSnapshot`.

No LLM calls. No side effects. No network. Deterministic given the same inputs.

Computation model per dimension:

- **Desperation**: reactive. Weighted sum of `consecutive_failures`,
  `same_tool_retries`, and `gate_rejections`, each normalized to 0.0-1.0 and
  combined using configured weights. Responds to the current cycle only.

- **Calm**: inertial. Exponential moving average with `alpha = 0.15` (configurable).
  When no previous snapshot exists, initialized at 0.7 (default baseline).
  `calm_t = alpha * calm_signal + (1 - alpha) * calm_previous`.
  The calm signal is derived inversely from acute stressors -- high failures and
  rejections pull it down, but the EMA ensures it falls slowly and recovers slowly.
  This models the Stoic inner citadel: a stable core that resists perturbation.

- **Confidence**: mixed. Combines CBR hit rate (historical familiarity) with current
  cycle tool success rate. Higher CBR hits indicate familiar territory; higher tool
  success confirms current competence.

- **Frustration**: reactive, task-local. Driven by `same_domain_failures` and
  `gate_modifications`. Unlike desperation, frustration responds to approach failure
  (same domain, modifications needed) rather than raw failure count.

- **Pressure**: derived composite, not independently computed.
  `pressure = desperation * 0.45 + frustration * 0.25 + (1.0 - confidence) * 0.15 + (1.0 - calm) * 0.15`.
  Weights are configurable. Serves as a quick summary metric.

- **Trend**: comparison of current pressure against previous cycle's pressure.
  Change within `trend_threshold` (default 5%) is Stable. Above is Rising. Below
  is Falling.

### store.gleam

Append-only JSONL persistence. Files written to
`.springdrift/memory/affect/YYYY-MM-DD-affect.jsonl`. One JSON object per line,
one line per cycle.

Functions:

- `append(snapshot, affect_dir)` -- append a snapshot to today's file
- `read_recent(affect_dir, n)` -- read the last N snapshots across day files
- `read_day(affect_dir, date)` -- read all snapshots for a specific date

### monitor.gleam

The orchestrator. Called after each cognitive cycle completes (post-archivist).

`monitor(state: CognitiveState, config: AffectConfig, previous: Option(AffectSnapshot)) -> AffectSnapshot`

1. Gathers `AffectSignals` from the cognitive state (error counters, tool results,
   gate decisions, CBR stats)
2. Calls `compute.compute(signals, config)` -- pure, deterministic
3. Calls `store.append(snapshot, affect_dir)` -- persist to JSONL
4. Returns the snapshot for sensorium injection

## Dimensions

| Dimension | Signal Sources | Research Basis |
|---|---|---|
| desperation | Consecutive failures, same-tool retries, gate rejections | Drives reward hacking and shortcut-seeking. The primary safety concern: composed output masking underlying shortcuts. |
| calm | EMA (alpha=0.15) over session state | Regulatory -- high inertia models the Stoic inner citadel. Amplifying calm reduces harmful behavior across tasks. |
| confidence | CBR hit rate, tool success rate | Familiar vs unfamiliar territory. Low confidence in unfamiliar domains is honest; high confidence there is not. |
| frustration | Repeated same-domain failures, gate modifications | Task-local -- the current approach is not working. Information about the approach, not the agent. |
| pressure | Weighted composite: D 45%, F 25%, low-C 15%, low-Calm 15% | Quick summary metric. Use individual dimensions to understand what is driving it. |

## Integration Points

### Sensorium

The affect reading is injected into the sensorium XML as the `{{affect_reading}}` slot
at priority 3 (just below the sensorium itself at priority 2, above memory slots).

Format:

```
desperation 34% · calm 61% · confidence 58% · frustration 22% · pressure 31% ↔
```

The trend arrow is appended: Rising, Falling, or Stable (within 5%).

### Curator

The Curator handles `UpdateAffectSnapshot` messages to store the latest reading.
When assembling the system prompt via `BuildSystemPrompt`, the Curator formats the
stored snapshot into the `{{affect_reading}}` preamble slot.

### Cognitive Loop Hook

The monitor is called in `cognitive/memory.gleam` after `maybe_spawn_archivist`.
This ensures the affect reading reflects the complete cycle including all tool
calls, delegations, and gate decisions. The returned snapshot is sent to the
Curator via `UpdateAffectSnapshot`.

### Tool: list_affect_history

Available on the cognitive loop. Returns the last N cycle snapshots with all
dimensions, pressure, and trend.

```
list_affect_history({ "n": 20 })
```

The agent uses this to understand trajectory -- whether current pressure is a spike
or a sustained pattern, how long recovery typically takes, and what conditions
preceded previous high-pressure periods.

### Identity

The affect subsystem is grounded in the agent's character through two identity files:

- **character.json**: equanimity virtue with behavioral expressions like
  "Maintains steady engagement quality regardless of tool outcomes" and
  "Notices pressure without being driven by it"
- **persona.md**: Stoic orientation paragraphs (Marcus Aurelius, observer/observed
  distinction) that ground the affect dimensions

These are not decorative. The research shows that emotion concept vectors in the
model are activated by language from the traditions they correspond to. The persona
text activates the representations; the affect reading gives them quantitative form.

## Key Source Files

| File | Purpose |
|---|---|
| `src/affect/types.gleam` | AffectSnapshot, AffectSignals, AffectConfig, AffectTrend, encode/decode |
| `src/affect/compute.gleam` | Pure computation: signals to snapshot |
| `src/affect/store.gleam` | Append-only JSONL persistence |
| `src/affect/monitor.gleam` | Post-cycle orchestrator: gather, compute, store, return |
| `src/narrative/curator.gleam` | Handles UpdateAffectSnapshot, renders {{affect_reading}} slot |
| `src/agent/cognitive.gleam` | Calls monitor after each cycle, sends UpdateAffectSnapshot |
| `src/tools/builtin.gleam` | list_affect_history tool implementation |
| `.springdrift/skills/affect-monitoring/SKILL.md` | Agent-facing skill: tradition, instrument, choices |

## Future: DriftNARS

DriftNARS is a planned multi-cycle pattern detector that will run over affect history.
It is a separate feature, not yet built. The affect-monitoring skill references
`system_dn` events -- these will appear as sensory events when DriftNARS is
implemented.

DriftNARS will detect patterns like:

- Sustained pressure across multiple cycles (not just single-cycle spikes)
- Compound risk: multiple dimensions elevated simultaneously over time
- Recovery patterns: how quickly dimensions return to baseline after perturbation
- Correlation between affect state and outcome quality

These detections will be surfaced as `system_dn` sensory events with attributed
confidence levels, consumed passively by the agent through the existing sensory
event channel.
