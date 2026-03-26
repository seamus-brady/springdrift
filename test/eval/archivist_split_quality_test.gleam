//// Eval: Archivist split quality — two-phase Reflector/Curator pipeline.
////
//// Tests that the reflect phase produces structured insights, the curate phase
//// produces a NarrativeEntry, and the fallback chain handles failures gracefully.
//// Uses mock provider only — no network calls.

import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import llm/adapters/mock
import narrative/archivist.{type ArchivistContext, ArchivistContext}
import narrative/types.{Conversation, Narrative, Success}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_context() -> ArchivistContext {
  ArchivistContext(
    cycle_id: "test-cycle-001",
    parent_cycle_id: None,
    user_input: "What is the current weather in Dublin?",
    final_response: "The current weather in Dublin is 14C and partly cloudy with light winds from the southwest.",
    agent_completions: [],
    model_used: "mock-model",
    classification: "simple",
    total_input_tokens: 500,
    total_output_tokens: 200,
    tool_calls: 2,
    dprime_decisions: [],
    thread_index_json: "{}",
    retrieved_case_ids: [],
  )
}

/// A realistic reflection response covering the seven assessment categories.
fn realistic_reflection() -> String {
  "1. TASK ATTEMPTED: The user asked about current weather in Dublin. This was a straightforward data query requiring real-time information.

2. APPROACH TAKEN: I processed the query directly without delegation since it was classified as simple. I used my general knowledge to provide weather information.

3. TOOLS USED: No tools were called in this cycle — the response was generated directly from model knowledge.

4. WHAT WORKED WELL: The response was concise and addressed the user's question directly. The classification as 'simple' was correct, avoiding unnecessary overhead.

5. WHAT FAILED OR WAS UNEXPECTED: The response may contain stale weather data since no real-time web search was performed. For weather queries, delegation to a researcher agent with web_search would produce more accurate results.

6. LESSONS FOR FUTURE: Weather queries should be routed to the researcher agent for real-time data. Classification as 'simple' is correct for complexity, but the tool selection should prioritise freshness for time-sensitive queries.

7. D' SAFETY NOTES: No D' evaluations were triggered for this cycle."
}

/// Valid XStructor XML for a narrative entry matching the schema.
fn valid_narrative_xml() -> String {
  "<narrative_entry>
  <summary>I was asked about the current weather in Dublin. I responded with general knowledge rather than delegating to a researcher for real-time data.</summary>
  <intent>
    <classification>data_query</classification>
    <description>User requested current weather information for Dublin</description>
    <domain>environment</domain>
  </intent>
  <outcome>
    <status>success</status>
    <confidence>0.7</confidence>
    <assessment>Responded successfully but could have used web search for fresher data</assessment>
  </outcome>
  <keywords>
    <keyword>weather</keyword>
    <keyword>Dublin</keyword>
  </keywords>
  <entities>
    <locations>
      <location>Dublin</location>
    </locations>
  </entities>
  <metrics>
    <input_tokens>500</input_tokens>
    <output_tokens>200</output_tokens>
    <tool_calls>2</tool_calls>
    <agent_delegations>0</agent_delegations>
    <model_used>mock-model</model_used>
  </metrics>
</narrative_entry>"
}

// ---------------------------------------------------------------------------
// Test 1: Reflection produces actionable insights
// ---------------------------------------------------------------------------

pub fn reflect_produces_actionable_insights_test() {
  let ctx = test_context()
  let provider = mock.provider_with_text(realistic_reflection())

  let result = archivist.reflect(ctx, provider, "mock-model")

  // Should succeed
  result |> should.be_ok

  let assert Ok(text) = result

  // Should contain non-empty content
  { string.length(text) > 0 } |> should.be_true

  // Should contain key assessment categories from the reflection prompt
  { string.contains(text, "TASK ATTEMPTED") } |> should.be_true
  { string.contains(text, "WHAT WORKED WELL") } |> should.be_true
  { string.contains(text, "WHAT FAILED") } |> should.be_true
  { string.contains(text, "LESSONS FOR FUTURE") } |> should.be_true
}

// ---------------------------------------------------------------------------
// Test 2: Curation produces structured entry from reflection
// ---------------------------------------------------------------------------

pub fn curate_produces_structured_entry_test() {
  let ctx = test_context()
  let provider = mock.provider_with_text(valid_narrative_xml())
  let reflection = realistic_reflection()

  let result = archivist.curate(ctx, reflection, provider, "mock-model", 1024)

  // Should return Some(NarrativeEntry)
  result |> should.be_some

  let assert Some(entry) = result

  // Verify the entry has populated fields
  { string.length(entry.summary) > 0 } |> should.be_true
  entry.cycle_id |> should.equal("test-cycle-001")
  entry.entry_type |> should.equal(Narrative)
}

// ---------------------------------------------------------------------------
// Test 3: Fallback chain — all calls fail returns None
// ---------------------------------------------------------------------------

pub fn generate_returns_none_when_all_calls_fail_test() {
  let ctx = test_context()
  let provider = mock.provider_with_error("LLM unreachable")

  let result = archivist.generate(ctx, provider, "mock-model", 1024, False)

  // Both phases fail, single-call fallback also fails via LLM error
  // generate should return None gracefully
  result |> should.be_none
}

// ---------------------------------------------------------------------------
// Test 4: Phase 2 failure preserves fallback entry
// ---------------------------------------------------------------------------

pub fn phase2_failure_returns_fallback_entry_test() {
  // Use a handler that succeeds on the first call (reflection) but
  // returns invalid non-XML for subsequent calls (curation attempts).
  // Since mock always returns the same thing, we test the phases independently.

  // Phase 1: succeeds with a reflection
  let ctx = test_context()
  let provider = mock.provider_with_text(realistic_reflection())
  let reflect_result = archivist.reflect(ctx, provider, "mock-model")
  reflect_result |> should.be_ok

  // Phase 2: fails because the reflection text is not valid XML
  // When curate receives non-XML from the LLM, XStructor validation fails
  // and curate falls back to Some(fallback_entry)
  let bad_provider =
    mock.provider_with_text("This is plain text, not XML at all")
  let curate_result =
    archivist.curate(
      ctx,
      realistic_reflection(),
      bad_provider,
      "mock-model",
      1024,
    )

  // Should still return Some — the fallback entry preserves cycle context
  curate_result |> should.be_some

  let assert Some(entry) = curate_result
  entry.cycle_id |> should.equal("test-cycle-001")
  // Fallback entries have lower confidence (0.4)
  { entry.outcome.confidence <. 0.5 } |> should.be_true
  // Fallback entries note they are reconstructed
  {
    string.contains(entry.outcome.assessment, "archivist")
    || string.contains(entry.outcome.assessment, "Reconstructed")
    || string.contains(entry.outcome.assessment, "fallback")
  }
  |> should.be_true
}

// ---------------------------------------------------------------------------
// Test 5: Two-phase produces richer entry than fallback
// ---------------------------------------------------------------------------

pub fn two_phase_produces_richer_entry_than_fallback_test() {
  let ctx = test_context()

  // Two-phase path: curate with valid XML produces a proper entry
  let good_provider = mock.provider_with_text(valid_narrative_xml())
  let curated =
    archivist.curate(
      ctx,
      realistic_reflection(),
      good_provider,
      "mock-model",
      1024,
    )
  curated |> should.be_some
  let assert Some(curated_entry) = curated

  // Fallback path: curate with invalid text produces a fallback entry
  let bad_provider = mock.provider_with_text("Not valid XML")
  let fallback =
    archivist.curate(
      ctx,
      realistic_reflection(),
      bad_provider,
      "mock-model",
      1024,
    )
  fallback |> should.be_some
  let assert Some(fallback_entry) = fallback

  // The curated entry should have a summary from the LLM (richer than fallback)
  { string.contains(curated_entry.summary, "Dublin") } |> should.be_true

  // The curated entry should have higher confidence than the fallback
  { curated_entry.outcome.confidence >. fallback_entry.outcome.confidence }
  |> should.be_true
}

// ---------------------------------------------------------------------------
// Test 6: Reflect returns error on empty response
// ---------------------------------------------------------------------------

pub fn reflect_errors_on_empty_response_test() {
  let ctx = test_context()
  let provider = mock.provider_with_text("")

  let result = archivist.reflect(ctx, provider, "mock-model")

  // Empty reflection should return Error
  result |> should.be_error
}

// ---------------------------------------------------------------------------
// Test 7: Reflect returns error on LLM failure
// ---------------------------------------------------------------------------

pub fn reflect_returns_error_on_llm_failure_test() {
  let ctx = test_context()
  let provider = mock.provider_with_error("connection refused")

  let result = archivist.reflect(ctx, provider, "mock-model")

  result |> should.be_error
}

// ---------------------------------------------------------------------------
// Test 8: Generate with good provider returns Some entry
// ---------------------------------------------------------------------------

pub fn generate_with_good_provider_returns_entry_test() {
  let ctx = test_context()
  // The mock returns the same text for every call. For generate, Phase 1
  // gets the XML (which is non-empty so reflect succeeds), then Phase 2
  // gets the same XML (which passes XStructor validation).
  let provider = mock.provider_with_text(valid_narrative_xml())

  let result = archivist.generate(ctx, provider, "mock-model", 1024, False)

  result |> should.be_some
  let assert Some(entry) = result
  entry.cycle_id |> should.equal("test-cycle-001")
  entry.entry_type |> should.equal(Narrative)
  { string.length(entry.summary) > 0 } |> should.be_true
}

// ---------------------------------------------------------------------------
// Test 9: Curate with LLM error returns None (not fallback)
// ---------------------------------------------------------------------------

pub fn curate_with_llm_error_returns_none_test() {
  let ctx = test_context()
  let provider = mock.provider_with_error("timeout")

  let result =
    archivist.curate(ctx, realistic_reflection(), provider, "mock-model", 1024)

  // When the LLM itself errors (not XStructor validation), curate returns None
  result |> should.be_none
}

// ---------------------------------------------------------------------------
// Test 10: Fallback entry preserves cycle metadata
// ---------------------------------------------------------------------------

pub fn fallback_entry_preserves_cycle_metadata_test() {
  let ctx = test_context()
  // Force the fallback path: non-XML LLM response triggers XStructor failure
  let provider = mock.provider_with_text("Just plain text, no XML here")

  let result =
    archivist.curate(ctx, "some reflection", provider, "mock-model", 1024)

  result |> should.be_some
  let assert Some(entry) = result

  // Fallback should preserve the cycle_id from context
  entry.cycle_id |> should.equal("test-cycle-001")
  // Fallback should have metrics from context
  entry.metrics.input_tokens |> should.equal(500)
  entry.metrics.output_tokens |> should.equal(200)
  // Outcome status should be Success (non-empty response, no agent failures)
  entry.outcome.status |> should.equal(Success)
  // Intent should be Conversation (no researcher agent in completions)
  entry.intent.classification |> should.equal(Conversation)
}
