import agent/registry.{type Registry}
import agent/types.{
  type AgentCompletionRecord, type CognitiveMessage, type CognitiveStatus,
  type Notification, type PendingTask, type SupervisorMessage,
}
import dag/types as dag_types
import dprime/types as dprime_types
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/curator.{type CuratorMessage}
import narrative/librarian.{type LibrarianMessage}

pub type CognitiveState {
  CognitiveState(
    self: Subject(CognitiveMessage),
    provider: Provider,
    model: String,
    system: String,
    max_tokens: Int,
    max_context_messages: Option(Int),
    tools: List(llm_types.Tool),
    messages: List(llm_types.Message),
    registry: Registry,
    pending: Dict(String, PendingTask),
    status: CognitiveStatus,
    cycle_id: Option(String),
    verbose: Bool,
    notify: Subject(Notification),
    task_model: String,
    reasoning_model: String,
    save_in_progress: Bool,
    save_pending: Option(List(llm_types.Message)),
    dprime_state: Option(dprime_types.DprimeState),
    // Narrative (always enabled)
    narrative_dir: String,
    cbr_dir: String,
    archivist_model: String,
    librarian: Option(Subject(LibrarianMessage)),
    agent_completions: List(AgentCompletionRecord),
    last_user_input: String,
    // Profile
    active_profile: Option(String),
    supervisor: Option(Subject(SupervisorMessage)),
    profile_dirs: List(String),
    write_anywhere: Bool,
    output_dprime_state: Option(dprime_types.DprimeState),
    dprime_decisions: List(dag_types.DprimeDecisionRecord),
    curator: Option(Subject(CuratorMessage)),
  )
}
