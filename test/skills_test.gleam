// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import skills.{type SkillMeta, Active, Operator, SkillMeta}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Build a SkillMeta with sensible defaults so tests can override only the
/// fields they care about. Without this every test would have to know about
/// 13 fields.
fn skill(
  name: String,
  agents: List(String),
  contexts: List(String),
) -> SkillMeta {
  SkillMeta(
    id: name,
    name: name,
    description: "A test skill",
    path: "/path/" <> name <> "/SKILL.md",
    version: 1,
    status: Active,
    agents: agents,
    contexts: contexts,
    token_cost_estimate: 0,
    author: Operator,
    created_at: "",
    updated_at: "",
    derived_from: None,
  )
}

// ---------------------------------------------------------------------------
// parse_frontmatter
// ---------------------------------------------------------------------------

pub fn parse_valid_frontmatter_test() {
  let content =
    "---\nname: pdf-processing\ndescription: Extracts text from PDFs\n---\n\n# PDF Processing"
  let result = skills.parse_frontmatter(content)
  result |> should.be_ok
  let assert Ok(#(name, description, agents)) = result
  name |> should.equal("pdf-processing")
  description |> should.equal("Extracts text from PDFs")
  agents |> should.equal([])
}

pub fn parse_with_agents_test() {
  let content =
    "---\nname: web-research\ndescription: Search tools\nagents: researcher, cognitive\n---"
  let result = skills.parse_frontmatter(content)
  result |> should.be_ok
  let assert Ok(#(_name, _desc, agents)) = result
  agents |> should.equal(["researcher", "cognitive"])
}

pub fn parse_missing_name_test() {
  let content = "---\ndescription: A skill without a name\n---"
  skills.parse_frontmatter(content) |> should.be_error
}

pub fn parse_missing_description_test() {
  let content = "---\nname: my-skill\n---"
  skills.parse_frontmatter(content) |> should.be_error
}

pub fn parse_extra_fields_ignored_test() {
  let content =
    "---\nname: my-skill\ndescription: My skill\nlicense: MIT\nmetadata: extra\n---"
  let result = skills.parse_frontmatter(content)
  result |> should.be_ok
  let assert Ok(#(name, description, _agents)) = result
  name |> should.equal("my-skill")
  description |> should.equal("My skill")
}

// ---------------------------------------------------------------------------
// for_agent
// ---------------------------------------------------------------------------

pub fn for_agent_filters_correctly_test() {
  let all_skills = [
    skill("web-research", ["researcher", "cognitive"], []),
    skill("code-review", ["coder"], []),
    skill("how-to", [], []),
  ]

  let researcher_skills = skills.for_agent(all_skills, "researcher")
  list.length(researcher_skills) |> should.equal(2)

  let coder_skills = skills.for_agent(all_skills, "coder")
  list.length(coder_skills) |> should.equal(2)

  let planner_skills = skills.for_agent(all_skills, "planner")
  list.length(planner_skills) |> should.equal(1)
}

pub fn for_agent_all_keyword_test() {
  let all_skills = [skill("universal", ["all"], [])]
  let result = skills.for_agent(all_skills, "anything")
  list.length(result) |> should.equal(1)
}

pub fn for_agent_all_specialists_keyword_test() {
  let all_skills = [skill("specialists-only", ["all_specialists"], [])]
  // cognitive is NOT a specialist
  list.length(skills.for_agent(all_skills, "cognitive")) |> should.equal(0)
  // any non-cognitive name is treated as a specialist
  list.length(skills.for_agent(all_skills, "researcher")) |> should.equal(1)
  list.length(skills.for_agent(all_skills, "coder")) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// for_context
// ---------------------------------------------------------------------------

pub fn for_context_empty_means_always_inject_test() {
  let all_skills = [skill("unscoped", [], [])]
  // No contexts on the skill → injected regardless of query domains
  list.length(skills.for_context(all_skills, [])) |> should.equal(1)
  list.length(skills.for_context(all_skills, ["legal"])) |> should.equal(1)
}

pub fn for_context_matches_domain_test() {
  let all_skills = [
    skill("legal-research", [], ["legal"]),
    skill("web-research", [], ["research", "web"]),
  ]
  let legal = skills.for_context(all_skills, ["legal"])
  list.length(legal) |> should.equal(1)
  let web = skills.for_context(all_skills, ["web"])
  list.length(web) |> should.equal(1)
  let none_match = skills.for_context(all_skills, ["finance"])
  list.length(none_match) |> should.equal(0)
}

pub fn for_context_all_keyword_test() {
  let all_skills = [skill("ambient", [], ["all"])]
  list.length(skills.for_context(all_skills, [])) |> should.equal(1)
  list.length(skills.for_context(all_skills, ["anything"])) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// status helpers
// ---------------------------------------------------------------------------

pub fn status_round_trip_test() {
  skills.status_to_string(skills.Active) |> should.equal("active")
  skills.status_to_string(skills.Archived) |> should.equal("archived")
  skills.status_from_string("active") |> should.equal(skills.Active)
  skills.status_from_string("ARCHIVED") |> should.equal(skills.Archived)
  // Unknown values default to Active so a typo never silently archives.
  skills.status_from_string("garbage") |> should.equal(skills.Active)
}

// ---------------------------------------------------------------------------
// estimate_token_cost
// ---------------------------------------------------------------------------

pub fn estimate_token_cost_test() {
  // Empty body → zero
  skills.estimate_token_cost("") |> should.equal(0)
  // Rough chars/token ratio of 4
  skills.estimate_token_cost("abcd") |> should.equal(1)
  skills.estimate_token_cost("12345678") |> should.equal(2)
}

// ---------------------------------------------------------------------------
// to_system_prompt_xml
// ---------------------------------------------------------------------------

pub fn to_system_prompt_xml_empty_test() {
  skills.to_system_prompt_xml([]) |> should.equal("")
}

pub fn to_system_prompt_xml_single_skill_test() {
  let s =
    SkillMeta(
      id: "pdf-processing",
      name: "pdf-processing",
      description: "Extracts text from PDFs",
      path: "/abs/path/pdf-processing/SKILL.md",
      version: 1,
      status: Active,
      agents: [],
      contexts: [],
      token_cost_estimate: 0,
      author: Operator,
      created_at: "",
      updated_at: "",
      derived_from: None,
    )
  let xml = skills.to_system_prompt_xml([s])
  string.contains(xml, "<available_skills>") |> should.be_true
  string.contains(xml, "<name>pdf-processing</name>") |> should.be_true
  string.contains(xml, "<description>Extracts text from PDFs</description>")
  |> should.be_true
  string.contains(xml, "<location>/abs/path/pdf-processing/SKILL.md</location>")
  |> should.be_true
}

// ---------------------------------------------------------------------------
// xml_escape
// ---------------------------------------------------------------------------

pub fn xml_escape_ampersand_test() {
  skills.xml_escape("R&D") |> should.equal("R&amp;D")
}

pub fn xml_escape_angle_brackets_test() {
  skills.xml_escape("<script>alert(1)</script>")
  |> should.equal("&lt;script&gt;alert(1)&lt;/script&gt;")
}

pub fn xml_escape_quotes_test() {
  skills.xml_escape("say \"hello\" & 'goodbye'")
  |> should.equal("say &quot;hello&quot; &amp; &apos;goodbye&apos;")
}

pub fn xml_escape_no_special_chars_test() {
  skills.xml_escape("plain text") |> should.equal("plain text")
}

pub fn xml_escape_all_special_chars_test() {
  skills.xml_escape("&<>\"'")
  |> should.equal("&amp;&lt;&gt;&quot;&apos;")
}

pub fn to_system_prompt_xml_escapes_special_chars_test() {
  let s = skill("R&D <tool>", [], [])
  let s_with_desc = SkillMeta(..s, description: "Does \"stuff\" & 'things'")
  let xml = skills.to_system_prompt_xml([s_with_desc])
  string.contains(xml, "<name>R&amp;D &lt;tool&gt;</name>") |> should.be_true
  string.contains(
    xml,
    "<description>Does &quot;stuff&quot; &amp; &apos;things&apos;</description>",
  )
  |> should.be_true
}

pub fn to_system_prompt_xml_multiple_skills_test() {
  let xml =
    skills.to_system_prompt_xml([
      skill("skill-one", [], []),
      skill("skill-two", [], []),
    ])
  string.contains(xml, "<name>skill-one</name>") |> should.be_true
  string.contains(xml, "<name>skill-two</name>") |> should.be_true
}
