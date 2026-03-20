import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import planner/log
import planner/types.{
  type Endeavour, type PlannerTask, Active, Complete, Endeavour,
  EndeavourComplete, Open, Pending, PlanStep, PlannerTask, SystemEndeavour,
  SystemTask,
}
import simplifile

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/planner_log_test_" <> suffix
  let _ = simplifile.create_directory_all(dir)
  case simplifile.read_directory(dir) {
    Ok(files) ->
      list.each(files, fn(f) {
        let _ = simplifile.delete(dir <> "/" <> f)
        Nil
      })
    Error(_) -> Nil
  }
  dir
}

fn make_task(id: String, title: String) -> PlannerTask {
  PlannerTask(
    task_id: id,
    endeavour_id: None,
    origin: SystemTask,
    title:,
    description: "Test task",
    status: Pending,
    plan_steps: [
      PlanStep(
        index: 1,
        description: "Step one",
        status: Pending,
        completed_at: None,
      ),
      PlanStep(
        index: 2,
        description: "Step two",
        status: Pending,
        completed_at: None,
      ),
    ],
    dependencies: [],
    complexity: "simple",
    risks: ["risk1"],
    materialised_risks: [],
    created_at: "2026-03-19T09:00:00",
    updated_at: "2026-03-19T09:00:00",
    cycle_ids: [],
    forecast_score: None,
  )
}

fn make_endeavour(id: String, title: String) -> Endeavour {
  Endeavour(
    endeavour_id: id,
    origin: SystemEndeavour,
    title:,
    description: "Test endeavour",
    status: Open,
    task_ids: [],
    created_at: "2026-03-19T09:00:00",
    updated_at: "2026-03-19T09:00:00",
  )
}

// ---------------------------------------------------------------------------
// Task persistence tests
// ---------------------------------------------------------------------------

pub fn load_empty_dir_test() {
  let dir = test_dir("empty")
  let ops = log.load_all_task_ops(dir)
  ops |> should.equal([])
}

pub fn load_nonexistent_dir_test() {
  let ops = log.load_all_task_ops("/tmp/planner_nonexistent_xyz")
  ops |> should.equal([])
}

pub fn task_ops_write_and_load_test() {
  let dir = test_dir("task_ops")
  let task = make_task("task-001", "Research pricing")

  // Write operations directly to a file (simulating append)
  let create_op = types.CreateTask(task:)
  let status_op =
    types.UpdateTaskStatus(
      task_id: "task-001",
      status: Active,
      at: "2026-03-19T10:00:00",
    )

  let line1 = json.to_string(log.encode_task_op(create_op))
  let line2 = json.to_string(log.encode_task_op(status_op))
  let _ =
    simplifile.write(
      dir <> "/2026-03-19-tasks.jsonl",
      line1 <> "\n" <> line2 <> "\n",
    )

  let ops = log.load_all_task_ops(dir)
  list.length(ops) |> should.equal(2)
}

// ---------------------------------------------------------------------------
// Resolve tests
// ---------------------------------------------------------------------------

pub fn resolve_create_task_test() {
  let task = make_task("task-001", "Research pricing")
  let ops = [types.CreateTask(task:)]
  let tasks = log.resolve_tasks(ops)

  list.length(tasks) |> should.equal(1)
  let assert [resolved] = tasks
  resolved.task_id |> should.equal("task-001")
  resolved.status |> should.equal(Pending)
}

pub fn resolve_update_status_test() {
  let task = make_task("task-001", "Research pricing")
  let ops = [
    types.CreateTask(task:),
    types.UpdateTaskStatus(
      task_id: "task-001",
      status: Active,
      at: "2026-03-19T10:00:00",
    ),
  ]
  let tasks = log.resolve_tasks(ops)

  let assert [resolved] = tasks
  resolved.status |> should.equal(Active)
  resolved.updated_at |> should.equal("2026-03-19T10:00:00")
}

pub fn resolve_complete_step_test() {
  let task = make_task("task-001", "Research")
  let ops = [
    types.CreateTask(task:),
    types.CompleteStep(
      task_id: "task-001",
      step_index: 1,
      at: "2026-03-19T10:00:00",
    ),
  ]
  let tasks = log.resolve_tasks(ops)

  let assert [resolved] = tasks
  case resolved.plan_steps {
    [s1, s2] -> {
      s1.status |> should.equal(Complete)
      s1.completed_at |> should.equal(Some("2026-03-19T10:00:00"))
      s2.status |> should.equal(Pending)
    }
    _ -> should.fail()
  }
  // Task not auto-completed since step 2 still pending
  resolved.status |> should.equal(Pending)
}

pub fn resolve_auto_complete_all_steps_test() {
  let task = make_task("task-001", "Research")
  let ops = [
    types.CreateTask(task:),
    types.CompleteStep(
      task_id: "task-001",
      step_index: 1,
      at: "2026-03-19T10:00:00",
    ),
    types.CompleteStep(
      task_id: "task-001",
      step_index: 2,
      at: "2026-03-19T11:00:00",
    ),
  ]
  let tasks = log.resolve_tasks(ops)

  let assert [resolved] = tasks
  // Task auto-completes when all steps done
  resolved.status |> should.equal(Complete)
}

pub fn resolve_flag_risk_test() {
  let task = make_task("task-001", "Research")
  let ops = [
    types.CreateTask(task:),
    types.FlagRisk(
      task_id: "task-001",
      text: "Login wall encountered",
      at: "2026-03-19T10:00:00",
    ),
  ]
  let tasks = log.resolve_tasks(ops)

  let assert [resolved] = tasks
  resolved.materialised_risks |> should.equal(["Login wall encountered"])
}

pub fn resolve_add_cycle_id_test() {
  let task = make_task("task-001", "Research")
  let ops = [
    types.CreateTask(task:),
    types.AddCycleId(task_id: "task-001", cycle_id: "cycle-001"),
    types.AddCycleId(task_id: "task-001", cycle_id: "cycle-002"),
    // Duplicate should be ignored
    types.AddCycleId(task_id: "task-001", cycle_id: "cycle-001"),
  ]
  let tasks = log.resolve_tasks(ops)

  let assert [resolved] = tasks
  resolved.cycle_ids |> should.equal(["cycle-001", "cycle-002"])
}

pub fn resolve_update_forecast_score_test() {
  let task = make_task("task-001", "Research")
  let ops = [
    types.CreateTask(task:),
    types.UpdateForecastScore(task_id: "task-001", score: 0.42),
  ]
  let tasks = log.resolve_tasks(ops)

  let assert [resolved] = tasks
  resolved.forecast_score |> should.equal(Some(0.42))
}

pub fn resolve_unknown_task_id_ignored_test() {
  let task = make_task("task-001", "Research")
  let ops = [
    types.CreateTask(task:),
    // Op for unknown task — should be silently ignored
    types.UpdateTaskStatus(
      task_id: "task-999",
      status: Active,
      at: "2026-03-19T10:00:00",
    ),
  ]
  let tasks = log.resolve_tasks(ops)

  list.length(tasks) |> should.equal(1)
  let assert [resolved] = tasks
  resolved.status |> should.equal(Pending)
}

pub fn resolve_multiple_tasks_test() {
  let t1 = make_task("task-001", "First")
  let t2 = make_task("task-002", "Second")
  let ops = [
    types.CreateTask(task: t1),
    types.CreateTask(task: t2),
    types.UpdateTaskStatus(
      task_id: "task-001",
      status: Active,
      at: "2026-03-19T10:00:00",
    ),
  ]
  let tasks = log.resolve_tasks(ops)

  list.length(tasks) |> should.equal(2)
}

// ---------------------------------------------------------------------------
// Endeavour persistence tests
// ---------------------------------------------------------------------------

pub fn endeavour_ops_empty_test() {
  let dir = test_dir("end_empty")
  let ops = log.load_all_endeavour_ops(dir)
  ops |> should.equal([])
}

pub fn endeavour_ops_write_and_load_test() {
  let dir = test_dir("end_ops")
  let e = make_endeavour("end-001", "Market report")
  let op = types.CreateEndeavour(endeavour: e)
  let line = json.to_string(log.encode_endeavour_op(op))
  let _ = simplifile.write(dir <> "/2026-03-19-endeavours.jsonl", line <> "\n")

  let ops = log.load_all_endeavour_ops(dir)
  list.length(ops) |> should.equal(1)
}

pub fn resolve_create_endeavour_test() {
  let e = make_endeavour("end-001", "Market report")
  let ops = [types.CreateEndeavour(endeavour: e)]
  let endeavours = log.resolve_endeavours(ops)

  list.length(endeavours) |> should.equal(1)
  let assert [resolved] = endeavours
  resolved.endeavour_id |> should.equal("end-001")
  resolved.status |> should.equal(Open)
}

pub fn resolve_add_task_to_endeavour_test() {
  let e = make_endeavour("end-001", "Market report")
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.AddTaskToEndeavour(endeavour_id: "end-001", task_id: "task-001"),
    types.AddTaskToEndeavour(endeavour_id: "end-001", task_id: "task-002"),
    // Duplicate should be ignored
    types.AddTaskToEndeavour(endeavour_id: "end-001", task_id: "task-001"),
  ]
  let endeavours = log.resolve_endeavours(ops)

  let assert [resolved] = endeavours
  resolved.task_ids |> should.equal(["task-001", "task-002"])
}

pub fn resolve_update_endeavour_status_test() {
  let e = make_endeavour("end-001", "Market report")
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.UpdateEndeavourStatus(
      endeavour_id: "end-001",
      status: EndeavourComplete,
    ),
  ]
  let endeavours = log.resolve_endeavours(ops)

  let assert [resolved] = endeavours
  resolved.status |> should.equal(EndeavourComplete)
}

pub fn resolve_unknown_endeavour_id_ignored_test() {
  let e = make_endeavour("end-001", "Market report")
  let ops = [
    types.CreateEndeavour(endeavour: e),
    types.AddTaskToEndeavour(endeavour_id: "end-999", task_id: "task-001"),
  ]
  let endeavours = log.resolve_endeavours(ops)

  let assert [resolved] = endeavours
  resolved.task_ids |> should.equal([])
}
