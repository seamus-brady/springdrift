// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import planner/log
import planner/types.{
  type Endeavour, type PlannerTask, Abandoned, Active, Complete, Endeavour,
  EndeavourAbandoned, EndeavourComplete, Failed, Open, Pending, PlanStep,
  PlannerTask, SystemEndeavour, SystemTask, UserEndeavour, UserTask,
  new_endeavour,
}

// ---------------------------------------------------------------------------
// Task encode/decode roundtrip
// ---------------------------------------------------------------------------

fn make_task() -> PlannerTask {
  PlannerTask(
    task_id: "task-001",
    endeavour_id: Some("end-001"),
    origin: SystemTask,
    title: "Research pricing",
    description: "Find competitor pricing pages",
    status: Active,
    plan_steps: [
      PlanStep(
        index: 1,
        description: "Search for competitors",
        status: Complete,
        completed_at: Some("2026-03-19T10:00:00"),
        verification: None,
      ),
      PlanStep(
        index: 2,
        description: "Extract pricing data",
        status: Pending,
        completed_at: None,
        verification: None,
      ),
    ],
    dependencies: [#("1", "2")],
    complexity: "medium",
    risks: ["Pages may require login"],
    materialised_risks: [],
    created_at: "2026-03-19T09:00:00",
    updated_at: "2026-03-19T10:00:00",
    cycle_ids: ["cycle-001", "cycle-002"],
    forecast_score: Some(0.35),
    forecast_breakdown: None,
    pre_mortem: None,
    post_mortem: None,
  )
}

pub fn task_roundtrip_test() {
  let task = make_task()
  let encoded = json.to_string(log.encode_task(task))
  let assert Ok(decoded) = json.parse(encoded, log.task_decoder())

  decoded.task_id |> should.equal("task-001")
  decoded.endeavour_id |> should.equal(Some("end-001"))
  decoded.origin |> should.equal(SystemTask)
  decoded.title |> should.equal("Research pricing")
  decoded.status |> should.equal(Active)
  decoded.complexity |> should.equal("medium")
  decoded.forecast_score |> should.equal(Some(0.35))

  case decoded.plan_steps {
    [s1, s2] -> {
      s1.index |> should.equal(1)
      s1.status |> should.equal(Complete)
      s1.completed_at |> should.equal(Some("2026-03-19T10:00:00"))
      s2.index |> should.equal(2)
      s2.status |> should.equal(Pending)
      s2.completed_at |> should.equal(None)
    }
    _ -> should.fail()
  }

  case decoded.dependencies {
    [#(from, to)] -> {
      from |> should.equal("1")
      to |> should.equal("2")
    }
    _ -> should.fail()
  }

  decoded.risks |> should.equal(["Pages may require login"])
  decoded.materialised_risks |> should.equal([])
  decoded.cycle_ids |> should.equal(["cycle-001", "cycle-002"])
}

pub fn task_no_endeavour_roundtrip_test() {
  let task = PlannerTask(..make_task(), endeavour_id: None)
  let encoded = json.to_string(log.encode_task(task))
  let assert Ok(decoded) = json.parse(encoded, log.task_decoder())
  decoded.endeavour_id |> should.equal(None)
}

pub fn task_user_origin_roundtrip_test() {
  let task = PlannerTask(..make_task(), origin: UserTask)
  let encoded = json.to_string(log.encode_task(task))
  let assert Ok(decoded) = json.parse(encoded, log.task_decoder())
  decoded.origin |> should.equal(UserTask)
}

pub fn task_all_statuses_roundtrip_test() {
  let statuses = [Pending, Active, Complete, Failed, Abandoned]
  statuses
  |> should.equal([Pending, Active, Complete, Failed, Abandoned])
  // Test each encodes/decodes correctly
  let task = make_task()
  let assert Ok(decoded_pending) =
    json.parse(
      json.to_string(log.encode_task(PlannerTask(..task, status: Pending))),
      log.task_decoder(),
    )
  decoded_pending.status |> should.equal(Pending)

  let assert Ok(decoded_failed) =
    json.parse(
      json.to_string(log.encode_task(PlannerTask(..task, status: Failed))),
      log.task_decoder(),
    )
  decoded_failed.status |> should.equal(Failed)

  let assert Ok(decoded_abandoned) =
    json.parse(
      json.to_string(log.encode_task(PlannerTask(..task, status: Abandoned))),
      log.task_decoder(),
    )
  decoded_abandoned.status |> should.equal(Abandoned)
}

pub fn task_no_forecast_score_roundtrip_test() {
  let task = PlannerTask(..make_task(), forecast_score: None)
  let encoded = json.to_string(log.encode_task(task))
  let assert Ok(decoded) = json.parse(encoded, log.task_decoder())
  decoded.forecast_score |> should.equal(None)
}

// ---------------------------------------------------------------------------
// Endeavour encode/decode roundtrip
// ---------------------------------------------------------------------------

fn make_endeavour() -> Endeavour {
  let e =
    new_endeavour(
      "end-001",
      SystemEndeavour,
      "Market report",
      "Prepare a comprehensive market report",
      "2026-03-19T09:00:00",
    )
  Endeavour(..e, status: Open, task_ids: ["task-001", "task-002"])
}

pub fn endeavour_roundtrip_test() {
  let e = make_endeavour()
  let encoded = json.to_string(log.encode_endeavour(e))
  let assert Ok(decoded) = json.parse(encoded, log.endeavour_decoder())

  decoded.endeavour_id |> should.equal("end-001")
  decoded.origin |> should.equal(SystemEndeavour)
  decoded.title |> should.equal("Market report")
  decoded.description |> should.equal("Prepare a comprehensive market report")
  decoded.status |> should.equal(Open)
  decoded.task_ids |> should.equal(["task-001", "task-002"])
}

pub fn endeavour_user_origin_roundtrip_test() {
  let e = Endeavour(..make_endeavour(), origin: UserEndeavour)
  let encoded = json.to_string(log.encode_endeavour(e))
  let assert Ok(decoded) = json.parse(encoded, log.endeavour_decoder())
  decoded.origin |> should.equal(UserEndeavour)
}

pub fn endeavour_all_statuses_roundtrip_test() {
  let e = make_endeavour()

  let assert Ok(d1) =
    json.parse(
      json.to_string(log.encode_endeavour(Endeavour(..e, status: Open))),
      log.endeavour_decoder(),
    )
  d1.status |> should.equal(Open)

  let assert Ok(d2) =
    json.parse(
      json.to_string(log.encode_endeavour(
        Endeavour(..e, status: EndeavourComplete),
      )),
      log.endeavour_decoder(),
    )
  d2.status |> should.equal(EndeavourComplete)

  let assert Ok(d3) =
    json.parse(
      json.to_string(log.encode_endeavour(
        Endeavour(..e, status: EndeavourAbandoned),
      )),
      log.endeavour_decoder(),
    )
  d3.status |> should.equal(EndeavourAbandoned)
}

// ---------------------------------------------------------------------------
// TaskOp encode/decode roundtrip
// ---------------------------------------------------------------------------

pub fn create_task_op_roundtrip_test() {
  let op = types.CreateTask(task: make_task())
  let encoded = json.to_string(log.encode_task_op(op))
  let assert Ok(decoded) = json.parse(encoded, log.task_op_decoder())
  case decoded {
    types.CreateTask(task:) -> task.task_id |> should.equal("task-001")
    _ -> should.fail()
  }
}

pub fn update_status_op_roundtrip_test() {
  let op =
    types.UpdateTaskStatus(
      task_id: "task-001",
      status: Complete,
      at: "2026-03-19T12:00:00",
    )
  let encoded = json.to_string(log.encode_task_op(op))
  let assert Ok(decoded) = json.parse(encoded, log.task_op_decoder())
  case decoded {
    types.UpdateTaskStatus(task_id:, status:, at:) -> {
      task_id |> should.equal("task-001")
      status |> should.equal(Complete)
      at |> should.equal("2026-03-19T12:00:00")
    }
    _ -> should.fail()
  }
}

pub fn complete_step_op_roundtrip_test() {
  let op =
    types.CompleteStep(
      task_id: "task-001",
      step_index: 2,
      at: "2026-03-19T11:00:00",
    )
  let encoded = json.to_string(log.encode_task_op(op))
  let assert Ok(decoded) = json.parse(encoded, log.task_op_decoder())
  case decoded {
    types.CompleteStep(task_id:, step_index:, at:) -> {
      task_id |> should.equal("task-001")
      step_index |> should.equal(2)
      at |> should.equal("2026-03-19T11:00:00")
    }
    _ -> should.fail()
  }
}

pub fn flag_risk_op_roundtrip_test() {
  let op =
    types.FlagRisk(
      task_id: "task-001",
      text: "Login wall encountered",
      at: "2026-03-19T11:30:00",
    )
  let encoded = json.to_string(log.encode_task_op(op))
  let assert Ok(decoded) = json.parse(encoded, log.task_op_decoder())
  case decoded {
    types.FlagRisk(task_id:, text:, at:) -> {
      task_id |> should.equal("task-001")
      text |> should.equal("Login wall encountered")
      at |> should.equal("2026-03-19T11:30:00")
    }
    _ -> should.fail()
  }
}

pub fn add_cycle_id_op_roundtrip_test() {
  let op = types.AddCycleId(task_id: "task-001", cycle_id: "cycle-003")
  let encoded = json.to_string(log.encode_task_op(op))
  let assert Ok(decoded) = json.parse(encoded, log.task_op_decoder())
  case decoded {
    types.AddCycleId(task_id:, cycle_id:) -> {
      task_id |> should.equal("task-001")
      cycle_id |> should.equal("cycle-003")
    }
    _ -> should.fail()
  }
}

pub fn update_forecast_score_op_roundtrip_test() {
  let op = types.UpdateForecastScore(task_id: "task-001", score: 0.72)
  let encoded = json.to_string(log.encode_task_op(op))
  let assert Ok(decoded) = json.parse(encoded, log.task_op_decoder())
  case decoded {
    types.UpdateForecastScore(task_id:, score:) -> {
      task_id |> should.equal("task-001")
      score |> should.equal(0.72)
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// EndeavourOp encode/decode roundtrip
// ---------------------------------------------------------------------------

pub fn create_endeavour_op_roundtrip_test() {
  let op = types.CreateEndeavour(endeavour: make_endeavour())
  let encoded = json.to_string(log.encode_endeavour_op(op))
  let assert Ok(decoded) = json.parse(encoded, log.endeavour_op_decoder())
  case decoded {
    types.CreateEndeavour(endeavour:) ->
      endeavour.endeavour_id |> should.equal("end-001")
    _ -> should.fail()
  }
}

pub fn add_task_to_endeavour_op_roundtrip_test() {
  let op =
    types.AddTaskToEndeavour(endeavour_id: "end-001", task_id: "task-003")
  let encoded = json.to_string(log.encode_endeavour_op(op))
  let assert Ok(decoded) = json.parse(encoded, log.endeavour_op_decoder())
  case decoded {
    types.AddTaskToEndeavour(endeavour_id:, task_id:) -> {
      endeavour_id |> should.equal("end-001")
      task_id |> should.equal("task-003")
    }
    _ -> should.fail()
  }
}

pub fn update_endeavour_status_op_roundtrip_test() {
  let op =
    types.UpdateEndeavourStatus(
      endeavour_id: "end-001",
      status: EndeavourComplete,
    )
  let encoded = json.to_string(log.encode_endeavour_op(op))
  let assert Ok(decoded) = json.parse(encoded, log.endeavour_op_decoder())
  case decoded {
    types.UpdateEndeavourStatus(endeavour_id:, status:) -> {
      endeavour_id |> should.equal("end-001")
      status |> should.equal(EndeavourComplete)
    }
    _ -> should.fail()
  }
}
