# Parallel Agents, Teams, and Federation — Specification

**Status**: Planned
**Date**: 2026-03-26
**Dependencies**: Multi-tenant (planned), Comms agent (planned)
**Runtime**: BEAM/OTP — this spec exploits capabilities unique to the Erlang VM

---

## Table of Contents

- [Overview](#overview)
  - [The Atomic Agent Principle](#the-atomic-agent-principle)
  - [Why Atomicity Matters](#why-atomicity-matters)
- [Level 1: Parallel Agent Dispatch](#level-1-parallel-agent-dispatch)
  - [Current State](#current-state)
  - [Proposed Change](#proposed-change)
  - [Dependency Detection](#dependency-detection)
  - [Implementation](#implementation)
  - [D' Integration](#d-integration)
  - [Effort](#effort)
- [Level 2: Agent Teams](#level-2-agent-teams)
  - [Concept](#concept)
  - [Team Specification](#team-specification)
  - [Example: Research Team](#example-research-team)
  - [Coordination Strategies](#coordination-strategies)
  - [Team Orchestrator (`src/agent/team.gleam`)](#team-orchestrator-srcagentteamgleam)
  - [Team-Level Meta Observer](#team-level-meta-observer)
  - [D' Integration](#d-integration)
  - [Effort](#effort)
- [Level 3: Federated Instances](#level-3-federated-instances)
  - [Concept](#concept)
  - [Why Distributed Erlang](#why-distributed-erlang)
  - [Federation Protocol](#federation-protocol)
  - [Trust Model](#trust-model)
  - [Example: Legal + Insurance Collaboration](#example-legal-insurance-collaboration)
  - [Federation Manager (`src/federation/manager.gleam`)](#federation-manager-srcfederationmanagergleam)
  - [Sensorium Integration](#sensorium-integration)
  - [Web GUI: Federation Tab](#web-gui-federation-tab)
  - [Effort](#effort)
- [Implementation Order](#implementation-order)
- [BEAM Capabilities Exploited](#beam-capabilities-exploited)
- [What Nobody Else Has](#what-nobody-else-has)
- [Security Considerations](#security-considerations)


## Overview

Three levels of agent parallelism, each building on the last:

1. **Parallel dispatch** — multiple sub-agents working simultaneously on independent subtasks within a single cognitive loop
2. **Agent teams** — coordinated groups of sub-agents working on the same problem from different angles with shared context
3. **Federated instances** — multiple Springdrift instances collaborating across a distributed Erlang cluster, each with independent memory, identity, and safety gates

The BEAM gives us process isolation, location transparency, supervision trees, and backpressure for free. The engineering work is in orchestration, coordination, and inter-agent safety.

### The Atomic Agent Principle

A Springdrift instance is a **bounded autonomous entity** — one identity, one memory, one cognitive loop, one persona. It is atomic. Sub-agents (researcher, coder, planner, etc.) are its hands, not independent minds. They execute within its cognitive boundary and report back.

Levels 1 and 2 (parallel dispatch, teams) operate WITHIN a single instance. The cognitive loop orchestrates its own sub-agents more effectively — this doesn't change the identity boundary.

Level 3 (federation) is collaboration BETWEEN autonomous entities. Each instance is a complete agent with its own memory, values, and safety configuration. Federation is peer-to-peer communication between equals, not decomposition of one entity across machines. An instance asking another instance for information is like one professional consulting another — it doesn't merge them into one person.

### Why Atomicity Matters

An agent you can audit is an agent you can trust. A single bounded entity with one identity, one memory, and one decision trail is **accountable** — you can ask it what it did and why, trace every decision through its logs, and hold one entity responsible for its outputs. This is tractable for human oversight.

A distributed agent spread across nodes, with shared state and collective decision-making, is not accountable. When something goes wrong, there is no single entity that made the decision, no single audit trail to follow, and no clear answer to "who is responsible for this output?" This matters in every regulated industry and in every organisation that needs to explain its AI's behaviour to a board, a regulator, or a court.

Springdrift's architecture reflects this deliberately: one agent, one persona, one complete record. Federation adds collaboration without sacrificing individual accountability — each instance's decisions are independently auditable, and the provenance chain tracks exactly which information came from which peer.

---

## Level 1: Parallel Agent Dispatch

### Current State

The cognitive loop dispatches agents sequentially — send one `StartChild`, wait for `AgentComplete`, then dispatch the next. The `active_delegations` Dict already tracks multiple concurrent delegations, but the dispatch logic sends them one at a time.

### Proposed Change

When the LLM requests multiple agent tool calls in the same response (e.g. `agent_researcher` + `agent_coder`), dispatch them simultaneously if they have no data dependencies.

```gleam
pub type DispatchStrategy {
  Sequential    // Current behaviour — one at a time
  Parallel      // All independent agents at once
  Pipeline      // Output of one feeds input of next
}
```

### Dependency Detection

Two agent calls are independent if:
- Neither references the other's output
- They don't write to the same memory keys
- They don't use the same sandbox slot

The cognitive loop infers independence from the tool call arguments. Conservative default: if unclear, dispatch sequentially.

### Implementation

```
Current flow:
  LLM returns [agent_researcher, agent_coder]
  → dispatch researcher → wait → dispatch coder → wait → synthesise

Parallel flow:
  LLM returns [agent_researcher, agent_coder]
  → dispatch researcher AND coder simultaneously
  → wait for ALL AgentComplete messages
  → synthesise both results
```

Changes:
- `src/agent/cognitive/agents.gleam` — partition agent calls into independent groups, dispatch each group in parallel
- `src/agent/cognitive.gleam` — handle multiple simultaneous `AgentComplete` messages, synthesise when all in a group have completed
- Existing `active_delegations` Dict already supports multiple concurrent entries

### D' Integration

Each parallel agent's tool calls go through D' independently. One agent being blocked doesn't affect the other.

### Effort

Small — ~100 lines. The infrastructure is already there; it's a dispatch wiring change.

---

## Level 2: Agent Teams

### Concept

A team is a coordinated group of agents working on the same problem with a shared coordination strategy. Unlike parallel dispatch (which is fire-and-forget), teams have:

- A **shared working context** visible to all team members
- A **coordination strategy** (how they collaborate)
- A **team-level meta observer** (detects cross-agent patterns)
- A **synthesis step** (combines team outputs into a single result)

### Team Specification

```gleam
pub type TeamSpec {
  TeamSpec(
    name: String,
    agents: List(TeamMember),
    strategy: TeamStrategy,
    shared_context_scope: ContextScope,
    max_rounds: Int,              // Max coordination rounds before forcing synthesis
    synthesis_model: String,      // Model for final synthesis (reasoning_model)
  )
}

pub type TeamMember {
  TeamMember(
    agent_spec: AgentSpec,
    role: String,                 // "lead_researcher", "data_analyst", "fact_checker"
    perspective: String,          // Instruction overlay: "Focus on quantitative data"
  )
}

pub type TeamStrategy {
  /// All agents work simultaneously, results merged at end
  ParallelMerge
  /// Agents work in sequence, each building on the previous
  Pipeline
  /// Agents produce independent analyses, then debate disagreements
  DebateAndConsensus(max_debate_rounds: Int)
  /// One lead agent delegates to specialists as needed
  LeadWithSpecialists(lead: String)
}

pub type ContextScope {
  /// Team members share a working memory (facts with scope: Team)
  SharedFacts
  /// Team members see each other's narrative entries
  SharedNarrative
  /// Full visibility — all memory shared
  FullShared
  /// No sharing — independent work, merged at synthesis only
  Independent
}
```

### Example: Research Team

```gleam
let research_team = TeamSpec(
  name: "deep-research",
  agents: [
    TeamMember(
      agent_spec: researcher_spec,
      role: "academic_researcher",
      perspective: "Focus on peer-reviewed papers and arxiv preprints",
    ),
    TeamMember(
      agent_spec: researcher_spec,
      role: "industry_analyst",
      perspective: "Focus on industry reports, market data, and enterprise adoption",
    ),
    TeamMember(
      agent_spec: observer_spec,
      role: "fact_checker",
      perspective: "Verify claims from the other researchers against available evidence",
    ),
  ],
  strategy: DebateAndConsensus(max_debate_rounds: 2),
  shared_context_scope: SharedFacts,
  max_rounds: 3,
  synthesis_model: "claude-opus-4-6",
)
```

### Coordination Strategies

#### ParallelMerge
All agents dispatched simultaneously. Each works independently. Results merged by the cognitive loop using the synthesis model. Best for breadth: "research this topic from multiple angles."

#### Pipeline
Agent outputs feed sequentially. Agent 1 researches → Agent 2 analyses → Agent 3 writes report. Best for depth: "research, then analyse, then write up."

#### DebateAndConsensus
Agents produce independent analyses. A debate round identifies disagreements. Agents revise their positions. If consensus isn't reached in `max_debate_rounds`, the synthesis model decides. Best for accuracy: "what's the right answer when experts disagree?"

#### LeadWithSpecialists
One agent acts as lead, delegating sub-tasks to specialists as needed. The lead has its own react loop and can invoke team members like tools. Best for complex orchestration: "plan the work and assign pieces."

### Team Orchestrator (`src/agent/team.gleam`)

New OTP actor per active team:

```gleam
pub type TeamMessage {
  StartTeam(task: String, reply_to: Subject(TeamResult))
  RoundComplete(agent: String, result: AgentSuccess)
  DebateRound(round: Int)
  Synthesise
  Cancel
}

pub type TeamResult {
  TeamResult(
    synthesis: String,
    per_agent_results: List(#(String, AgentSuccess)),
    rounds_used: Int,
    consensus_reached: Bool,
    total_tokens: Int,
  )
}
```

### Team-Level Meta Observer

Monitors cross-agent patterns:
- **Disagreement detection**: agents reach contradictory conclusions
- **Redundancy detection**: agents are doing the same work
- **Stagnation**: debate rounds aren't converging
- **Token budget**: team total exceeding limits

Signals feed into the existing meta observer framework.

### D' Integration

- Each agent's tool calls go through D' independently
- Inter-agent messages (in debate rounds) pass through the D' input gate — one agent's output is untrusted input to another
- The synthesis step goes through the output gate before delivery to the user

### Effort

Large — ~500-700 lines. New `team.gleam` orchestrator, coordination strategies, inter-agent message routing, team meta observer.

---

## Level 3: Federated Instances

### Concept

Multiple Springdrift instances running as independent nodes in a distributed Erlang cluster. Each instance has its own:
- Cognitive loop and agent roster
- Memory (narrative, CBR, facts)
- Identity and persona
- D' safety configuration
- Tenant data

Instances communicate via a typed federation protocol. Each instance treats incoming messages from other instances as untrusted — they pass through the D' input gate.

### Why Distributed Erlang

The BEAM provides:
- **Location transparency**: `process.send(subject, message)` works identically whether the subject is local or on a remote node
- **Node discovery**: `net_kernel:connect_node/1` establishes connections
- **Process monitoring**: `process.monitor` works across nodes — crash detection is automatic
- **No serialisation overhead for Erlang terms**: messages between nodes use the Erlang external term format natively

This means two Springdrift instances on different machines communicate using the exact same `Subject(CognitiveMessage)` mechanism used internally. No HTTP APIs, no message queues, no serialisation layers.

### Federation Protocol

```gleam
pub type FederatedMessage {
  /// Request: ask another instance for information
  FederatedQuery(
    from_instance: InstanceId,
    query: String,
    context: String,
    reply_to: Subject(FederatedReply),
  )
  /// Response: answer from another instance
  FederatedReply(
    from_instance: InstanceId,
    response: String,
    confidence: Float,
    sources: List(String),
  )
  /// Broadcast: share a finding with all federated instances
  FederatedBroadcast(
    from_instance: InstanceId,
    finding: String,
    domain: String,
    relevance: Float,
  )
  /// Handshake: establish trust between instances
  FederatedHandshake(
    instance_id: InstanceId,
    instance_name: String,
    capabilities: List(String),   // ["legal", "insurance", "research"]
    dprime_config_hash: String,   // Prove safety configuration is adequate
  )
}

pub type InstanceId {
  InstanceId(
    node: String,                 // Erlang node name
    tenant_id: String,
    agent_uuid: String,
  )
}
```

### Trust Model

Federated instances don't blindly trust each other:

1. **Handshake**: Instances exchange capabilities and D' config hashes. An instance can refuse federation with another whose safety config doesn't meet minimum standards.
2. **Input gate on all received messages**: Every `FederatedQuery` and `FederatedBroadcast` passes through the receiving instance's D' input gate. Injection attempts from a compromised instance are caught.
3. **Provenance tracking**: Facts derived from federated queries are tagged with `derivation: FederatedQuery` and `source_agent: "instance:{name}"`. The receiving instance knows which facts came from which source.
4. **Confidence discounting**: Federated information carries a confidence discount (configurable, default 0.8x). The receiving instance's facts from its own experience are weighted higher than second-hand information.

### Example: Legal + Insurance Collaboration

```
Node 1: Legal Springdrift (persona: "Atlas", domain: legal)
  - Case law CBR, regulatory compliance memory
  - D' configured for legal sensitivity (client confidentiality)

Node 2: Insurance Springdrift (persona: "Beacon", domain: insurance)
  - Underwriting CBR, claims outcome memory
  - D' configured for actuarial accuracy

Scenario: Coverage dispute involving both contract law and insurance policy interpretation

Atlas queries Beacon:
  "What is the typical claims outcome for professional indemnity policies
   where the insured's contract included a limitation of liability clause?"

Beacon's D' input gate evaluates → ACCEPT (legitimate insurance query)
Beacon searches its CBR → finds relevant cases
Beacon's D' output gate evaluates the response → ACCEPT
Response sent back to Atlas with confidence 0.75 and source cases

Atlas integrates Beacon's response, applies 0.8x confidence discount (effective 0.60),
tags the derived fact with provenance: FederatedQuery from Beacon
```

### Federation Manager (`src/federation/manager.gleam`)

OTP actor managing federated connections:

```gleam
pub type FederationMessage {
  Connect(node: String, reply_to: Subject(Result(InstanceId, String)))
  Disconnect(instance_id: InstanceId)
  Query(to: InstanceId, query: String, context: String, reply_to: Subject(FederatedReply))
  Broadcast(finding: String, domain: String)
  ListPeers(reply_to: Subject(List(PeerInfo)))
  HandleIncoming(msg: FederatedMessage)
}

pub type PeerInfo {
  PeerInfo(
    instance_id: InstanceId,
    name: String,
    capabilities: List(String),
    connected_since: String,
    messages_exchanged: Int,
    trust_score: Float,           // Computed from successful exchanges
  )
}
```

### Sensorium Integration

The sensorium gains a `<federation>` section:

```xml
<federation peers="2">
  <peer name="Beacon" domain="insurance" trust="0.85" last_exchange="2m ago"/>
  <peer name="Sentinel" domain="compliance" trust="0.92" last_exchange="15m ago"/>
</federation>
```

The agent knows who it can ask for help and how much to trust them.

### Web GUI: Federation Tab

Admin tab showing:
- Connected peers with trust scores
- Message exchange history
- Per-peer query/response latency
- Trust score evolution over time

### Effort

Large — ~800-1000 lines. Federation protocol, trust model, manager actor, D' integration for inter-instance messages, sensorium and web GUI updates.

---

## Implementation Order

| Phase | Level | What | Effort | Dependencies |
|---|---|---|---|---|
| 1 | Parallel dispatch | Dispatch independent agents simultaneously | Small (~100 lines) | None — can ship now |
| 2 | Team types | TeamSpec, TeamStrategy, TeamMember types | Small (~80 lines) | None |
| 3 | ParallelMerge strategy | Simplest team coordination — fan out, merge results | Medium (~200 lines) | Phase 1-2 |
| 4 | Pipeline strategy | Sequential agent chain | Medium (~150 lines) | Phase 2 |
| 5 | Team orchestrator | OTP actor for team lifecycle | Medium (~250 lines) | Phase 2-4 |
| 6 | DebateAndConsensus | Inter-agent debate with convergence detection | Large (~300 lines) | Phase 5 |
| 7 | Team meta observer | Cross-agent pattern detection | Medium (~150 lines) | Phase 5, existing meta observer |
| 8 | Federation protocol | Types, handshake, trust model | Medium (~200 lines) | Multi-tenant plan |
| 9 | Federation manager | OTP actor for peer connections | Medium (~250 lines) | Phase 8 |
| 10 | D' for federation | Input gate on inter-instance messages | Small (~50 lines) | Phase 8-9, existing D' |
| 11 | Distributed Erlang wiring | Node connection, process monitoring | Medium (~150 lines) | Phase 8-9 |
| 12 | Sensorium + web GUI | Federation visibility | Medium (~200 lines) | Phase 9 |

Phase 1 (parallel dispatch) is immediately valuable with zero dependencies. It can ship this week. The rest builds incrementally.

---

## BEAM Capabilities Exploited

| BEAM Feature | How It's Used |
|---|---|
| Lightweight processes | Each agent, team member, and federated connection is its own process |
| Process isolation | One agent crashing doesn't affect others in the team |
| Supervision trees | Per-team supervisor restarts failed agents mid-collaboration |
| Location transparency | Federation uses the same Subject channels as local dispatch |
| Node monitoring | Federated peer disconnection detected automatically |
| Mailbox backpressure | `mailbox_size` monitoring prevents agent flooding |
| Hot code reload | Update agent logic without stopping a running team |
| ETS | Per-team shared working memory without serialisation |
| Selective receive | Team orchestrator waits for specific agents to complete |

---

## What Nobody Else Has

LangChain, CrewAI, and AutoGen support multi-agent orchestration. None of them have:

- **Process-level fault isolation** — a crashing agent in LangChain takes down the Python process
- **Location-transparent federation** — distributing agents across machines requires HTTP APIs and serialisation in every other framework
- **Safety gates on inter-agent communication** — no framework runs D' (or equivalent) on messages between agents
- **Typed supervision with restart strategies** — other frameworks retry; Springdrift supervises with configurable restart policies per agent
- **Trust-scored federation** — no framework tracks how reliable another agent's information has been historically

The BEAM was designed for telecoms — thousands of concurrent, supervised, fault-isolated processes communicating via message passing. That's exactly what a team of collaborating AI agents is.

---

## Security Considerations

- **Inter-agent messages pass through D' input gate** — agents don't trust each other by default
- **Federation handshake requires D' config validation** — instances with inadequate safety config are refused
- **Confidence discounting on federated information** — second-hand information weighted lower
- **Provenance tracking** — facts from federation tagged with source instance
- **Tenant isolation preserved** — federation operates between instances, not between tenants within an instance
- **Rate limiting** — per-peer message rate caps prevent flooding
- **Deterministic pre-filter on inter-agent content** — blocks credential leakage between instances
