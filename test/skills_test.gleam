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
  let assert Ok(#(name, description)) = result
  name |> should.equal("pdf-processing")
  description |> should.equal("Extracts text from PDFs")
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
  let assert Ok(#(name, description)) = result
  name |> should.equal("my-skill")
  description |> should.equal("My skill")
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
    )
  let xml = skills.to_system_prompt_xml([skill])
  string.contains(xml, "<available_skills>") |> should.be_true
  string.contains(xml, "<name>pdf-processing</name>") |> should.be_true
  string.contains(xml, "<description>Extracts text from PDFs</description>")
  |> should.be_true
  string.contains(xml, "<location>/abs/path/pdf-processing/SKILL.md</location>")
  |> should.be_true
}

pub fn to_system_prompt_xml_multiple_skills_test() {
  let skill1 =
    SkillMeta(
      name: "skill-one",
      description: "First skill",
      path: "/path/skill-one/SKILL.md",
    )
  let skill2 =
    SkillMeta(
      name: "skill-two",
      description: "Second skill",
      path: "/path/skill-two/SKILL.md",
    )
  let xml = skills.to_system_prompt_xml([skill1, skill2])
  string.contains(xml, "<name>skill-one</name>") |> should.be_true
  string.contains(xml, "<name>skill-two</name>") |> should.be_true
}
