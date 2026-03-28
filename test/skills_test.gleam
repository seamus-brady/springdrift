import gleam/string
import gleeunit
import gleeunit/should
import skills.{SkillMeta}

pub fn main() -> Nil {
  gleeunit.main()
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
  let skills = [
    SkillMeta(name: "web-research", description: "Search", path: "/a", agents: [
      "researcher",
      "cognitive",
    ]),
    SkillMeta(name: "code-review", description: "Code", path: "/b", agents: [
      "coder",
    ]),
    SkillMeta(name: "how-to", description: "Guide", path: "/c", agents: []),
  ]

  let researcher_skills = skills.for_agent(skills, "researcher")
  list.length(researcher_skills) |> should.equal(2)

  let coder_skills = skills.for_agent(skills, "coder")
  list.length(coder_skills) |> should.equal(2)

  let planner_skills = skills.for_agent(skills, "planner")
  list.length(planner_skills) |> should.equal(1)
}

pub fn for_agent_all_keyword_test() {
  let skills = [
    SkillMeta(
      name: "universal",
      description: "For everyone",
      path: "/a",
      agents: ["all"],
    ),
  ]

  let result = skills.for_agent(skills, "anything")
  list.length(result) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// to_system_prompt_xml
// ---------------------------------------------------------------------------

pub fn to_system_prompt_xml_empty_test() {
  skills.to_system_prompt_xml([]) |> should.equal("")
}

pub fn to_system_prompt_xml_single_skill_test() {
  let skill =
    SkillMeta(
      name: "pdf-processing",
      description: "Extracts text from PDFs",
      path: "/abs/path/pdf-processing/SKILL.md",
      agents: [],
    )
  let xml = skills.to_system_prompt_xml([skill])
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
  let skill =
    SkillMeta(
      name: "R&D <tool>",
      description: "Does \"stuff\" & 'things'",
      path: "/path/to/SKILL.md",
      agents: [],
    )
  let xml = skills.to_system_prompt_xml([skill])
  string.contains(xml, "<name>R&amp;D &lt;tool&gt;</name>") |> should.be_true
  string.contains(
    xml,
    "<description>Does &quot;stuff&quot; &amp; &apos;things&apos;</description>",
  )
  |> should.be_true
}

pub fn to_system_prompt_xml_multiple_skills_test() {
  let skill1 =
    SkillMeta(
      name: "skill-one",
      description: "First skill",
      path: "/path/skill-one/SKILL.md",
      agents: [],
    )
  let skill2 =
    SkillMeta(
      name: "skill-two",
      description: "Second skill",
      path: "/path/skill-two/SKILL.md",
      agents: [],
    )
  let xml = skills.to_system_prompt_xml([skill1, skill2])
  string.contains(xml, "<name>skill-one</name>") |> should.be_true
  string.contains(xml, "<name>skill-two</name>") |> should.be_true
}

import gleam/list
