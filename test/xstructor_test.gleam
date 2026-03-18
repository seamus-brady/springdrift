import gleam/dict
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import llm/adapters/mock
import xstructor

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// clean_response
// ---------------------------------------------------------------------------

pub fn clean_response_plain_xml_test() {
  let xml = "<root><name>hello</name></root>"
  xstructor.clean_response(xml)
  |> should.equal(xml)
}

pub fn clean_response_with_code_fences_test() {
  let input = "```xml\n<root><name>hello</name></root>\n```"
  xstructor.clean_response(input)
  |> should.equal("<root><name>hello</name></root>")
}

pub fn clean_response_with_xml_declaration_test() {
  let input = "<?xml version=\"1.0\"?>\n<root><name>hello</name></root>"
  xstructor.clean_response(input)
  |> should.equal("<root><name>hello</name></root>")
}

pub fn clean_response_with_both_fences_and_declaration_test() {
  let input =
    "```xml\n<?xml version=\"1.0\"?>\n<root><name>hello</name></root>\n```"
  xstructor.clean_response(input)
  |> should.equal("<root><name>hello</name></root>")
}

pub fn clean_response_with_whitespace_test() {
  let input = "  \n  <root><name>hello</name></root>  \n  "
  xstructor.clean_response(input)
  |> should.equal("<root><name>hello</name></root>")
}

// ---------------------------------------------------------------------------
// extract
// ---------------------------------------------------------------------------

pub fn extract_simple_elements_test() {
  let xml = "<root><name>hello</name><value>42</value></root>"
  let result = xstructor.extract(xml)
  result |> should.be_ok
  let assert Ok(elements) = result
  dict.get(elements, "root.name") |> should.equal(Ok("hello"))
  dict.get(elements, "root.value") |> should.equal(Ok("42"))
}

pub fn extract_nested_elements_test() {
  let xml =
    "<root><intent><classification>data_query</classification><domain>weather</domain></intent></root>"
  let result = xstructor.extract(xml)
  result |> should.be_ok
  let assert Ok(elements) = result
  dict.get(elements, "root.intent.classification")
  |> should.equal(Ok("data_query"))
  dict.get(elements, "root.intent.domain")
  |> should.equal(Ok("weather"))
}

pub fn extract_list_indexing_test() {
  let xml =
    "<root><items><item>alpha</item><item>beta</item><item>gamma</item></items></root>"
  let result = xstructor.extract(xml)
  result |> should.be_ok
  let assert Ok(elements) = result
  dict.get(elements, "root.items.item.0") |> should.equal(Ok("alpha"))
  dict.get(elements, "root.items.item.1") |> should.equal(Ok("beta"))
  dict.get(elements, "root.items.item.2") |> should.equal(Ok("gamma"))
}

pub fn extract_empty_elements_test() {
  let xml = "<root><name></name></root>"
  let result = xstructor.extract(xml)
  result |> should.be_ok
  let assert Ok(elements) = result
  dict.get(elements, "root.name") |> should.equal(Ok(""))
}

// ---------------------------------------------------------------------------
// extract_list
// ---------------------------------------------------------------------------

pub fn extract_list_basic_test() {
  let elements =
    dict.from_list([
      #("root.items.item.0", "a"),
      #("root.items.item.1", "b"),
      #("root.items.item.2", "c"),
    ])
  xstructor.extract_list(elements, "root.items.item")
  |> should.equal(["a", "b", "c"])
}

pub fn extract_list_empty_test() {
  let elements = dict.from_list([#("root.name", "hello")])
  xstructor.extract_list(elements, "root.items.item")
  |> should.equal([])
}

pub fn extract_list_single_test() {
  let elements = dict.from_list([#("root.items.item.0", "only")])
  xstructor.extract_list(elements, "root.items.item")
  |> should.equal(["only"])
}

// ---------------------------------------------------------------------------
// generate with mock provider
// ---------------------------------------------------------------------------

pub fn generate_valid_first_try_test() {
  // Write schema to temp dir, compile, then test generate
  let schema_dir = ".springdrift/test-schemas-" <> unique_id()
  let schema_content =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"result\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"value\" type=\"xs:string\"/>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

  let assert Ok(schema) =
    xstructor.compile_schema(schema_dir, "test.xsd", schema_content)

  let config =
    xstructor.XStructorConfig(
      schema: schema,
      system_prompt: "Return XML",
      xml_example: "<result><value>example</value></result>",
      max_retries: 3,
      max_tokens: 512,
    )

  let provider =
    mock.provider_with_text("<result><value>hello world</value></result>")

  let result = xstructor.generate(config, "test prompt", provider, "mock")
  result |> should.be_ok
  let assert Ok(xr) = result
  xr.retries_used |> should.equal(0)
  dict.get(xr.elements, "result.value") |> should.equal(Ok("hello world"))

  // Cleanup
  cleanup_dir(schema_dir)
}

pub fn generate_fenced_valid_xml_test() {
  let schema_dir = ".springdrift/test-schemas-" <> unique_id()
  let schema_content =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"result\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"value\" type=\"xs:string\"/>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

  let assert Ok(schema) =
    xstructor.compile_schema(schema_dir, "test.xsd", schema_content)

  let config =
    xstructor.XStructorConfig(
      schema: schema,
      system_prompt: "Return XML",
      xml_example: "<result><value>example</value></result>",
      max_retries: 3,
      max_tokens: 512,
    )

  // LLM wraps response in code fences
  let provider =
    mock.provider_with_text(
      "```xml\n<result><value>fenced</value></result>\n```",
    )

  let result = xstructor.generate(config, "test prompt", provider, "mock")
  result |> should.be_ok
  let assert Ok(xr) = result
  dict.get(xr.elements, "result.value") |> should.equal(Ok("fenced"))

  cleanup_dir(schema_dir)
}

pub fn generate_llm_error_test() {
  let schema_dir = ".springdrift/test-schemas-" <> unique_id()
  let schema_content =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"result\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"value\" type=\"xs:string\"/>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

  let assert Ok(schema) =
    xstructor.compile_schema(schema_dir, "test.xsd", schema_content)

  let config =
    xstructor.XStructorConfig(
      schema: schema,
      system_prompt: "Return XML",
      xml_example: "<result><value>example</value></result>",
      max_retries: 3,
      max_tokens: 512,
    )

  let provider = mock.provider_with_error("connection refused")
  let result = xstructor.generate(config, "test prompt", provider, "mock")
  result |> should.be_error
  let assert Error(msg) = result
  let assert True = string.contains(msg, "LLM error")

  cleanup_dir(schema_dir)
}

pub fn generate_all_retries_fail_test() {
  let schema_dir = ".springdrift/test-schemas-" <> unique_id()
  let schema_content =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"result\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"value\" type=\"xs:string\"/>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

  let assert Ok(schema) =
    xstructor.compile_schema(schema_dir, "test.xsd", schema_content)

  let config =
    xstructor.XStructorConfig(
      schema: schema,
      system_prompt: "Return XML",
      xml_example: "<result><value>example</value></result>",
      max_retries: 2,
      max_tokens: 512,
    )

  // Provider always returns invalid XML (wrong element name)
  let provider = mock.provider_with_text("<wrong><bad>nope</bad></wrong>")
  let result = xstructor.generate(config, "test prompt", provider, "mock")
  result |> should.be_error

  cleanup_dir(schema_dir)
}

pub fn generate_invalid_then_valid_retry_test() {
  let schema_dir = ".springdrift/test-schemas-" <> unique_id()
  let schema_content =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"result\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"value\" type=\"xs:string\"/>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

  let assert Ok(schema) =
    xstructor.compile_schema(schema_dir, "test.xsd", schema_content)

  let config =
    xstructor.XStructorConfig(
      schema: schema,
      system_prompt: "Return XML",
      xml_example: "<result><value>example</value></result>",
      max_retries: 3,
      max_tokens: 512,
    )

  // First call returns invalid, second returns valid
  let provider =
    mock.provider_with_handler(fn(req) {
      case list.length(req.messages) > 1 {
        // Retry attempt — has error feedback in messages
        True -> Ok(mock.text_response("<result><value>fixed</value></result>"))
        // First attempt — return invalid
        False -> Ok(mock.text_response("<wrong><bad>nope</bad></wrong>"))
      }
    })

  let result = xstructor.generate(config, "test prompt", provider, "mock")
  result |> should.be_ok
  let assert Ok(xr) = result
  xr.retries_used |> should.equal(1)
  dict.get(xr.elements, "result.value") |> should.equal(Ok("fixed"))

  cleanup_dir(schema_dir)
}

// ---------------------------------------------------------------------------
// compile_schema
// ---------------------------------------------------------------------------

pub fn compile_schema_valid_test() {
  let schema_dir = ".springdrift/test-schemas-" <> unique_id()
  let schema_content =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"test\" type=\"xs:string\"/>
</xs:schema>"

  let result = xstructor.compile_schema(schema_dir, "valid.xsd", schema_content)
  result |> should.be_ok

  cleanup_dir(schema_dir)
}

pub fn compile_schema_invalid_test() {
  let schema_dir = ".springdrift/test-schemas-" <> unique_id()
  let result =
    xstructor.compile_schema(schema_dir, "bad.xsd", "not valid xsd at all")
  result |> should.be_error
  cleanup_dir(schema_dir)
}

// ---------------------------------------------------------------------------
// validate
// ---------------------------------------------------------------------------

pub fn validate_valid_xml_test() {
  let schema_dir = ".springdrift/test-schemas-" <> unique_id()
  let schema_content =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"greeting\" type=\"xs:string\"/>
</xs:schema>"

  let assert Ok(schema) =
    xstructor.compile_schema(schema_dir, "greeting.xsd", schema_content)

  xstructor.validate("<greeting>hello</greeting>", schema)
  |> should.be_ok

  cleanup_dir(schema_dir)
}

pub fn validate_invalid_xml_test() {
  let schema_dir = ".springdrift/test-schemas-" <> unique_id()
  let schema_content =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"greeting\" type=\"xs:string\"/>
</xs:schema>"

  let assert Ok(schema) =
    xstructor.compile_schema(schema_dir, "greeting.xsd", schema_content)

  xstructor.validate("<wrong>hello</wrong>", schema)
  |> should.be_error

  cleanup_dir(schema_dir)
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
