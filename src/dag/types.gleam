// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{type Option}

// ---------------------------------------------------------------------------
// CycleNode — the vertex type for the DAG experience index
// ---------------------------------------------------------------------------

pub type CycleNode {
  CycleNode(
    cycle_id: String,
    parent_id: Option(String),
    node_type: CycleNodeType,
    timestamp: String,
    outcome: NodeOutcome,
    model: String,
    complexity: String,
    tool_calls: List(ToolSummary),
    dprime_gates: List(GateSummary),
    tokens_in: Int,
    tokens_out: Int,
    duration_ms: Int,
    agent_output: Option(AgentOutput),
    /// Instance name for cognitive cycles (e.g. "Curragh"), empty for sub-agents.
    instance_name: String,
    /// Stable UUID for cognitive cycles, empty for sub-agents.
    instance_id: String,
  )
}

pub type CycleNodeType {
  CognitiveCycle
  AgentCycle
  SchedulerCycle
  /// Deputy-loop cycle — an ephemeral, restricted cog loop that briefs
  /// specialist agents on delegated attention. See docs/roadmap/planned/deputy-agents.md.
  DeputyCycle
}

pub type NodeOutcome {
  NodeSuccess
  NodePartial
  NodeFailure(reason: String)
  NodePending
}

// ---------------------------------------------------------------------------
// Tool and gate summaries — lightweight records on CycleNode
// ---------------------------------------------------------------------------

pub type ToolSummary {
  ToolSummary(name: String, success: Bool, error: Option(String))
}

pub type GateSummary {
  GateSummary(gate: String, decision: String, score: Float)
}

// ---------------------------------------------------------------------------
// Agent output — structured findings from agent cycles
// ---------------------------------------------------------------------------

pub type AgentOutput {
  PlanOutput(
    steps: List(String),
    dependencies: List(#(String, String)),
    complexity: String,
    risks: List(String),
  )
  ResearchOutput(
    facts: List(FoundFact),
    sources: Int,
    dead_ends: List(String),
    confidence: Float,
  )
  CoderOutput(files_touched: List(String), patterns: List(String))
  WriterOutput(word_count: Int, format: String, sections: List(String))
  GenericOutput(notes: List(String))
}

pub type FoundFact {
  FoundFact(label: String, value: String, confidence: Float)
}

// ---------------------------------------------------------------------------
// Query return types
// ---------------------------------------------------------------------------

pub type DagSubtree {
  DagSubtree(root: CycleNode, children: List(DagSubtree))
}

pub type DayStats {
  DayStats(
    date: String,
    total_cycles: Int,
    root_cycles: Int,
    agent_cycles: Int,
    success_count: Int,
    partial_count: Int,
    failure_count: Int,
    total_tokens_in: Int,
    total_tokens_out: Int,
    total_duration_ms: Int,
    tool_failure_rate: Float,
    models_used: List(String),
    gate_decisions: List(GateSummary),
    agent_failures: List(AgentFailureRecord),
  )
}

pub type AgentFailureRecord {
  AgentFailureRecord(agent_model: String, reason: String, cycle_id: String)
}

// ---------------------------------------------------------------------------
// Tool activity record — per-tool usage stats from DAG queries
// ---------------------------------------------------------------------------

pub type ToolActivityRecord {
  ToolActivityRecord(
    name: String,
    total_calls: Int,
    success_count: Int,
    failure_count: Int,
    cycle_ids: List(String),
  )
}

// ---------------------------------------------------------------------------
// D-prime decision record — passed from cognitive loop to Archivist
// ---------------------------------------------------------------------------

pub type DprimeDecisionRecord {
  DprimeDecisionRecord(
    gate: String,
    decision: String,
    score: Float,
    explanation: String,
  )
}
