import gleeunit
import gleeunit/should
import xstructor
import xstructor/schemas

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "generate_uuid")
fn unique_id() -> String

@external(erlang, "file", "del_dir_r")
fn del_dir_r(path: String) -> a

fn cleanup_dir(dir: String) -> Nil {
  let _ = del_dir_r(dir)
  Nil
}

fn compile(name: String, content: String) {
  let schema_dir = "/tmp/springdrift-test-schemas-" <> unique_id()
  let result = xstructor.compile_schema(schema_dir, name, content)
  #(schema_dir, result)
}

// ---------------------------------------------------------------------------
// Candidates schema
// ---------------------------------------------------------------------------

pub fn candidates_example_validates_test() {
  let #(dir, result) = compile("candidates.xsd", schemas.candidates_xsd)
  result |> should.be_ok
  let assert Ok(schema) = result
  xstructor.validate(schemas.candidates_example, schema)
  |> should.be_ok
  cleanup_dir(dir)
}

pub fn candidates_missing_description_fails_test() {
  let #(dir, result) = compile("candidates.xsd", schemas.candidates_xsd)
  let assert Ok(schema) = result
  let bad_xml =
    "<candidates><candidate><projected_outcome>ok</projected_outcome></candidate></candidates>"
  xstructor.validate(bad_xml, schema)
  |> should.be_error
  cleanup_dir(dir)
}

pub fn candidates_empty_optional_passes_test() {
  let #(dir, result) = compile("candidates.xsd", schemas.candidates_xsd)
  let assert Ok(schema) = result
  let xml =
    "<candidates><candidate><description>test</description></candidate></candidates>"
  xstructor.validate(xml, schema)
  |> should.be_ok
  cleanup_dir(dir)
}

// ---------------------------------------------------------------------------
// Forecasts schema
// ---------------------------------------------------------------------------

pub fn forecasts_example_validates_test() {
  let #(dir, result) = compile("forecasts.xsd", schemas.forecasts_xsd)
  result |> should.be_ok
  let assert Ok(schema) = result
  xstructor.validate(schemas.forecasts_example, schema)
  |> should.be_ok
  cleanup_dir(dir)
}

pub fn forecasts_bad_magnitude_fails_test() {
  let #(dir, result) = compile("forecasts.xsd", schemas.forecasts_xsd)
  let assert Ok(schema) = result
  let bad_xml =
    "<forecasts><forecast><feature>safety</feature><magnitude>5</magnitude></forecast></forecasts>"
  xstructor.validate(bad_xml, schema)
  |> should.be_error
  cleanup_dir(dir)
}

pub fn forecasts_negative_magnitude_fails_test() {
  let #(dir, result) = compile("forecasts.xsd", schemas.forecasts_xsd)
  let assert Ok(schema) = result
  let bad_xml =
    "<forecasts><forecast><feature>safety</feature><magnitude>-1</magnitude></forecast></forecasts>"
  xstructor.validate(bad_xml, schema)
  |> should.be_error
  cleanup_dir(dir)
}

pub fn forecasts_valid_magnitude_range_test() {
  let #(dir, result) = compile("forecasts.xsd", schemas.forecasts_xsd)
  let assert Ok(schema) = result
  let xml =
    "<forecasts><forecast><feature>safety</feature><magnitude>3</magnitude></forecast></forecasts>"
  xstructor.validate(xml, schema)
  |> should.be_ok
  cleanup_dir(dir)
}

// ---------------------------------------------------------------------------
// Summary schema
// ---------------------------------------------------------------------------

pub fn summary_example_validates_test() {
  let #(dir, result) = compile("summary.xsd", schemas.summary_xsd)
  result |> should.be_ok
  let assert Ok(schema) = result
  xstructor.validate(schemas.summary_example, schema)
  |> should.be_ok
  cleanup_dir(dir)
}

pub fn summary_without_keywords_passes_test() {
  let #(dir, result) = compile("summary.xsd", schemas.summary_xsd)
  let assert Ok(schema) = result
  let xml =
    "<summary_response><summary>A brief summary of the period.</summary></summary_response>"
  xstructor.validate(xml, schema)
  |> should.be_ok
  cleanup_dir(dir)
}

pub fn summary_missing_summary_fails_test() {
  let #(dir, result) = compile("summary.xsd", schemas.summary_xsd)
  let assert Ok(schema) = result
  let bad_xml =
    "<summary_response><keywords><keyword>test</keyword></keywords></summary_response>"
  xstructor.validate(bad_xml, schema)
  |> should.be_error
  cleanup_dir(dir)
}

// ---------------------------------------------------------------------------
// CBR Case schema
// ---------------------------------------------------------------------------

pub fn cbr_case_example_validates_test() {
  let #(dir, result) = compile("cbr_case.xsd", schemas.cbr_case_xsd)
  result |> should.be_ok
  let assert Ok(schema) = result
  xstructor.validate(schemas.cbr_case_example, schema)
  |> should.be_ok
  cleanup_dir(dir)
}

pub fn cbr_case_minimal_passes_test() {
  let #(dir, result) = compile("cbr_case.xsd", schemas.cbr_case_xsd)
  let assert Ok(schema) = result
  let xml =
    "<cbr_case><problem><user_input>test</user_input></problem><solution><approach>direct</approach></solution><outcome><status>success</status></outcome></cbr_case>"
  xstructor.validate(xml, schema)
  |> should.be_ok
  cleanup_dir(dir)
}

// ---------------------------------------------------------------------------
// Narrative Entry schema
// ---------------------------------------------------------------------------

pub fn narrative_entry_example_validates_test() {
  let #(dir, result) =
    compile("narrative_entry.xsd", schemas.narrative_entry_xsd)
  result |> should.be_ok
  let assert Ok(schema) = result
  xstructor.validate(schemas.narrative_entry_example, schema)
  |> should.be_ok
  cleanup_dir(dir)
}

pub fn narrative_entry_summary_only_passes_test() {
  let #(dir, result) =
    compile("narrative_entry.xsd", schemas.narrative_entry_xsd)
  let assert Ok(schema) = result
  let xml =
    "<narrative_entry><summary>I helped the user.</summary></narrative_entry>"
  xstructor.validate(xml, schema)
  |> should.be_ok
  cleanup_dir(dir)
}

pub fn narrative_entry_missing_summary_fails_test() {
  let #(dir, result) =
    compile("narrative_entry.xsd", schemas.narrative_entry_xsd)
  let assert Ok(schema) = result
  let bad_xml =
    "<narrative_entry><intent><classification>conversation</classification></intent></narrative_entry>"
  xstructor.validate(bad_xml, schema)
  |> should.be_error
  cleanup_dir(dir)
}

pub fn narrative_entry_with_all_optional_sections_test() {
  let #(dir, result) =
    compile("narrative_entry.xsd", schemas.narrative_entry_xsd)
  let assert Ok(schema) = result
  let xml =
    "<narrative_entry>
  <summary>Full entry test</summary>
  <intent>
    <classification>data_query</classification>
    <description>Testing all fields</description>
    <domain>test</domain>
  </intent>
  <outcome>
    <status>success</status>
    <confidence>0.95</confidence>
    <assessment>All good</assessment>
  </outcome>
  <delegation_chain>
    <step>
      <agent>researcher</agent>
      <instruction>find data</instruction>
      <outcome>success</outcome>
      <contribution>found it</contribution>
    </step>
  </delegation_chain>
  <decisions>
    <decision>
      <point>Which agent?</point>
      <choice>researcher</choice>
      <rationale>Best for web queries</rationale>
    </decision>
  </decisions>
  <keywords>
    <keyword>test</keyword>
    <keyword>validation</keyword>
  </keywords>
  <entities>
    <locations><location>London</location></locations>
    <organisations><organisation>Acme Corp</organisation></organisations>
  </entities>
  <sources>
    <source><type>web</type><name>example.com</name></source>
  </sources>
  <metrics>
    <input_tokens>100</input_tokens>
    <output_tokens>50</output_tokens>
    <tool_calls>2</tool_calls>
  </metrics>
  <observations>
    <observation>
      <type>performance</type>
      <severity>info</severity>
      <detail>Fast response</detail>
    </observation>
  </observations>
</narrative_entry>"
  xstructor.validate(xml, schema)
  |> should.be_ok
  cleanup_dir(dir)
}
