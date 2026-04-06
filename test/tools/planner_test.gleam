// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import llm/types as llm_types
import narrative/librarian
import planner/types
import simplifile
import tools/planner as planner_tools

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/planner_tools_test_" <> suffix
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

fn start_lib(dir: String) -> process.Subject(librarian.LibrarianMessage) {
  let planner_dir = dir <> "/planner"
  let _ = simplifile.create_directory_all(planner_dir)
  librarian.start(
    dir <> "/narrative",
    dir <> "/cbr",
    dir <> "/facts",
    dir <> "/artifacts",
    planner_dir,
    0,
    librarian.default_cbr_config(),
  )
}

fn make_call(name: String, input_json: String) -> llm_types.ToolCall {
  llm_types.ToolCall(id: "call-001", name:, input_json:)
}

fn create_test_task(
  dir: String,
  lib: process.Subject(librarian.LibrarianMessage),
) -> String {
  planner_tools.create_task(
    dir <> "/planner",
    lib,
    "Test task",
    "A test task description",
    ["Step one", "Step two", "Step three"],
    [],
    [#("1", "2")],
    "simple",
    ["risk1"],
    types.SystemTask,
    None,
    "cycle-001",
  )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn get_active_work_empty_test() {
  let dir = test_dir("active_empty")
  let lib = start_lib(dir)

  let result =
    planner_tools.execute(
      make_call("get_active_work", "{}"),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolSuccess(content:, ..) ->
      content |> should.equal("No active work.")
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn create_task_and_get_detail_test() {
  let dir = test_dir("create_detail")
  let lib = start_lib(dir)
  let task_id = create_test_task(dir, lib)

  // Small delay for Librarian to process the notify
  process.sleep(50)

  let result =
    planner_tools.execute(
      make_call("get_task_detail", "{\"task_id\":\"" <> task_id <> "\"}"),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      should.be_true(string.contains(content, task_id))
      should.be_true(string.contains(content, "Test task"))
      should.be_true(string.contains(content, "Step one"))
    }
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn activate_task_test() {
  let dir = test_dir("activate")
  let lib = start_lib(dir)
  let task_id = create_test_task(dir, lib)
  process.sleep(50)

  let result =
    planner_tools.execute(
      make_call("activate_task", "{\"task_id\":\"" <> task_id <> "\"}"),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolSuccess(content:, ..) ->
      should.be_true(string.contains(content, "activated"))
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn complete_step_test() {
  let dir = test_dir("complete_step")
  let lib = start_lib(dir)
  let task_id = create_test_task(dir, lib)
  process.sleep(50)

  let result =
    planner_tools.execute(
      make_call(
        "complete_task_step",
        "{\"task_id\":\"" <> task_id <> "\",\"step_index\":1}",
      ),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolSuccess(content:, ..) ->
      should.be_true(string.contains(content, "Step 1 marked complete"))
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn flag_risk_test() {
  let dir = test_dir("flag_risk")
  let lib = start_lib(dir)
  let task_id = create_test_task(dir, lib)
  process.sleep(50)

  let result =
    planner_tools.execute(
      make_call(
        "flag_risk",
        "{\"task_id\":\""
          <> task_id
          <> "\",\"risk_description\":\"API rate limited\"}",
      ),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolSuccess(content:, ..) ->
      should.be_true(string.contains(content, "Risk flagged"))
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn create_endeavour_test() {
  let dir = test_dir("create_end")
  let lib = start_lib(dir)

  let result =
    planner_tools.execute(
      make_call(
        "create_endeavour",
        "{\"title\":\"Market report\",\"description\":\"Prepare market analysis\"}",
      ),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      should.be_true(string.contains(content, "Endeavour created"))
      should.be_true(string.contains(content, "Market report"))
    }
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn get_task_detail_not_found_test() {
  let dir = test_dir("not_found")
  let lib = start_lib(dir)

  let result =
    planner_tools.execute(
      make_call("get_task_detail", "{\"task_id\":\"nonexistent\"}"),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolFailure(error:, ..) ->
      should.be_true(string.contains(error, "not found"))
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn request_forecast_review_all_empty_test() {
  let dir = test_dir("forecast_empty")
  let lib = start_lib(dir)

  let result =
    planner_tools.execute(
      make_call("request_forecast_review", "{}"),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolSuccess(content:, ..) ->
      content |> should.equal("No active tasks to review.")
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn request_forecast_review_specific_not_found_test() {
  let dir = test_dir("forecast_notfound")
  let lib = start_lib(dir)

  let result =
    planner_tools.execute(
      make_call("request_forecast_review", "{\"task_id\":\"nonexistent\"}"),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolFailure(error:, ..) ->
      should.be_true(string.contains(error, "not found"))
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn request_forecast_review_with_task_test() {
  let dir = test_dir("forecast_task")
  let lib = start_lib(dir)
  let task_id = create_test_task(dir, lib)
  process.sleep(50)

  // Activate the task first
  let _ =
    planner_tools.execute(
      make_call("activate_task", "{\"task_id\":\"" <> task_id <> "\"}"),
      dir <> "/planner",
      lib,
      option.None,
    )
  process.sleep(50)

  let result =
    planner_tools.execute(
      make_call("request_forecast_review", "{}"),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      should.be_true(string.contains(content, "Forecast Review"))
      should.be_true(string.contains(content, task_id))
      should.be_true(string.contains(content, "D' score"))
    }
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn request_forecast_review_specific_task_test() {
  let dir = test_dir("forecast_specific")
  let lib = start_lib(dir)
  let task_id = create_test_task(dir, lib)
  process.sleep(50)

  let result =
    planner_tools.execute(
      make_call(
        "request_forecast_review",
        "{\"task_id\":\"" <> task_id <> "\"}",
      ),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolSuccess(content:, ..) -> {
      should.be_true(string.contains(content, "Forecast Review"))
      should.be_true(string.contains(content, task_id))
      should.be_true(string.contains(content, "D' score"))
      should.be_true(string.contains(content, "Summary:"))
    }
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

// request_forecast_review moved to Planner agent
pub fn request_forecast_review_on_cognitive_loop_test() {
  planner_tools.is_planner_tool("request_forecast_review")
  |> should.equal(True)
}

pub fn unknown_tool_test() {
  let dir = test_dir("unknown")
  let lib = start_lib(dir)

  let result =
    planner_tools.execute(
      make_call("nonexistent_tool", "{}"),
      dir <> "/planner",
      lib,
      option.None,
    )

  case result {
    llm_types.ToolFailure(error:, ..) ->
      should.be_true(string.contains(error, "Unknown planner tool"))
    _ -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}
