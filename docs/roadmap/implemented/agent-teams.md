# Level 2: Agent Teams

**Status**: Implemented (2026-04-01)
**Date**: 2026-03-26
**Dependencies**: Parallel agent dispatch (Level 1)
**Effort**: Large (~500-700 lines)

---

## Concept

A team is a coordinated group of agents working on the same problem with a shared coordination strategy. Unlike parallel dispatch (which is fire-and-forget), teams have:

- A **shared working context** visible to all team members
- A **coordination strategy** (how they collaborate)
- A **team-level meta observer** (detects cross-agent patterns)
- A **synthesis step** (combines team outputs into a single result)

## Team Specification

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

## Example: Research Team

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

## Coordination Strategies

### ParallelMerge
All agents dispatched simultaneously. Each works independently. Results merged by the cognitive loop using the synthesis model. Best for breadth: "research this topic from multiple angles."

### Pipeline
Agent outputs feed sequentially. Agent 1 researches → Agent 2 analyses → Agent 3 writes report. Best for depth: "research, then analyse, then write up."

### DebateAndConsensus
Agents produce independent analyses. A debate round identifies disagreements. Agents revise their positions. If consensus isn't reached in `max_debate_rounds`, the synthesis model decides. Best for accuracy: "what's the right answer when experts disagree?"

### LeadWithSpecialists
One agent acts as lead, delegating sub-tasks to specialists as needed. The lead has its own react loop and can invoke team members like tools. Best for complex orchestration: "plan the work and assign pieces."

## Team Orchestrator (`src/agent/team.gleam`)

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

## Team-Level Meta Observer

Monitors cross-agent patterns:
- **Disagreement detection**: agents reach contradictory conclusions
- **Redundancy detection**: agents are doing the same work
- **Stagnation**: debate rounds aren't converging
- **Token budget**: team total exceeding limits

Signals feed into the existing meta observer framework.

## D' Integration

- Each agent's tool calls go through D' independently
- Inter-agent messages (in debate rounds) pass through the D' input gate — one agent's output is untrusted input to another
- The synthesis step goes through the output gate before delivery to the user

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | TeamSpec, TeamStrategy, TeamMember types | Small (~80 lines) |
| 2 | ParallelMerge strategy | Medium (~200 lines) |
| 3 | Pipeline strategy | Medium (~150 lines) |
| 4 | Team orchestrator OTP actor | Medium (~250 lines) |
| 5 | DebateAndConsensus | Large (~300 lines) |
| 6 | Team meta observer | Medium (~150 lines) |
