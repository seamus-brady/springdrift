import agent/registry.{type Registry}
import agent/types.{
  type AgentCompletionRecord, type CognitiveMessage, type CognitiveStatus,
  type Notification, type PendingTask, type SupervisorMessage,
}
import dag/types as dag_types
import dprime/types as dprime_types
import embedding/types as embedding_types
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/curator.{type CuratorMessage}
import narrative/librarian.{type LibrarianMessage}
import tools/memory

/// Model selection and generation parameters — extracted for documentation
/// and potential future refactoring into a sub-record.
pub type ModelConfig {
  ModelConfig(
    model: String,
    task_model: String,
    reasoning_model: String,
    max_tokens: Int,
    archivist_model: String,
  )
}

/// Memory subsystem references — extracted for documentation
/// and potential future refactoring into a sub-record.
pub type MemoryContext {
  MemoryContext(
    narrative_dir: String,
    cbr_dir: String,
    librarian: Option(Subject(LibrarianMessage)),
    curator: Option(Subject(CuratorMessage)),
    embedding_config: embedding_types.EmbeddingConfig,
  )
}

pub type CognitiveState {
  CognitiveState(
    // --- Core process ---
    self: Subject(CognitiveMessage),
    provider: Provider,
    notify: Subject(Notification),
    // --- Model config (see ModelConfig) ---
    model: String,
    task_model: String,
    reasoning_model: String,
    max_tokens: Int,
    archivist_model: String,
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
    // --- Memory context (see MemoryContext) ---
    narrative_dir: String,
    cbr_dir: String,
    librarian: Option(Subject(LibrarianMessage)),
    curator: Option(Subject(CuratorMessage)),
    embedding_config: embedding_types.EmbeddingConfig,
    // --- Agent subsystem ---
    registry: Registry,
    agent_completions: List(AgentCompletionRecord),
    last_user_input: String,
    supervisor: Option(Subject(SupervisorMessage)),
    // --- D' safety ---
    dprime_state: Option(dprime_types.DprimeState),
    output_dprime_state: Option(dprime_types.DprimeState),
    dprime_decisions: List(dag_types.DprimeDecisionRecord),
    // --- Profile and identity ---
    active_profile: Option(String),
    profile_dirs: List(String),
    write_anywhere: Bool,
    agent_uuid: String,
    session_since: String,
    // --- Memory tool limits ---
    memory_limits: memory.MemoryLimits,
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
  )
}

/// Extract memory context from state.
pub fn memory_context(state: CognitiveState) -> MemoryContext {
  MemoryContext(
    narrative_dir: state.narrative_dir,
    cbr_dir: state.cbr_dir,
    librarian: state.librarian,
    curator: state.curator,
    embedding_config: state.embedding_config,
  )
}
