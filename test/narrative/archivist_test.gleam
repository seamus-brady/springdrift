// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import llm/adapters/mock
import llm/types as llm_types
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
    retrieved_case_ids: [],
    strategy_registry_enabled: True,
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

// ---------------------------------------------------------------------------
// Phase 1: Reflection tests
// ---------------------------------------------------------------------------

pub fn reflect_returns_plain_text_insights_test() {
  let reflection_text =
    "The user said hello. I responded with a greeting. This was a simple conversational exchange with no tools needed."
  let provider = mock.provider_with_text(reflection_text)
  let ctx = make_ctx()
  let result = archivist.reflect(ctx, provider, "mock-model")
  result |> should.be_ok
  let assert Ok(text) = result
  text |> should.equal(reflection_text)
}

pub fn reflect_prompt_contains_cycle_context_test() {
  // Use a handler mock to inspect the request
  let provider =
    mock.provider_with_handler(fn(req) {
      // The user message should contain the cycle context
      let assert [msg] = req.messages
      let assert [llm_types.TextContent(text: prompt_text)] = msg.content
      // Verify cycle context elements are in the prompt
      let assert True = string.contains(prompt_text, "test-cycle-123")
      let assert True = string.contains(prompt_text, "hello")
      let assert True = string.contains(prompt_text, "mock-model")
      let assert True = string.contains(prompt_text, "simple")
      Ok(mock.text_response("Reflection: user said hello"))
    })
  let ctx = make_ctx()
  let result = archivist.reflect(ctx, provider, "mock-model")
  result |> should.be_ok
}

pub fn reflect_with_dprime_decisions_in_prompt_test() {
  let ctx =
    ArchivistContext(..make_ctx(), dprime_decisions: [
      "Tool gate: ALLOW (score 0.1)",
      "Input gate: ALLOW",
    ])
  let provider =
    mock.provider_with_handler(fn(req) {
      let assert [msg] = req.messages
      let assert [llm_types.TextContent(text: prompt_text)] = msg.content
      let assert True = string.contains(prompt_text, "Tool gate: ALLOW")
      let assert True = string.contains(prompt_text, "Input gate: ALLOW")
      Ok(mock.text_response("D' gates all passed."))
    })
  let result = archivist.reflect(ctx, provider, "mock-model")
  result |> should.be_ok
}

pub fn reflect_llm_failure_returns_error_test() {
  let provider = mock.provider_with_error("connection refused")
  let ctx = make_ctx()
  let result = archivist.reflect(ctx, provider, "mock-model")
  result |> should.be_error
}

pub fn reflect_empty_response_returns_error_test() {
  let provider = mock.provider_with_text("   ")
  let ctx = make_ctx()
  let result = archivist.reflect(ctx, provider, "mock-model")
  result |> should.be_error
}

// ---------------------------------------------------------------------------
// Phase 2: Curation tests
// ---------------------------------------------------------------------------

pub fn curate_uses_reflection_in_prompt_test() {
  let reflection =
    "The user greeted me. I responded warmly. Nothing surprising."
  let xml =
    "<narrative_entry>
  <summary>I greeted the user warmly.</summary>
  <intent>
    <classification>conversation</classification>
    <description>greeting</description>
    <domain>general</domain>
  </intent>
  <outcome>
    <status>success</status>
    <confidence>0.9</confidence>
    <assessment>Simple greeting</assessment>
  </outcome>
</narrative_entry>"
  // Use handler to verify the reflection is in the prompt
  let provider =
    mock.provider_with_handler(fn(req) {
      let assert [msg] = req.messages
      let assert [llm_types.TextContent(text: prompt_text)] = msg.content
      // The curation prompt should contain the reflection text
      let assert True = string.contains(prompt_text, "REFLECTION")
      let assert True = string.contains(prompt_text, "I responded warmly")
      Ok(mock.text_response(xml))
    })
  let ctx = make_ctx()
  let result = archivist.curate(ctx, reflection, provider, "mock-model", 4096)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("I greeted the user warmly.")
}

pub fn curate_llm_failure_returns_none_test() {
  let provider = mock.provider_with_error("connection refused")
  let ctx = make_ctx()
  let result =
    archivist.curate(ctx, "Some reflection text", provider, "mock-model", 4096)
  result |> should.be_none
}

pub fn curate_invalid_xml_falls_back_test() {
  let provider = mock.provider_with_text("Not valid XML at all!")
  let ctx = make_ctx()
  let result =
    archivist.curate(
      ctx,
      "Reflection: user said hello",
      provider,
      "mock-model",
      4096,
    )
  // Should fall back to a fallback entry (not None)
  result |> should.be_some
  let assert Some(entry) = result
  let assert True = string.contains(entry.summary, "I was asked")
}

// ---------------------------------------------------------------------------
// Two-phase integration: generate with fallback behavior
// ---------------------------------------------------------------------------

pub fn generate_phase1_failure_falls_back_to_single_call_test() {
  // When the reflection LLM call fails, generate should fall back to the
  // original single-call approach. We use a handler that fails on the first
  // call (reflection — no STRUCTURED OUTPUT TASK in system), then succeeds
  // on the second call (single-call — has STRUCTURED OUTPUT TASK in system).
  let xml =
    "<narrative_entry>
  <summary>Single-call fallback entry.</summary>
  <outcome>
    <status>success</status>
    <confidence>0.7</confidence>
  </outcome>
</narrative_entry>"
  let provider =
    mock.provider_with_handler(fn(req) {
      case req.system {
        Some(sys) ->
          case string.contains(sys, "STRUCTURED OUTPUT TASK") {
            // This is the XStructor call (single-call fallback) — return valid XML
            True -> Ok(mock.text_response(xml))
            // This is the reflection call — simulate LLM failure
            False -> Error(llm_types.UnknownError(reason: "reflection failed"))
          }
        None -> Error(llm_types.UnknownError(reason: "no system prompt"))
      }
    })
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", 4096, False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("Single-call fallback entry.")
}

pub fn generate_phase2_failure_preserves_fallback_entry_test() {
  // Phase 1 (reflection) succeeds, Phase 2 (curation) fails with LLM error.
  // Should produce a fallback entry (not None), because Phase 1 succeeded.
  let provider =
    mock.provider_with_handler(fn(req) {
      case req.system {
        Some(sys) ->
          case string.contains(sys, "STRUCTURED OUTPUT TASK") {
            // Phase 2 (curation) — fail
            True -> Error(llm_types.UnknownError(reason: "curation LLM failed"))
            // Phase 1 (reflection) — succeed
            False ->
              Ok(mock.text_response(
                "The user greeted me. Simple conversational cycle.",
              ))
          }
        None -> Error(llm_types.UnknownError(reason: "no system prompt"))
      }
    })
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", 4096, False)
  // Phase 2 failed, but we should still get a fallback entry
  result |> should.be_some
  let assert Some(entry) = result
  // Fallback entry from context
  let assert True = string.contains(entry.summary, "I was asked")
}

pub fn generate_two_phase_success_test() {
  // Both phases succeed — the curation produces the final structured entry
  let xml =
    "<narrative_entry>
  <summary>Two-phase entry: user was greeted.</summary>
  <intent>
    <classification>conversation</classification>
    <description>greeting</description>
    <domain>general</domain>
  </intent>
  <outcome>
    <status>success</status>
    <confidence>0.95</confidence>
    <assessment>Two-phase pipeline completed</assessment>
  </outcome>
</narrative_entry>"
  let provider =
    mock.provider_with_handler(fn(req) {
      case req.system {
        Some(sys) ->
          case string.contains(sys, "STRUCTURED OUTPUT TASK") {
            // Phase 2 (curation) — return valid XML
            True -> Ok(mock.text_response(xml))
            // Phase 1 (reflection) — return plain text
            False ->
              Ok(mock.text_response("Reflection: user said hello, I responded."))
          }
        None ->
          Ok(mock.text_response("Reflection: user said hello, I responded."))
      }
    })
  let ctx = make_ctx()
  let result = archivist.generate(ctx, provider, "mock-model", 4096, False)
  result |> should.be_some
  let assert Some(entry) = result
  entry.summary |> should.equal("Two-phase entry: user was greeted.")
  entry.outcome.status |> should.equal(Success)
}
