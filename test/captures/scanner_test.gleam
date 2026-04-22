// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import captures/scanner
import captures/types.{type Capture, AgentSelf, Capture, Pending}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should

fn short(id: String, text: String) -> Capture {
  Capture(
    schema_version: 1,
    id: id,
    created_at: "2026-04-22T10:00:00Z",
    source_cycle_id: "cyc-001",
    text: text,
    source: AgentSelf,
    due_hint: None,
    status: Pending,
  )
}

// ---------------------------------------------------------------------------
// sanity_filter — extraction-quality gate (pure)
// ---------------------------------------------------------------------------

pub fn sanity_filter_drops_empty_text_test() {
  let captures = [short("cap-1", "   "), short("cap-2", "real capture")]
  let result = scanner.sanity_filter(captures, 10, "cyc-test")
  should.equal(list.length(result), 1)
  case result {
    [only] -> should.equal(only.id, "cap-2")
    _ -> should.fail()
  }
}

pub fn sanity_filter_drops_overlong_text_test() {
  let long_text = string.repeat("A", 600)
  let captures = [short("cap-1", long_text), short("cap-2", "fits")]
  let result = scanner.sanity_filter(captures, 10, "cyc-test")
  should.equal(list.length(result), 1)
  case result {
    [only] -> should.equal(only.id, "cap-2")
    _ -> should.fail()
  }
}

pub fn sanity_filter_drops_prompt_echo_test() {
  // Text suspiciously similar to the scanner's own prompt should be rejected.
  let captures = [
    short("cap-1", "Extract any commitment or promise from the cycle output."),
    short("cap-2", "Follow up on the research thread next week."),
  ]
  let result = scanner.sanity_filter(captures, 10, "cyc-test")
  should.equal(list.length(result), 1)
  case result {
    [only] -> should.equal(only.id, "cap-2")
    _ -> should.fail()
  }
}

pub fn sanity_filter_caps_to_max_per_cycle_test() {
  let many =
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]
    |> list.map(fn(i) {
      short("cap-" <> int.to_string(i), "action number " <> int.to_string(i))
    })
  let result = scanner.sanity_filter(many, 5, "cyc-test")
  should.equal(list.length(result), 5)
}

pub fn sanity_filter_escapes_xml_test() {
  let captures = [
    short("cap-1", "Deal with <script>alert(1)</script> & friends"),
  ]
  let result = scanner.sanity_filter(captures, 10, "cyc-test")
  case result {
    [only] -> {
      // XML-dangerous characters should have been replaced
      should.be_false(string.contains(only.text, "<script>"))
      should.be_false(string.contains(only.text, "</script>"))
      should.be_true(string.contains(only.text, "&lt;"))
      should.be_true(string.contains(only.text, "&amp;"))
    }
    _ -> should.fail()
  }
}

pub fn sanity_filter_trims_whitespace_test() {
  let captures = [short("cap-1", "   padded   ")]
  let result = scanner.sanity_filter(captures, 10, "cyc-test")
  case result {
    [only] -> should.equal(only.text, "padded")
    _ -> should.fail()
  }
}

pub fn sanity_filter_zero_input_returns_empty_test() {
  let result = scanner.sanity_filter([], 10, "cyc-test")
  should.equal(list.length(result), 0)
}
