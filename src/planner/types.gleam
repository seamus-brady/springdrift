//// Planner types — Tasks and Endeavours for goal tracking.
////
//// A Task is a unit of planned work with steps, dependencies, and risks.
//// An Endeavour is a self-directed initiative grouping multiple independent Tasks.
//// Both persist as append-only JSONL operations, with state derived by replay.

import gleam/option.{type Option}

// ---------------------------------------------------------------------------
// Task
// ---------------------------------------------------------------------------

pub type TaskStatus {
  Pending
  Active
  Complete
  Failed
  Abandoned
}

pub type TaskOrigin {
  SystemTask
  UserTask
}

pub type PlanStep {
  PlanStep(
    index: Int,
    description: String,
    status: TaskStatus,
    completed_at: Option(String),
  )
}

pub type PlannerTask {
  PlannerTask(
    task_id: String,
    endeavour_id: Option(String),
    origin: TaskOrigin,
    title: String,
    description: String,
    status: TaskStatus,
    plan_steps: List(PlanStep),
    dependencies: List(#(String, String)),
    complexity: String,
    risks: List(String),
    materialised_risks: List(String),
    created_at: String,
    updated_at: String,
    cycle_ids: List(String),
    forecast_score: Option(Float),
  )
}

// ---------------------------------------------------------------------------
// Endeavour
// ---------------------------------------------------------------------------

pub type EndeavourStatus {
  Open
  EndeavourComplete
  EndeavourAbandoned
}

pub type EndeavourOrigin {
  SystemEndeavour
  UserEndeavour
}

pub type Endeavour {
  Endeavour(
    endeavour_id: String,
    origin: EndeavourOrigin,
    title: String,
    description: String,
    status: EndeavourStatus,
    task_ids: List(String),
    created_at: String,
    updated_at: String,
  )
}

// ---------------------------------------------------------------------------
// Task operations (append-only log)
// ---------------------------------------------------------------------------

pub type TaskOp {
  CreateTask(task: PlannerTask)
  UpdateTaskStatus(task_id: String, status: TaskStatus, at: String)
  CompleteStep(task_id: String, step_index: Int, at: String)
  FlagRisk(task_id: String, text: String, at: String)
  AddCycleId(task_id: String, cycle_id: String)
  UpdateForecastScore(task_id: String, score: Float)
}

// ---------------------------------------------------------------------------
// Endeavour operations (append-only log)
// ---------------------------------------------------------------------------

pub type EndeavourOp {
  CreateEndeavour(endeavour: Endeavour)
  AddTaskToEndeavour(endeavour_id: String, task_id: String)
  UpdateEndeavourStatus(endeavour_id: String, status: EndeavourStatus)
}
