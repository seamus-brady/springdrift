import agent/cognitive/escalation.{type EscalationConfig}
import agent/registry.{type Registry}
import agent/types.{
  type AgentCompletionRecord, type CognitiveMessage, type CognitiveStatus,
  type DelegationInfo, type Notification, type PendingTask, type QueuedInput,
  type SensoryEvent, type SupervisorMessage,
}
import dag/types as dag_types
import dprime/deterministic.{type DeterministicConfig}
import dprime/types as dprime_types
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import llm/provider.{type Provider}
import llm/retry
import llm/types as llm_types

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

import meta/log as meta_log
import meta/observer as meta_observer
import meta/types as meta_types
import narrative/curator.{type CuratorMessage}
import narrative/librarian.{type LibrarianMessage}
import narrative/threading
import tools/memory

/// Model selection and generation parameters.
pub type ModelConfig {
  ModelConfig(
    model: String,
    task_model: String,
    reasoning_model: String,
    max_tokens: Int,
    archivist_model: String,
    archivist_max_tokens: Int,
  )
}

/// Memory subsystem references — set once at startup, never mutated.
pub type MemoryContext {
  MemoryContext(
    narrative_dir: String,
    cbr_dir: String,
    librarian: Option(Subject(LibrarianMessage)),
    curator: Option(Subject(CuratorMessage)),
  )
}

/// Identity and profile context — set at startup, rarely mutated.
pub type IdentityContext {
  IdentityContext(
    agent_uuid: String,
    agent_name: String,
    session_since: String,
    write_anywhere: Bool,
  )
}

/// Runtime configuration — set at startup, never mutated.
pub type RuntimeConfig {
  RuntimeConfig(
    retry_config: retry.RetryConfig,
    classify_timeout_ms: Int,
    threading_config: threading.ThreadingConfig,
    memory_limits: memory.MemoryLimits,
    how_to_content: Option(String),
    max_delegation_depth: Int,
    sandbox_enabled: Bool,
    deterministic_config: Option(DeterministicConfig),
    fact_decay_half_life_days: Int,
    escalation_config: EscalationConfig,
  )
}

pub type CognitiveState {
  CognitiveState(
    // --- Core process ---
    self: Subject(CognitiveMessage),
    provider: Provider,
    notify: Subject(Notification),
    // --- Model config ---
    model: String,
    task_model: String,
    reasoning_model: String,
    max_tokens: Int,
    archivist_model: String,
    archivist_max_tokens: Int,
    // --- Conversation ---
    system: String,
    max_context_messages: Option(Int),
    tools: List(llm_types.Tool),
    messages: List(llm_types.Message),
    // --- Loop control ---
    status: CognitiveStatus,
    cycle_id: Option(String),
    pending: Dict(String, PendingTask),
    save_in_progress: Bool,
    save_pending: Option(List(llm_types.Message)),
    verbose: Bool,
    // --- Memory context (read-only after init) ---
    memory: MemoryContext,
    // --- Agent subsystem ---
    registry: Registry,
    agent_completions: List(AgentCompletionRecord),
    active_delegations: Dict(String, DelegationInfo),
    last_user_input: String,
    supervisor: Option(Subject(SupervisorMessage)),
    // --- Cycle telemetry ---
    cycle_tool_calls: List(dag_types.ToolSummary),
    cycle_started_ms: Int,
    cycle_node_type: dag_types.CycleNodeType,
    // --- D' safety (isolated per gate type to prevent history contamination) ---
    input_dprime_state: Option(dprime_types.DprimeState),
    tool_dprime_state: Option(dprime_types.DprimeState),
    output_dprime_state: Option(dprime_types.DprimeState),
    dprime_decisions: List(dag_types.DprimeDecisionRecord),
    // --- Input queue ---
    input_queue: List(QueuedInput),
    input_queue_cap: Int,
    // --- Sensory events (accumulated between cycles) ---
    pending_sensory_events: List(SensoryEvent),
    active_task_id: Option(String),
    // --- Planner persistence ---
    planner_dir: String,
    // --- Identity and profile (read-only after init) ---
    identity: IdentityContext,
    // --- Runtime config (read-only after init) ---
    config: RuntimeConfig,
    // --- Secret redaction ---
    redact_secrets: Bool,
    // --- Layer 3b meta observer ---
    meta_state: Option(meta_types.MetaState),
  )
}

/// Extract model config from state.
pub fn model_config(state: CognitiveState) -> ModelConfig {
  ModelConfig(
    model: state.model,
    task_model: state.task_model,
    reasoning_model: state.reasoning_model,
    max_tokens: state.max_tokens,
    archivist_model: state.archivist_model,
    archivist_max_tokens: state.archivist_max_tokens,
  )
}

/// Extract memory context from state.
pub fn memory_context(state: CognitiveState) -> MemoryContext {
  state.memory
}

/// Run the Layer 3b meta observer post-cycle and update state.
/// Called after CognitiveReply is sent but before transitioning to Idle.
/// `tokens_used` is the total tokens (input + output) for this cycle.
pub fn apply_meta_observation(
  state: CognitiveState,
  tokens_used: Int,
) -> CognitiveState {
  case state.meta_state {
    None -> state
    Some(ms) -> {
      let cycle_id = option.unwrap(state.cycle_id, "unknown")
      let gate_summaries =
        list.map(state.dprime_decisions, fn(d) {
          meta_types.GateDecisionSummary(
            gate: d.gate,
            decision: d.decision,
            score: d.score,
          )
        })
      let obs =
        meta_types.MetaObservation(
          cycle_id:,
          timestamp: get_datetime(),
          gate_decisions: gate_summaries,
          tokens_used:,
          tool_call_count: list.length(state.cycle_tool_calls),
          had_delegations: !dict.is_empty(state.active_delegations),
        )
      // Persist to JSONL for cross-session continuity
      meta_log.append(obs)
      let new_ms = meta_observer.observe(ms, obs)
      CognitiveState(..state, meta_state: Some(new_ms))
    }
  }
}
