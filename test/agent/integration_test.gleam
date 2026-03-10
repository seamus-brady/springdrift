/// Multi-agent integration test — verifies multiple agents can be started via
/// the supervisor and complete tasks independently through the framework.
import agent/framework
import agent/supervisor
import agent/types.{
  type AgentSpec, type CognitiveMessage, AgentComplete, AgentEvent, AgentFailure,
  AgentSpec, AgentStarted, AgentStopped, AgentSuccess, AgentTask, ShutdownAll,
  StartChild, StopChild, Temporary,
}
import gleam/erlang/process
import gleam/list
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
    human_name: name,
    description: name <> " agent",
    system_prompt: "You are a " <> name <> " agent.",
    provider:,
    model: "mock",
    max_tokens: 256,
    max_turns: 3,
    max_consecutive_errors: 2,
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
// Multiple agents started and completing tasks independently
// ---------------------------------------------------------------------------

pub fn multiple_agents_complete_tasks_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let sup = supervisor.start(cognitive, 5)

  // Start three agents with different responses
  let counter = process.new_subject()
  process.send(counter, 0)
  let provider_a = mock.provider_with_text("result-from-alpha")
  let provider_b = mock.provider_with_text("result-from-beta")
  let provider_c = mock.provider_with_text("result-from-gamma")

  let spec_a = make_spec("alpha", provider_a, Temporary)
  let spec_b = make_spec("beta", provider_b, Temporary)
  let spec_c = make_spec("gamma", provider_c, Temporary)

  let task_a = start_child(sup, spec_a)
  let assert Ok(AgentStarted(name: "alpha", ..)) = drain_event(cognitive, 5000)

  let task_b = start_child(sup, spec_b)
  let assert Ok(AgentStarted(name: "beta", ..)) = drain_event(cognitive, 5000)

  let task_c = start_child(sup, spec_c)
  let assert Ok(AgentStarted(name: "gamma", ..)) = drain_event(cognitive, 5000)

  // Send tasks to all three
  let reply_subj: process.Subject(CognitiveMessage) = process.new_subject()

  process.send(
    task_a,
    AgentTask(
      task_id: "task-a",
      tool_use_id: "tu-a",
      instruction: "research topic A",
      context: "",
      parent_cycle_id: "cycle-1",
      reply_to: reply_subj,
    ),
  )
  process.send(
    task_b,
    AgentTask(
      task_id: "task-b",
      tool_use_id: "tu-b",
      instruction: "write about B",
      context: "",
      parent_cycle_id: "cycle-1",
      reply_to: reply_subj,
    ),
  )
  process.send(
    task_c,
    AgentTask(
      task_id: "task-c",
      tool_use_id: "tu-c",
      instruction: "code feature C",
      context: "",
      parent_cycle_id: "cycle-1",
      reply_to: reply_subj,
    ),
  )

  // Collect all three completions
  let assert Ok(msg1) = process.receive(reply_subj, 10_000)
  let assert Ok(msg2) = process.receive(reply_subj, 10_000)
  let assert Ok(msg3) = process.receive(reply_subj, 10_000)

  // All should be AgentComplete
  let results =
    list.filter_map([msg1, msg2, msg3], fn(m) {
      case m {
        AgentComplete(outcome: AgentSuccess(task_id: tid, result: r, ..)) ->
          Ok(#(tid, r))
        _ -> Error(Nil)
      }
    })

  list.length(results) |> should.equal(3)

  // All task IDs should be present
  let task_ids = list.map(results, fn(r) { r.0 })
  list.contains(task_ids, "task-a") |> should.be_true()
  list.contains(task_ids, "task-b") |> should.be_true()
  list.contains(task_ids, "task-c") |> should.be_true()
}

// ---------------------------------------------------------------------------
// Mixed success and failure across agents
// ---------------------------------------------------------------------------

pub fn mixed_success_and_failure_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let sup = supervisor.start(cognitive, 3)

  let good_provider = mock.provider_with_text("success")
  let bad_provider = mock.provider_with_error("model overloaded")

  let spec_good = make_spec("good-agent", good_provider, Temporary)
  let spec_bad = make_spec("bad-agent", bad_provider, Temporary)

  let task_good = start_child(sup, spec_good)
  let assert Ok(AgentStarted(..)) = drain_event(cognitive, 5000)

  let task_bad = start_child(sup, spec_bad)
  let assert Ok(AgentStarted(..)) = drain_event(cognitive, 5000)

  let reply_subj: process.Subject(CognitiveMessage) = process.new_subject()

  process.send(
    task_good,
    AgentTask(
      task_id: "good-task",
      tool_use_id: "tu-good",
      instruction: "do well",
      context: "",
      parent_cycle_id: "cycle-2",
      reply_to: reply_subj,
    ),
  )
  process.send(
    task_bad,
    AgentTask(
      task_id: "bad-task",
      tool_use_id: "tu-bad",
      instruction: "do badly",
      context: "",
      parent_cycle_id: "cycle-2",
      reply_to: reply_subj,
    ),
  )

  // Collect both
  let assert Ok(msg1) = process.receive(reply_subj, 10_000)
  let assert Ok(msg2) = process.receive(reply_subj, 10_000)

  // Categorize
  let outcomes =
    list.map([msg1, msg2], fn(m) {
      case m {
        AgentComplete(outcome: AgentSuccess(task_id: tid, ..)) -> #(
          tid,
          "success",
        )
        AgentComplete(outcome: AgentFailure(task_id: tid, ..)) -> #(
          tid,
          "failure",
        )
        _ -> #("unknown", "unknown")
      }
    })

  // Should have one success and one failure
  let assert Ok(#("good-task", "success")) =
    list.find(outcomes, fn(o) { o.0 == "good-task" })
  let assert Ok(#("bad-task", "failure")) =
    list.find(outcomes, fn(o) { o.0 == "bad-task" })
}

// ---------------------------------------------------------------------------
// Supervisor shutdown stops all agents
// ---------------------------------------------------------------------------

pub fn shutdown_stops_running_agents_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let sup = supervisor.start(cognitive, 3)

  let provider = mock.provider_with_text("ok")
  let spec_a = make_spec("agent-x", provider, Temporary)
  let spec_b = make_spec("agent-y", provider, Temporary)

  let _task_a = start_child(sup, spec_a)
  let assert Ok(AgentStarted(name: "agent-x", ..)) =
    drain_event(cognitive, 5000)

  let _task_b = start_child(sup, spec_b)
  let assert Ok(AgentStarted(name: "agent-y", ..)) =
    drain_event(cognitive, 5000)

  // Shutdown all
  process.send(sup, ShutdownAll)

  // Should receive AgentStopped for both
  let assert Ok(AgentStopped(..)) = drain_event(cognitive, 5000)
  let assert Ok(AgentStopped(..)) = drain_event(cognitive, 5000)
}

// ---------------------------------------------------------------------------
// Agent with tool executor receives tool calls
// ---------------------------------------------------------------------------

pub fn agent_tool_execution_test() {
  // Provider that returns a tool call on first call (no tool results in messages),
  // then returns text on second call (has tool results in messages).
  let provider =
    mock.provider_with_handler(fn(req: llm_types.LlmRequest) {
      // Check if the request already has tool results (second call)
      let has_tool_results =
        list.any(req.messages, fn(m) {
          list.any(m.content, fn(c) {
            case c {
              llm_types.ToolResultContent(..) -> True
              _ -> False
            }
          })
        })
      case has_tool_results {
        False ->
          Ok(mock.tool_call_response(
            "calculator",
            "{\"a\": 2, \"operator\": \"+\", \"b\": 3}",
            "tc-1",
          ))
        True -> Ok(mock.text_response("The answer is 5"))
      }
    })

  let spec =
    AgentSpec(
      name: "calc-agent",
      human_name: "Calculator Agent",
      description: "An agent that can calculate",
      system_prompt: "You are a calculator agent.",
      provider:,
      model: "mock",
      max_tokens: 256,
      max_turns: 5,
      max_consecutive_errors: 2,
      tools: [],
      restart: Temporary,
      tool_executor: fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
        case call.name {
          "calculator" ->
            llm_types.ToolSuccess(tool_use_id: call.id, content: "5")
          _ -> llm_types.ToolFailure(tool_use_id: call.id, error: "unknown")
        }
      },
    )

  let assert Ok(#(_pid, task_subj)) = framework.start_agent(spec)

  let reply_subj: process.Subject(CognitiveMessage) = process.new_subject()
  process.send(
    task_subj,
    AgentTask(
      task_id: "calc-task",
      tool_use_id: "tu-calc",
      instruction: "What is 2 + 3?",
      context: "",
      parent_cycle_id: "cycle-3",
      reply_to: reply_subj,
    ),
  )

  let assert Ok(msg) = process.receive(reply_subj, 10_000)
  case msg {
    AgentComplete(outcome: AgentSuccess(result: r, tools_used: tools, ..)) -> {
      r |> should.equal("The answer is 5")
      list.contains(tools, "calculator") |> should.be_true()
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Stop one agent while others continue
// ---------------------------------------------------------------------------

pub fn stop_one_agent_others_continue_test() {
  let cognitive: process.Subject(CognitiveMessage) = process.new_subject()
  let sup = supervisor.start(cognitive, 3)

  let provider = mock.provider_with_text("still alive")
  let spec_keep = make_spec("keeper", provider, Temporary)
  let spec_remove = make_spec("remover", provider, Temporary)

  let task_keep = start_child(sup, spec_keep)
  let assert Ok(AgentStarted(name: "keeper", ..)) = drain_event(cognitive, 5000)

  let _task_remove = start_child(sup, spec_remove)
  let assert Ok(AgentStarted(name: "remover", ..)) =
    drain_event(cognitive, 5000)

  // Stop one agent
  process.send(sup, StopChild(name: "remover"))
  let assert Ok(AgentStopped(name: "remover")) = drain_event(cognitive, 5000)

  // The remaining agent should still work
  let reply_subj: process.Subject(CognitiveMessage) = process.new_subject()
  process.send(
    task_keep,
    AgentTask(
      task_id: "keep-task",
      tool_use_id: "tu-keep",
      instruction: "are you there?",
      context: "",
      parent_cycle_id: "cycle-4",
      reply_to: reply_subj,
    ),
  )

  let assert Ok(msg) = process.receive(reply_subj, 10_000)
  case msg {
    AgentComplete(outcome: AgentSuccess(task_id: tid, ..)) ->
      tid |> should.equal("keep-task")
    _ -> should.fail()
  }
}
