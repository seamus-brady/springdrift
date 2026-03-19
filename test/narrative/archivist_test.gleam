import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import llm/adapters/mock
import narrative/archivist.{type ArchivistContext, ArchivistContext}
import narrative/types.{Success}

pub fn main() -> Nil {
  gleeunit.main()
}

fn make_ctx() -> ArchivistContext {
  ArchivistContext(
    cycle_id: "test-cycle-123",
    parent_cycle_id: None,
    user_input: "hello",
    final_response: "Hello! How can I help?",
    agent_completions: [],
    model_used: "mock-model",
    classification: "simple",
    total_input_tokens: 100,
    total_output_tokens: 50,
    tool_calls: 0,
    dprime_decisions: [],
    thread_index_json: "{}",
  )
}

// ---------------------------------------------------------------------------
// generate tests via mock provider (XML responses)
// ---------------------------------------------------------------------------

pub fn generate_valid_xml_response_test() {
  let xml =
    "<narrative_entry>
  <summary>I greeted the user.</summary>
  <intent>
    <classification>conversation</classification>
    <description>greeting</description>
    <domain>general</domain>
  </intent>
  <outcome>
    <status>success</status>
    <confidence>0.9</confidence>
    <assessment>Simple greeting handled</assessment>
  </outcome>
  <keywords>
    <keyword>greeting</keyword>
  </keywords>
  <metrics>
    <input_tokens>100</input_tokens>
    <output_tokens>50</output_tokens>
    <model_used>mock-model</model_used>
  </metrics>
</narrative_entry>"
  let provider = mock.provider_with_text(xml)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", 4096, False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("I greeted the user.")
  entry.cycle_id |> should.equal("test-cycle-123")
  entry.outcome.status |> should.equal(Success)
}

pub fn generate_minimal_xml_uses_defaults_test() {
  // Only summary — everything else should get defaults from extraction
  let xml =
    "<narrative_entry>
  <summary>Minimal entry.</summary>
</narrative_entry>"
  let provider = mock.provider_with_text(xml)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", 4096, False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("Minimal entry.")
  entry.cycle_id |> should.equal("test-cycle-123")
  entry.keywords |> should.equal([])
  entry.delegation_chain |> should.equal([])
}

pub fn generate_completely_invalid_response_falls_back_test() {
  let provider = mock.provider_with_text("I cannot produce XML, sorry!")
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", 4096, False)
  result |> should.be_some
  let assert Some(entry) = result
  // Fallback entry — should contain the user input and a factual summary
  let assert True = string.contains(entry.summary, "I was asked")
  let assert True = string.contains(entry.summary, "hello")
  entry.cycle_id |> should.equal("test-cycle-123")
}

pub fn generate_llm_failure_returns_none_test() {
  let provider = mock.provider_with_error("connection refused")
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", 4096, False)
  result |> should.be_none
}

pub fn generate_overrides_cycle_id_from_context_test() {
  // XStructor won't pass through cycle_id — it's always set from context
  let xml =
    "<narrative_entry>
  <summary>Test.</summary>
  <intent>
    <classification>conversation</classification>
  </intent>
  <outcome>
    <status>success</status>
    <confidence>0.5</confidence>
  </outcome>
</narrative_entry>"
  let provider = mock.provider_with_text(xml)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", 4096, False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.cycle_id |> should.equal("test-cycle-123")
}

pub fn generate_with_delegation_chain_test() {
  let xml =
    "<narrative_entry>
  <summary>Delegated research.</summary>
  <intent>
    <classification>data_query</classification>
  </intent>
  <outcome>
    <status>success</status>
    <confidence>0.8</confidence>
  </outcome>
  <delegation_chain>
    <step>
      <agent>researcher</agent>
      <instruction>find info</instruction>
      <outcome>success</outcome>
      <contribution>found data</contribution>
    </step>
  </delegation_chain>
  <keywords>
    <keyword>research</keyword>
  </keywords>
</narrative_entry>"
  let provider = mock.provider_with_text(xml)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", 4096, False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("Delegated research.")
  let assert [step] = entry.delegation_chain
  step.agent |> should.equal("researcher")
  step.instruction |> should.equal("find info")
}

pub fn generate_xml_with_markdown_fences_test() {
  let xml =
    "```xml\n<narrative_entry>
  <summary>I helped with a task.</summary>
  <intent>
    <classification>exploration</classification>
  </intent>
  <outcome>
    <status>success</status>
    <confidence>0.8</confidence>
  </outcome>
  <keywords>
    <keyword>help</keyword>
  </keywords>
</narrative_entry>\n```"
  let provider = mock.provider_with_text(xml)
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", 4096, False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("I helped with a task.")
}
