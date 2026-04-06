// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/registry
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should

// ---------------------------------------------------------------------------
// new
// ---------------------------------------------------------------------------

pub fn new_registry_is_empty_test() {
  let reg = registry.new()
  registry.size(reg) |> should.equal(0)
  registry.list_agents(reg) |> should.equal([])
}

// ---------------------------------------------------------------------------
// register + lookup
// ---------------------------------------------------------------------------

pub fn register_and_lookup_test() {
  let subj = process.new_subject()
  let reg =
    registry.new()
    |> registry.register("planner", subj, [])

  registry.size(reg) |> should.equal(1)
  registry.get_task_subject(reg, "planner") |> should.equal(Some(subj))
  registry.get_status(reg, "planner") |> should.equal(Some(registry.Running))
}

pub fn lookup_missing_returns_none_test() {
  let reg = registry.new()
  registry.get_task_subject(reg, "nonexistent") |> should.equal(None)
  registry.get_status(reg, "nonexistent") |> should.equal(None)
}

// ---------------------------------------------------------------------------
// multiple agents
// ---------------------------------------------------------------------------

pub fn register_multiple_agents_test() {
  let subj1 = process.new_subject()
  let subj2 = process.new_subject()
  let reg =
    registry.new()
    |> registry.register("planner", subj1, ["plan"])
    |> registry.register("coder", subj2, ["run_code"])

  registry.size(reg) |> should.equal(2)
  registry.get_task_subject(reg, "planner") |> should.equal(Some(subj1))
  registry.get_task_subject(reg, "coder") |> should.equal(Some(subj2))
}

// ---------------------------------------------------------------------------
// unregister
// ---------------------------------------------------------------------------

pub fn unregister_removes_agent_test() {
  let subj = process.new_subject()
  let reg =
    registry.new()
    |> registry.register("planner", subj, [])
    |> registry.unregister("planner")

  registry.size(reg) |> should.equal(0)
  registry.get_task_subject(reg, "planner") |> should.equal(None)
}

pub fn unregister_nonexistent_is_noop_test() {
  let reg = registry.new()
  let reg2 = registry.unregister(reg, "nonexistent")
  registry.size(reg2) |> should.equal(0)
}

// ---------------------------------------------------------------------------
// status transitions
// ---------------------------------------------------------------------------

pub fn mark_restarting_test() {
  let subj = process.new_subject()
  let reg =
    registry.new()
    |> registry.register("planner", subj, [])
    |> registry.mark_restarting("planner")

  registry.get_status(reg, "planner")
  |> should.equal(Some(registry.Restarting))
}

pub fn mark_stopped_test() {
  let subj = process.new_subject()
  let reg =
    registry.new()
    |> registry.register("planner", subj, [])
    |> registry.mark_stopped("planner")

  registry.get_status(reg, "planner")
  |> should.equal(Some(registry.Stopped))
}

// ---------------------------------------------------------------------------
// duplicate guard
// ---------------------------------------------------------------------------

pub fn register_duplicate_updates_instead_of_appending_test() {
  let subj1 = process.new_subject()
  let subj2 = process.new_subject()
  let reg =
    registry.new()
    |> registry.register("planner", subj1, ["plan"])
    |> registry.register("planner", subj2, ["plan"])

  // Should still be size 1, not 2
  registry.size(reg) |> should.equal(1)
  // Should have the new subject
  registry.get_task_subject(reg, "planner") |> should.equal(Some(subj2))
}

// ---------------------------------------------------------------------------
// update_task_subject
// ---------------------------------------------------------------------------

pub fn update_task_subject_test() {
  let subj1 = process.new_subject()
  let subj2 = process.new_subject()
  let reg =
    registry.new()
    |> registry.register("planner", subj1, ["plan"])
    |> registry.mark_restarting("planner")
    |> registry.update_task_subject("planner", subj2)

  registry.get_task_subject(reg, "planner") |> should.equal(Some(subj2))
  // update_task_subject sets status back to Running
  registry.get_status(reg, "planner") |> should.equal(Some(registry.Running))
}

pub fn mark_running_after_restarting_test() {
  let subj = process.new_subject()
  let reg =
    registry.new()
    |> registry.register("planner", subj, [])
    |> registry.mark_restarting("planner")
    |> registry.mark_running("planner")

  registry.get_status(reg, "planner")
  |> should.equal(Some(registry.Running))
}
