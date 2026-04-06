# Work Management Architecture

Springdrift's work management stack covers the full lifecycle of planned work:
Plan, Execute, Appraise, Learn. Two specialist agents (Planner and Project
Manager) divide responsibilities between reasoning and administration. Tasks
and Endeavours persist as append-only JSONL operations. The Forecaster
evaluates plan health using D' scoring. The Appraiser generates pre-mortems
and post-mortems that close the feedback loop into CBR memory.

---

## 1. Overview: Plan, Execute, Appraise, Learn

The work management lifecycle has four phases:

1. **Plan** -- The Planner agent decomposes a goal into a structured plan
   (XML output validated against XSD). The cognitive loop creates a
   `PlannerTask` from the plan, with steps, dependencies, risks, and
   verifications.

2. **Execute** -- The Project Manager manages task lifecycle transitions,
   endeavour phases, work sessions, and blockers. The cognitive loop's quick
   tools (`complete_task_step`, `activate_task`) handle synchronous
   side-effects during execution.

3. **Appraise** -- The Appraiser fires pre-mortems on task activation and
   post-mortems on completion/failure/abandonment. These are fire-and-forget
   LLM calls that never block the user.

4. **Learn** -- Post-mortems create CBR cases (Strategy, Pitfall,
   Troubleshooting) that surface in future `recall_cases` queries.
   Pre-mortem predictions are compared against reality in the post-mortem.
   The Forecaster uses pre-mortem data to evaluate ongoing plan health.

---

## 2. Agents

### Planner -- Pure XML Reasoning

The Planner is a **tool-less** agent that produces structured XML plans. It
has no tools and no side effects. Its output is validated against the planner
XSD schema (`schemas.planner_output_xsd` in `src/xstructor/schemas.gleam`).

| Property | Value |
|---|---|
| Name | `planner` |
| Tools | None (empty list) |
| max_turns | 5 |
| max_consecutive_errors | 2 |
| max_tokens | 2048 |
| Restart | Permanent |
| Source | `src/agents/planner.gleam` |

The system prompt is built by `schemas.build_system_prompt()` combining a
base prompt with the planner XSD and XML example. The agent's entire final
response must be valid XML -- no prose before or after.

**Replan variant:** `spec_with_forecast/3` creates a Planner spec with
`<forecast_context>` prepended to the system prompt. Used when the
Forecaster triggers a replan suggestion. The forecast context contains the
D' score, per-feature breakdown, completed/remaining steps, and materialised
risks.

### Project Manager -- Tool-Based Work Administration

The PM owns the lifecycle of work **after** the Planner creates it. It
manages endeavours, phases, tasks, sessions, blockers, and forecaster
configuration. All operations are via tools.

| Property | Value |
|---|---|
| Name | `project_manager` |
| Tools | 23 (full `planner_agent_tools()` set) |
| max_turns | 15 |
| max_consecutive_errors | 3 |
| max_tokens | 2048 |
| max_context_messages | Unlimited |
| Restart | Permanent |
| Source | `src/agents/project_manager.gleam` |

The PM receives an `AppraiserContext` (optional) so that tool executions that
trigger lifecycle transitions (e.g. `abandon_task`) can spawn post-mortems.

**Sprint contract protocol:** Before executing a multi-step workflow (3+
tool calls), the PM states its intent: what it will do, what success looks
like, and what it is assuming. Then it executes and verifies against its
stated criteria. This is enforced via the system prompt, not code.

---

## 3. Tasks

### PlannerTask Structure

Defined in `src/planner/types.gleam`:

```gleam
pub type PlannerTask {
  PlannerTask(
    task_id: String,
    endeavour_id: Option(String),
    origin: TaskOrigin,           // SystemTask | UserTask
    title: String,
    description: String,
    status: TaskStatus,
    plan_steps: List(PlanStep),
    dependencies: List(#(String, String)),  // (from_step, to_step)
    complexity: String,           // "simple" | "medium" | "complex"
    risks: List(String),
    materialised_risks: List(String),
    created_at: String,
    updated_at: String,
    cycle_ids: List(String),
    forecast_score: Option(Float),
    forecast_breakdown: Option(List(ForecastBreakdown)),
    pre_mortem: Option(PreMortem),
    post_mortem: Option(PostMortem),
  )
}
```

### PlanStep

```gleam
pub type PlanStep {
  PlanStep(
    index: Int,
    description: String,
    status: TaskStatus,
    completed_at: Option(String),
    verification: Option(String),
  )
}
```

The `verification` field holds a testable assertion for the step (e.g. "At
least 3 competitor URLs found"). Populated from the `<verifications>` section
of the Planner's XML output, where each `<verify>` element maps positionally
to a `<step>`. See section 10 for details.

### Task Lifecycle

```
Pending --> Active --> Complete
                  \--> Failed
                  \--> Abandoned
```

- **Pending** -- Created but not yet the focus of work.
- **Active** -- Currently being worked on. Activation triggers a pre-mortem
  (if thresholds met).
- **Complete** -- All steps finished. Triggers a post-mortem.
- **Failed** -- Work attempted but goal not achieved. Always triggers a full
  LLM post-mortem.
- **Abandoned** -- Stopped before completion. Always triggers a full LLM
  post-mortem.

### TaskOp System

Tasks persist as append-only JSONL operations in
`.springdrift/memory/planner/YYYY-MM-DD-tasks.jsonl`. Current state is
derived by replaying operations via `planner_log.resolve_tasks()`.

| TaskOp variant | Purpose |
|---|---|
| `CreateTask` | Initial task creation with full PlannerTask |
| `UpdateTaskStatus` | Status transition (Pending, Active, Complete, etc.) |
| `CompleteStep` | Mark a single step complete |
| `FlagRisk` | Record a materialised risk |
| `AddCycleId` | Associate a cognitive cycle with the task |
| `UpdateForecastScore` | Update the task's D' health score |
| `UpdateForecastBreakdown` | Update score + per-feature breakdown |
| `UpdateTaskFields` | Edit title and/or description |
| `AddTaskStep` | Append a new step |
| `RemoveTaskStep` | Remove a step by index |
| `DeleteTask` | Permanently remove the task |
| `AddPreMortem` | Attach a pre-mortem evaluation |
| `AddPostMortem` | Attach a post-mortem evaluation |

---

## 4. Endeavours

An Endeavour is a living work programme grouping multiple tasks into a
phased, self-scheduling initiative with blockers, stakeholders, and approval
gates.

### Endeavour Structure

Defined in `src/planner/types.gleam`:

```gleam
pub type Endeavour {
  Endeavour(
    endeavour_id: String,
    origin: EndeavourOrigin,        // SystemEndeavour | UserEndeavour
    title: String,
    description: String,
    status: EndeavourStatus,
    task_ids: List(String),
    created_at: String,
    updated_at: String,
    goal: String,
    success_criteria: List(String),
    deadline: Option(String),
    phases: List(Phase),
    work_sessions: List(WorkSession),
    next_session: Option(String),
    session_cadence: Option(SessionCadence),
    stakeholders: List(Stakeholder),
    last_update_sent: Option(String),
    update_cadence: Option(String),
    blockers: List(Blocker),
    replan_count: Int,
    original_phase_count: Int,
    approval_config: ApprovalConfig,
    feature_overrides: Option(List(Feature)),
    threshold_override: Option(Float),
    forecast_score: Option(Float),
    forecast_breakdown: Option(List(ForecastBreakdown)),
    total_cycles: Int,
    total_tokens: Int,
    post_mortem: Option(EndeavourPostMortem),
  )
}
```

### Endeavour Status

```
Draft --> EndeavourActive --> EndeavourComplete
                         \--> EndeavourFailed
                         \--> EndeavourAbandoned
                         \--> EndeavourBlocked --> EndeavourActive (on resolve)
                         \--> OnHold
```

### Phases

Each `Phase` has a name, description, status, task_ids, dependencies,
milestone, and session estimates (estimated vs actual). Phase statuses:
`PhaseNotStarted`, `PhaseInProgress`, `PhaseComplete`, `PhaseBlocked(reason)`,
`PhaseSkipped(reason)`.

### Work Sessions

A `WorkSession` is a scheduled period of autonomous work with:
- `session_id`, `scheduled_at`, `status`
- `phase` and `focus` (what to work on)
- `max_cycles` and `max_tokens` (budget limits)
- `actual_cycles` and `actual_tokens` (consumption tracking)

Session statuses: `SessionScheduled`, `SessionInProgress`,
`SessionCompleted(outcome)`, `SessionSkipped(reason)`, `SessionFailed(reason)`.

### Blockers

A `Blocker` records something preventing progress, with a
`requires_human: Bool` flag. Resolving all blockers on a blocked endeavour
auto-restores `EndeavourActive` status.

### Approval Gates

`ApprovalConfig` defines per-endeavour approval requirements for five gate
types, each set to `Auto`, `Notify`, or `RequireApproval`:

| Gate | Default | Purpose |
|---|---|---|
| `phase_transition` | Auto | Advancing to the next phase |
| `budget_increase` | RequireApproval | Exceeding resource estimates |
| `external_communication` | Auto | Sending stakeholder updates |
| `replan` | Notify | Restructuring phases |
| `completion` | RequireApproval | Marking the endeavour complete |

### EndeavourOp System

Endeavours persist as append-only JSONL operations in
`.springdrift/memory/planner/YYYY-MM-DD-endeavours.jsonl`. Current state is
derived by replaying operations via `planner_log.resolve_endeavours()`.

| EndeavourOp variant | Purpose |
|---|---|
| `CreateEndeavour` | Initial creation |
| `AddTaskToEndeavour` | Associate a task |
| `UpdateEndeavourStatus` | Status transition |
| `UpdatePhase` | Change phase status |
| `AddPhase` | Add a new phase |
| `AddBlocker` | Record a blocker |
| `ResolveBlocker` | Mark a blocker resolved |
| `RecordSession` | Record a completed session |
| `ScheduleSession` | Schedule a future session |
| `CancelSession` | Cancel a scheduled session |
| `SendUpdate` | Record a stakeholder communication |
| `Replan` | Replace phases (records reason) |
| `RecordMetrics` | Update cycle/token totals |
| `UpdateForecasterConfig` | Per-endeavour feature/threshold overrides |
| `UpdateEndeavourFields` | Edit goal, criteria, deadline, cadence, approval |
| `UpdateEndeavourForecastBreakdown` | Update score + per-feature breakdown |
| `DeleteEndeavour` | Permanently remove |
| `AddEndeavourPostMortem` | Attach an endeavour-level post-mortem |

---

## 5. Pre-Mortems

Pre-mortems predict failure modes before task execution begins. They follow
the Archivist pattern: `spawn_unlinked`, XStructor-validated output, JSONL
persistence, Librarian notification. Failures never affect the user.

### When They Fire

A pre-mortem is spawned by `appraiser.spawn_pre_mortem/2` when a task is
activated, subject to three threshold conditions (any one is sufficient):

1. Task complexity >= `min_complexity` (default: `"medium"`)
2. Number of plan steps >= `min_steps` (default: 3)
3. Task is part of an endeavour (`endeavour_id` is `Some`)

Simple standalone tasks with fewer than 3 steps skip the pre-mortem entirely.
The function `appraiser.should_pre_mortem/2` implements this check. Tasks
that already have a pre-mortem are also skipped.

### What They Produce

A `PreMortem` record (defined in `src/narrative/appraisal_types.gleam`):

| Field | Type | Content |
|---|---|---|
| `task_id` | String | The task being evaluated |
| `failure_modes` | List(String) | Specific ways the task could fail |
| `blind_spot_assumptions` | List(String) | Assumptions that could be wrong |
| `dependencies_at_risk` | List(String) | External factors that could break |
| `information_gaps` | List(String) | What we do not know but need to |
| `similar_pitfall_case_ids` | List(String) | CBR cases with similar pitfalls |
| `created_at` | String | ISO timestamp |

The LLM prompt tells the model to "assume this task fails" and identify
concrete failure modes. The output is validated against `pre_mortem.xsd`.
CBR pitfall cases are queried to provide context (currently a stub awaiting
full CBR integration).

### How They Feed the Forecaster

Pre-mortem data is stored on the task via `AddPreMortem` and is available to
the Forecaster's heuristic scoring. Materialised risks (recorded via
`flag_risk`) are compared against predicted failure modes. The post-mortem
later compares pre-mortem predictions against reality.

---

## 6. Post-Mortems

Post-mortems evaluate quality after task completion, failure, or abandonment.

### When They Fire

A post-mortem is spawned by `appraiser.spawn_post_mortem/2` on any terminal
status transition. The evaluation depth depends on the task:

| Transition | Evaluation type | Condition |
|---|---|---|
| Task completed | Deterministic | Simple task, fewer than `min_steps`, not in an endeavour |
| Task completed | Full LLM | Complexity >= `min_complexity` OR steps >= `min_steps` |
| Task failed | Full LLM | Always, regardless of complexity |
| Task abandoned | Full LLM | Always -- abandonment has the most to teach |

Deterministic post-mortems use `appraisal_types.deterministic_achieved/2`
(verdict: Achieved, no lessons or comparisons). Full LLM post-mortems use
XStructor with the `post_mortem.xsd` schema.

### Verdicts

`AppraisalVerdict` is an enum with four values:

| Verdict | Meaning | CBR category created |
|---|---|---|
| `Achieved` | Goal fully met | Strategy |
| `PartiallyAchieved` | Goal partly met, gaps remain | Troubleshooting |
| `NotAchieved` | Goal not met | Pitfall |
| `AbandonedWithLearnings` | Stopped early, but something was learned | Pitfall |

### CBR Case Creation

Every post-mortem creates a CBR case via `create_cbr_case/3` in
`src/narrative/appraiser.gleam`. The case captures:

- **Problem:** Task title, description, complexity, keywords extracted from title
- **Solution:** Step descriptions, agents used, tools used
- **Outcome:** Verdict as status string, confidence score (Achieved=0.8,
  Partial=0.6, NotAchieved=0.7, Abandoned=0.5), lessons as assessment,
  contributing factors as pitfalls

Case IDs are prefixed `cbr-appraisal-` followed by a UUID.

### Sensory Events

On completion, a `QueuedSensoryEvent` is sent to the cognitive loop:
- Event name: `post_mortem`
- Title: `"{task title} -- {verdict}"`
- Body: Task ID, verdict, and the first lesson learned (if any)

### Prediction Comparisons

When a task has both a pre-mortem and a post-mortem, the LLM is asked to
compare predictions against reality. Each `PredictionComparison` has
`prediction`, `reality`, and `accurate: Bool` fields. These are extracted
from the XStructor result using indexed paths
(`post_mortem.prediction_comparisons.comparison.N`).

---

## 7. Endeavour Post-Mortems

Endeavour post-mortems synthesise across all task post-mortems when an
endeavour reaches a terminal status (Complete, Failed, Abandoned).

### Trigger

`appraiser.spawn_endeavour_post_mortem/2` is called when the endeavour
status transitions to a terminal state. Endeavours that already have a
post-mortem are skipped.

### Process

1. Gather task verdicts from all associated task_ids. For tasks without
   post-mortems, the verdict is inferred from task status (Complete ->
   Achieved, Failed -> NotAchieved, Abandoned -> AbandonedWithLearnings).

2. Build a prompt with the endeavour's goal, success criteria, status, and
   per-task verdict summary.

3. Generate structured output via XStructor using
   `endeavour_post_mortem.xsd`.

### EndeavourPostMortem Structure

Defined in `src/narrative/appraisal_types.gleam`:

| Field | Type | Content |
|---|---|---|
| `endeavour_id` | String | The endeavour being evaluated |
| `verdict` | AppraisalVerdict | Overall endeavour verdict |
| `goal_achieved` | Bool | Whether the stated goal was met |
| `criteria_results` | List(CriterionResult) | Per-criterion evaluation |
| `task_verdicts` | List(#(String, AppraisalVerdict)) | Per-task verdicts |
| `synthesis` | String | Cross-task synthesis narrative |
| `created_at` | String | ISO timestamp |

Each `CriterionResult` has `criterion: String`, `met: Bool`,
`evidence: String`.

### Sensory Event

On completion, a `QueuedSensoryEvent` is sent:
- Event name: `endeavour_post_mortem`
- Title: `"{endeavour title} -- {verdict}"`
- Body: The synthesis text

---

## 8. Forecaster

The Forecaster is an OTP actor (`src/planner/forecaster.gleam`) that
periodically evaluates active tasks and endeavours using D' scoring.

### Architecture

- Self-ticking via `process.send_after` with configurable `tick_ms`
  (default: 300,000ms / 5 minutes).
- On each tick: query Librarian for active tasks/endeavours, compute
  heuristic health scores, persist breakdowns, and send replan suggestions
  when thresholds are exceeded.
- No LLM calls -- all scoring is heuristic/deterministic.

### Plan Health Features

Five default features defined in `src/planner/features.gleam`:

| Feature | Importance | Critical | What it measures |
|---|---|---|---|
| `step_completion_rate` | High | Yes | Steps vs cycles -- are you making progress? |
| `dependency_health` | High | Yes | Blocked dependencies or active blockers |
| `complexity_drift` | Medium | No | Actual cycles vs planned complexity |
| `risk_materialization` | Medium | No | How many predicted risks actually happened |
| `scope_creep` | Low | No | Steps/phases added beyond the original plan |

Each feature is scored on a 0-3 magnitude scale by heuristic functions in
`compute_heuristic_forecasts/1` (for tasks) and
`compute_endeavour_forecasts/1` (for endeavours). The D' engine
(`dprime/engine.compute_dprime/3`) computes a composite score normalised to
[0,1] via importance-weighted magnitude sum.

### Task Evaluation

`evaluate_task/2` runs for each active task with at least `min_cycles`
cycles. Heuristic scoring:

- **step_completion_rate:** If `cycles / steps > 2.0` and less than half
  complete -> magnitude 3. If `> 1.5` and not all complete -> magnitude 2.
- **dependency_health:** Count of blocked dependencies. 1->1, 2->2, 3+->3.
- **complexity_drift:** Cycles beyond expected for the complexity level
  (simple: 5/3, medium: 8/6, complex: 12/10 thresholds).
- **risk_materialization:** Count of materialised risks. Direct mapping.
- **scope_creep:** Currently always 0 (approximation).

### Endeavour Evaluation

`evaluate_endeavour/2` runs for active/blocked endeavours with phases.
Heuristic scoring maps endeavour signals to the same feature names:

- **step_completion_rate** (mapped from session overrun): Percentage of
  actual sessions exceeding estimated sessions across all phases.
- **dependency_health** (mapped from blockers): Count of active (unresolved)
  blockers.
- **scope_creep** (mapped from phase drift): Phases added beyond
  `original_phase_count`.
- **risk_materialization** (mapped from replan count): Number of replans.

### Per-Endeavour Overrides

Each endeavour can have `feature_overrides: Option(List(Feature))` and
`threshold_override: Option(Float)`. The `planner_config.effective_features/2`
function merges per-endeavour overrides over the base config. Set via the
`update_forecaster_config` tool.

### Replan Suggestions

When a task/endeavour's D' score exceeds the replan threshold (default
0.55), the Forecaster sends a `ForecasterSuggestion` message to the
cognitive loop containing:
- `task_id` / `task_title`
- `plan_dprime` (the composite score)
- `explanation` (features with magnitude >= 4, completed/remaining steps,
  materialised risks)

This arrives as a `QueuedSensoryEvent` for the cognitive loop to act on.

### Forecast Breakdown Persistence

Per-feature breakdowns are persisted via `UpdateForecastBreakdown` (tasks)
and `UpdateEndeavourForecastBreakdown` (endeavours). Each
`ForecastBreakdown` record contains `feature_name`, `magnitude`, `rationale`,
and `weighted_score`. These are queryable via `get_forecast_breakdown` and
visible in `get_task_detail` / `get_endeavour_detail`.

---

## 9. Sprint Contracts

The sprint contract is a negotiate-before-execute protocol enforced via the
Project Manager's system prompt. It is not a code-level mechanism.

**Protocol:**

1. Before executing a multi-step workflow (3+ tool calls), the PM states:
   - What it will do (specific operations)
   - What success looks like (verifiable outcomes)
   - Any assumptions it is making

2. The PM executes the planned operations.

3. The PM verifies results against its stated criteria.

**Cognitive loop interaction:** The orchestrating agent sees the PM's stated
intent in the agent's output. If the plan looks wrong, the agent can
`cancel_agent("project_manager")` and re-delegate with clearer instructions.

The skill at `.springdrift/skills/planner-management/SKILL.md` documents
this pattern and advises the cognitive loop to apply the same principle when
executing complex work directly.

---

## 10. Verifiable Steps

### Verification Field on PlanStep

Each `PlanStep` has an `Option(String)` `verification` field. This holds a
testable assertion that defines what it means for the step to be done (e.g.
"At least 3 competitor URLs found", "Comparison table has tier breakdown").

### Planner XSD Verifications Section

The planner output XSD (`schemas.planner_output_xsd`) includes an optional
`<verifications>` element:

```xml
<xs:element name="verifications" minOccurs="0">
  <xs:complexType>
    <xs:sequence>
      <xs:element name="verify" type="xs:string"
                  minOccurs="0" maxOccurs="unbounded"/>
    </xs:sequence>
  </xs:complexType>
</xs:element>
```

The Planner's XML example shows verifications mapped positionally to steps:

```xml
<verifications>
  <verify>At least 3 competitor URLs found</verify>
  <verify>Pricing data extracted for each competitor</verify>
  <verify>Comparison table has tier breakdown</verify>
  <verify>Summary includes year-on-year trends</verify>
</verifications>
```

When the cognitive loop creates a `PlannerTask` from the Planner's XML
output, each `<verify>` element is assigned to the corresponding `PlanStep`
by index. Steps without a matching verification get `None`.

### Forecaster Config in Plans

The planner XSD also allows an optional `<forecaster_config>` element with a
custom threshold and per-feature importance overrides. This lets the Planner
suggest forecaster tuning as part of the plan itself:

```xml
<forecaster_config>
  <threshold>0.60</threshold>
  <feature name="scope_creep" importance="high"/>
</forecaster_config>
```

---

## 11. Session Handoff

### Purpose

`session_handoff.json` provides a lightweight summary of the previous
session, read on resume to give the agent immediate context without replaying
the full narrative log.

### HandoffData Structure

Defined in `src/session_handoff.gleam`:

```gleam
pub type HandoffData {
  HandoffData(
    saved_at: String,           // ISO timestamp of save
    session_since: String,      // Session start time
    message_count: Int,         // Messages in the session
    cycles_today: Int,          // Cognitive cycles today
    active_task_id: Option(String),
    active_task_title: Option(String),
    last_user_input: String,    // Truncated to 200 chars
    agents_active: Int,         // Running agents at save time
    tokens_in: Int,
    tokens_out: Int,
  )
}
```

### Write

`session_handoff.write/1` serialises `HandoffData` to JSON and writes to
`.springdrift/session_handoff.json`. Called alongside session save. The
`last_user_input` field is truncated to 200 characters.

### Read

`session_handoff.read/0` reads and parses the handoff file. Returns
`Option(HandoffData)` -- `None` if the file is missing or malformed. All
fields use `optional_field` decoders with sensible defaults. Empty string
`active_task_id` / `active_task_title` are mapped to `None`.

### Prompt Injection

`session_handoff.format_for_prompt/1` renders a one-line summary suitable
for the sensorium or system prompt:

```
Last session: 2026-04-01T14:30:00Z (42 messages, 12 cycles, 85000 tokens). Active task: Research pricing. Last input: "check competitor sites"
```

---

## 12. Tools

### Cognitive Loop Tools (6 tools)

Defined by `planner_tools.all()` in `src/tools/planner.gleam`. These are
synchronous side-effect operations available directly on the cognitive loop
without agent delegation.

| Tool | Purpose |
|---|---|
| `complete_task_step` | Mark a step complete on a task (params: task_id, step_index) |
| `activate_task` | Set a pending task as current focus (params: task_id) |
| `get_active_work` | List all active tasks and endeavours with progress |
| `get_task_detail` | Full task structure: steps, risks, forecast, pre/post-mortem |
| `create_task` | Create a new task with title, description, steps, complexity, risks |
| `request_forecast_review` | Trigger an immediate forecast evaluation for a task |

### Project Manager Agent Tools (23 tools)

Defined by `planner_tools.planner_agent_tools()`. These are heavier
operations that warrant a full agent delegation to the PM.

| Tool | Category | Purpose |
|---|---|---|
| `create_endeavour` | Endeavour | Create a multi-task initiative |
| `add_task_to_endeavour` | Endeavour | Associate a task with an endeavour |
| `flag_risk` | Task | Record a materialised risk |
| `abandon_task` | Task | Stop tracking a task |
| `request_forecast_review` | Forecast | Trigger immediate health evaluation |
| `add_phase` | Phase | Add a new phase to an endeavour |
| `advance_phase` | Phase | Mark current phase complete, advance to next |
| `schedule_work_session` | Session | Schedule an autonomous work period |
| `report_blocker` | Blocker | Record a blocking issue |
| `resolve_blocker` | Blocker | Mark a blocker resolved |
| `get_endeavour_detail` | Endeavour | Full state: phases, blockers, sessions, metrics |
| `get_forecaster_config` | Forecast | View features, weights, thresholds |
| `update_forecaster_config` | Forecast | Adjust per-endeavour feature weights/threshold |
| `update_endeavour` | Endeavour | Edit goal, deadline, cadence, approval config |
| `cancel_work_session` | Session | Cancel a scheduled session |
| `list_work_sessions` | Session | View session history with filtering |
| `update_task` | Task | Edit title or description |
| `add_task_step` | Task | Add a new step to an existing task |
| `remove_task_step` | Task | Remove a step by index |
| `get_forecast_breakdown` | Forecast | Per-feature D' breakdown for task or endeavour |
| `delete_task` | Task | Permanently remove a task |
| `delete_endeavour` | Endeavour | Permanently remove an endeavour |
| `purge_empty_tasks` | Cleanup | Remove tasks with no steps or description |

The tool executor is `planner_tools.execute/4`, which receives
`planner_dir`, `librarian`, and `appraiser_ctx` via closure from the PM spec.

---

## 13. Configuration

### [appraisal] Section

Controls pre-mortem and post-mortem generation thresholds. Fields on
`AppConfig`:

| Config key | AppConfig field | Default | Purpose |
|---|---|---|---|
| `[appraisal] model` | `appraiser_model` | task_model | LLM model for appraisal calls |
| `[appraisal] max_tokens` | `appraiser_max_tokens` | 4096 | Max tokens per appraisal LLM call |
| `[appraisal] min_complexity` | `appraisal_min_complexity` | `"medium"` | Minimum complexity for pre-mortem |
| `[appraisal] min_steps` | `appraisal_min_steps` | 3 | Minimum steps for pre-mortem |

The `AppraiserContext` bundles these into a runtime context passed to
`spawn_pre_mortem` and `spawn_post_mortem`.

### [forecaster] Section

Controls the plan-health Forecaster actor:

| Config key | AppConfig field | Default | Purpose |
|---|---|---|---|
| `forecaster_enabled` | `forecaster_enabled` | False | Enable the Forecaster actor |
| `forecaster_tick_ms` | `forecaster_tick_ms` | 300000 | Evaluation interval (ms) |
| `forecaster_replan_threshold` | `forecaster_replan_threshold` | 0.55 | D' score above which replan is suggested |
| `forecaster_min_cycles` | `forecaster_min_cycles` | 2 | Min cycles before evaluation |

### [agents.project_manager] Section

Controls the PM agent spec:

| Config key | AppConfig field | Default | Purpose |
|---|---|---|---|
| `[agents.project_manager] max_tokens` | `pm_max_tokens` | 2048 | Max output tokens per LLM call |
| `[agents.project_manager] max_turns` | `pm_max_turns` | 15 | Max react-loop iterations |
| `[agents.project_manager] max_errors` | `pm_max_errors` | 3 | Tool failure circuit breaker |

---

## 14. Key Source Files

| File | Purpose |
|---|---|
| `src/agents/planner.gleam` | Planner agent spec -- pure XML reasoning, no tools |
| `src/agents/project_manager.gleam` | PM agent spec -- 23 tools, sprint contract protocol |
| `src/planner/types.gleam` | PlannerTask, PlanStep, Endeavour, Phase, WorkSession, Blocker, TaskOp, EndeavourOp |
| `src/planner/log.gleam` | Append-only JSONL persistence, `resolve_tasks()`, `resolve_endeavours()` |
| `src/planner/features.gleam` | Plan-health feature definitions, `default_replan_threshold` |
| `src/planner/config.gleam` | `ForecasterFeatureConfig`, load/save, `effective_features()` |
| `src/planner/forecaster.gleam` | OTP Forecaster actor -- self-ticking D' evaluation |
| `src/tools/planner.gleam` | Tool definitions (`all()`, `planner_agent_tools()`) and `execute()` |
| `src/narrative/appraiser.gleam` | Pre-mortem and post-mortem generation (fire-and-forget) |
| `src/narrative/appraisal_types.gleam` | PreMortem, PostMortem, EndeavourPostMortem, AppraisalVerdict, encoders/decoders |
| `src/session_handoff.gleam` | HandoffData write/read/format for session resume |
| `src/xstructor/schemas.gleam` | XSD schemas: `planner_output_xsd`, `pre_mortem_xsd`, `post_mortem_xsd`, `endeavour_post_mortem_xsd` |
| `src/config.gleam` | AppConfig fields for `[appraisal]`, `[forecaster]`, `[agents.project_manager]` |
| `.springdrift/skills/task-appraisal/SKILL.md` | Cognitive skill: how pre/post-mortems work, verdicts, actions |
| `.springdrift/skills/planner-management/SKILL.md` | PM/cognitive skill: forecaster introspection, endeavour lifecycle, sprint contracts |
