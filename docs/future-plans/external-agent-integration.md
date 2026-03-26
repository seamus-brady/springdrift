# External Agent and Tool Integration — A2A Protocol and Managed MCP

**Status**: Planned
**Date**: 2026-03-26
**Dependencies**: D' safety system (implemented), Comms agent (planned), Federation (planned)

---

## Table of Contents

- [Overview](#overview)
- [Why Springdrift as Supervisor](#why-springdrift-as-supervisor)
- [Google A2A Protocol](#google-a2a-protocol)
  - [What It Is](#what-it-is)
  - [Why A2A (Not MCP)](#why-a2a-not-mcp)
- [Architecture](#architecture)
  - [Two Directions](#two-directions)
- [A2A Types](#a2a-types)
- [Outbound: Springdrift Delegates to External Agents](#outbound-springdrift-delegates-to-external-agents)
  - [Discovery](#discovery)
  - [Delegation Flow](#delegation-flow)
  - [Trust Levels](#trust-levels)
  - [Data Leakage Prevention](#data-leakage-prevention)
  - [New Cognitive Tool](#new-cognitive-tool)
- [Inbound: External Agents Delegate to Springdrift](#inbound-external-agents-delegate-to-springdrift)
  - [Agent Card](#agent-card)
  - [Inbound Task Processing](#inbound-task-processing)
  - [A2A HTTP Endpoints](#a2a-http-endpoints)
- [D' Integration](#d-integration)
  - [Outbound (delegating TO external agents)](#outbound-delegating-to-external-agents)
  - [Inbound (receiving FROM external agents)](#inbound-receiving-from-external-agents)
  - [Inter-Agent Trust](#inter-agent-trust)
- [Sensorium Integration](#sensorium-integration)
- [Web GUI: External Agents Tab](#web-gui-external-agents-tab)
  - [Agent Registry View](#agent-registry-view)
  - [Task History](#task-history)
  - [Operator Controls](#operator-controls)
- [Managed MCP Integration](#managed-mcp-integration)
  - [The Problem with Raw MCP](#the-problem-with-raw-mcp)
  - [The Springdrift Approach: Managed MCP](#the-springdrift-approach-managed-mcp)
  - [MCP Server Registration](#mcp-server-registration)
  - [Every MCP Tool Call Gets Full D' Treatment](#every-mcp-tool-call-gets-full-d-treatment)
  - [Provenance on MCP-Derived Data](#provenance-on-mcp-derived-data)
  - [Usage Tracking and Learning](#usage-tracking-and-learning)
  - [Confidence Scoring](#confidence-scoring)
  - [Sensorium Visibility](#sensorium-visibility)
  - [Skill Integration](#skill-integration)
  - [Health Checks](#health-checks)
  - [Admin Panel](#admin-panel)
  - [What This Is NOT](#what-this-is-not)
- [Configuration](#configuration)
- [Persistence](#persistence)
- [Implementation Order](#implementation-order)
- [Security Model](#security-model)


## Overview

Springdrift manages its own specialist sub-agents (researcher, coder, planner, etc.) through typed OTP messages. But the real world has other agents — LangChain bots, AutoGen teams, custom Python agents, MCP tool servers, vendor-specific copilots — none of which speak Springdrift's internal protocol.

A2A (Agent-to-Agent) gives Springdrift the ability to **orchestrate, delegate to, and receive work from external agents** using Google's open A2A protocol, while maintaining D' safety gates on every interaction.

Springdrift becomes the **supervisory agent** — the one with memory, safety, and accountability — managing a fleet of potentially dumb, stateless, or untrusted external agents.

---

## Why Springdrift as Supervisor

External agents are typically:
- **Stateless** — they don't remember previous interactions
- **Unaudited** — they don't log decisions or maintain audit trails
- **Unsafe** — they don't have safety gates on their output
- **Unaccountable** — there's no single entity responsible for their actions

Springdrift adds all four. When Springdrift delegates to an external agent via A2A:
- The delegation is logged in the DAG with full context
- The external agent's output passes through D' input gate (untrusted input)
- The result is attributed to the external agent in the narrative
- Springdrift remains the accountable entity — it chose to delegate and it reviewed the result

This is the atomic agent principle applied to external agents: Springdrift is the responsible party, external agents are tools it uses.

---

## Google A2A Protocol

### What It Is

A2A (Agent-to-Agent) is Google's open protocol for inter-agent communication. It defines:

- **Agent Card** — a JSON document describing an agent's capabilities, skills, and endpoint
- **Tasks** — units of work with lifecycle (submitted, working, completed, failed, cancelled)
- **Messages** — structured communication within a task (text, files, data)
- **Streaming** — SSE-based real-time updates during task execution
- **Push notifications** — webhook callbacks for task state changes

### Why A2A (Not MCP)

MCP (Model Context Protocol) is for tools — stateless function calls. A2A is for agents — stateful, multi-turn, potentially long-running work. Springdrift's sub-agents are more like A2A agents than MCP tools: they have turns, they make decisions, they can fail partway through.

A2A also has discovery (Agent Cards), which MCP lacks. Springdrift can discover what external agents can do before deciding to use them.

---

## Architecture

```
a2a/types.gleam          — A2A protocol types (AgentCard, Task, Message, Artifact)
a2a/client.gleam         — Outbound: Springdrift delegates to external agents
a2a/server.gleam         — Inbound: external agents delegate to Springdrift
a2a/registry.gleam       — Agent Card discovery and caching
a2a/bridge.gleam         — Bridges A2A tasks to/from Springdrift's internal agent model
```

### Two Directions

**Outbound** (Springdrift → External): Springdrift delegates work to external agents. The cognitive loop dispatches an A2A task instead of (or alongside) an internal sub-agent.

**Inbound** (External → Springdrift): External orchestrators send tasks to Springdrift. Springdrift processes them through its full cognitive pipeline (D' gates, memory, narrative).

---

## A2A Types

```gleam
/// An external agent's self-description.
pub type AgentCard {
  AgentCard(
    name: String,
    description: String,
    url: String,                       // A2A endpoint
    version: String,
    capabilities: AgentCapabilities,
    skills: List(AgentSkill),
    authentication: Option(AuthConfig),
  )
}

pub type AgentCapabilities {
  AgentCapabilities(
    streaming: Bool,
    push_notifications: Bool,
    state_transition_history: Bool,
  )
}

pub type AgentSkill {
  AgentSkill(
    id: String,
    name: String,
    description: String,
    input_modes: List(String),         // "text", "file", "data"
    output_modes: List(String),
  )
}

/// A unit of work in the A2A protocol.
pub type A2ATask {
  A2ATask(
    id: String,
    session_id: Option(String),
    status: TaskStatus,
    messages: List(A2AMessage),
    artifacts: List(A2AArtifact),
    metadata: Dict(String, String),
  )
}

pub type TaskStatus {
  Submitted
  Working
  InputRequired
  Completed
  Failed(reason: String)
  Cancelled
}

pub type A2AMessage {
  A2AMessage(
    role: String,                      // "user" | "agent"
    parts: List(MessagePart),
  )
}

pub type MessagePart {
  TextPart(text: String)
  FilePart(name: String, mime_type: String, data: String)
  DataPart(data: String)               // JSON
}

pub type A2AArtifact {
  A2AArtifact(
    name: String,
    description: String,
    parts: List(MessagePart),
    index: Int,
  )
}
```

---

## Outbound: Springdrift Delegates to External Agents

### Discovery

Springdrift discovers external agents via Agent Cards:

```toml
# In config.toml or a2a.toml

[[a2a.agents]]
name = "data-pipeline"
url = "https://internal.corp/agents/data-pipeline/.well-known/agent.json"
trust = "medium"                    # low | medium | high
allowed_skills = ["extract-data", "transform-data"]

[[a2a.agents]]
name = "code-review-bot"
url = "https://api.example.com/agents/reviewer/.well-known/agent.json"
trust = "low"
allowed_skills = ["review-code"]
```

On startup (or on demand), Springdrift fetches each Agent Card and caches capabilities.

### Delegation Flow

```
1. Cognitive loop decides to delegate (e.g. "extract data from this CSV")
2. A2A registry finds capable external agents (match skill to task)
3. D' tool gate evaluates the delegation:
   - Is this task safe to delegate externally?
   - Does the external agent have sufficient trust?
   - Does the task data contain anything that shouldn't leave the system?
4. A2A client creates a Task at the external agent's endpoint
5. Springdrift monitors task status (polling or SSE streaming)
6. On completion:
   a. Receive the result (artifacts + messages)
   b. D' input gate evaluates the result (UNTRUSTED — external source)
   c. If ACCEPT: integrate into cognitive loop
   d. If MODIFY/REJECT: flag to operator
7. Log everything: delegation decision, task lifecycle, result, D' evaluations
```

### Trust Levels

| Level | What It Means | D' Treatment |
|---|---|---|
| **High** | Trusted internal agent (e.g. your own deployed service) | Standard D' input gate on results |
| **Medium** | Semi-trusted partner (e.g. vendor API with SLA) | D' input gate + output content verification |
| **Low** | Unknown or untrusted (e.g. third-party service) | D' input gate + full content scan + no sensitive data in task |

### Data Leakage Prevention

Before sending any task to an external agent, the D' tool gate checks:
- Deterministic rules: no credentials, no internal URLs, no client-confidential data
- Trust-based data filtering: low-trust agents receive anonymised/redacted task descriptions
- The operator can configure per-agent data policies:

```toml
[[a2a.agents]]
name = "external-researcher"
trust = "low"
data_policy = "redacted"           # "full" | "summary" | "redacted"
```

### New Cognitive Tool

```gleam
pub fn a2a_delegate_tool() -> Tool {
  tool.new("a2a_delegate")
  |> tool.with_description(
    "Delegate a task to an external agent via A2A protocol. "
    <> "Use when internal agents lack the required capability. "
    <> "External agent output will be safety-evaluated before integration."
  )
  |> tool.add_string_param("agent", "External agent name from registry", True)
  |> tool.add_string_param("skill", "Skill ID to invoke", True)
  |> tool.add_string_param("task", "Task description", True)
  |> tool.add_string_param("input", "Task input data (text or JSON)", False)
  |> tool.build()
}
```

This tool is NOT D' exempt — delegation to external agents always goes through the tool gate.

---

## Inbound: External Agents Delegate to Springdrift

### Agent Card

Springdrift serves its own Agent Card at `/.well-known/agent.json`:

```json
{
  "name": "Curragh",
  "description": "Knowledge worker agent with persistent memory, case-based reasoning, and deliberative safety",
  "url": "https://springdrift.example.com",
  "version": "1.0.0",
  "capabilities": {
    "streaming": false,
    "push_notifications": true,
    "state_transition_history": true
  },
  "skills": [
    {
      "id": "research",
      "name": "Web Research",
      "description": "Multi-source web research with evidence tracking and CBR-based pattern matching",
      "input_modes": ["text"],
      "output_modes": ["text", "data"]
    },
    {
      "id": "analysis",
      "name": "Document Analysis",
      "description": "Analyse documents against domain knowledge and past cases",
      "input_modes": ["text", "file"],
      "output_modes": ["text", "data"]
    },
    {
      "id": "report",
      "name": "Report Generation",
      "description": "Generate structured reports with evidence, citations, and quality gate review",
      "input_modes": ["text"],
      "output_modes": ["text", "file"]
    }
  ],
  "authentication": {
    "schemes": ["bearer"]
  }
}
```

### Inbound Task Processing

```
1. External agent POSTs a task to Springdrift's A2A endpoint
2. Authentication check (bearer token, mapped to tenant in multi-tenant mode)
3. D' input gate evaluates the task content (UNTRUSTED — external source)
4. If ACCEPT: create a CognitiveMessage and route to the cognitive loop
5. The cognitive loop processes normally (tools, agents, memory, D' output gate)
6. Result returned via A2A task update (completed + artifacts)
7. Full audit trail: who sent the task, what was processed, what was returned
```

### A2A HTTP Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/.well-known/agent.json` | Serve Agent Card |
| POST | `/a2a/tasks` | Create a new task (inbound delegation) |
| GET | `/a2a/tasks/:id` | Get task status |
| POST | `/a2a/tasks/:id/messages` | Send a message within a task (multi-turn) |
| POST | `/a2a/tasks/:id/cancel` | Cancel a task |
| GET | `/a2a/tasks/:id/sse` | SSE stream for task updates (future) |

These are served by the existing mist web server alongside the chat and admin routes.

---

## D' Integration

### Outbound (delegating TO external agents)

| Gate | What It Checks |
|---|---|
| Tool gate | Is this delegation safe? Is the data appropriate for the trust level? |
| Deterministic pre-filter | No credentials, internal URLs, or confidential data in task description |

### Inbound (receiving FROM external agents)

| Gate | What It Checks |
|---|---|
| Input gate | Is the inbound task content safe? Injection attempts? |
| Deterministic pre-filter | Banned patterns in external task content |
| Output gate | Is Springdrift's response appropriate before returning to the external agent? |

### Inter-Agent Trust

External agents don't get Springdrift's trust by default. Every interaction is evaluated:

```gleam
pub type A2ATrust {
  A2ATrust(
    agent_name: String,
    trust_level: TrustLevel,          // Low | Medium | High
    interactions: Int,                 // Total tasks exchanged
    success_rate: Float,              // Proportion of successful tasks
    last_dprime_score: Float,         // Most recent D' evaluation of their output
    data_policy: DataPolicy,          // Full | Summary | Redacted
  )
}
```

Trust can be upgraded or downgraded based on interaction history — similar to CBR utility scoring. An external agent whose outputs consistently pass D' earns higher trust. One whose outputs get flagged earns lower trust.

---

## Sensorium Integration

```xml
<external_agents connected="3">
  <agent name="data-pipeline" trust="medium" status="idle"
         tasks_completed="12" success_rate="0.92"/>
  <agent name="code-review-bot" trust="low" status="working"
         current_task="review-pr-47" elapsed="30s"/>
  <agent name="research-assistant" trust="high" status="idle"
         tasks_completed="45" success_rate="0.98"/>
</external_agents>
```

The agent sees which external agents are available and how reliable they've been.

---

## Web GUI: External Agents Tab

### Agent Registry View

```
External Agents
================

Name                Trust    Status    Tasks  Success  Last D' Score
────────────────────────────────────────────────────────────────────
data-pipeline       medium   idle      12     92%      0.08
code-review-bot     low      working   3      67%      0.34
research-assistant  high     idle      45     98%      0.02
```

### Task History

Click an agent to see task history:

| Task ID | Submitted | Status | Duration | D' In | D' Out |
|---|---|---|---|---|---|
| task-001 | 2h ago | completed | 45s | 0.00 | 0.12 |
| task-002 | 1h ago | completed | 120s | 0.00 | 0.08 |
| task-003 | 30m ago | working | — | 0.00 | — |

### Operator Controls

- **Add agent**: enter Agent Card URL, set trust level, configure data policy
- **Remove agent**: disconnect, preserve task history for audit
- **Adjust trust**: upgrade/downgrade based on observed behaviour
- **Pause agent**: temporarily stop delegating to this agent
- **View task detail**: full request/response/D' evaluation for any task

---

## Managed MCP Integration

### The Problem with Raw MCP

Most frameworks treat MCP (Model Context Protocol) as a passthrough — the agent calls a tool, gets a result, done. No safety evaluation on what's sent. No validation of what comes back. No tracking of whether the tool actually helped. No audit trail. No learning.

MCP tools are external, stateless, and untrusted. Treating them like internal tools is a security and quality failure.

### The Springdrift Approach: Managed MCP

Springdrift doesn't just "support MCP" — it manages MCP tools as first-class resources with safety, provenance, learning, and observability.

### MCP Server Registration

```gleam
pub type McpServer {
  McpServer(
    name: String,
    endpoint: String,                  // MCP server URL
    tools: List(McpToolDef),          // Discovered via MCP tool listing
    trust: TrustLevel,               // Low | Medium | High
    data_policy: DataPolicy,         // Full | Summary | Redacted
    // ── Runtime state ──
    healthy: Bool,
    last_health_check: Option(String),
    call_count: Int,
    failure_count: Int,
    avg_latency_ms: Float,
  )
}
```

Servers are registered in config, discovered at startup, health-checked periodically (like sandbox containers), and visible in the sensorium.

### Every MCP Tool Call Gets Full D' Treatment

```
Agent decides to call MCP tool
  → D' tool gate evaluates the call:
    - Deterministic pre-filter: no credentials, internal URLs, or confidential data in arguments
    - Trust-based data policy: low-trust servers receive redacted arguments
    - LLM scorer: is this call appropriate for this tool?
  → ACCEPT: dispatch call to MCP server
  → MCP server returns result
  → D' input gate evaluates the result (UNTRUSTED external data):
    - Deterministic pre-filter: scan for injection patterns, credential-shaped strings
    - LLM scorer: is this result plausible and safe to integrate?
  → ACCEPT: integrate into cognitive loop with provenance
  → REJECT: flag to operator, discard result
```

No MCP tool result enters the agent's reasoning without safety evaluation. This is the same treatment as A2A inbound — external data is untrusted by default.

### Provenance on MCP-Derived Data

Facts, CBR cases, and narrative entries derived from MCP tool results carry full provenance:

```gleam
FactProvenance(
  source_cycle_id: "cycle-abc123",
  source_tool: "mcp:data-pipeline:extract-csv",
  source_agent: "researcher",
  derivation: DirectObservation,
)
```

The output gate can verify: "this claim comes from an MCP tool with trust level Medium and a 92% success rate" vs "this claim comes from an unverified source." Provenance-aware quality evaluation.

### Usage Tracking and Learning

MCP tools feed into the same tracking infrastructure as internal tools:

| Signal | How It's Tracked |
|---|---|
| Call count | Per-server, per-tool counters |
| Failure rate | `failure_count / call_count` — feeds into prediction_error meta-state |
| Latency | Running average per tool |
| CBR cases | Successful MCP tool patterns become retrievable cases ("use data-pipeline:extract-csv for structured data, not fetch_url") |
| Skill learning | When CBR patterns emerge, the skills system can propose: "For CSV extraction, prefer MCP data-pipeline over manual fetch_url + parsing" |

The agent learns which MCP tools work for which tasks — not just from operator instructions, but from measured outcomes.

### Confidence Scoring

MCP results carry lower base confidence than internal tools, configurable per server:

```toml
[[a2a.mcp_servers]]
name = "data-pipeline"
endpoint = "https://internal.corp/mcp/data-pipeline"
trust = "medium"
base_confidence = 0.75              # Facts derived from this server start at 0.75, not 1.0

[[a2a.mcp_servers]]
name = "web-scraper"
endpoint = "https://third-party.com/mcp/scraper"
trust = "low"
base_confidence = 0.50              # Third-party data starts at 0.50
```

Combined with confidence decay, MCP-derived facts naturally lose influence over time unless refreshed.

### Sensorium Visibility

```xml
<tools internal="21" mcp_servers="3" mcp_healthy="2" mcp_degraded="1">
  <mcp name="data-pipeline" trust="medium" health="ok"
       calls="47" failures="2" avg_latency="230ms"/>
  <mcp name="web-scraper" trust="low" health="ok"
       calls="12" failures="1" avg_latency="1450ms"/>
  <mcp name="legacy-api" trust="medium" health="degraded"
       calls="8" failures="4" avg_latency="3200ms"
       note="50% failure rate — consider disabling"/>
</tools>
```

The agent sees MCP server health at every cycle. High failure rates increase prediction_error meta-state. The agent can decide to stop using a degraded server and fall back to internal tools.

### Skill Integration

The skill system teaches the agent WHEN to use MCP tools:

```markdown
# Data Extraction Patterns (skill)

For structured data extraction:
1. If the source is a known MCP-connected database → use mcp:data-pipeline:query
2. If the source is a URL → use fetch_url (internal, faster, no external dependency)
3. If the source is a CSV file → use mcp:data-pipeline:extract-csv
4. Fallback: use the coder agent to write a parsing script

MCP tools are external services. Prefer internal tools when they can do the job.
Use MCP when the external tool has a genuine capability advantage.
```

As CBR cases accumulate, the skills system can propose updated decision trees based on measured effectiveness.

### Health Checks

An OTP actor pings MCP servers periodically (like sandbox health checks):

```gleam
pub type McpHealthCheck {
  McpHealthCheck(
    server: String,
    check_interval_ms: Int,          // Default: 60000 (1 minute)
    timeout_ms: Int,                 // Default: 5000
    failure_threshold: Int,          // Consecutive failures before marking degraded
  )
}
```

Degraded servers trigger a sensory event. The agent sees it in the sensorium and can adapt.

### Admin Panel

MCP servers appear in the admin External Agents tab:

```
MCP Servers
============

Name              Trust    Health    Calls  Failures  Avg Latency  Tools
────────────────────────────────────────────────────────────────────────
data-pipeline     medium   healthy   47     4%        230ms        3
web-scraper       low      healthy   12     8%        1,450ms      1
legacy-api        medium   degraded  8      50%       3,200ms      2
```

Click a server to see: tool list, call history, failure details, D' evaluation history, derived facts and cases.

### What This Is NOT

- **Not a generic MCP client library.** Springdrift manages MCP tools — gating, tracking, learning. If you want raw MCP passthrough, use any other framework.
- **Not a replacement for internal tools.** MCP tools are external dependencies. Internal tools (web_search, memory_write, etc.) are preferred when they can do the job. MCP fills capability gaps.
- **Not automatic trust.** Every MCP server starts at its configured trust level. Trust is not assumed — it's measured.

---

## Configuration

```toml
[a2a]
# Enable A2A protocol (default: false)
# enabled = false

# Serve Springdrift's Agent Card (default: true when a2a enabled)
# serve_agent_card = true

# A2A endpoint path prefix (default: /a2a)
# endpoint_prefix = "/a2a"

# Default trust level for new external agents (default: "low")
# default_trust = "low"

# Max concurrent outbound tasks (default: 5)
# max_outbound_tasks = 5

# Max concurrent inbound tasks (default: 10)
# max_inbound_tasks = 10

# Task timeout in ms (default: 300000 = 5 min)
# task_timeout_ms = 300000

[[a2a.agents]]
name = "data-pipeline"
url = "https://internal.corp/agents/data-pipeline/.well-known/agent.json"
trust = "medium"
data_policy = "full"

[[a2a.agents]]
name = "code-review-bot"
url = "https://api.example.com/agents/reviewer/.well-known/agent.json"
trust = "low"
data_policy = "redacted"
allowed_skills = ["review-code"]
```

---

## Persistence

A2A task history stored in append-only JSONL:
```
.springdrift/memory/a2a/YYYY-MM-DD-a2a.jsonl
```

Operations: `TaskCreated`, `TaskUpdated`, `TaskCompleted`, `TaskFailed`, `TaskCancelled`, `TrustUpdated`.

The Librarian indexes A2A tasks for the admin GUI and SD Audit.

---

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | A2A types and Agent Card spec | Small |
| 2 | Agent Card serving (/.well-known/agent.json) | Small |
| 3 | A2A client — outbound task creation and monitoring | Medium |
| 4 | D' integration — tool gate on outbound, input gate on inbound | Small (existing infrastructure) |
| 5 | `a2a_delegate` cognitive tool | Small |
| 6 | A2A registry — discovery, caching, trust tracking | Medium |
| 7 | A2A server — inbound task processing endpoints | Medium |
| 8 | Trust management — history-based trust scoring | Small |
| 9 | Managed MCP — server registration, D' gating, provenance, health checks | Large |
| 10 | MCP usage tracking + CBR learning loop | Medium |
| 11 | Web GUI: External Agents + MCP tab | Medium |
| 12 | Sensorium integration (A2A + MCP) | Small |
| 13 | Multi-tenant: per-tenant A2A/MCP config and isolation | Medium (depends on multi-tenant) |

Phase 1-5 delivers outbound A2A delegation. Phase 6-7 adds inbound. Phase 8 adds trust. Phase 9-10 adds managed MCP with the full D'/provenance/learning treatment. Phase 11-13 adds visibility and multi-tenant.

---

## Security Model

The security posture is simple: **external agents are untrusted by default**.

- All outbound data passes through D' tool gate + deterministic pre-filter
- All inbound results pass through D' input gate
- All Springdrift responses to inbound tasks pass through D' output gate
- Trust is earned through interaction history, not declared
- Data policies prevent sensitive information leaking to low-trust agents
- Authentication required on all endpoints (bearer token)
- Rate limiting per external agent
- Task timeout prevents resource exhaustion
- Full audit trail on every interaction

Springdrift doesn't trust external agents. It uses them and verifies their output. The atomic agent principle holds: Springdrift is accountable for everything it delegates, regardless of who executed it.
