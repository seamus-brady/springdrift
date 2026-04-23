// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dag/types as dag_types
import deputy/types as deputy_types
import dprime/types as dprime_types
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option}
import llm/provider.{type Provider}
import llm/tool
import llm/types.{
  type ContentBlock, type LlmResponse, type Message, type Tool, type ToolCall,
  type ToolResult, type Usage,
}
import query_complexity.{type QueryComplexity}
import scheduler/types as scheduler_types

// ---------------------------------------------------------------------------
// Agent spec → Tool conversion
// ---------------------------------------------------------------------------

/// Build a Tool definition from an AgentSpec so the LLM can call agents.
pub fn agent_to_tool(spec: AgentSpec) -> Tool {
  tool.new("agent_" <> spec.name)
  |> tool.with_description(spec.description)
  |> tool.add_string_param("instruction", "Task for the agent", True)
  |> tool.add_string_param("context", "Relevant context", False)
  |> tool.add_integer_param(
    "max_turns",
    "Override turn limit for this delegation (optional, default: "
      <> int.to_string(spec.max_turns)
      <> ")",
    False,
  )
  |> tool.add_string_param(
    "depends_on",
    "Task ID of a concurrently dispatched agent that must succeed first (optional)",
    False,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Dispatch strategy — how multiple agent calls in one response are handled
// ---------------------------------------------------------------------------

/// Strategy for dispatching multiple agent tool calls from a single LLM response.
/// Parallel is the default: all independent agents run simultaneously.
pub type DispatchStrategy {
  /// All agents dispatched simultaneously, results collected in any order.
  /// This is the default and already-implemented behaviour.
  Parallel
  /// Agents dispatched one at a time; each receives the prior agent's output
  /// as additional context. Used by team Pipeline strategy.
  Pipeline
  /// Agents dispatched one at a time in order. No context chaining.
  Sequential
}

// ---------------------------------------------------------------------------
// Restart strategy
// ---------------------------------------------------------------------------

pub type RestartStrategy {
  Permanent
  Transient
  Temporary
}

// ---------------------------------------------------------------------------
// Agent identity — human-readable name + GUID for tracking
// ---------------------------------------------------------------------------

pub type AgentIdentity {
  AgentIdentity(human_name: String, guid: String, agent_id: String)
}

// ---------------------------------------------------------------------------
// Agent spec — pure data describing how to start an agent
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Agent task — unit of work dispatched to an agent
// ---------------------------------------------------------------------------

pub type AgentTask {
  AgentTask(
    task_id: String,
    tool_use_id: String,
    instruction: String,
    context: String,
    parent_cycle_id: String,
    reply_to: Subject(CognitiveMessage),
    depth: Int,
    /// Override the agent's default max_turns for this delegation.
    /// Capped by max_agent_turns_cap in config.
    max_turns_override: Option(Int),
    /// Deputy subject for this hierarchy, if deputies are enabled and a
    /// deputy was spawned. Sub-delegations inherit the parent's deputy
    /// subject rather than spawning a new one. None when deputies are
    /// disabled or the deputy spawn/briefing failed.
    deputy_subject: Option(Subject(deputy_types.DeputyMessage)),
  )
}

// ---------------------------------------------------------------------------
// Agent outcome — result of agent work (always data, never exceptions)
// ---------------------------------------------------------------------------

pub type AgentOutcome {
  AgentSuccess(
    task_id: String,
    agent: String,
    agent_id: String,
    agent_human_name: String,
    agent_cycle_id: String,
    result: String,
    structured_result: Option(AgentResult),
    instruction: String,
    tools_used: List(String),
    tool_call_details: List(ToolCallDetail),
    /// Tool errors that occurred during the react loop. Non-empty means the
    /// agent's LLM chose to continue despite failures — the orchestrator
    /// should treat the result with suspicion.
    tool_errors: List(String),
    input_tokens: Int,
    output_tokens: Int,
    duration_ms: Int,
  )
  AgentFailure(
    task_id: String,
    agent: String,
    agent_id: String,
    agent_human_name: String,
    agent_cycle_id: String,
    error: String,
    instruction: String,
    tools_used: List(String),
    tool_call_details: List(ToolCallDetail),
    input_tokens: Int,
    output_tokens: Int,
    duration_ms: Int,
  )
}

// ---------------------------------------------------------------------------
// Agent result — structured return type from agent work
// ---------------------------------------------------------------------------

pub type AgentResult {
  AgentResult(
    final_text: String,
    agent_id: String,
    cycle_id: String,
    findings: AgentFindings,
  )
}

/// Forecaster config suggestion from the Planner — optional feature weight
/// overrides and threshold that will be applied to the task after creation.
pub type PlannerForecasterConfig {
  PlannerForecasterConfig(
    threshold: Option(Float),
    feature_overrides: List(#(String, String)),
  )
}

pub type AgentFindings {
  ResearcherFindings(
    sources: List(DiscoveredSource),
    facts: List(ExtractedFact),
    data_points: List(AgentDataPoint),
    dead_ends: List(String),
  )
  PlannerFindings(
    plan_steps: List(String),
    dependencies: List(#(String, String)),
    complexity: String,
    risks: List(String),
    verifications: List(String),
    task_id: Option(String),
    endeavour_id: Option(String),
    forecaster_config: Option(PlannerForecasterConfig),
  )
  CoderFindings(
    files_touched: List(String),
    patterns_used: List(String),
    errors_fixed: List(String),
    libraries: List(String),
  )
  WriterFindings(word_count: Int, format: String, sections: List(String))
  GenericFindings(notes: List(String))
}

pub type DiscoveredSource {
  DiscoveredSource(url: String, title: String, relevance: Float)
}

pub type ExtractedFact {
  ExtractedFact(label: String, value: String, confidence: Float)
}

pub type AgentDataPoint {
  AgentDataPoint(label: String, value: String, unit: String)
}

// ---------------------------------------------------------------------------
// Tool call detail — captured per tool invocation for introspection
// ---------------------------------------------------------------------------

pub type ToolCallDetail {
  ToolCallDetail(
    name: String,
    input_summary: String,
    output_summary: String,
    success: Bool,
  )
}

// ---------------------------------------------------------------------------
// Agent completion record — accumulated in cognitive loop for Archivist
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Lifecycle events from supervisor → cognitive loop
// ---------------------------------------------------------------------------

pub type AgentLifecycleEvent {
  AgentStarted(
    name: String,
    task_subject: Subject(AgentTask),
    tool_names: List(String),
  )
  AgentCrashed(name: String, reason: String)
  AgentRestarted(
    name: String,
    attempt: Int,
    task_subject: Subject(AgentTask),
    tool_names: List(String),
  )
  AgentRestartFailed(name: String, reason: String)
  AgentStopped(name: String)
}

// ---------------------------------------------------------------------------
// Supervisor messages
// ---------------------------------------------------------------------------

pub type SupervisorMessage {
  StartChild(
    spec: AgentSpec,
    reply_to: Subject(Result(Subject(AgentTask), String)),
  )
  StopChild(name: String)
  ShutdownAll
  /// Resolve an agent's current task_subject by name. Returns None if
  /// no agent is currently registered under that name (including the
  /// window between a Transient restart and the new process coming up).
  /// Used by off-cog callers — notably meta-learning BEAM workers —
  /// that need a live handle without threading one through startup
  /// and then getting wedged when the agent restarts.
  LookupAgentSubject(
    name: String,
    reply_to: Subject(Option(Subject(AgentTask))),
  )
}

// ---------------------------------------------------------------------------
// Cognitive loop messages (exhaustive matching)
// ---------------------------------------------------------------------------

pub type CognitiveMessage {
  /// Inbound user message. `source_id` is the Frontdoor destination
  /// token — cognitive ClaimCycle's it, and every reply and question
  /// for the resulting cycle routes through Frontdoor to whichever
  /// sink is registered. Callers with no Frontdoor interest pass "".
  /// `reply_to` is vestigial — adapters pass a throwaway subject. It
  /// exists because cognitive's internal `PendingThink` chain still
  /// threads a `Subject(CognitiveReply)` through gate callbacks; the
  /// cycle-terminal `output.send_reply` helper is the only actual
  /// caller and it publishes to Frontdoor regardless.
  UserInput(source_id: String, text: String, reply_to: Subject(CognitiveReply))
  UserAnswer(answer: String)
  /// Sent by Frontdoor when an autonomous cycle raised a human question
  /// but has no human destination to ask. Cognitive treats it exactly
  /// like a UserAnswer — the waiting react loop resumes with the
  /// synthesised "no human available" text instead of hanging.
  InjectUserAnswer(text: String)
  ThinkComplete(task_id: String, response: LlmResponse)
  ThinkError(task_id: String, error: String, retryable: Bool)
  ThinkWorkerDown(task_id: String, reason: String)
  AgentComplete(outcome: AgentOutcome)
  AgentProgress(progress: DelegationProgress)
  AgentQuestion(question: String, agent: String, reply_to: Subject(String))
  AgentEvent(event: AgentLifecycleEvent)
  SetModel(model: String)
  /// Post-startup wiring: hands cognitive a handle on the scheduler
  /// runner so it can push `UserInputObserved` signals back whenever a
  /// UserInput arrives. The scheduler uses those signals to idle-gate
  /// recurring ticks so meta jobs don't hijack an active operator
  /// conversation. Called once from `springdrift.gleam` after both the
  /// cognitive loop and the scheduler have started.
  SetScheduler(scheduler: Subject(scheduler_types.SchedulerMessage))
  ClassifyComplete(
    cycle_id: String,
    complexity: QueryComplexity,
    text: String,
    reply_to: Subject(CognitiveReply),
  )
  SafetyGateComplete(
    task_id: String,
    result: dprime_types.GateResult,
    response: LlmResponse,
    calls: List(ToolCall),
    reply_to: Subject(CognitiveReply),
  )
  InputSafetyGateComplete(
    cycle_id: String,
    result: dprime_types.GateResult,
    model: String,
    text: String,
    reply_to: Subject(CognitiveReply),
  )
  PostExecutionGateComplete(
    cycle_id: String,
    result: dprime_types.GateResult,
    pre_score: Float,
    reply_to: Subject(CognitiveReply),
  )
  SetSupervisor(supervisor: Subject(SupervisorMessage))
  SchedulerInput(
    source_id: String,
    job_name: String,
    query: String,
    kind: scheduler_types.JobKind,
    for_: scheduler_types.ForTarget,
    title: String,
    body: String,
    tags: List(String),
    /// Vestigial — see UserInput.reply_to.
    reply_to: Subject(CognitiveReply),
  )
  OutputGateComplete(
    cycle_id: String,
    result: dprime_types.GateResult,
    report_text: String,
    modification_count: Int,
    reply_to: Subject(CognitiveReply),
  )
  GetMessages(reply_to: Subject(List(Message)))
  /// Cheap liveness check: cognitive replies with its current status
  /// tag. Used by /health to distinguish "alive and processing" from
  /// "queue jammed / crashed". Does not touch message history or any
  /// other state; safe to call from external pingers.
  Ping(reply_to: Subject(PingReply))
  GateTimeout(task_id: String, gate: String)
  /// Watchdog: fires if the cognitive loop stays non-Idle too long.
  /// Generation prevents stale timeouts from prior cycles.
  WatchdogTimeout(generation: Int)
  QueuedSensoryEvent(event: SensoryEvent)
  ForecasterSuggestion(
    task_id: String,
    task_title: String,
    plan_dprime: Float,
    explanation: String,
  )
}

pub type CognitiveReply {
  CognitiveReply(
    response: String,
    model: String,
    usage: Option(Usage),
    /// Names of tools the cognitive loop fired during the cycle that
    /// produced this reply. Used by the scheduler runner to enforce
    /// the Phase 3b required_tools check — a job that didn't actually
    /// call its declared required tools is marked JobFailed instead
    /// of JobComplete. Ordering preserved.
    tools_fired: List(String),
  )
}

/// Reply payload for the `Ping` liveness check. `status_tag` is a
/// short string naming the current `CognitiveStatus` variant (e.g.
/// "Idle", "Thinking", "WaitingForAgents") — useful for the /health
/// endpoint to distinguish a busy-but-alive loop from a hung one.
/// `cycle_id` is the current cycle's id when non-Idle, None when Idle.
pub type PingReply {
  PingReply(status_tag: String, cycle_id: Option(String))
}

// ---------------------------------------------------------------------------
// Cognitive loop status
// ---------------------------------------------------------------------------

pub type CognitiveStatus {
  Idle
  Thinking(task_id: String)
  Classifying(cycle_id: String)
  WaitingForAgents(
    pending_ids: List(String),
    accumulated_results: List(ContentBlock),
    reply_to: Subject(CognitiveReply),
  )
  WaitingForUser(question: String, context: WaitingContext)
  EvaluatingSafety(
    task_id: String,
    response: LlmResponse,
    calls: List(ToolCall),
    reply_to: Subject(CognitiveReply),
  )
  EvaluatingInputSafety(
    cycle_id: String,
    model: String,
    text: String,
    reply_to: Subject(CognitiveReply),
  )
  EvaluatingPostExecution(
    cycle_id: String,
    pre_score: Float,
    reply_to: Subject(CognitiveReply),
  )
}

// ---------------------------------------------------------------------------
// Waiting context — what to do when the user answers
// ---------------------------------------------------------------------------

pub type WaitingContext {
  OwnToolWaiting(tool_use_id: String, reply_to: Subject(CognitiveReply))
  AgentWaiting(reply_to: Subject(String))
}

// ---------------------------------------------------------------------------
// Pending task tracking
// ---------------------------------------------------------------------------

pub type PendingTask {
  PendingThink(
    task_id: String,
    model: String,
    fallback_from: Option(String),
    reply_to: Subject(CognitiveReply),
    output_gate_count: Int,
    empty_retried: Bool,
    node_type: dag_types.CycleNodeType,
  )
  PendingAgent(
    task_id: String,
    tool_use_id: String,
    agent: String,
    reply_to: Subject(CognitiveReply),
  )
}

// ---------------------------------------------------------------------------
// Notification (cognitive → UI channel, decoupled from TUI)
// ---------------------------------------------------------------------------

pub type QuestionSource {
  CognitiveQuestion
  AgentQuestionSource(agent: String)
}

pub type Notification {
  QuestionForHuman(question: String, source: QuestionSource)
  SaveWarning(message: String)
  ToolCalling(name: String)
  SafetyGateNotice(decision: String, score: Float, explanation: String)
  AgentLifecycleNotice(event_type: String, agent_name: String)
  InputQueued(position: Int, queue_size: Int)
  InputQueueFull(queue_cap: Int)
  SchedulerReminder(name: String, title: String, body: String)
  SchedulerJobStarted(name: String, kind: String)
  SchedulerJobCompleted(name: String, result_preview: String)
  SchedulerJobFailed(name: String, reason: String)
  PlannerNotification(task_id: String, title: String, action: String)
  SandboxStarted(pool_size: Int, port_range: String)
  SandboxContainerFailed(slot: Int, reason: String)
  SandboxUnavailable(reason: String)
  ModelEscalation(from_model: String, to_model: String, reason: String)
  /// Live turn-level progress from a delegated agent. Powers the web UI
  /// status strip so the operator sees what's actually happening during
  /// a multi-turn agent react loop instead of an opaque "thinking" spinner.
  AgentProgressNotice(
    agent_name: String,
    turn: Int,
    max_turns: Int,
    tokens: Int,
    current_tool: Option(String),
    elapsed_ms: Int,
  )
  /// Cognitive loop status transition. Drives the status strip's label
  /// and the inline status-bubble's step list.
  /// status: "idle" | "thinking" | "classifying" | "waiting_for_agents"
  ///       | "waiting_for_user" | "evaluating_safety"
  StatusChange(status: String, detail: Option(String))
  /// Per-cycle affect snapshot (0-100 dimensions) + trend + cognitive
  /// status. Drives the web UI ambient background — gradient hue, opacity,
  /// and breathing rhythm all derive from this. Honest biometric signal
  /// of the agent's interior state.
  AffectTickNotice(
    desperation: Float,
    calm: Float,
    confidence: Float,
    frustration: Float,
    pressure: Float,
    trend: String,
    status: String,
  )
}

// ---------------------------------------------------------------------------
// Sensory event — ambient input accumulated between cycles
// ---------------------------------------------------------------------------

pub type SensoryEvent {
  SensoryEvent(name: String, title: String, body: String, fired_at: String)
}

// ---------------------------------------------------------------------------
// Queued input — buffered when the cognitive loop is busy
// ---------------------------------------------------------------------------

pub type QueuedInput {
  QueuedInput(
    source_id: String,
    text: String,
    reply_to: Subject(CognitiveReply),
  )
  QueuedSchedulerInput(
    source_id: String,
    job_name: String,
    query: String,
    kind: scheduler_types.JobKind,
    for_: scheduler_types.ForTarget,
    title: String,
    body: String,
    tags: List(String),
    reply_to: Subject(CognitiveReply),
  )
  QueuedSensoryInput(event: SensoryEvent)
}

// ---------------------------------------------------------------------------
// Delegation progress — mid-flight updates from agent framework
// ---------------------------------------------------------------------------

/// Progress report sent by the framework during an agent's react loop.
pub type DelegationProgress {
  DelegationProgress(
    task_id: String,
    agent: String,
    turn: Int,
    max_turns: Int,
    input_tokens: Int,
    output_tokens: Int,
    last_tool: String,
    depth: Int,
  )
}

/// Live delegation state tracked by the cognitive loop.
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
