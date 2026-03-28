# Self-Diagnostic Skill — Specification

**Status**: Planned
**Date**: 2026-03-26
**Source**: Curragh's self-analysis (agent-originated requirement)
**Dependencies**: Skills management (planned), Scheduler (implemented), Sensorium (implemented)

---

## Table of Contents

- [Origin](#origin)
- [The Insight: Composition Over Construction](#the-insight-composition-over-construction)
- [What to Build](#what-to-build)
  - [A Diagnostic Skill, Not a Diagnostic Tool](#a-diagnostic-skill-not-a-diagnostic-tool)
  - [skill.toml](#skilltoml)
  - [SKILL.md](#skillmd)
- [Trigger Integration](#trigger-integration)
  - [On Boot](#on-boot)
  - [On Schedule](#on-schedule)
  - [On Anomaly](#on-anomaly)
- [Sensorium Integration](#sensorium-integration)
- [Observer Agent Role](#observer-agent-role)
- [What This Is NOT](#what-this-is-not)
- [Relationship to Other Components](#relationship-to-other-components)
- [Implementation Order](#implementation-order)
- [Why This Matters](#why-this-matters)


## Origin

This spec originates from the agent itself. Curragh is the development and test instance of Springdrift — the first and longest-running installation, used to validate the framework under real operating conditions. When asked "do you need a dedicated self-diagnostic tool?", Curragh analysed its own capabilities and concluded:

> "No, I don't need a new tool. I need the scheduler (so diagnostics can run without you asking), and possibly the skill store (so I can save the diagnostic pattern rather than reinventing it each time). A dedicated diagnostic tool would be redundant — it'd just be a hardcoded version of what I can already compose from the tools I have. And a composed version is better, because I can adapt it as the system changes."

This is the correct analysis. The diagnostic capability already exists as composable tools. What's missing is the pattern — a stored, schedulable, self-adapting routine that uses those tools systematically.

---

## The Insight: Composition Over Construction

Curragh can already run a comprehensive self-diagnostic by composing existing tools:

| Step | Tool | What It Checks |
|---|---|---|
| 1 | `introspect` | Agent roster, identity, D' config, sandbox status |
| 2 | `reflect` | Cycle counts, success rates, token usage, model distribution |
| 3 | `list_recent_cycles` | Cycle persistence — are cycles being logged correctly? |
| 4 | `query_tool_activity` | Per-tool telemetry — failures, latency, usage patterns |
| 5 | `memory_query_facts` | Memory health — fact count, scope distribution |
| 6 | `recall_threads` | Thread health — active threads, orphan detection |
| 7 | `recall_cases` | CBR quality — case count, category distribution, utility scores |
| 8 | `memory_write` → `memory_read` → `memory_clear_key` | Memory round-trip test |

The agent composed all of these in a single cycle to produce a diagnostic report. No new tools were needed.

**What's missing is not capability — it's automation.**

---

## What to Build

### A Diagnostic Skill, Not a Diagnostic Tool

```
.springdrift/skills/self-diagnostic/
├── SKILL.md
└── skill.toml
```

The skill defines the diagnostic PATTERN — what to check, in what order, what constitutes an anomaly, and how to report findings. The agent executes it using existing tools.

### skill.toml

```toml
id = "self-diagnostic"
name = "System Self-Diagnostic"
description = "Composable health check routine using existing introspection tools"
version = 1
status = "active"

[scoping]
agents = ["cognitive", "observer"]
contexts = ["diagnostic", "health", "all"]

[triggers]
on_boot = true                     # Run at session start
schedule = "daily"                 # Run daily via scheduler
on_anomaly = true                  # Run when sensorium flags degradation
```

### SKILL.md

```markdown
# System Self-Diagnostic

Run this diagnostic when: starting a new session, on daily schedule,
or when the sensorium shows elevated prediction_error or uncertainty.

## Procedure

### 1. System State Check
Call `introspect`. Verify:
- All 5 specialist agents are Running (planner, researcher, coder, writer, observer)
- D' is enabled with expected feature counts
- Sandbox status matches config (enabled/disabled)
- Agent UUID and session start are present

Flag: any agent not Running, D' disabled unexpectedly, sandbox mismatch.

### 2. Cycle Persistence Check
Call `reflect` for today and `list_recent_cycles` for today.
Verify:
- Cycle count from reflect matches cycle count from list_recent_cycles
- No gaps in cycle sequence
- Success rate is above 70%
- Token usage is within budget

Flag: count mismatch (cycles lost), success rate below 50%, budget exceeded.

### 3. Tool Health Check
Call `query_tool_activity` for today. Verify:
- No tool has failure rate above 20%
- All expected tools appear (memory, web, sandbox if enabled)
- No tool shows zero calls if it should have been used

Flag: high failure rate tools, missing tools, dead tools.

### 4. Memory Health Check
Call `memory_query_facts` with keyword "*". Verify:
- Fact count is non-zero (unless first session)
- Persistent facts exist
- No fact has been written and immediately deleted (conflict indicator)

Call `recall_threads`. Verify:
- At least one thread exists (unless first session)
- No thread has >100 entries without a summary

Call `recall_cases` with broad query. Verify:
- Case count is non-zero (unless first session)
- Categories are distributed (not all one type)
- Utility scores show variance (not all 0.5 — meaning feedback loop is working)

Flag: empty memory on established session, all-same categories, uniform utility scores.

### 5. Memory Round-Trip Test
Write a test fact: key="diagnostic_probe", value="probe_[timestamp]", scope=ephemeral
Read it back. Verify value matches.
Clear it. Verify it's gone.

Flag: write failure, read mismatch, clear failure.

### 6. D' Gate Health Check
Check today's reflect data for D' gate decisions.
Verify:
- Input gate has evaluated at least one input
- No gate has 100% rejection rate (unless session just started)
- Deterministic blocks are a minority of total blocks (if most blocks are deterministic, the LLM scorer may be failing)

Flag: zero evaluations, 100% rejection, all-deterministic blocks.

### 7. Meta-State Assessment
Read sensorium vitals (from introspect). Verify:
- Uncertainty is below 0.8 (unless first session — everything is novel)
- Prediction error is below 0.5
- If both are high: the agent is struggling and should report to operator

Flag: uncertainty > 0.8, prediction_error > 0.5, both elevated simultaneously.

## Reporting

Store diagnostic results as a session-scope fact:
  key: "last_diagnostic"
  value: JSON summary of findings
  confidence: 1.0
  scope: session

If any flags fired:
- Store each flag as a session fact: "diagnostic_flag_[name]"
- If critical flags (memory failure, all agents down, D' disabled):
  Surface to operator via sensorium events

If no flags:
- Store "diagnostic_status: healthy" as session fact

## Adaptation

This skill is a starting point. As the system evolves:
- New tools should be incorporated (comms health, federation peer status)
- Thresholds should be tuned based on operational experience
- The CBR system will capture which diagnostic patterns actually predict problems
- Eventually this skill may be auto-updated from CBR patterns via the skills learning loop
```

---

## Trigger Integration

### On Boot

When the agent starts a session, the Curator checks for `on_boot = true` skills and injects them as a sensory event:

```gleam
SensoryEvent(
  name: "boot_diagnostic",
  title: "Run boot-time self-diagnostic",
  body: "The self-diagnostic skill is configured to run at session start.",
  fired_at: now,
)
```

The agent sees this in the sensorium `<events>` section and runs the diagnostic as its first action.

### On Schedule

A scheduler job fires the diagnostic daily:

```toml
[[task]]
name = "daily-diagnostic"
kind = "recurring"
interval_ms = 86400000
query = "Run the self-diagnostic skill and report any findings"
```

### On Anomaly

The meta observer or sensorium vitals trigger the diagnostic when meta-states indicate degradation:

```gleam
// In meta observer or sensorium assembly:
case uncertainty >. 0.8 || prediction_error >. 0.5 {
  True -> emit SensoryEvent("anomaly_diagnostic", "Elevated meta-states detected — run self-diagnostic")
  False -> Nil
}
```

The agent sees the event and decides whether to run the diagnostic skill.

---

## Sensorium Integration

The diagnostic results feed back into the sensorium:

```xml
<vitals cycles_today="12" agents_active="5"
        uncertainty="0.30" prediction_error="0.08" novelty="0.61"
        diagnostic="healthy" last_diagnostic="2h ago"/>
```

When flags are present:
```xml
<vitals cycles_today="12" agents_active="4"
        uncertainty="0.75" prediction_error="0.42" novelty="0.88"
        diagnostic="degraded" last_diagnostic="15m ago"
        diagnostic_flags="agent_down:observer,high_tool_failures:web_search"/>
```

The agent sees its own health status at every cycle without running the diagnostic again.

---

## Observer Agent Role

The Observer agent is the natural executor for diagnostics. It already has all the diagnostic tools (reflect, inspect_cycle, list_recent_cycles, query_tool_activity, etc.) and is designed for system examination.

When the cognitive loop receives a diagnostic trigger (boot, schedule, anomaly):
1. Delegate to the Observer agent with the diagnostic skill as context
2. Observer runs the procedure, collects findings
3. Observer returns structured results to the cognitive loop
4. Cognitive loop stores results as session facts and updates sensorium

This keeps the diagnostic execution out of the main cognitive loop — it's delegated work, like any other agent task.

---

## What This Is NOT

- **Not a monitoring system.** Springdrift is not Prometheus. The diagnostic is the agent examining itself, not an external system watching it.
- **Not a new tool.** Every check uses existing tools. The skill is a pattern, not new capability.
- **Not a hardcoded routine.** The skill is a markdown document that the agent interprets. It can be edited, versioned, and improved like any other skill.
- **Not a replacement for SD Audit.** SD Audit is external, offline, batch analysis by a human. The self-diagnostic is the agent's own real-time health awareness.

---

## Relationship to Other Components

| Component | Relationship |
|---|---|
| Skills management | The diagnostic is a skill — versioned, scoped, with effectiveness tracking |
| Scheduler | Triggers daily and on-demand diagnostic runs |
| Observer agent | Executes the diagnostic procedure via delegation |
| Sensorium | Diagnostic results surface as vitals attributes |
| Meta observer | Anomaly detection triggers diagnostic runs |
| Meta-states | Uncertainty and prediction_error feed into anomaly trigger |
| CBR | Diagnostic outcomes become cases — the system learns which checks predict real problems |
| SD Audit | External verification complements internal self-diagnostic |
| Comms agent (future) | Critical diagnostic flags can be sent to operator via email/WhatsApp |

---

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | Write the SKILL.md and skill.toml | Small — it's a document |
| 2 | Add `on_boot` trigger to Curator (sensory event for boot skills) | Small |
| 3 | Add daily-diagnostic scheduler job (via schedule.toml or operator) | Trivial — existing infrastructure |
| 4 | Add anomaly trigger (meta-state threshold → sensory event) | Small |
| 5 | Add diagnostic status to sensorium vitals | Small |
| 6 | Observer agent delegation for diagnostic execution | Already works — just needs the skill context |

Most of this is configuration, not code. The infrastructure is built. The skill is a document. The triggers use existing mechanisms. The heaviest piece is Phase 5 (sensorium attribute), and that's ~20 lines.

---

## Why This Matters

An agent that can examine itself and report "I'm healthy" or "I'm degraded, here's what's wrong" is fundamentally different from an agent that just runs until it breaks. The self-diagnostic skill is the agent's own awareness of its operational health — Sloman's meta-management layer applied to system integrity, not just safety evaluation.

The fact that Curragh designed this spec itself — identifying what it needs, what it doesn't need, and why composition beats construction — is the capability in action. The agent doesn't need a tool to examine itself. It needs the pattern for when and how to do it.
