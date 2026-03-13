/// Supervisor restart strategy tests.
///
/// Note: The agent framework's agent_loop is a permanent recursive loop that
/// never exits after completing a task. Testing actual restart behavior requires
/// killing agent processes, which we do via StopChild + re-StartChild to verify
/// the supervisor handles child lifecycle correctly. We also test that different
/// restart strategies can be specified on agent specs.
import agent/supervisor
import agent/types.{
  type AgentSpec, type CognitiveMessage, AgentComplete, AgentEvent, AgentSpec,
  AgentStarted, AgentStopped, AgentSuccess, AgentTask, Permanent, ShutdownAll,
  StartChild, StopChild, Temporary, Transient,
}
import gleam/erlang/process
import gleam/option.{None}
import gleeunit
import gleeunit/should
import llm/adapters/mock
import llm/types as llm_types

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn noop_executor(call: llm_types.ToolCall) -> llm_types.ToolResult {
  llm_types.ToolFailure(tool_use_id: call.id, error: "no tools")
}

fn make_spec(
  name: String,
  provider,
  restart: types.RestartStrategy,
) -> AgentSpec {
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
    max_context_messages: None,
    tools: [],
    restart:,
    tool_executor: noop_executor,
  )
}

fn start_child(
  sup: process.Subject(types.SupervisorMessage),
  spec: AgentSpec,
) -> process.Subject(types.AgentTask) {
  let reply_subj = process.new_subject()
  process.send(sup, StartChild(spec:, reply_to: reply_subj))
  let assert Ok(Ok(task_subj)) = process.receive(reply_subj, 5000)
  task_subj
}

fn drain_event(
  cognitive: process.Subject(CognitiveMessage),
  timeout: Int,
) -> Result(types.AgentLifecycleEvent, Nil) {
  case process.receive(cognitive, timeout) {
    Ok(AgentEvent(event:)) -> Ok(event)
    Ok(_) -> drain_event(cognitive, timeout)
    Error(_) -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Permanent strategy agent can be started
// ---------------------------------------------------------------------------

pub fn permanent_agent_starts_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let provider = mock.provider_with_text("ok")
  let assert Ok(sup) = supervisor.start(cognitive, 3)
  let spec = make_spec("perm-agent", provider, Permanent)

  let _task_subj = start_child(sup, spec)
  let assert Ok(AgentStarted(name: n, ..)) = drain_event(cognitive, 5000)
  n |> should.equal("perm-agent")
}

// ---------------------------------------------------------------------------
// Transient strategy agent can be started
// ---------------------------------------------------------------------------

pub fn transient_agent_starts_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let provider = mock.provider_with_text("ok")
  let assert Ok(sup) = supervisor.start(cognitive, 3)
  let spec = make_spec("trans-agent", provider, Transient)

  let _task_subj = start_child(sup, spec)
  let assert Ok(AgentStarted(name: n, ..)) = drain_event(cognitive, 5000)
  n |> should.equal("trans-agent")
}

// ---------------------------------------------------------------------------
// Temporary strategy agent can be started
// ---------------------------------------------------------------------------

pub fn temporary_agent_starts_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let provider = mock.provider_with_text("ok")
  let assert Ok(sup) = supervisor.start(cognitive, 3)
  let spec = make_spec("temp-agent", provider, Temporary)

  let _task_subj = start_child(sup, spec)
  let assert Ok(AgentStarted(name: n, ..)) = drain_event(cognitive, 5000)
  n |> should.equal("temp-agent")
}

// ---------------------------------------------------------------------------
// Multiple agents with different strategies
// ---------------------------------------------------------------------------

pub fn mixed_strategy_agents_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let provider = mock.provider_with_text("ok")
  let assert Ok(sup) = supervisor.start(cognitive, 5)

  let _t1 = start_child(sup, make_spec("perm", provider, Permanent))
  let assert Ok(AgentStarted(name: "perm", ..)) = drain_event(cognitive, 5000)

  let _t2 = start_child(sup, make_spec("trans", provider, Transient))
  let assert Ok(AgentStarted(name: "trans", ..)) = drain_event(cognitive, 5000)

  let _t3 = start_child(sup, make_spec("temp", provider, Temporary))
  let assert Ok(AgentStarted(name: "temp", ..)) = drain_event(cognitive, 5000)
}

// ---------------------------------------------------------------------------
// Stop then re-start same agent name
// ---------------------------------------------------------------------------

pub fn stop_and_restart_same_name_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let provider = mock.provider_with_text("ok")
  let assert Ok(sup) = supervisor.start(cognitive, 3)
  let spec = make_spec("recyclable", provider, Temporary)

  let _task_subj1 = start_child(sup, spec)
  let assert Ok(AgentStarted(name: "recyclable", ..)) =
    drain_event(cognitive, 5000)

  // Stop it
  process.send(sup, StopChild(name: "recyclable"))
  let assert Ok(AgentStopped(name: "recyclable")) = drain_event(cognitive, 5000)

  // Re-start with same name
  let _task_subj2 = start_child(sup, spec)
  let assert Ok(AgentStarted(name: "recyclable", ..)) =
    drain_event(cognitive, 5000)
}

// ---------------------------------------------------------------------------
// Agent completes task then remains alive for more tasks
// ---------------------------------------------------------------------------

pub fn agent_survives_task_completion_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let provider = mock.provider_with_text("result")
  let assert Ok(sup) = supervisor.start(cognitive, 3)
  let spec = make_spec("survivor", provider, Permanent)

  let task_subj = start_child(sup, spec)
  let assert Ok(AgentStarted(..)) = drain_event(cognitive, 5000)

  // First task
  let reply1: process.Subject(CognitiveMessage) = process.new_subject()
  process.send(
    task_subj,
    AgentTask(
      task_id: "t1",
      tool_use_id: "tu1",
      instruction: "first",
      context: "",
      parent_cycle_id: "c1",
      reply_to: reply1,
    ),
  )
  let assert Ok(AgentComplete(outcome: AgentSuccess(task_id: "t1", ..))) =
    process.receive(reply1, 5000)

  // Second task — agent should still be alive
  let reply2: process.Subject(CognitiveMessage) = process.new_subject()
  process.send(
    task_subj,
    AgentTask(
      task_id: "t2",
      tool_use_id: "tu2",
      instruction: "second",
      context: "",
      parent_cycle_id: "c2",
      reply_to: reply2,
    ),
  )
  let assert Ok(AgentComplete(outcome: AgentSuccess(task_id: "t2", ..))) =
    process.receive(reply2, 5000)
}

// ---------------------------------------------------------------------------
// ShutdownAll with multiple strategies
// ---------------------------------------------------------------------------

pub fn shutdown_all_mixed_strategies_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let provider = mock.provider_with_text("ok")
  let assert Ok(sup) = supervisor.start(cognitive, 5)

  let _t1 = start_child(sup, make_spec("a", provider, Permanent))
  let assert Ok(AgentStarted(..)) = drain_event(cognitive, 5000)

  let _t2 = start_child(sup, make_spec("b", provider, Transient))
  let assert Ok(AgentStarted(..)) = drain_event(cognitive, 5000)

  let _t3 = start_child(sup, make_spec("c", provider, Temporary))
  let assert Ok(AgentStarted(..)) = drain_event(cognitive, 5000)

  process.send(sup, ShutdownAll)

  // Should get 3 AgentStopped events
  let assert Ok(AgentStopped(..)) = drain_event(cognitive, 5000)
  let assert Ok(AgentStopped(..)) = drain_event(cognitive, 5000)
  let assert Ok(AgentStopped(..)) = drain_event(cognitive, 5000)
}

// ---------------------------------------------------------------------------
// Stop non-existent child doesn't crash
// ---------------------------------------------------------------------------

pub fn stop_nonexistent_child_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let assert Ok(sup) = supervisor.start(cognitive, 3)

  // This should not crash the supervisor
  process.send(sup, StopChild(name: "does-not-exist"))
  // Drain the AgentStopped notification (supervisor sends it even for missing children)
  let assert Ok(AgentStopped(name: "does-not-exist")) =
    drain_event(cognitive, 5000)

  // Start a child to verify supervisor still works
  let provider = mock.provider_with_text("ok")
  let _task_subj =
    start_child(sup, make_spec("after-ghost", provider, Temporary))
  let assert Ok(AgentStarted(name: "after-ghost", ..)) =
    drain_event(cognitive, 5000)
}
