import agent/registry.{type Registry}
import agent/types.{type Notification}
import dprime/types as dprime_types
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None}
import gleam/string
import llm/provider.{type Provider}
import llm/retry
import llm/types as llm_types
import narrative/curator.{type CuratorMessage}
import narrative/librarian.{type LibrarianMessage}
import narrative/threading
import simplifile
import tools/memory

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

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
    archivist_max_tokens: Int,
    librarian: Option(Subject(LibrarianMessage)),
    profile_dirs: List(String),
    write_anywhere: Bool,
    curator: Option(Subject(CuratorMessage)),
    agent_uuid: String,
    session_since: String,
    retry_config: retry.RetryConfig,
    classify_timeout_ms: Int,
    threading_config: threading.ThreadingConfig,
    memory_limits: memory.MemoryLimits,
    input_queue_cap: Int,
    how_to_content: Option(String),
  )
}

/// Create a CognitiveConfig with sensible defaults for testing.
/// Uses isolated temp directories so tests never pollute the live memory store.
pub fn default_test_config(
  provider: Provider,
  notify: Subject(Notification),
) -> CognitiveConfig {
  let id = string.slice(generate_uuid(), 0, 8)
  let base = "/tmp/springdrift_test/" <> id
  let narrative_dir = base <> "/narrative"
  let cbr_dir = base <> "/cbr"
  let _ = simplifile.create_directory_all(narrative_dir)
  let _ = simplifile.create_directory_all(cbr_dir)
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
    narrative_dir:,
    cbr_dir:,
    archivist_model: "mock-model",
    archivist_max_tokens: 8192,
    librarian: None,
    profile_dirs: [],
    write_anywhere: False,
    curator: None,
    agent_uuid: "",
    session_since: "",
    retry_config: retry.default_retry_config(),
    classify_timeout_ms: 10_000,
    threading_config: threading.default_config(),
    memory_limits: memory.default_limits(),
    input_queue_cap: 10,
    how_to_content: None,
  )
}
