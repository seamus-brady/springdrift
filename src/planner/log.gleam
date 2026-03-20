//// Append-only planner log — daily JSONL files in .springdrift/memory/planner/.
////
//// Tasks use daily rotation (YYYY-MM-DD-tasks.jsonl) like facts and narrative.
//// Endeavours use daily rotation (YYYY-MM-DD-endeavours.jsonl).
//// State is derived by replaying operations via resolve_tasks/resolve_endeavours.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import planner/types.{
  type Endeavour, type EndeavourOp, type EndeavourOrigin, type EndeavourStatus,
  type PlanStep, type PlannerTask, type TaskOp, type TaskOrigin, type TaskStatus,
  Abandoned, Active, AddCycleId, AddTaskToEndeavour, Complete, CompleteStep,
  CreateEndeavour, CreateTask, Endeavour, EndeavourAbandoned, EndeavourComplete,
  Failed, FlagRisk, Open, Pending, PlanStep, PlannerTask, SystemEndeavour,
  SystemTask, UpdateEndeavourStatus, UpdateForecastScore, UpdateTaskStatus,
  UserEndeavour, UserTask,
}
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

// ---------------------------------------------------------------------------
// Task operations — append
// ---------------------------------------------------------------------------

/// Append a TaskOp to a dated JSONL file (YYYY-MM-DD-tasks.jsonl).
pub fn append_task_op(dir: String, op: TaskOp) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> "-tasks.jsonl"
  let json_str = json.to_string(encode_task_op(op))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug("planner/log", "append_task_op", "Appended task op", None)
    Error(e) ->
      slog.log_error(
        "planner/log",
        "append_task_op",
        "Failed to append: " <> simplifile.describe_error(e),
        None,
      )
  }
}

// ---------------------------------------------------------------------------
// Endeavour operations — append
// ---------------------------------------------------------------------------

/// Append an EndeavourOp to a dated JSONL file (YYYY-MM-DD-endeavours.jsonl).
pub fn append_endeavour_op(dir: String, op: EndeavourOp) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> "-endeavours.jsonl"
  let json_str = json.to_string(encode_endeavour_op(op))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug(
        "planner/log",
        "append_endeavour_op",
        "Appended endeavour op",
        None,
      )
    Error(e) ->
      slog.log_error(
        "planner/log",
        "append_endeavour_op",
        "Failed to append: " <> simplifile.describe_error(e),
        None,
      )
  }
}

// ---------------------------------------------------------------------------
// Loading — tasks
// ---------------------------------------------------------------------------

/// Load task operations for a specific date.
pub fn load_task_ops_date(dir: String, date: String) -> List(TaskOp) {
  let path = dir <> "/" <> date <> "-tasks.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_task_jsonl(content)
  }
}

/// Load all task operations from all dated JSONL files, in chronological order.
pub fn load_all_task_ops(dir: String) -> List(TaskOp) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      files
      |> list.filter(fn(f) { string.ends_with(f, "-tasks.jsonl") })
      |> list.sort(string.compare)
      |> list.flat_map(fn(f) {
        let date = string.drop_end(f, 12)
        load_task_ops_date(dir, date)
      })
    }
  }
}

/// Resolve current task state by replaying all operations.
pub fn resolve_tasks(ops: List(TaskOp)) -> List(PlannerTask) {
  let tasks: Dict(String, PlannerTask) =
    list.fold(ops, dict.new(), fn(acc, op) {
      case op {
        CreateTask(task:) -> dict.insert(acc, task.task_id, task)

        UpdateTaskStatus(task_id:, status:, at:) ->
          update_task(acc, task_id, fn(t) {
            PlannerTask(..t, status:, updated_at: at)
          })

        CompleteStep(task_id:, step_index:, at:) ->
          update_task(acc, task_id, fn(t) {
            let steps =
              list.map(t.plan_steps, fn(s) {
                case s.index == step_index {
                  True ->
                    PlanStep(..s, status: Complete, completed_at: Some(at))
                  False -> s
                }
              })
            // Auto-complete task when all steps are done
            let all_complete = list.all(steps, fn(s) { s.status == Complete })
            let new_status = case all_complete {
              True -> Complete
              False -> t.status
            }
            PlannerTask(
              ..t,
              plan_steps: steps,
              status: new_status,
              updated_at: at,
            )
          })

        FlagRisk(task_id:, text:, at:) ->
          update_task(acc, task_id, fn(t) {
            PlannerTask(
              ..t,
              materialised_risks: list.append(t.materialised_risks, [text]),
              updated_at: at,
            )
          })

        AddCycleId(task_id:, cycle_id:) ->
          update_task(acc, task_id, fn(t) {
            case list.contains(t.cycle_ids, cycle_id) {
              True -> t
              False ->
                PlannerTask(
                  ..t,
                  cycle_ids: list.append(t.cycle_ids, [cycle_id]),
                )
            }
          })

        UpdateForecastScore(task_id:, score:) ->
          update_task(acc, task_id, fn(t) {
            PlannerTask(..t, forecast_score: Some(score))
          })
      }
    })

  dict.values(tasks)
}

fn update_task(
  tasks: Dict(String, PlannerTask),
  task_id: String,
  updater: fn(PlannerTask) -> PlannerTask,
) -> Dict(String, PlannerTask) {
  case dict.get(tasks, task_id) {
    Ok(t) -> dict.insert(tasks, task_id, updater(t))
    Error(_) -> tasks
  }
}

// ---------------------------------------------------------------------------
// Loading — endeavours
// ---------------------------------------------------------------------------

/// Load endeavour operations for a specific date.
pub fn load_endeavour_ops_date(dir: String, date: String) -> List(EndeavourOp) {
  let path = dir <> "/" <> date <> "-endeavours.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_endeavour_jsonl(content)
  }
}

/// Load all endeavour operations from all dated JSONL files.
pub fn load_all_endeavour_ops(dir: String) -> List(EndeavourOp) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      files
      |> list.filter(fn(f) { string.ends_with(f, "-endeavours.jsonl") })
      |> list.sort(string.compare)
      |> list.flat_map(fn(f) {
        let date = string.drop_end(f, 17)
        load_endeavour_ops_date(dir, date)
      })
    }
  }
}

/// Resolve current endeavour state by replaying all operations.
pub fn resolve_endeavours(ops: List(EndeavourOp)) -> List(Endeavour) {
  let endeavours: Dict(String, Endeavour) =
    list.fold(ops, dict.new(), fn(acc, op) {
      case op {
        CreateEndeavour(endeavour:) ->
          dict.insert(acc, endeavour.endeavour_id, endeavour)

        AddTaskToEndeavour(endeavour_id:, task_id:) ->
          case dict.get(acc, endeavour_id) {
            Ok(e) -> {
              let updated = case list.contains(e.task_ids, task_id) {
                True -> e
                False ->
                  Endeavour(..e, task_ids: list.append(e.task_ids, [task_id]))
              }
              dict.insert(acc, endeavour_id, updated)
            }
            Error(_) -> acc
          }

        UpdateEndeavourStatus(endeavour_id:, status:) ->
          case dict.get(acc, endeavour_id) {
            Ok(e) -> dict.insert(acc, endeavour_id, Endeavour(..e, status:))
            Error(_) -> acc
          }
      }
    })

  dict.values(endeavours)
}

// ---------------------------------------------------------------------------
// JSON encoding — TaskOp
// ---------------------------------------------------------------------------

pub fn encode_task_op(op: TaskOp) -> json.Json {
  case op {
    CreateTask(task:) ->
      json.object([
        #("op", json.string("create_task")),
        #("task", encode_task(task)),
      ])

    UpdateTaskStatus(task_id:, status:, at:) ->
      json.object([
        #("op", json.string("update_task_status")),
        #("task_id", json.string(task_id)),
        #("status", json.string(encode_task_status(status))),
        #("at", json.string(at)),
      ])

    CompleteStep(task_id:, step_index:, at:) ->
      json.object([
        #("op", json.string("complete_step")),
        #("task_id", json.string(task_id)),
        #("step_index", json.int(step_index)),
        #("at", json.string(at)),
      ])

    FlagRisk(task_id:, text:, at:) ->
      json.object([
        #("op", json.string("flag_risk")),
        #("task_id", json.string(task_id)),
        #("text", json.string(text)),
        #("at", json.string(at)),
      ])

    AddCycleId(task_id:, cycle_id:) ->
      json.object([
        #("op", json.string("add_cycle_id")),
        #("task_id", json.string(task_id)),
        #("cycle_id", json.string(cycle_id)),
      ])

    UpdateForecastScore(task_id:, score:) ->
      json.object([
        #("op", json.string("update_forecast_score")),
        #("task_id", json.string(task_id)),
        #("score", json.float(score)),
      ])
  }
}

pub fn encode_task(t: PlannerTask) -> json.Json {
  json.object([
    #("task_id", json.string(t.task_id)),
    #("endeavour_id", case t.endeavour_id {
      Some(id) -> json.string(id)
      None -> json.null()
    }),
    #("origin", json.string(encode_task_origin(t.origin))),
    #("title", json.string(t.title)),
    #("description", json.string(t.description)),
    #("status", json.string(encode_task_status(t.status))),
    #("plan_steps", json.array(t.plan_steps, encode_step)),
    #(
      "dependencies",
      json.array(t.dependencies, fn(d) {
        json.object([
          #("from", json.string(d.0)),
          #("to", json.string(d.1)),
        ])
      }),
    ),
    #("complexity", json.string(t.complexity)),
    #("risks", json.array(t.risks, json.string)),
    #("materialised_risks", json.array(t.materialised_risks, json.string)),
    #("created_at", json.string(t.created_at)),
    #("updated_at", json.string(t.updated_at)),
    #("cycle_ids", json.array(t.cycle_ids, json.string)),
    #("forecast_score", case t.forecast_score {
      Some(s) -> json.float(s)
      None -> json.null()
    }),
  ])
}

fn encode_step(s: PlanStep) -> json.Json {
  json.object([
    #("index", json.int(s.index)),
    #("description", json.string(s.description)),
    #("status", json.string(encode_task_status(s.status))),
    #("completed_at", case s.completed_at {
      Some(at) -> json.string(at)
      None -> json.null()
    }),
  ])
}

fn encode_task_status(s: TaskStatus) -> String {
  case s {
    Pending -> "pending"
    Active -> "active"
    Complete -> "complete"
    Failed -> "failed"
    Abandoned -> "abandoned"
  }
}

fn encode_task_origin(o: TaskOrigin) -> String {
  case o {
    SystemTask -> "system"
    UserTask -> "user"
  }
}

// ---------------------------------------------------------------------------
// JSON encoding — EndeavourOp
// ---------------------------------------------------------------------------

pub fn encode_endeavour_op(op: EndeavourOp) -> json.Json {
  case op {
    CreateEndeavour(endeavour:) ->
      json.object([
        #("op", json.string("create_endeavour")),
        #("endeavour", encode_endeavour(endeavour)),
      ])

    AddTaskToEndeavour(endeavour_id:, task_id:) ->
      json.object([
        #("op", json.string("add_task")),
        #("endeavour_id", json.string(endeavour_id)),
        #("task_id", json.string(task_id)),
      ])

    UpdateEndeavourStatus(endeavour_id:, status:) ->
      json.object([
        #("op", json.string("update_endeavour_status")),
        #("endeavour_id", json.string(endeavour_id)),
        #("status", json.string(encode_endeavour_status(status))),
      ])
  }
}

pub fn encode_endeavour(e: Endeavour) -> json.Json {
  json.object([
    #("endeavour_id", json.string(e.endeavour_id)),
    #("origin", json.string(encode_endeavour_origin(e.origin))),
    #("title", json.string(e.title)),
    #("description", json.string(e.description)),
    #("status", json.string(encode_endeavour_status(e.status))),
    #("task_ids", json.array(e.task_ids, json.string)),
    #("created_at", json.string(e.created_at)),
    #("updated_at", json.string(e.updated_at)),
  ])
}

fn encode_endeavour_status(s: EndeavourStatus) -> String {
  case s {
    Open -> "open"
    EndeavourComplete -> "complete"
    EndeavourAbandoned -> "abandoned"
  }
}

fn encode_endeavour_origin(o: EndeavourOrigin) -> String {
  case o {
    SystemEndeavour -> "system"
    UserEndeavour -> "user"
  }
}

// ---------------------------------------------------------------------------
// JSON decoding — TaskOp (lenient with defaults)
// ---------------------------------------------------------------------------

pub fn task_op_decoder() -> decode.Decoder(TaskOp) {
  use op_type <- decode.field("op", decode.string)
  case op_type {
    "create_task" -> {
      use task <- decode.field("task", task_decoder())
      decode.success(CreateTask(task:))
    }
    "update_task_status" -> {
      use task_id <- decode.field("task_id", decode.string)
      use status <- decode.field("status", status_string_decoder())
      use at <- decode.field("at", decode.string)
      decode.success(UpdateTaskStatus(task_id:, status:, at:))
    }
    "complete_step" -> {
      use task_id <- decode.field("task_id", decode.string)
      use step_index <- decode.field("step_index", decode.int)
      use at <- decode.field("at", decode.string)
      decode.success(CompleteStep(task_id:, step_index:, at:))
    }
    "flag_risk" -> {
      use task_id <- decode.field("task_id", decode.string)
      use text <- decode.field("text", decode.string)
      use at <- decode.field("at", decode.string)
      decode.success(FlagRisk(task_id:, text:, at:))
    }
    "add_cycle_id" -> {
      use task_id <- decode.field("task_id", decode.string)
      use cycle_id <- decode.field("cycle_id", decode.string)
      decode.success(AddCycleId(task_id:, cycle_id:))
    }
    "update_forecast_score" -> {
      use task_id <- decode.field("task_id", decode.string)
      use score <- decode.field("score", flexible_float_decoder())
      decode.success(UpdateForecastScore(task_id:, score:))
    }
    _ ->
      decode.failure(
        CreateTask(task: empty_task()),
        "Unknown task op: " <> op_type,
      )
  }
}

pub fn task_decoder() -> decode.Decoder(PlannerTask) {
  use task_id <- decode.field("task_id", decode.string)
  use endeavour_id <- decode.field(
    "endeavour_id",
    decode.optional(decode.string),
  )
  use origin <- decode.field(
    "origin",
    decode.optional(decode.string)
      |> decode.map(fn(o) { decode_task_origin(option.unwrap(o, "system")) }),
  )
  use title <- decode.field(
    "title",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use description <- decode.field(
    "description",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use status <- decode.field(
    "status",
    decode.optional(decode.string)
      |> decode.map(fn(s) { decode_task_status(option.unwrap(s, "pending")) }),
  )
  use plan_steps <- decode.field(
    "plan_steps",
    decode.optional(decode.list(step_decoder()))
      |> decode.map(option.unwrap(_, [])),
  )
  use dependencies <- decode.field(
    "dependencies",
    decode.optional(decode.list(dep_decoder()))
      |> decode.map(option.unwrap(_, [])),
  )
  use complexity <- decode.field(
    "complexity",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use risks <- decode.field(
    "risks",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use materialised_risks <- decode.field(
    "materialised_risks",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use created_at <- decode.field(
    "created_at",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use updated_at <- decode.field(
    "updated_at",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use cycle_ids <- decode.field(
    "cycle_ids",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use forecast_score <- decode.field(
    "forecast_score",
    decode.optional(flexible_float_decoder()),
  )
  decode.success(PlannerTask(
    task_id:,
    endeavour_id:,
    origin:,
    title:,
    description:,
    status:,
    plan_steps:,
    dependencies:,
    complexity:,
    risks:,
    materialised_risks:,
    created_at:,
    updated_at:,
    cycle_ids:,
    forecast_score:,
  ))
}

fn step_decoder() -> decode.Decoder(PlanStep) {
  use index <- decode.field("index", decode.int)
  use description <- decode.field(
    "description",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use status <- decode.field(
    "status",
    decode.optional(decode.string)
      |> decode.map(fn(s) { decode_task_status(option.unwrap(s, "pending")) }),
  )
  use completed_at <- decode.field(
    "completed_at",
    decode.optional(decode.string),
  )
  decode.success(PlanStep(index:, description:, status:, completed_at:))
}

fn dep_decoder() -> decode.Decoder(#(String, String)) {
  use from <- decode.field("from", decode.string)
  use to <- decode.field("to", decode.string)
  decode.success(#(from, to))
}

fn status_string_decoder() -> decode.Decoder(TaskStatus) {
  use s <- decode.then(decode.string)
  decode.success(decode_task_status(s))
}

/// Decode a float that might be encoded as an int (JSON has no int/float distinction).
fn flexible_float_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [
    decode.int |> decode.map(int.to_float),
  ])
}

fn decode_task_status(s: String) -> TaskStatus {
  case s {
    "active" -> Active
    "complete" -> Complete
    "failed" -> Failed
    "abandoned" -> Abandoned
    _ -> Pending
  }
}

fn decode_task_origin(o: String) -> TaskOrigin {
  case o {
    "user" -> UserTask
    _ -> SystemTask
  }
}

fn empty_task() -> PlannerTask {
  PlannerTask(
    task_id: "",
    endeavour_id: None,
    origin: SystemTask,
    title: "",
    description: "",
    status: Pending,
    plan_steps: [],
    dependencies: [],
    complexity: "",
    risks: [],
    materialised_risks: [],
    created_at: "",
    updated_at: "",
    cycle_ids: [],
    forecast_score: None,
  )
}

// ---------------------------------------------------------------------------
// JSON decoding — EndeavourOp (lenient with defaults)
// ---------------------------------------------------------------------------

pub fn endeavour_op_decoder() -> decode.Decoder(EndeavourOp) {
  use op_type <- decode.field("op", decode.string)
  case op_type {
    "create_endeavour" -> {
      use endeavour <- decode.field("endeavour", endeavour_decoder())
      decode.success(CreateEndeavour(endeavour:))
    }
    "add_task" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use task_id <- decode.field("task_id", decode.string)
      decode.success(AddTaskToEndeavour(endeavour_id:, task_id:))
    }
    "update_endeavour_status" -> {
      use endeavour_id <- decode.field("endeavour_id", decode.string)
      use status <- decode.field("status", endeavour_status_string_decoder())
      decode.success(UpdateEndeavourStatus(endeavour_id:, status:))
    }
    _ ->
      decode.failure(
        CreateEndeavour(endeavour: empty_endeavour()),
        "Unknown endeavour op: " <> op_type,
      )
  }
}

pub fn endeavour_decoder() -> decode.Decoder(Endeavour) {
  use endeavour_id <- decode.field("endeavour_id", decode.string)
  use origin <- decode.field(
    "origin",
    decode.optional(decode.string)
      |> decode.map(fn(o) {
        decode_endeavour_origin(option.unwrap(o, "system"))
      }),
  )
  use title <- decode.field(
    "title",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use description <- decode.field(
    "description",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use status <- decode.field(
    "status",
    decode.optional(decode.string)
      |> decode.map(fn(s) { decode_endeavour_status(option.unwrap(s, "open")) }),
  )
  use task_ids <- decode.field(
    "task_ids",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use created_at <- decode.field(
    "created_at",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use updated_at <- decode.field(
    "updated_at",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  decode.success(Endeavour(
    endeavour_id:,
    origin:,
    title:,
    description:,
    status:,
    task_ids:,
    created_at:,
    updated_at:,
  ))
}

fn endeavour_status_string_decoder() -> decode.Decoder(EndeavourStatus) {
  use s <- decode.then(decode.string)
  decode.success(decode_endeavour_status(s))
}

fn decode_endeavour_status(s: String) -> EndeavourStatus {
  case s {
    "complete" -> EndeavourComplete
    "abandoned" -> EndeavourAbandoned
    _ -> Open
  }
}

fn decode_endeavour_origin(o: String) -> EndeavourOrigin {
  case o {
    "user" -> UserEndeavour
    _ -> SystemEndeavour
  }
}

fn empty_endeavour() -> Endeavour {
  Endeavour(
    endeavour_id: "",
    origin: SystemEndeavour,
    title: "",
    description: "",
    status: Open,
    task_ids: [],
    created_at: "",
    updated_at: "",
  )
}

// ---------------------------------------------------------------------------
// JSONL parsing
// ---------------------------------------------------------------------------

fn parse_task_jsonl(content: String) -> List(TaskOp) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, task_op_decoder()) {
      Ok(op) -> Ok(op)
      Error(_) -> Error(Nil)
    }
  })
}

fn parse_endeavour_jsonl(content: String) -> List(EndeavourOp) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, endeavour_op_decoder()) {
      Ok(op) -> Ok(op)
      Error(_) -> Error(Nil)
    }
  })
}
