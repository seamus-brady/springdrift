---
name: planner-management
description: How to introspect and control the forecaster, manage endeavour lifecycle, adjust feature weights, edit tasks, view forecast breakdowns, and handle failures.
agents: project_manager, cognitive
---

## Understanding the Forecaster

The Forecaster evaluates active tasks and endeavours using D' scoring with
configurable feature sets. Five default features:

| Feature | Default | Critical | What it measures |
|---|---|---|---|
| step_completion_rate | HIGH | Yes | Steps vs cycles — are you making progress? |
| dependency_health | HIGH | Yes | Blocked dependencies or active blockers |
| complexity_drift | MEDIUM | No | Actual cycles vs planned complexity |
| risk_materialization | MEDIUM | No | How many predicted risks actually happened |
| scope_creep | LOW | No | Steps/phases added beyond the original plan |

D' score = importance-weighted magnitude sum, normalised to [0,1].
Score above replan_threshold (default 0.55) triggers a replan suggestion.

## Inspecting Forecaster Config

Use `get_forecaster_config` to see the global default features and thresholds.
Pass `endeavour_id` to see the effective config for a specific endeavour
(base defaults merged with per-endeavour overrides).

## Viewing Forecast Breakdowns

Use `get_forecast_breakdown(id)` to see per-feature detail for any task or
endeavour. The breakdown shows each feature's raw magnitude, weighted score
(normalised contribution to the composite D' score), and rationale. This
tells you exactly *which* feature is driving the health score and why.

Example: if `step_completion_rate` has magnitude=7 and weighted=0.47 but
`scope_creep` has magnitude=1 and weighted=0.02, the problem is slow
progress, not scope changes — adjust your response accordingly.

## Adjusting Feature Weights

Per-endeavour overrides let you tune the Forecaster without changing global
defaults. Use `update_forecaster_config` on a specific endeavour.

**When the Forecaster is too sensitive** (frequent false replan suggestions):
- Increase the threshold: `update_forecaster_config(endeavour_id, threshold_override: 0.70)`
- Downgrade noisy features: `update_forecaster_config(endeavour_id, feature_name: "scope_creep", importance: "low")`

**When the Forecaster misses real problems:**
- Lower the threshold: `update_forecaster_config(endeavour_id, threshold_override: 0.40)`
- Upgrade critical features: `update_forecaster_config(endeavour_id, feature_name: "dependency_health", importance: "high")`

**Example:** For an endeavour where scope changes are expected (exploratory
research), reduce scope_creep importance to LOW so it doesn't trigger replans.

## Task Management

**Edit tasks:** `update_task(task_id, title?, description?)` changes title or
description. `add_task_step(task_id, description)` adds a new step.
`remove_task_step(task_id, step_index)` removes a step by index.

**Quick operations** (on cognitive loop, no delegation needed):
- `complete_task_step` — mark a step done
- `activate_task` — set as current focus
- `get_active_work` — list all active tasks and endeavours
- `get_task_detail` — full task structure

**Heavy operations** (require delegation to project_manager):
- `create_endeavour` — new multi-task initiative
- `flag_risk` — record a materialised risk
- `abandon_task` — stop tracking
- `request_forecast_review` — check plan health scores
- `get_forecast_breakdown` — per-feature D' breakdown for a task or endeavour
- `delete_task` — permanently remove a task (prefer `abandon_task` for normal cancellation)
- `delete_endeavour` — permanently remove an endeavour (does not delete associated tasks)

## Endeavour Lifecycle

**Creating:** `create_endeavour` for multi-task initiatives. Then `add_phase`
to structure the work into ordered phases.

**Updating:** `update_endeavour(endeavour_id, goal?, deadline?, update_cadence?)`
to adjust goal, deadline, or stakeholder update frequency after creation.

**Scheduling:** `schedule_work_session` for autonomous sessions at specific
times. `cancel_work_session` to remove a scheduled session. `list_work_sessions`
to see session history.

**Monitoring:** `get_endeavour_detail` for full state (phases, blockers,
sessions, metrics). `get_forecaster_config(endeavour_id)` for health scoring
config.

## Phase Management

- `add_phase` — add a new phase to an endeavour
- `advance_phase` — mark current phase complete, advance to next
  (may require operator approval if `phase_transition = require_approval`)

## Handling Failures

**Blockers:** Use `report_blocker` to record what's blocking progress. Set
`requires_human: true` if operator intervention is needed. Use `resolve_blocker`
when the issue is resolved — this auto-restores Active status if all blockers
are clear.

**Session failures:** Recorded automatically. Review with `list_work_sessions`.
Consider cancelling remaining scheduled sessions if the approach needs to change.

**Replan triggers:** When the Forecaster suggests replanning:
1. Check the per-feature breakdown: `get_forecast_breakdown(endeavour_id)`
2. Identify which features are driving the score (high weighted_score)
3. Decide: adjust thresholds (if the signal is noise) or replan (if genuine)
4. If replanning: create new phases via `add_phase`, adjust the endeavour

## Sprint Contracts

When delegating multi-step work to the project_manager, the PM will state
its intent before executing: what it will do, what success looks like, and
what it's assuming. This is the sprint contract pattern.

If the PM's stated plan looks wrong, cancel it (`cancel_agent`) and
re-delegate with clearer instructions. If it looks right, let it execute.

When you delegate complex work yourself (not through PM), apply the same
principle: state what you're about to do, then do it. Don't silently execute
a long sequence of operations.

## Cost Awareness

Each work session consumes cycles and tokens (visible in `list_work_sessions`
and `get_endeavour_detail`). Set `max_cycles` per session to control cost.
Consider cancelling low-value scheduled sessions when budget is tight.

Check the sensorium's `tokens_remaining` before scheduling heavy sessions.

## Task vs Endeavour Decision

- Single sequential plan, completable in one session = **Task**
- Multiple independent work streams toward one goal = **Endeavour**
- Research spanning multiple sessions = **Endeavour**
- One-off investigation = **Task**
- Deadline-driven multi-phase project = **Endeavour**
