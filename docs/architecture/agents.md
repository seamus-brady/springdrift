# Agent Subsystem Architecture

This document covers the agent substrate, specialist agents, teams, tool dispatch,
delegation management, parallel execution, structured output, and error surfacing
in Springdrift.

---

## 1. Agent Substrate

The agent substrate is the infrastructure layer that turns declarative `AgentSpec`
records into supervised, tool-using OTP processes.

### AgentSpec

Defined in `src/agent/types.gleam`. A pure data record describing everything needed
to start an agent:

```gleam
pub type AgentSpec {
  AgentSpec(
    name: String,
    human_name: String,
    description: String,
    system_prompt: String,
    provider: Provider,
    model: String,
    max_tokens: Int,
    max_turns: Int,
    max_consecutive_errors: Int,
    max_context_messages: Option(Int),
    tools: List(Tool),
    restart: RestartStrategy,
    tool_executor: fn(ToolCall) -> ToolResult,
    inter_turn_delay_ms: Int,
    redact_secrets: Bool,
  )
}
```

Key fields:

- `max_turns` -- hard cap on react-loop iterations before the agent must return.
- `max_context_messages` -- when `Some(n)`, `context.trim` is applied per-agent to
  keep context lean (e.g. researcher uses 30 to avoid bloating during multi-turn
  web research).
- `tool_executor` -- a closure capturing dependencies (directories, librarian
  subjects, sandbox managers). This is how agents get access to stateful resources
  without shared mutable state.
- `inter_turn_delay_ms` -- pause between react-loop turns, used to avoid
  rate-limiting.
- `redact_secrets` -- when `True`, tool results are scanned for secrets before
  being added to context.

### Framework (`src/agent/framework.gleam`)

Wraps each `AgentSpec` into a running OTP process with a react loop. The lifecycle:

1. The supervisor sends `StartChild(spec, task)` to launch an agent.
2. `framework.start_agent` spawns an unlinked process with its own message history,
   tool set, and executor closure.
3. The react loop calls the LLM, inspects the response:
   - Tool calls: executes via `tool_executor`, appends results, loops.
   - Text response: agent is done, builds `AgentOutcome`.
   - Max turns reached: returns whatever is available.
4. On completion, sends `AgentComplete(outcome)` back to the cognitive loop.
5. When an agent calls `request_human_input`, the framework routes the question
   through the cognitive loop to the user -- sub-agents cannot directly interact
   with the user.

The framework also handles structured output extraction (`build_findings`) and
context trimming per-agent.

### Supervisor (`src/agent/supervisor.gleam`)

Manages agent lifecycle with three restart strategies:

| Strategy | Behaviour |
|---|---|
| `Permanent` | Always restart on exit (crash or normal) |
| `Transient` | Restart only on abnormal exit (crash) |
| `Temporary` | Never restart |

Messages: `StartChild(spec, task)`, `StopChild(name)`, `ShutdownAll`.

Lifecycle events (`AgentStarted`, `AgentCrashed`, `AgentRestarted`, `AgentStopped`)
and scheduler events (`SchedulerJobStarted`, `SchedulerJobCompleted`,
`SchedulerJobFailed`) are forwarded through the cognitive loop to the notification
channel for TUI/web display.

### Registry (`src/agent/registry.gleam`)

A pure data structure (no OTP process) tracking agent names, task subjects, and
status. Exposed to the LLM via the `introspect` memory tool.

```gleam
pub type AgentStatus {
  Running
  Restarting
  Stopped
}

pub type RegistryEntry {
  RegistryEntry(
    name: String,
    task_subject: Subject(AgentTask),
    status: AgentStatus,
    ...
  )
}
```

### Worker (`src/agent/worker.gleam`)

Spawns unlinked think workers for blocking LLM calls. Each worker:

- Makes the LLM call with retry (3x exponential backoff via `llm/retry`).
- Sends `ThinkComplete` or `ThinkError` back to the cognitive loop.
- A monitor forwarder detects crashes (`ThinkWorkerDown`) but not normal exits.

---

## 2. Specialist Agents

All agent specs live in `src/agents/`. Each is a module exporting a `spec()` function
that returns an `AgentSpec`.

| Agent | File | Tools | max_turns | max_context | max_tokens | Restart | Purpose |
|---|---|---|---|---|---|---|---|
| Planner | `agents/planner.gleam` | None (pure XML reasoning) | 5 | unlimited | 2048 | Permanent | Decompose goals into structured plans with steps, dependencies, complexity, risks |
| Project Manager | `agents/project_manager.gleam` | planner tools | 15 | unlimited | 2048 | Permanent | Manage endeavours, phases, sessions, blockers, forecaster config |
| Researcher | `agents/researcher.gleam` | web + artifacts + builtin | 8 | 30 | 2048 | Permanent | Web search and content extraction via Kagi, Brave, Jina, DuckDuckGo, fetch_url. Large results auto-stored as artifacts. |
| Coder | `agents/coder.gleam` | sandbox + builtin | 10 | unlimited | 4096 | Permanent | Execute code in Podman sandbox, manage servers, iterate on errors |
| Writer | `agents/writer.gleam` | knowledge drafts + artifacts + builtin | 5 | unlimited | 4096 | Permanent | Synthesise research into structured, well-cited reports |
| Observer | `agents/observer.gleam` | diagnostic + CBR curation | 6 | 20 | 2048 | Transient | Cycle forensics, pattern detection, fact tracing, CBR curation |
| Comms | `agents/comms.gleam` | comms + builtin | 6 | 20 | configurable | Permanent | Send/receive email via AgentMail with three-layer safety. Opt-in via `[comms] enabled`. |
| Scheduler | `agents/scheduler.gleam` | scheduler tools | 4 | unlimited | 1024 | Permanent | Create, manage, and query scheduled jobs. Natural-language front-end over the scheduler runner. |
| Remembrancer | `agents/remembrancer.gleam` | deep memory + skill proposals | 8 | 30 | configurable | Transient | Deep-memory operations across the archive, consolidation, pattern mining, skill proposals. Also dispatched by meta-learning BEAM workers off-cog. |

### Planner vs Project Manager split

The Planner is a pure reasoning agent with no tools. It receives a goal and produces
XML output validated against the `planner_output_xsd` schema. It thinks about _what_
to do.

The Project Manager is a tool-using agent that manages the lifecycle of work _after_
the Planner creates it. It operates on endeavours, phases, tasks, sessions, blockers,
and forecaster configuration through 19 planner tools. It implements a "Sprint
Contract Protocol" -- before executing multi-step workflows, it states intent,
success criteria, and assumptions.

### Transient restart (Observer, Remembrancer)

Two agents use `Transient` restart. They are diagnostic / meta-level
agents — if they crash they should be restarted (abnormal exit), but
if they complete normally and aren't needed, they stay stopped.
Everything else is `Permanent` so the tool surface the operator sees
stays stable.

---

## 3. Agent Teams

Defined in `src/agent/team.gleam`. A team is a coordinated group of agents that
appears to the cognitive loop as a single tool (`team_<name>`).

### TeamSpec

```gleam
pub type TeamSpec {
  TeamSpec(
    name: String,
    description: String,
    members: List(TeamMember),
    strategy: TeamStrategy,
    context_scope: ContextScope,
    max_rounds: Int,
    synthesis_model: String,
    synthesis_max_tokens: Int,
  )
}

pub type TeamMember {
  TeamMember(agent_name: String, role: String, perspective: String)
}
```

- `agent_name` must match a registered agent.
- `role` is injected as `<team_role>` in the agent's instruction.
- `perspective` is injected as `<perspective>` overlay.

### Coordination Strategies

```gleam
pub type TeamStrategy {
  ParallelMerge
  TeamPipeline
  DebateAndConsensus(max_debate_rounds: Int)
  LeadWithSpecialists(lead: String)
}
```

| Strategy | Flow |
|---|---|
| **ParallelMerge** | All members work simultaneously. Results merged by a synthesis LLM call. |
| **TeamPipeline** | Members work in sequence. Each receives the prior member's output as `<prior_stage_output>` context. |
| **DebateAndConsensus** | Members produce independent analyses, then debate disagreements over multiple rounds. Convergence detected by keyword overlap (>60% significant words). Forces synthesis after `max_debate_rounds` if no consensus. |
| **LeadWithSpecialists** | Specialists work in parallel first. The lead receives all specialist results as `<specialist_results>` context and produces the final output. No separate synthesis -- the lead's output IS the result. |

### Context Scope

```gleam
pub type ContextScope {
  SharedFacts    -- Team members share working memory
  Independent   -- No sharing; merged at synthesis only
}
```

### Tool Generation

`team_to_tool(spec: TeamSpec) -> Tool` builds a tool definition from a `TeamSpec`.
The tool name is `team_<name>`, and the description includes member roles, agent
names, and strategy type. The tool takes two parameters: `instruction` (required)
and `context` (optional).

### TeamResult

```gleam
pub type TeamResult {
  TeamResult(
    synthesis: String,
    per_agent_results: List(#(String, String)),
    rounds_used: Int,
    consensus_reached: Bool,
    total_input_tokens: Int,
    total_output_tokens: Int,
    total_duration_ms: Int,
  )
}
```

---

## 4. Tool Dispatch

When the LLM responds with tool calls, the cognitive loop partitions them by prefix:

| Prefix | Destination | Examples |
|---|---|---|
| `agent_<name>` | Agent delegation via supervisor | `agent_researcher`, `agent_coder`, `agent_planner` |
| `team_<name>` | Team orchestrator process | `team_analysis` |
| Memory tools | Direct execution on cognitive loop | `recall_recent`, `memory_write`, `recall_cases`, `reflect`, `introspect` |
| Quick planner tools | Direct execution on cognitive loop | `complete_task_step`, `activate_task`, `get_active_work`, `get_task_detail` |
| `cancel_agent` | Sends `StopChild` to supervisor | Kills a misbehaving agent by name |

Agent and team tools are generated automatically:

- `agent_to_tool(spec: AgentSpec) -> Tool` in `src/agent/types.gleam`
- `team_to_tool(spec: TeamSpec) -> Tool` in `src/agent/team.gleam`

Both produce tools with `instruction` (required) and `context` (optional) string
parameters.

Memory tools and quick planner tools run synchronously within the cognitive loop
turn. Agent and team delegations are asynchronous -- the cognitive loop transitions
to `WaitingForAgents` status and collects results as they arrive.

---

## 5. Delegation Management

The cognitive loop tracks active agent delegations via `active_delegations` on
`CognitiveState`, a `Dict(String, DelegationInfo)`.

### DelegationInfo

Defined in `src/agent/types.gleam`:

```gleam
pub type DelegationInfo {
  DelegationInfo(
    agent: String,
    instruction: String,
    turn: Int,
    max_turns: Int,
    input_tokens: Int,
    output_tokens: Int,
    last_tool: String,
    started_at_ms: Int,
    depth: Int,
    violation_count: Int,
  )
}
```

### Progress tracking

The agent framework sends `AgentProgress` messages after each react-loop turn with
turn count, token usage, and last tool called. The Curator renders a `<delegations>`
section in the sensorium XML showing live agent state (name, turn N/M, tokens,
elapsed time, instruction summary).

### Depth limits

Delegation depth is capped by `max_delegation_depth` config (default: 3). `AgentTask`
carries a `depth: Int` field, set to 1 for cognitive-loop dispatches. Sub-agents
cannot dispatch further agents beyond the depth limit.

### Cancellation

The `cancel_agent` tool sends `StopChild(name)` to the supervisor, killing a
misbehaving or stuck agent. This is exposed to the LLM as a cognitive-loop tool.

### Sub-agent restrictions

Sub-agents cannot hijack the user interaction channel. `request_human_input` is
removed from all sub-agent tool sets -- `builtin.agent_tools()` provides the safe
subset excluding it. Agents report only through their return value.

---

## 6. Parallel Dispatch

When the LLM requests multiple agent tool calls in a single response, they are
dispatched simultaneously as independent OTP processes.

The `DispatchStrategy` type in `src/agent/types.gleam` documents three modes:

```gleam
pub type DispatchStrategy {
  Parallel     -- All agents dispatched simultaneously (default)
  Pipeline     -- Sequential, each receives prior agent's output
  Sequential   -- Sequential, no context chaining
}
```

**Parallel** is the default for cognitive-loop agent dispatch. The flow:

1. LLM response contains multiple `agent_*` / `team_*` tool calls.
2. All are dispatched simultaneously via `StartChild` to the supervisor.
3. The cognitive loop transitions to `WaitingForAgents` status.
4. Results accumulate in any order as `AgentComplete` messages arrive.
5. When all agents complete, results are combined into a single user message.
6. The cognitive loop re-thinks to synthesise the combined results.

**Pipeline** and **Sequential** are used internally by the team orchestrator
(`TeamPipeline` strategy) -- not directly by the cognitive loop.

---

## 7. Structured Output

When an agent completes, the framework populates `AgentSuccess.structured_result`
with typed `AgentResult` containing `AgentFindings`.

### AgentResult

```gleam
pub type AgentResult {
  AgentResult(
    final_text: String,
    agent_id: String,
    cycle_id: String,
    findings: AgentFindings,
  )
}
```

### AgentFindings variants

Defined in `src/agent/types.gleam`, built by `build_findings()` in
`src/agent/framework.gleam`:

| Variant | Fields | Extraction method |
|---|---|---|
| `PlannerFindings` | `plan_steps`, `dependencies`, `complexity`, `risks`, `verifications`, `task_id`, `endeavour_id`, `forecaster_config` | XStructor XML parsing of `<plan>` output against `planner_output_xsd` |
| `ResearcherFindings` | `sources: List(DiscoveredSource)`, `facts`, `data_points`, `dead_ends` | Extracted from `ToolCallDetail` -- web_search/fetch_url calls become sources, failures become dead ends |
| `CoderFindings` | `files_touched`, `patterns_used`, `errors_fixed`, `libraries` | Extracted from `ToolCallDetail` -- write_file/read_file calls tracked, failures collected |
| `WriterFindings` | `word_count`, `format`, `sections` | Minimal extraction (word_count=0 placeholder) |
| `GenericFindings` | `notes: List(String)` | Fallback for unrecognised agent names -- lists unique tools used |

### Supporting types

```gleam
pub type DiscoveredSource {
  DiscoveredSource(url: String, title: String, relevance: Float)
}

pub type PlannerForecasterConfig {
  PlannerForecasterConfig(
    threshold: Option(Float),
    feature_overrides: List(#(String, String)),
  )
}
```

### Downstream consumers

- **DAG nodes**: Structured findings feed into DAG nodes as typed `AgentOutput`
  variants, making agent work inspectable via `inspect_cycle`.
- **Curator inter-agent context**: `write_back_result` in
  `src/agent/cognitive/agents.gleam` uses findings to build context for
  subsequent agents (e.g. planner verification steps, researcher source lists).
- **Task auto-creation**: When `PlannerFindings` includes plan steps, the
  cognitive loop automatically creates `PlannerTask` records.

---

## 8. Error Surfacing

Agent errors are surfaced through two complementary paths.

### Reactive: tool failure warnings in result text

`AgentSuccess.tool_errors` captures tool failures that occurred during the react
loop. When non-empty (the agent's LLM chose to continue despite failures), the
cognitive loop prefixes a warning block to the result text:

```
[WARNING: agent researcher had tool failures]
- web_search: HTTP 429 rate limited
- fetch_url: Connection timeout
[END WARNING]

<agent's actual result text>
```

This ensures the orchestrating LLM knows the result may be unreliable and can
decide whether to retry, delegate to a different agent, or proceed with caveats.

### Proactive: agent health in sensorium

Agent completion pushes `UpdateAgentHealth` to the Curator with the first error
message. This makes agent health visible in the sensorium's
`<vitals agent_health="...">` section _before_ the next cycle starts.

The sensorium vitals include:

- `agent_health` -- latest agent error (if any)
- `last_failure` -- from narrative entries, replaces raw success_rate
- `success_rate` -- 0.0-1.0, computed from recent narrative entries
- `recent_failures` -- semicolon-separated last 3 failure descriptions

### AgentCompletionRecord

Defined in `src/agent/types.gleam`. Accumulated in `CognitiveState.agent_completions`
during a cycle and reset at the start of each `handle_user_input`. Fed to the
Archivist for narrative generation:

```gleam
pub type AgentCompletionRecord {
  AgentCompletionRecord(
    agent_id: String,
    agent_human_name: String,
    agent_cycle_id: String,
    instruction: String,
    result: Result(String, String),
    tools_used: List(String),
    tool_call_details: List(ToolCallDetail),
    input_tokens: Int,
    output_tokens: Int,
    duration_ms: Int,
  )
}
```

### ToolCallDetail

Captured per tool invocation for introspection and findings extraction:

```gleam
pub type ToolCallDetail {
  ToolCallDetail(
    name: String,
    input_summary: String,
    output_summary: String,
    success: Bool,
  )
}
```

### Lifecycle events

The supervisor emits lifecycle events that flow through the cognitive loop to the
notification channel:

| Event | Trigger |
|---|---|
| `AgentStarted` | Agent process spawned |
| `AgentCrashed` | Agent process exited abnormally |
| `AgentRestarted` | Supervisor restarted an agent (Permanent/Transient) |
| `AgentRestartFailed` | Restart attempt failed |
| `AgentStopped` | Agent stopped via `StopChild` or normal exit |

These appear in both the TUI (spinner label and notice area) and web GUI
(mapped to `ToolNotification`).
