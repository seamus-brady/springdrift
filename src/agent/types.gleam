import dprime/types as dprime_types
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import llm/provider.{type Provider}
import llm/types.{
  type ContentBlock, type LlmResponse, type Message, type Tool, type ToolCall,
  type ToolResult, type Usage,
}
import query_complexity.{type QueryComplexity}

// ---------------------------------------------------------------------------
// Restart strategy
// ---------------------------------------------------------------------------

pub type RestartStrategy {
  Permanent
  Transient
  Temporary
}

// ---------------------------------------------------------------------------
// Agent spec — pure data describing how to start an agent
// ---------------------------------------------------------------------------

pub type AgentSpec {
  AgentSpec(
    name: String,
    description: String,
    system_prompt: String,
    provider: Provider,
    model: String,
    max_tokens: Int,
    max_turns: Int,
    max_consecutive_errors: Int,
    tools: List(Tool),
    restart: RestartStrategy,
    tool_executor: fn(ToolCall) -> ToolResult,
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
  )
}

// ---------------------------------------------------------------------------
// Agent outcome — result of agent work (always data, never exceptions)
// ---------------------------------------------------------------------------

pub type AgentOutcome {
  AgentSuccess(task_id: String, agent: String, result: String)
  AgentFailure(task_id: String, agent: String, error: String)
}

// ---------------------------------------------------------------------------
// Lifecycle events from supervisor → cognitive loop
// ---------------------------------------------------------------------------

pub type AgentLifecycleEvent {
  AgentStarted(name: String, task_subject: Subject(AgentTask))
  AgentCrashed(name: String, reason: String)
  AgentRestarted(name: String, attempt: Int, task_subject: Subject(AgentTask))
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
}

// ---------------------------------------------------------------------------
// Cognitive loop messages (exhaustive matching)
// ---------------------------------------------------------------------------

pub type CognitiveMessage {
  UserInput(text: String, reply_to: Subject(CognitiveReply))
  UserAnswer(answer: String)
  ThinkComplete(task_id: String, response: LlmResponse)
  ThinkError(task_id: String, error: String, retryable: Bool)
  ThinkWorkerDown(task_id: String, reason: String)
  AgentComplete(outcome: AgentOutcome)
  AgentQuestion(question: String, agent: String, reply_to: Subject(String))
  AgentEvent(event: AgentLifecycleEvent)
  SaveResult(error: Option(String))
  SetModel(model: String)
  RestoreMessages(messages: List(Message))
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
}

pub type CognitiveReply {
  CognitiveReply(response: String, model: String, usage: Option(Usage))
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
}
