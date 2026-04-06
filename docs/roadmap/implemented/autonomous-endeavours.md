# Autonomous Endeavours — Long-Horizon Work Management

**Status**: Implemented (2026-04-01)
**Date**: 2026-03-26
**Dependencies**: Tasks & Endeavours (implemented), Scheduler (implemented), Comms agent (implemented), Parallel dispatch (implemented), Agent teams (implemented)

---

## Table of Contents

- [Overview](#overview)
- [The Problem with Current Tasks](#the-problem-with-current-tasks)
- [Endeavour as a Work Programme](#endeavour-as-a-work-programme)
  - [Enhanced Endeavour Type](#enhanced-endeavour-type)
  - [Phases](#phases)
  - [Work Sessions](#work-sessions)
  - [Stakeholders](#stakeholders)
  - [Blockers](#blockers)
- [Autonomous Work Cycle](#autonomous-work-cycle)
  - [Self-Scheduling](#self-scheduling)
  - [Forecaster Integration](#forecaster-integration)
- [Human-in-the-Loop](#human-in-the-loop)
  - [Approval Gates](#approval-gates)
  - [Human Communication](#human-communication)
- [Web GUI Enhancements](#web-gui-enhancements)
  - [Endeavours Dashboard (new view, not just a tab)](#endeavours-dashboard-new-view-not-just-a-tab)
  - [Endeavour Detail View](#endeavour-detail-view)
  - [Task View Enhancement](#task-view-enhancement)
  - [Sensorium Enhancement](#sensorium-enhancement)
- [Planner Integration](#planner-integration)
  - [Endeavour Creation](#endeavour-creation)
  - [Trigger: Size and Scope](#trigger-size-and-scope)
  - [Replan](#replan)
- [Persistence](#persistence)
- [Tools](#tools)
  - [New Tools](#new-tools)
  - [Updated Tools](#updated-tools)
- [Implementation Order](#implementation-order)
- [What This Enables](#what-this-enables)


## Overview

Elevate Endeavours from a passive grouping mechanism to an active work management system. An Endeavour becomes the unit of long-horizon autonomous operation — the agent pursues a goal over days or weeks, scheduling its own work, communicating progress to stakeholders, handling blockers, and adapting its plan based on outcomes.

Currently: an Endeavour is a list of task IDs with a title. The agent creates tasks, marks steps complete, and that's it. There is no proactive scheduling, no stakeholder communication, no blocker management, and no adaptation.

Proposed: an Endeavour is a living work programme that the agent actively manages — planning phases, scheduling work sessions, communicating with humans and peers, tracking progress against milestones, and replanning when things change.

---

## The Problem with Current Tasks

Tasks are too small and too passive:

- A Task is a few cognitive cycles. It has steps, but no timeline.
- Tasks don't schedule themselves. The operator has to tell the agent to work on them.
- Tasks don't communicate. Progress is only visible in the web GUI if someone looks.
- Tasks don't adapt. If step 3 fails, the agent doesn't replan steps 4-7.
- Tasks don't coordinate. Two tasks in the same Endeavour don't know about each other.

The Forecaster detects task health degradation but can only suggest a replan — it can't execute one autonomously.

---

## Endeavour as a Work Programme

### Enhanced Endeavour Type

```gleam
pub type Endeavour {
  Endeavour(
    endeavour_id: String,
    title: String,
    description: String,
    status: EndeavourStatus,
    // ── Goal ──
    goal: String,                          // What success looks like
    success_criteria: List(String),        // Measurable criteria
    deadline: Option(String),              // ISO date, if time-bound
    // ── Work structure ──
    phases: List(Phase),                   // Ordered phases of work
    task_ids: List(String),               // All associated tasks
    // ── Schedule ──
    work_sessions: List(WorkSession),     // Scheduled autonomous work periods
    next_session: Option(String),         // ISO datetime of next scheduled session
    session_cadence: Option(SessionCadence),
    // ── Communication ──
    stakeholders: List(Stakeholder),      // Who to update and how often
    last_update_sent: Option(String),     // ISO datetime
    update_cadence: Option(String),       // "daily" | "weekly" | "on_milestone"
    // ── Adaptation ──
    blockers: List(Blocker),             // Active blockers
    replan_count: Int,                    // How many times the plan has been revised
    original_phase_count: Int,           // For scope tracking
    // ── Metrics ──
    total_cycles: Int,
    total_tokens: Int,
    started_at: String,
    last_activity: String,
  )
}

pub type EndeavourStatus {
  Draft             // Created but not started
  Active            // Work in progress
  Blocked           // Has unresolved blockers
  OnHold            // Paused by operator
  Complete          // All success criteria met
  Failed            // Abandoned with reason
}
```

### Phases

A Phase is a coherent chunk of work within an Endeavour — larger than a task step, smaller than the whole Endeavour.

```gleam
pub type Phase {
  Phase(
    name: String,
    description: String,
    status: PhaseStatus,
    task_ids: List(String),           // Tasks in this phase
    depends_on: List(String),         // Phase names this depends on
    milestone: Option(String),        // What completing this phase means
    estimated_sessions: Int,          // How many work sessions expected
    actual_sessions: Int,
  )
}

pub type PhaseStatus {
  PhaseNotStarted
  PhaseInProgress
  PhaseComplete
  PhaseBlocked(reason: String)
  PhaseSkipped(reason: String)
}
```

### Work Sessions

A scheduled period where the agent autonomously works on the Endeavour.

```gleam
pub type WorkSession {
  WorkSession(
    session_id: String,
    scheduled_at: String,             // ISO datetime
    status: SessionStatus,
    phase: String,                    // Which phase this session targets
    focus: String,                    // Specific objective for this session
    max_cycles: Int,                  // Budget for this session
    max_tokens: Int,
    actual_cycles: Int,
    actual_tokens: Int,
    outcome: Option(String),          // What was accomplished
  )
}

pub type SessionStatus {
  Scheduled
  InProgress
  Completed(outcome: String)
  Skipped(reason: String)
  Failed(reason: String)
}

pub type SessionCadence {
  FixedInterval(interval_ms: Int)     // Every N ms
  Weekdays(time: String)              // "09:00" on weekdays
  Custom(cron: String)                // Cron-like expression
}
```

### Stakeholders

Who needs updates and how.

```gleam
pub type Stakeholder {
  Stakeholder(
    name: String,
    channel: String,                  // "web" | "email" | "whatsapp"
    address: Option(String),          // Email/phone for non-web channels
    role: StakeholderRole,
    update_preference: UpdatePreference,
  )
}

pub type StakeholderRole {
  Owner           // Can approve/reject/redirect
  Reviewer        // Receives updates, can comment
  Observer        // Receives updates, read-only
}

pub type UpdatePreference {
  OnMilestone     // Update when a phase completes
  OnBlocker       // Update when work is blocked
  Periodic(cadence: String)  // "daily" | "weekly"
  All             // Every update type
}
```

### Blockers

```gleam
pub type Blocker {
  Blocker(
    id: String,
    description: String,
    detected_at: String,
    resolution_strategy: String,      // What the agent plans to do about it
    requires_human: Bool,            // Agent can't resolve this alone
    resolved_at: Option(String),
    resolution: Option(String),
  )
}
```

---

## Autonomous Work Cycle

When a work session fires (via scheduler), the agent:

```
1. Load Endeavour state
2. Check for blockers
   → If requires_human and unresolved: skip session, notify stakeholders
   → If agent-resolvable: attempt resolution first
3. Identify current phase and focus
4. Run cognitive cycles against the focus objective
   → Sub-agents dispatched as needed (researcher, coder, writer)
   → D' gates on all outputs
   → Respect max_cycles and max_tokens budget
5. Evaluate session outcome
   → Update task steps completed
   → Check phase completion (all tasks in phase done?)
   → Check success criteria (all criteria met?)
6. Plan next session
   → If phase complete: advance to next phase, schedule accordingly
   → If blocked: create Blocker, notify stakeholders, schedule retry
   → If progressing: schedule continuation session
7. Send stakeholder updates (if due)
   → Via comms agent: email/WhatsApp for external stakeholders
   → Via web GUI notification for web-connected stakeholders
8. Persist everything (JSONL, as always)
```

### Self-Scheduling

The Endeavour agent doesn't just execute work — it plans its own schedule:

```gleam
pub type ScheduleDecision {
  /// Continue working — schedule next session
  ContinueWork(focus: String, delay_ms: Int)
  /// Phase complete — advance and schedule
  AdvancePhase(next_phase: String, delay_ms: Int)
  /// Blocked — wait and retry
  WaitForBlocker(blocker_id: String, retry_ms: Int)
  /// Need human input — pause and notify
  RequestHumanInput(question: String, stakeholder: String)
  /// All done
  EndeavourComplete
  /// Give up
  EndeavourFailed(reason: String)
}
```

After each work session, the agent evaluates its progress and makes a scheduling decision. This feeds into the existing scheduler — `schedule_from_spec` creates the next session as a scheduled job.

### Forecaster Integration

The Forecaster evaluates Endeavour health, not just individual task health:

- Phase completion rate vs estimates
- Token burn rate vs budget
- Blocker accumulation
- Scope drift (phases added vs original count)
- Deadline proximity vs remaining work

When health degrades, the Forecaster suggests replanning the entire Endeavour, not just individual tasks.

---

## Human-in-the-Loop

### Approval Gates

Certain transitions require human approval:

```gleam
pub type ApprovalGate {
  PhaseTransition           // Moving to next phase
  BudgetIncrease            // Requesting more cycles/tokens
  ExternalCommunication     // Sending comms to non-operator stakeholders
  Replan                    // Significantly changing the plan
  Completion                // Marking the endeavour done
}
```

Config per endeavour:
```toml
[endeavour.approval]
phase_transition = "auto"        # "auto" | "require_approval"
budget_increase = "require_approval"
external_communication = "auto"  # D' handles safety; approval is for policy
replan = "notify"                # "auto" | "notify" | "require_approval"
completion = "require_approval"
```

### Human Communication

The agent communicates with stakeholders naturally:

**Progress updates** (via comms agent):
```
Subject: Endeavour Update — Q2 Market Analysis (Phase 2/4 Complete)

Phase 2 (Data Collection) is complete. Key findings:
- Collected data from 12 sources across 3 markets
- 2 sources were unavailable (flagged as blockers, resolved by substitution)
- Confidence in EU market data: 0.82. US market data: 0.71 (fewer sources).

Phase 3 (Analysis) begins tomorrow. Estimated 3 work sessions.

Next scheduled update: Friday, or on Phase 3 completion if earlier.
```

**Blocker notifications**:
```
⚠️ Endeavour "Q2 Market Analysis" is blocked.

Blocker: The Gartner report requires a paid subscription I don't have access to.
This data is needed for the competitive positioning section.

I can either:
1. Proceed without Gartner data (lower confidence on market sizing)
2. Wait for you to provide the report
3. Substitute with McKinsey's public estimates

Please advise. Work is paused on this phase until resolved.
```

**Completion reports**:
```
Endeavour "Q2 Market Analysis" is complete.

4 phases, 14 work sessions, 3 replans, 1 blocker resolved.
Success criteria: 3/3 met.
Total tokens: 245,000. Duration: 9 days.

Final report attached. Please review and confirm completion.
```

---

## Web GUI Enhancements

### Endeavours Dashboard (new view, not just a tab)

A dedicated page at `/endeavours` showing all active endeavours with:

**Board View** (default):
```
┌─────────────────────────────────────────────────────┐
│ Q2 Market Analysis                    Active ● 63%  │
│ Phase: Data Collection (2/4)                        │
│ Next session: Tomorrow 09:00                        │
│ Health: ██████████░░ 0.72                          │
│ Blockers: 0  │  Cycles: 42  │  Tokens: 128K       │
├─────────────────────────────────────────────────────┤
│ Three-Paper Integration              Complete ✓     │
│ Completed 2026-03-25                                │
│ 4 phases, 16 steps, 1 replan                       │
├─────────────────────────────────────────────────────┤
│ Infrastructure Upgrade               Blocked ⚠      │
│ Blocker: Waiting for GCP quota approval             │
│ Last activity: 2 days ago                           │
└─────────────────────────────────────────────────────┘
```

### Endeavour Detail View

Click an endeavour to see:

**Phase Timeline**:
```
Phase 1: Planning        ✅ Complete (2 sessions)
Phase 2: Data Collection ✅ Complete (5 sessions)
Phase 3: Analysis        🔄 In Progress (session 2/3 est.)
Phase 4: Report Writing  ⏳ Not started
```

**Work Session History**:
Table of all sessions with: time, phase, focus, cycles used, tokens used, outcome.

**Blocker Log**:
Active and resolved blockers with timestamps and resolutions.

**Stakeholder Updates**:
Sent updates with timestamps, channels, and delivery status.

**Metrics**:
- Progress: phases complete, steps complete, success criteria met
- Budget: cycles used/estimated, tokens used/estimated
- Health: Forecaster score with trend line
- Scope: original vs current phase count, replans

**Actions** (operator):
- Pause / Resume
- Add blocker manually
- Resolve blocker
- Approve phase transition
- Request replan
- Add/remove stakeholders
- Adjust budget
- Mark complete / Mark failed

### Task View Enhancement

Tasks within an endeavour show their phase context:
```
Task: "Collect EU market data"
Endeavour: Q2 Market Analysis
Phase: Data Collection (2/4)
Steps: 3/5 complete
```

### Sensorium Enhancement

The sensorium's `<tasks>` section gains endeavour context:

```xml
<endeavours active="2" blocked="1">
  <endeavour name="Q2 Market Analysis" phase="Analysis" health="0.72"
             next_session="2026-03-27T09:00:00Z" progress="63%"/>
  <endeavour name="Infrastructure Upgrade" status="blocked"
             blocker="Waiting for GCP quota" days_blocked="2"/>
</endeavours>
```

---

## Planner Integration

### Endeavour Creation

When the operator gives a large goal, the Planner agent creates an Endeavour (not just a Task):

```
User: "Research the 2027 agentic AI market, analyse Springdrift's position,
       and produce a report with recommendations. Take your time —
       I need this done properly over the next week."

Planner creates:
  Endeavour: "2027 Agentic AI Market Analysis"
  Goal: "Comprehensive market report with competitive positioning"
  Success criteria:
    - Market size data from 3+ sources
    - Competitive comparison table (5+ competitors)
    - Springdrift positioning recommendations with evidence
  Phases:
    1. Market research (3 sessions)
    2. Competitor analysis (2 sessions)
    3. Springdrift positioning (2 sessions)
    4. Report writing and review (2 sessions)
  Session cadence: Weekdays 09:00
  Stakeholder: operator (web, on_milestone)
```

### Trigger: Size and Scope

The Planner decides Task vs Endeavour based on:
- Estimated work > 5 cycles → Endeavour
- Multiple independent phases → Endeavour
- Deadline > 1 day away → Endeavour
- Operator language ("take your time", "over the next week", "long-term") → Endeavour

### Replan

When the Forecaster flags an Endeavour, the Planner is invoked to revise the plan:
- Remaining phases re-estimated
- Failed tasks decomposed differently
- Blocked phases rerouted if possible
- Budget reallocated across remaining phases

---

## Persistence

All Endeavour data in append-only JSONL:
```
.springdrift/memory/planner/YYYY-MM-DD-endeavours.jsonl
```

Enhanced operations:
```gleam
pub type EndeavourOp {
  CreateEndeavour(endeavour: Endeavour)
  UpdatePhase(endeavour_id: String, phase: String, status: PhaseStatus)
  AddBlocker(endeavour_id: String, blocker: Blocker)
  ResolveBlocker(endeavour_id: String, blocker_id: String, resolution: String)
  RecordSession(endeavour_id: String, session: WorkSession)
  ScheduleSession(endeavour_id: String, session: WorkSession)
  SendUpdate(endeavour_id: String, stakeholder: String, channel: String, content: String)
  Replan(endeavour_id: String, reason: String, new_phases: List(Phase))
  ChangeStatus(endeavour_id: String, status: EndeavourStatus)
  AddStakeholder(endeavour_id: String, stakeholder: Stakeholder)
}
```

Current state derived by replaying operations — consistent with existing append-only pattern.

---

## Tools

### New Tools

| Tool | Purpose |
|---|---|
| `create_endeavour_v2` | Create with phases, schedule, stakeholders |
| `plan_endeavour` | Generate phases and schedule from a goal description |
| `get_endeavour_detail` | Full status: phases, blockers, sessions, metrics |
| `schedule_work_session` | Schedule the next work session for an endeavour |
| `report_blocker` | Record a blocker, optionally notify stakeholders |
| `resolve_blocker` | Mark a blocker resolved |
| `advance_phase` | Mark current phase complete, advance to next |
| `send_stakeholder_update` | Compose and send an update via comms agent |
| `request_approval` | Ask a stakeholder to approve a gate transition |
| `replan_endeavour` | Invoke the Planner to revise remaining phases |

### Updated Tools

| Tool | Change |
|---|---|
| `get_active_work` | Shows endeavour context for each task |
| `complete_task_step` | Checks phase completion after step completes |
| `flag_risk` | Can flag risk at endeavour level, not just task |
| `abandon_task` | Checks if this blocks the endeavour's current phase |

---

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | Enhanced Endeavour type with phases, sessions, stakeholders | Medium |
| 2 | Endeavour persistence (new operations, JSONL) | Medium |
| 3 | Self-scheduling: session planning and scheduler integration | Medium |
| 4 | Planner integration: Task vs Endeavour decision, phase generation | Medium |
| 5 | Forecaster integration: endeavour-level health evaluation | Small |
| 6 | Blocker management: detection, tracking, notification | Medium |
| 7 | Stakeholder communication via comms agent | Medium — depends on comms agent |
| 8 | Approval gates | Small |
| 9 | Web GUI: Endeavours dashboard | Large |
| 10 | Web GUI: Endeavour detail view | Large |
| 11 | Sensorium: endeavour context | Small |
| 12 | Tools: new + updated | Medium |

---

## What This Enables

A user says: "Research the competitive landscape for AI agents in legal, produce a report, and send it to the team by Friday."

The agent:
1. Creates an Endeavour with 4 phases (research, analysis, writing, review)
2. Schedules work sessions across the week
3. Runs research autonomously during scheduled sessions
4. Sends a progress update on Wednesday
5. Hits a blocker (paywalled source) — notifies the operator via WhatsApp
6. Operator resolves the blocker by providing the document
7. Agent continues, adapts the plan for lost time
8. Produces the report Thursday evening
9. Output gate reviews quality — MODIFY for unsourced claims
10. Agent revises with proper citations
11. Sends final report to the team via email Friday morning
12. Requests operator confirmation to mark complete

That's not a chatbot. That's a knowledge worker.
