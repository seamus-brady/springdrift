import agent/framework
import agent/types.{
  type AgentSpec, type CognitiveMessage, AgentComplete, AgentFailure, AgentSpec,
  AgentSuccess, AgentTask, Temporary,
}
import gleam/erlang/process
import gleam/option.{None}
import gleeunit/should
import llm/adapters/mock
import llm/types as llm_types

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn noop_executor(call: llm_types.ToolCall) -> llm_types.ToolResult {
  llm_types.ToolFailure(tool_use_id: call.id, error: "no tools")
}

fn make_spec(provider) -> AgentSpec {
  AgentSpec(
    name: "test-agent",
    human_name: "Test Agent",
    description: "A test agent",
    system_prompt: "You are a test agent.",
    provider:,
    model: "mock",
    max_tokens: 256,
    max_turns: 3,
    max_consecutive_errors: 2,
    max_context_messages: None,
    tools: [],
    restart: Temporary,
    tool_executor: noop_executor,
    inter_turn_delay_ms: 200,
  )
}

// ---------------------------------------------------------------------------
// Agent starts and accepts a task → returns AgentSuccess
// ---------------------------------------------------------------------------

pub fn agent_success_test() {
  let provider = mock.provider_with_text("task completed")
  let spec = make_spec(provider)
  let assert Ok(#(_pid, task_subj)) = framework.start_agent(spec)

  let cognitive_subj: process.Subject(CognitiveMessage) = process.new_subject()
  let task =
    AgentTask(
      task_id: "task-1",
      tool_use_id: "tool-1",
      instruction: "Do something",
      context: "",
      parent_cycle_id: "cycle-1",
      reply_to: cognitive_subj,
    )
  process.send(task_subj, task)

  // Should receive AgentComplete with success
  let assert Ok(msg) = process.receive(cognitive_subj, 5000)
  case msg {
    AgentComplete(outcome:) ->
      case outcome {
        AgentSuccess(task_id: tid, agent: name, result: text, ..) -> {
          tid |> should.equal("task-1")
          name |> should.equal("test-agent")
          text |> should.equal("task completed")
        }
        AgentFailure(..) -> should.fail()
      }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Agent returns AgentFailure on provider error
// ---------------------------------------------------------------------------

pub fn agent_failure_on_error_test() {
  let provider = mock.provider_with_error("provider broke")
  let spec = make_spec(provider)
  let assert Ok(#(_pid, task_subj)) = framework.start_agent(spec)

  let cognitive_subj: process.Subject(CognitiveMessage) = process.new_subject()
  let task =
    AgentTask(
      task_id: "task-2",
      tool_use_id: "tool-2",
      instruction: "Do something",
      context: "",
      parent_cycle_id: "cycle-2",
      reply_to: cognitive_subj,
    )
  process.send(task_subj, task)

  let assert Ok(msg) = process.receive(cognitive_subj, 5000)
  case msg {
    AgentComplete(outcome:) ->
      case outcome {
        AgentFailure(task_id: tid, agent: name, ..) -> {
          tid |> should.equal("task-2")
          name |> should.equal("test-agent")
        }
        AgentSuccess(..) -> should.fail()
      }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Agent handles multiple concurrent tasks
// ---------------------------------------------------------------------------

pub fn agent_handles_multiple_tasks_test() {
  let provider = mock.provider_with_text("done")
  let spec = make_spec(provider)
  let assert Ok(#(_pid, task_subj)) = framework.start_agent(spec)

  let cognitive_subj: process.Subject(CognitiveMessage) = process.new_subject()

  // Send two tasks
  process.send(
    task_subj,
    AgentTask(
      task_id: "task-a",
      tool_use_id: "tool-a",
      instruction: "Task A",
      context: "",
      parent_cycle_id: "cycle-a",
      reply_to: cognitive_subj,
    ),
  )
  process.send(
    task_subj,
    AgentTask(
      task_id: "task-b",
      tool_use_id: "tool-b",
      instruction: "Task B",
      context: "",
      parent_cycle_id: "cycle-b",
      reply_to: cognitive_subj,
    ),
  )

  // Should receive two AgentComplete messages
  let assert Ok(_msg1) = process.receive(cognitive_subj, 5000)
  let assert Ok(_msg2) = process.receive(cognitive_subj, 5000)
}
