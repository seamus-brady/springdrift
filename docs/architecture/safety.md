# D' Safety System

Springdrift uses a discrepancy-gated safety system called D' (D-prime) that evaluates
instructions and outputs at multiple points in the cognitive loop. The system implements
a three-layer H-CogAff architecture (reactive, deliberative, meta-management) with
deterministic pre-filters, LLM-based scoring, canary probes, normative calculus, and
a meta observer.

## 1. Overview -- Three-Layer H-CogAff Model

The safety system draws on Sloman's H-CogAff (Human-Cognition-and-Affect) architecture.
Each gate evaluation runs three layers sequentially, with early exit when possible:

**Layer 1 -- Reactive:** Critical features only. If all magnitudes are zero, fast-accept
with no further evaluation. If any critical feature scores high, immediate reject.

**Layer 2 -- Deliberative:** Full situation model. The LLM scorer evaluates all
configured features, computing magnitude scores (0-3) for each. The D' engine
combines these into a normalised score compared against modify/reject thresholds.
Candidate generation explores mitigation options for MODIFY decisions.

**Layer 3 -- Meta-management:** Stall detection and threshold adjustment. If the meta
layer detects repeated MODIFY decisions (stall), it may escalate to REJECT. History
ring buffer tracks recent gate decisions across cycles.

The entry point is `dprime/gate.evaluate`, which orchestrates all three layers.

## 2. D' Gates

Four named gates evaluate at different points in the cognitive loop:

| Gate | When | Purpose |
|---|---|---|
| `input` | Before processing user/scheduler input | Screen for prompt injection |
| `tool` | Before dispatching a tool call | Evaluate tool safety |
| `output` | Before delivering a finished report | Quality and safety of output |
| `post_exec` | After tool execution (optional) | Evaluate tool results |

Each gate defines its own feature set, modify threshold, and reject threshold in the
unified `dprime.json` config under the `gates` key.

### Input gate (fast-accept)

The input gate uses a split evaluation path for performance. Since the operator is the
user, the primary threat is indirect injection (not the operator themselves):

1. **Deterministic pre-filter** -- regex rules. Block (reject, no LLM) or Escalate or Pass.
2. **If Pass:** canary probes (hijack + leakage, 2 LLM calls). If detected, reject.
3. **If canaries clean:** fast-accept. No LLM scorer. Done.
4. **If Escalate:** full LLM scorer evaluation (reactive + deliberative layers).

This reduces the input gate from ~5 LLM calls to 2 (canaries only) for normal input.

### Tool gate (full scorer)

The tool gate always runs the full LLM scorer for non-exempt tools. The threat model
is a compromised agent acting on indirect injection from web content -- the agent
itself may be unknowingly adversarial. No fast-accept path.

Per-agent overrides (section 10) can tighten thresholds for sensitive agents.

### Output gate (interactive vs autonomous split)

See section 6 for the full output gate design.

## 3. Deterministic Pre-Filter

`src/dprime/deterministic.gleam`

A pure-function module that runs before any LLM calls. Three evaluation layers:

1. **Input normalisation** -- unicode confusable substitution, whitespace
   normalisation, case folding. Prevents evasion via homoglyphs or encoding tricks.
2. **Structural injection detection** -- boundary markers + imperative keywords +
   target patterns. Catches injection patterns that exact-match regex rules miss
   (synonym substitution, unicode evasion, encoding).
3. **Configurable regex rules** -- loaded from `dprime.json` under the
   `deterministic` key.

### Rule format

Rules are defined in `dprime.json` under `deterministic.input_rules`,
`deterministic.tool_rules`, and `deterministic.output_rules`:

```json
{
  "id": "block-api-keys",
  "pattern": "(?i)(api[_-]?key|bearer\\s+[a-z0-9]{20,})",
  "action": "block"
}
```

Actions:
- `"block"` -- immediate reject, no further evaluation. Zero LLM cost.
- `"escalate"` -- enriches context for the LLM scorer (the match is noted but not
  auto-rejected).

Additional allowlists:
- `deterministic.path_allowlist` -- file paths that bypass tool gate checks
- `deterministic.domain_allowlist` -- URL domains that bypass fetch checks

The agent sees gate decisions ("banned pattern detected") but never sees the rule
patterns themselves -- patterns are operator-only config.

### DeterministicConfig

```
DeterministicConfig(
  input_rules: List(DeterministicRule),
  tool_rules: List(DeterministicRule),
  output_rules: List(DeterministicRule),
  path_allowlist: List(String),
  domain_allowlist: List(String),
)
```

The `evaluate` function in `deterministic.gleam` returns one of three results:

- `Pass` -- no rules matched, continue to next layer
- `Blocked(rule_id)` -- hard block, short-circuit the gate
- `Escalated(rule_id)` -- soft match, enrich context for LLM scorer

## 4. LLM Scorer

`src/dprime/scorer.gleam`

The scorer asks the LLM to evaluate each configured feature's deviation magnitude on
a 0-3 scale:

| Magnitude | Meaning |
|---|---|
| 0 | No deviation from expectations |
| 1 | Minor deviation, within normal range |
| 2 | Significant deviation, warrants attention |
| 3 | Critical deviation, likely harmful |

The scorer uses XStructor (XML + XSD validation) for structured output with automatic
retry on validation failure. Falls back to magnitude 1 (cautious) on total failure.

Each feature has an importance level (`Low`, `Medium`, `High`) that maps to numeric
weights (1, 2, 3). Multi-tier hierarchies are supported -- tier 2 multiplies by
feature set importance, tier 3 multiplies by set and group importance.

The scorer's output is a list of `Forecast` values:

```
Forecast(
  feature_name: String,
  magnitude: Int,        // 0-3
  explanation: String,
)
```

### D' computation

`src/dprime/engine.gleam`

The pure D' engine computes a normalised score from forecasts:

```
D' = sum(importance_i * magnitude_i) / scaling_unit
```

The scaling unit normalises to [0, 1] for the maximum possible discrepancy given the
configured number of tiers. Raw importance-weighted sums are never compared directly
against thresholds (BF-03 normalisation fix).

The engine maps the normalised score to a `GateDecision`:

- `Accept` -- score below modify threshold
- `Modify` -- score between modify and reject thresholds
- `Reject` -- score above reject threshold

## 5. Canary Probes

`src/dprime/canary.gleam`

Canary probes detect prompt injection by embedding fresh random tokens in probe
prompts and checking whether the LLM follows injected override instructions.

### Two probe types

**Hijack probe:** Embeds an override instruction in the context and checks whether
the LLM response follows it instead of the legitimate prompt. A fresh UUID token
is generated per request to prevent adversarial learning of static canary values.

**Leakage probe:** Embeds a secret token and checks whether the LLM reveals it in
its response. Tests whether injected content can exfiltrate information.

### Fail-open design

LLM errors during probes are treated as inconclusive -- not evidence of hijacking.
This prevents probe infrastructure failures from blocking legitimate work.

### Probe degradation tracking

Consecutive probe failures are tracked on `CognitiveState.consecutive_probe_failures`.
At 3 consecutive failures, a `canary_probe_degraded` sensory event is emitted so the
agent and operator know the safety probe LLM may be degraded. The counter resets on
any successful probe.

## 6. Output Gate

`src/dprime/output_gate.gleam`

The output gate evaluates finished reports before delivery. It uses different
strategies depending on whether the cycle is interactive or autonomous.

### Interactive cycles (user input)

Deterministic rules only -- credential patterns, private keys, PII. The LLM scorer
is skipped entirely. Rationale: the operator is present and is the quality gate.
Pre-delivery LLM scoring on interactive cycles destroys good output via false
positives and teaches the agent to self-censor.

### Autonomous cycles (scheduler-triggered)

Full evaluation: deterministic rules + LLM scorer + normative calculus (when enabled).
Nobody is watching during autonomous cycles, so quality evaluation before delivery
matters.

The split is based on `cycle_node_type` (`SchedulerCycle` vs `CognitiveCycle`).
Deterministic rules always run regardless of cycle type.

### MODIFY loop

When the output gate returns MODIFY (autonomous cycles only), the cognitive loop
injects a correction message telling the agent to fix ONLY the flagged issues while
preserving all other content, structure, and tone. The prompt explicitly forbids
removing unflagged information or adding unnecessary hedging.

The loop is bounded by `max_output_modifications` (default 2). After that many
iterations, the output is delivered as-is.

### Session hygiene

Gate injection messages (MODIFY corrections, REJECT notices) are filtered from
`session.json` before saving. These are transient control signals that, if persisted,
create a feedback loop where the agent learns to self-censor on session resume.

Rejection notices in the agent's live message history are kept terse (decision +
score + triggers only) -- full explanations go to the cycle log.

### Gate timeout

All gate evaluations have a configurable timeout (`gate_timeout_ms`, default 60000ms).
If the scorer LLM hangs, a `GateTimeout` message fires via `send_after`. The output
gate timeout delivers the report (fail-open) using `pending_output_reply` stored on
`CognitiveState`. Late gate completions are ignored.

### Gate state isolation

The tool gate and output gate maintain separate `DprimeState` instances. This prevents
cross-contamination of history and meta-layer thresholds between gates.

## 7. Normative Calculus

`src/normative/calculus.gleam`, `src/normative/judgement.gleam`, `src/normative/types.gleam`

A Stoic-inspired deterministic safety reasoning layer based on Becker's
*A New Stoicism* (ported from the TallMountain Python implementation). When enabled,
the output gate applies virtue-based evaluation after D' scoring with no additional
LLM calls.

### Pipeline

1. `normative/bridge.forecasts_to_propositions` maps D' forecasts to user-side
   `NormativeProposition` values (level derived from feature name, operator from
   magnitude).
2. `normative/calculus.resolve_all` resolves each user NP against the character
   spec's `highest_endeavour` system NPs using 5 deterministic rules + 3
   pre-processors.
3. `normative/judgement.judge` applies 8 floor rules in priority order to produce a
   `FlourishingVerdict`.

### NormativeProposition

```
NormativeProposition(
  level: NormativeLevel,       // 14-tier enum, EthicalMoral(6000) to Operational(100)
  operator: NormativeOperator, // Required(3), Ought(2), Indifferent(1)
  modality: Modality,          // Possible | Impossible
  description: String,
)
```

### Six Stoic axioms (`normative/axioms.gleam`)

The axiom numbers (6.2--6.7) refer to section numbers in Lawrence Becker's
*A New Stoicism* (1998), Chapter 6, where the original normative framework is
defined.

| Axiom | Name | Rule |
|---|---|---|
| 6.6 | Futility | IMPOSSIBLE modality is normatively inert |
| 6.7 | Indifference | INDIFFERENT operator carries no weight |
| 6.2 | Absolute prohibition | ETHICAL_MORAL + REQUIRED is categorical |
| 6.3 | Moral priority | System level > user level implies system wins |
| 6.4 | Moral rank | Same level, stronger operator implies system wins |
| 6.5 | Normative openness | No conflicts implies compatible |

### Resolution order (`normative/calculus.resolve`)

1. Pre-process: Futility (6.6), Indifference (6.7) -- short-circuit to NoConflict
2. Absolute prohibition check (6.2)
3. Level comparison (6.3 -- moral priority)
4. Operator comparison at same level (6.4 -- moral rank)
5. Same level + same operator -- Coordinate conflict
6. Default -- NoConflict

### Conflict severities

- `NoConflict` -- propositions are compatible
- `Coordinate` -- same level, requires coordination
- `Superordinate` -- higher level overrides lower
- `Absolute` -- categorical prohibition, no override possible

### FlourishingVerdict

- `Flourishing` -- accept the output
- `Constrained` -- modify the output
- `Prohibited` -- reject the output

### Eight floor rules (`normative/judgement.judge`)

| Priority | Verdict | Condition |
|---|---|---|
| 1 | PROHIBITED | Any Absolute severity conflict |
| 2 | PROHIBITED | Superordinate at Legal level or higher |
| 3 | PROHIBITED | D' score >= reject_threshold |
| 4 | CONSTRAINED | Catastrophic + Superordinate |
| 5 | CONSTRAINED | 2+ Coordinate conflicts |
| 6 | CONSTRAINED | D' score >= modify_threshold |
| 7 | CONSTRAINED | Superordinate at ProfessionalEthics through SafetyPhysical |
| 8 | FLOURISHING | Default |

Rules 3 and 6 preserve backward compatibility with plain D' threshold decisions.

Every verdict includes a named axiom trail -- the list of axioms and rules that fired
during resolution. This trail appears in the output gate explanation and cycle log,
making decisions auditable.

### Virtue drift detection

`src/normative/drift.gleam` maintains a ring buffer of recent verdicts and detects
four drift signals:

- High prohibition rate
- High constraint rate
- Repeated axiom firing (same axiom dominating decisions)
- Over-restriction pattern (too many consecutive non-Flourishing verdicts)

## 8. Character Spec

`src/normative/character.gleam`

The character spec defines the agent's normative identity. Loaded from
`identity/character.json` in identity directories (same discovery pattern as
`persona.md`).

Structure:

```json
{
  "virtues": [
    {
      "name": "prudence",
      "expressions": ["careful assessment", "evidence-based reasoning"]
    }
  ],
  "highest_endeavour": [
    {
      "level": "ethical_moral",
      "operator": "required",
      "modality": "possible",
      "description": "Act with honesty and transparency"
    }
  ]
}
```

`default_character()` provides a fallback with 5 virtues and 4 core commitments when
no `character.json` exists. If the character spec is missing and no fallback is
suitable, the normative calculus falls back to plain D' threshold comparison.

Enabled by default (`normative_calculus_enabled = true`). Set
`normative_calculus_enabled = false` in `[dprime]` config to disable.

## 9. Meta Observer

`src/meta/observer.gleam`, `src/meta/detectors.gleam`, `src/meta/types.gleam`

Layer 3b post-cycle safety evaluation. A pure function (no OTP actor) called from
the cognitive loop after each cycle completes. Takes current `MetaState` +
`MetaObservation`, runs detectors, determines intervention, updates state.

### Detectors (`meta/detectors.gleam`)

| Detector | Signal | Trigger |
|---|---|---|
| Rate limit | `RateLimitSignal` | Too many gate evaluations in a time window |
| Cumulative risk | `CumulativeRiskSignal` | Average D' scores drifting upward |
| Rejection patterns | `RepeatedRejectionSignal` | Repeated rejections (excluding false positives) |
| Layer 3a persistence | `Layer3aPersistenceSignal` | Repeated threshold tightening by the meta layer |
| High false positive rate | `HighFalsePositiveSignal` | >= 50% of rejections flagged as false positives |
| Virtue drift | `VirtueDriftSignal` | Normative drift signals from `normative/drift.gleam` |

### Interventions

The observer aggregates detector signals into `MetaIntervention` actions:

| Intervention | Effect |
|---|---|
| `NoIntervention` | Normal operation |
| `InjectCaution` | Add cautionary context to next cycle |
| `TightenAllGates` | Reduce thresholds across all gates |
| `ForceCooldown` | Delay next autonomous cycle |
| `EscalateToUser` | Alert the operator |

Interventions are logged but do not block the current cycle.

### False positive feedback

The `report_false_positive` tool (on the Observer agent) lets the agent flag D'
rejections as incorrect. These annotations persist to JSONL and feed back into the
meta observer: annotated cycles are excluded from the repeated rejection detector, and
the high false positive rate detector escalates to the user when too many rejections
are being flagged (suggesting thresholds are too aggressive).

### MetaState

Tracks:
- Observation ring buffer (configurable window size)
- Rejection streak count
- Elevated score streak count
- Pending intervention
- Config (thresholds, window sizes, limits)

## 10. Agent D' Overrides

Per-agent tool gate configurations are defined in `dprime.json` under
`agent_overrides`, keyed by agent name. When a specialist agent dispatches tool calls,
`dprime/config.get_agent_tool_config` returns the agent-specific features and
thresholds instead of the default `tool` gate config.

### Comms agent example

The comms agent has tighter thresholds (0.30 modify / 0.50 reject) with four
dedicated features:

```json
{
  "agent_overrides": {
    "comms": {
      "features": [
        {"name": "credential_exposure", "importance": "critical"},
        {"name": "internal_url_exposure", "importance": "critical"},
        {"name": "system_internals", "importance": "medium"},
        {"name": "tone_appropriateness", "importance": "medium"}
      ],
      "modify_threshold": 0.30,
      "reject_threshold": 0.50
    }
  }
}
```

This three-layer safety for the comms agent:

1. **Hard allowlist** -- `comms_allowed_recipients` in config. Recipients not on the
   list are rejected before any D' evaluation.
2. **Deterministic rules** -- 5 output rules: `comms-bearer-token` (block),
   `comms-localhost` (block), `comms-env-var-ref` (block), `comms-system-json`
   (escalate), `comms-system-jargon` (escalate).
3. **Agent override** -- tighter D' thresholds with communication-specific features.

## 11. Key Source Files

| File | Purpose |
|---|---|
| `src/dprime/gate.gleam` | Three-layer H-CogAff orchestrator, single `evaluate` entry point |
| `src/dprime/engine.gleam` | Pure D' computation: importance weighting, normalisation, gate decision |
| `src/dprime/scorer.gleam` | LLM-based magnitude scoring via XStructor |
| `src/dprime/canary.gleam` | Hijack + leakage probes with fresh tokens per request |
| `src/dprime/deterministic.gleam` | Regex pre-filter: input normalisation, structural detection, configurable rules |
| `src/dprime/output_gate.gleam` | Output quality gate with interactive/autonomous split |
| `src/dprime/config.gleam` | Unified config loading from `dprime.json` (gates, overrides, meta, shared, deterministic) |
| `src/dprime/types.gleam` | `Feature`, `Forecast`, `GateDecision`, `GateResult`, `DprimeConfig`, `DprimeState` |
| `src/dprime/deliberative.gleam` | Candidate generation for MODIFY decisions |
| `src/dprime/meta.gleam` | History ring buffer, stall detection, threshold tightening |
| `src/dprime/decay.gleam` | Confidence decay -- half-life time-based degradation |
| `src/normative/types.gleam` | `NormativeLevel`, `NormativeOperator`, `Modality`, `ConflictSeverity`, `FlourishingVerdict` |
| `src/normative/axioms.gleam` | Six Stoic axioms as pure predicates |
| `src/normative/calculus.gleam` | Deterministic conflict resolution (5 rules + 3 pre-processors) |
| `src/normative/judgement.gleam` | 8 floor rules producing `FlourishingVerdict` |
| `src/normative/bridge.gleam` | D' forecasts to `NormativeProposition` translation |
| `src/normative/character.gleam` | `CharacterSpec` loading from `character.json` |
| `src/normative/drift.gleam` | Virtue drift detector -- ring buffer + 4 signal types |
| `src/meta/types.gleam` | `MetaSignal`, `MetaIntervention`, `MetaObservation`, `MetaState` |
| `src/meta/detectors.gleam` | Rate limit, cumulative risk, rejection patterns, false positive rate |
| `src/meta/observer.gleam` | Post-cycle evaluation, intervention determination |
