import agent/registry.{type Registry}
import agent/types.{type Notification}
import dprime/types as dprime_types
import embedding/types as embedding_types
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/curator.{type CuratorMessage}
import narrative/librarian.{type LibrarianMessage}

/// Configuration record for starting the cognitive loop.
/// Replaces the 19-parameter `cognitive.start()` signature.
pub type CognitiveConfig {
  CognitiveConfig(
    provider: Provider,
    system: String,
    max_tokens: Int,
    max_context_messages: Option(Int),
    agent_tools: List(llm_types.Tool),
    initial_messages: List(llm_types.Message),
    registry: Registry,
    verbose: Bool,
    notify: Subject(Notification),
    task_model: String,
    reasoning_model: String,
    dprime_state: Option(dprime_types.DprimeState),
    output_dprime_state: Option(dprime_types.DprimeState),
    narrative_dir: String,
    cbr_dir: String,
    archivist_model: String,
    librarian: Option(Subject(LibrarianMessage)),
    profile_dirs: List(String),
    write_anywhere: Bool,
    curator: Option(Subject(CuratorMessage)),
    embedding_config: embedding_types.EmbeddingConfig,
    agent_uuid: String,
    session_since: String,
  )
}

/// Create a CognitiveConfig with sensible defaults for testing.
pub fn default_test_config(
  provider: Provider,
  notify: Subject(Notification),
) -> CognitiveConfig {
  CognitiveConfig(
    provider:,
    system: "You are a test assistant.",
    max_tokens: 256,
    max_context_messages: None,
    agent_tools: [],
    initial_messages: [],
    registry: registry.new(),
    verbose: False,
    notify:,
    task_model: "mock-model",
    reasoning_model: "mock-reasoning",
    dprime_state: None,
    output_dprime_state: None,
    narrative_dir: ".springdrift/memory/narrative",
    cbr_dir: ".springdrift/memory/cbr",
    archivist_model: "mock-model",
    librarian: None,
    profile_dirs: [],
    write_anywhere: False,
    curator: None,
    embedding_config: embedding_types.default_config(),
    agent_uuid: "",
    session_since: "",
  )
}
