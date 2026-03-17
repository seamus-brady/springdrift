import agents/scheduler as scheduler_agent
import gleam/erlang/process
import gleam/list

import gleeunit/should
import llm/adapters/mock
import llm/types.{ToolCall, ToolFailure, ToolSuccess}
import scheduler/types as sched_types

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A mock scheduler runner that handles AddJob, RemoveJob, CompleteJob, GetJobs.
fn mock_runner() -> process.Subject(sched_types.SchedulerMessage) {
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let subj: process.Subject(sched_types.SchedulerMessage) =
      process.new_subject()
    process.send(setup, subj)
    mock_runner_loop(subj)
  })
  let assert Ok(subj) = process.receive(setup, 5000)
  subj
}

fn mock_runner_loop(subj: process.Subject(sched_types.SchedulerMessage)) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(subj)
  let msg = process.selector_receive_forever(selector)
  case msg {
    sched_types.AddJob(job:, reply_to:) -> {
      process.send(reply_to, Ok(job.name))
    }
    sched_types.RemoveJob(name: _, reply_to:) -> {
      process.send(reply_to, Ok(Nil))
    }
    sched_types.CompleteJob(name: _, reply_to:) -> {
      process.send(reply_to, Ok(Nil))
    }
    sched_types.GetJobs(query: _, reply_to:) -> {
      process.send(reply_to, [])
    }
    sched_types.UpdateJob(name: _, updates: _, reply_to:) -> {
      process.send(reply_to, Ok(Nil))
    }
    sched_types.StopAll -> Nil
    _ -> Nil
  }
  mock_runner_loop(subj)
}

// ---------------------------------------------------------------------------
// spec produces valid AgentSpec
// ---------------------------------------------------------------------------

pub fn spec_name_test() {
  let runner = mock_runner()
  let provider = mock.provider_with_text("test")
  let s = scheduler_agent.spec(provider, "test-model", runner)
  s.name |> should.equal("scheduler")
  s.human_name |> should.equal("Scheduler")
  process.send(runner, sched_types.StopAll)
}

pub fn spec_has_tools_test() {
  let runner = mock_runner()
  let provider = mock.provider_with_text("test")
  let s = scheduler_agent.spec(provider, "test-model", runner)
  // Should have 8 tools
  list.length(s.tools) |> should.equal(8)
  process.send(runner, sched_types.StopAll)
}

// ---------------------------------------------------------------------------
// Tool executor routes get_current_datetime
// ---------------------------------------------------------------------------

pub fn executor_routes_datetime_test() {
  let runner = mock_runner()
  let provider = mock.provider_with_text("test")
  let s = scheduler_agent.spec(provider, "test-model", runner)
  let call =
    ToolCall(id: "test-1", name: "get_current_datetime", input_json: "{}")
  let result = s.tool_executor(call)
  case result {
    ToolSuccess(tool_use_id: id, content: c) -> {
      id |> should.equal("test-1")
      // Content should be a datetime string (non-empty)
      { c != "" } |> should.be_true()
    }
    _ -> should.fail()
  }
  process.send(runner, sched_types.StopAll)
}

// ---------------------------------------------------------------------------
// Tool executor routes schedule_reminder → AddJob
// ---------------------------------------------------------------------------

pub fn executor_routes_schedule_reminder_test() {
  let runner = mock_runner()
  let provider = mock.provider_with_text("test")
  let s = scheduler_agent.spec(provider, "test-model", runner)
  let call =
    ToolCall(
      id: "test-2",
      name: "schedule_reminder",
      input_json: "{\"title\":\"Call dentist\",\"due_at\":\"2026-03-18T15:00:00\",\"for_\":\"user\"}",
    )
  let result = s.tool_executor(call)
  case result {
    ToolSuccess(tool_use_id: id, content: c) -> {
      id |> should.equal("test-2")
      // Should mention the title
      { c != "" } |> should.be_true()
    }
    _ -> should.fail()
  }
  process.send(runner, sched_types.StopAll)
}

// ---------------------------------------------------------------------------
// Tool executor routes cancel_item → RemoveJob
// ---------------------------------------------------------------------------

pub fn executor_routes_cancel_item_test() {
  let runner = mock_runner()
  let provider = mock.provider_with_text("test")
  let s = scheduler_agent.spec(provider, "test-model", runner)
  let call =
    ToolCall(
      id: "test-3",
      name: "cancel_item",
      input_json: "{\"name\":\"remind-test-123\"}",
    )
  let result = s.tool_executor(call)
  case result {
    ToolSuccess(tool_use_id: id, content: _) -> {
      id |> should.equal("test-3")
    }
    _ -> should.fail()
  }
  process.send(runner, sched_types.StopAll)
}

// ---------------------------------------------------------------------------
// Tool executor routes complete_item → CompleteJob
// ---------------------------------------------------------------------------

pub fn executor_routes_complete_item_test() {
  let runner = mock_runner()
  let provider = mock.provider_with_text("test")
  let s = scheduler_agent.spec(provider, "test-model", runner)
  let call =
    ToolCall(
      id: "test-4",
      name: "complete_item",
      input_json: "{\"name\":\"todo-test-456\"}",
    )
  let result = s.tool_executor(call)
  case result {
    ToolSuccess(tool_use_id: id, content: _) -> {
      id |> should.equal("test-4")
    }
    _ -> should.fail()
  }
  process.send(runner, sched_types.StopAll)
}

// ---------------------------------------------------------------------------
// Tool executor routes list_schedule → GetJobs
// ---------------------------------------------------------------------------

pub fn executor_routes_list_schedule_test() {
  let runner = mock_runner()
  let provider = mock.provider_with_text("test")
  let s = scheduler_agent.spec(provider, "test-model", runner)
  let call =
    ToolCall(
      id: "test-5",
      name: "list_schedule",
      input_json: "{\"filter\":\"all\"}",
    )
  let result = s.tool_executor(call)
  case result {
    ToolSuccess(tool_use_id: id, content: c) -> {
      id |> should.equal("test-5")
      // Empty list returns "No scheduled items found."
      c |> should.equal("No scheduled items found.")
    }
    _ -> should.fail()
  }
  process.send(runner, sched_types.StopAll)
}

// ---------------------------------------------------------------------------
// Unknown tool returns ToolFailure
// ---------------------------------------------------------------------------

pub fn executor_unknown_tool_test() {
  let runner = mock_runner()
  let provider = mock.provider_with_text("test")
  let s = scheduler_agent.spec(provider, "test-model", runner)
  let call = ToolCall(id: "test-6", name: "nonexistent_tool", input_json: "{}")
  let result = s.tool_executor(call)
  case result {
    ToolFailure(tool_use_id: id, error: _) -> {
      id |> should.equal("test-6")
    }
    _ -> should.fail()
  }
  process.send(runner, sched_types.StopAll)
}

// ---------------------------------------------------------------------------
// add_todo tool
// ---------------------------------------------------------------------------

pub fn executor_routes_add_todo_test() {
  let runner = mock_runner()
  let provider = mock.provider_with_text("test")
  let s = scheduler_agent.spec(provider, "test-model", runner)
  let call =
    ToolCall(
      id: "test-7",
      name: "add_todo",
      input_json: "{\"title\":\"Buy milk\",\"for_\":\"user\"}",
    )
  let result = s.tool_executor(call)
  case result {
    ToolSuccess(tool_use_id: id, content: _) -> {
      id |> should.equal("test-7")
    }
    _ -> should.fail()
  }
  process.send(runner, sched_types.StopAll)
}

// ---------------------------------------------------------------------------
// add_appointment tool
// ---------------------------------------------------------------------------

pub fn executor_routes_add_appointment_test() {
  let runner = mock_runner()
  let provider = mock.provider_with_text("test")
  let s = scheduler_agent.spec(provider, "test-model", runner)
  let call =
    ToolCall(
      id: "test-8",
      name: "add_appointment",
      input_json: "{\"title\":\"Team sync\",\"at\":\"2026-03-18T15:00:00\",\"for_\":\"user\"}",
    )
  let result = s.tool_executor(call)
  case result {
    ToolSuccess(tool_use_id: id, content: _) -> {
      id |> should.equal("test-8")
    }
    _ -> should.fail()
  }
  process.send(runner, sched_types.StopAll)
}

// ---------------------------------------------------------------------------
// update_item tool
// ---------------------------------------------------------------------------

pub fn executor_routes_update_item_test() {
  let runner = mock_runner()
  let provider = mock.provider_with_text("test")
  let s = scheduler_agent.spec(provider, "test-model", runner)
  let call =
    ToolCall(
      id: "test-9",
      name: "update_item",
      input_json: "{\"name\":\"remind-test-123\",\"title\":\"New title\"}",
    )
  let result = s.tool_executor(call)
  case result {
    ToolSuccess(tool_use_id: id, content: _) -> {
      id |> should.equal("test-9")
    }
    _ -> should.fail()
  }
  process.send(runner, sched_types.StopAll)
}
