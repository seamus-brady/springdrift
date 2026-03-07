import agent/supervisor
import agent/types.{
  type AgentSpec, type CognitiveMessage, AgentEvent, AgentSpec, AgentStarted,
  AgentStopped, ShutdownAll, StartChild, StopChild, Temporary,
}
import gleam/erlang/process
import gleeunit/should
import llm/adapters/mock
import llm/types as llm_types

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn noop_executor(call: llm_types.ToolCall) -> llm_types.ToolResult {
  llm_types.ToolFailure(tool_use_id: call.id, error: "no tools")
}

fn make_spec(name: String, provider) -> AgentSpec {
  AgentSpec(
    name:,
    human_name: "Test Agent",
    description: "Test agent",
    system_prompt: "You are a test agent.",
    provider:,
    model: "mock",
    max_tokens: 256,
    max_turns: 3,
    max_consecutive_errors: 2,
    tools: [],
    restart: Temporary,
    tool_executor: noop_executor,
  )
}

// ---------------------------------------------------------------------------
// Start and stop a child
// ---------------------------------------------------------------------------

pub fn start_child_test() {
  let cognitive_subj: process.Subject(CognitiveMessage) = process.new_subject()
  let provider = mock.provider_with_text("ok")
  let sup = supervisor.start(cognitive_subj, 3)

  let reply_subj = process.new_subject()
  process.send(
    sup,
    StartChild(spec: make_spec("test", provider), reply_to: reply_subj),
  )

  let assert Ok(result) = process.receive(reply_subj, 5000)
  result |> should.be_ok

  // Should receive AgentStarted event
  let assert Ok(event_msg) = process.receive(cognitive_subj, 5000)
  case event_msg {
    AgentEvent(event:) ->
      case event {
        AgentStarted(name:, ..) -> name |> should.equal("test")
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn stop_child_test() {
  let cognitive_subj: process.Subject(CognitiveMessage) = process.new_subject()
  let provider = mock.provider_with_text("ok")
  let sup = supervisor.start(cognitive_subj, 3)

  // Start a child first
  let reply_subj = process.new_subject()
  process.send(
    sup,
    StartChild(spec: make_spec("test2", provider), reply_to: reply_subj),
  )
  let assert Ok(_) = process.receive(reply_subj, 5000)
  // Drain AgentStarted
  let assert Ok(_) = process.receive(cognitive_subj, 5000)

  // Stop it
  process.send(sup, StopChild(name: "test2"))

  // Should receive AgentStopped event
  let assert Ok(event_msg) = process.receive(cognitive_subj, 5000)
  case event_msg {
    AgentEvent(event:) ->
      case event {
        AgentStopped(name:) -> name |> should.equal("test2")
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Shutdown all
// ---------------------------------------------------------------------------

pub fn shutdown_all_test() {
  let cognitive_subj: process.Subject(CognitiveMessage) = process.new_subject()
  let provider = mock.provider_with_text("ok")
  let sup = supervisor.start(cognitive_subj, 3)

  // Start a child
  let reply_subj = process.new_subject()
  process.send(
    sup,
    StartChild(spec: make_spec("test3", provider), reply_to: reply_subj),
  )
  let assert Ok(_) = process.receive(reply_subj, 5000)
  // Drain AgentStarted
  let assert Ok(_) = process.receive(cognitive_subj, 5000)

  // Shutdown all
  process.send(sup, ShutdownAll)

  // Should receive AgentStopped
  let assert Ok(event_msg) = process.receive(cognitive_subj, 5000)
  case event_msg {
    AgentEvent(event:) ->
      case event {
        AgentStopped(name:) -> name |> should.equal("test3")
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}
