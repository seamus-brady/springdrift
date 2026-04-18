////
//// Tests for the Curator's <skill_procedures> sensorium block. The block
//// is the structured nudge that addresses Curragh's "skills as passive
//// reference" gap (2026-04-18) — only loaded skills appear, the whole
//// block is omitted when none match.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{None}
import gleam/string
import gleeunit/should
import narrative/curator
import skills.{type SkillMeta, Active, Operator, SkillMeta}

fn make_skill(id: String) -> SkillMeta {
  SkillMeta(
    id: id,
    name: id,
    description: "test skill",
    path: "/tmp/" <> id <> "/SKILL.md",
    version: 1,
    status: Active,
    agents: ["cognitive"],
    contexts: [],
    token_cost_estimate: 100,
    author: Operator,
    created_at: "",
    updated_at: "",
    derived_from: None,
  )
}

pub fn omitted_when_no_skills_loaded_test() {
  curator.render_sensorium_skill_procedures([])
  |> should.equal("")
}

pub fn omitted_when_no_loaded_skill_matches_a_procedure_test() {
  // A skill with an unrelated id — none of the procedure mappings match it.
  let skills = [make_skill("some-unrelated-skill")]
  curator.render_sensorium_skill_procedures(skills)
  |> should.equal("")
}

pub fn renders_only_matching_procedures_test() {
  // Only delegation-strategy and email-response are loaded; the other six
  // procedure rows must not appear.
  let skills = [
    make_skill("delegation-strategy"),
    make_skill("email-response"),
  ]
  let block = curator.render_sensorium_skill_procedures(skills)
  string.contains(block, "<skill_procedures>") |> should.equal(True)
  string.contains(block, "delegation-strategy") |> should.equal(True)
  string.contains(block, "email-response") |> should.equal(True)
  string.contains(block, "delegate_to_agent") |> should.equal(True)
  string.contains(block, "send_email") |> should.equal(True)
  // Procedures whose skill is not loaded must not leak.
  string.contains(block, "planner-patterns") |> should.equal(False)
  string.contains(block, "memory-management") |> should.equal(False)
}

pub fn renders_full_set_when_all_loaded_test() {
  let skills = [
    make_skill("delegation-strategy"),
    make_skill("planner-patterns"),
    make_skill("email-response"),
    make_skill("memory-management"),
    make_skill("web-research"),
    make_skill("self-diagnostic"),
    make_skill("task-appraisal"),
    make_skill("affect-monitoring"),
  ]
  let block = curator.render_sensorium_skill_procedures(skills)
  string.contains(block, "<skill_procedures>") |> should.equal(True)
  string.contains(block, "delegate_to_agent") |> should.equal(True)
  string.contains(block, "create_task") |> should.equal(True)
  string.contains(block, "send_email") |> should.equal(True)
  string.contains(block, "deep_memory_work") |> should.equal(True)
  string.contains(block, "web_research") |> should.equal(True)
  string.contains(block, "self_diagnostic") |> should.equal(True)
  string.contains(block, "appraisal") |> should.equal(True)
  string.contains(block, "affect_check") |> should.equal(True)
}
