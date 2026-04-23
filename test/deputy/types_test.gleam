// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import deputy/types.{
  BriefingCase, BriefingFact, DeputyBriefing, render_briefing, xml_escape,
}
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// ---------------------------------------------------------------------------
// render_briefing
// ---------------------------------------------------------------------------

pub fn render_empty_briefing_test() {
  let b =
    DeputyBriefing(
      deputy_id: "dep-abc",
      relevant_cases: [],
      relevant_facts: [],
      known_pitfalls: None,
      signal: "silent",
      elapsed_ms: 100,
    )
  let xml = render_briefing(b)
  should.be_true(string.contains(xml, "<briefing"))
  should.be_true(string.contains(xml, "deputy_id=\"dep-abc\""))
  should.be_true(string.contains(xml, "signal=\"silent\""))
  should.be_false(string.contains(xml, "<relevant_cases>"))
  should.be_false(string.contains(xml, "<relevant_facts>"))
  should.be_false(string.contains(xml, "<known_pitfalls>"))
}

pub fn render_briefing_with_cases_test() {
  let b =
    DeputyBriefing(
      deputy_id: "dep-xyz",
      relevant_cases: [
        BriefingCase(
          case_id: "CBR-1",
          similarity: 0.87,
          summary: "Prior fix pattern",
        ),
      ],
      relevant_facts: [],
      known_pitfalls: None,
      signal: "high_novelty",
      elapsed_ms: 200,
    )
  let xml = render_briefing(b)
  should.be_true(string.contains(xml, "<relevant_cases>"))
  should.be_true(string.contains(xml, "id=\"CBR-1\""))
  should.be_true(string.contains(xml, "Prior fix pattern"))
}

pub fn render_briefing_with_facts_and_pitfalls_test() {
  let b =
    DeputyBriefing(
      deputy_id: "dep-xyz",
      relevant_cases: [],
      relevant_facts: [
        BriefingFact(key: "test_pattern", value: "override the FFI"),
      ],
      known_pitfalls: Some("Three recent failures"),
      signal: "anomaly",
      elapsed_ms: 300,
    )
  let xml = render_briefing(b)
  should.be_true(string.contains(xml, "<relevant_facts>"))
  should.be_true(string.contains(xml, "key=\"test_pattern\""))
  should.be_true(string.contains(xml, "override the FFI"))
  should.be_true(string.contains(xml, "<known_pitfalls>"))
  should.be_true(string.contains(xml, "Three recent failures"))
}

pub fn render_briefing_empty_pitfalls_omitted_test() {
  let b =
    DeputyBriefing(
      deputy_id: "dep-xyz",
      relevant_cases: [],
      relevant_facts: [],
      known_pitfalls: Some("   "),
      signal: "silent",
      elapsed_ms: 50,
    )
  let xml = render_briefing(b)
  should.be_false(string.contains(xml, "<known_pitfalls>"))
}

// ---------------------------------------------------------------------------
// xml_escape
// ---------------------------------------------------------------------------

pub fn xml_escape_ampersand_test() {
  should.equal(xml_escape("a & b"), "a &amp; b")
}

pub fn xml_escape_angle_brackets_test() {
  should.equal(xml_escape("<tag>"), "&lt;tag&gt;")
}

pub fn xml_escape_quotes_test() {
  should.equal(xml_escape("\"hello\""), "&quot;hello&quot;")
}

pub fn xml_escape_apostrophes_test() {
  should.equal(xml_escape("it's"), "it&apos;s")
}

pub fn xml_escape_combined_test() {
  let input = "<foo attr=\"value\">bar & baz 'quux'</foo>"
  let output = xml_escape(input)
  should.be_false(string.contains(output, "<foo"))
  should.be_true(string.contains(output, "&lt;foo"))
  should.be_true(string.contains(output, "&quot;"))
  should.be_true(string.contains(output, "&amp;"))
  should.be_true(string.contains(output, "&apos;"))
}

pub fn render_briefing_escapes_untrusted_content_test() {
  let b =
    DeputyBriefing(
      deputy_id: "dep-xyz",
      relevant_cases: [
        BriefingCase(
          case_id: "CBR-1",
          similarity: 0.5,
          summary: "Has <script> and & in it",
        ),
      ],
      relevant_facts: [],
      known_pitfalls: None,
      signal: "routine",
      elapsed_ms: 10,
    )
  let xml = render_briefing(b)
  should.be_false(string.contains(xml, "<script>"))
  should.be_true(string.contains(xml, "&lt;script&gt;"))
  should.be_true(string.contains(xml, "&amp;"))
}
