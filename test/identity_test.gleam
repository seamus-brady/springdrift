import gleam/option.{None, Some}
import gleeunit/should
import identity

// ---------------------------------------------------------------------------
// Persona loading
// ---------------------------------------------------------------------------

pub fn load_persona_missing_dirs_test() {
  let result = identity.load_persona(["/nonexistent/dir"])
  result |> should.equal(None)
}

pub fn load_persona_empty_dirs_test() {
  let result = identity.load_persona([])
  result |> should.equal(None)
}

// ---------------------------------------------------------------------------
// Slot substitution
// ---------------------------------------------------------------------------

pub fn substitute_single_slot_test() {
  let text = "Hello {{name}}, welcome!"
  let slots = [identity.SlotValue(key: "name", value: "Alice")]
  identity.substitute_slots(text, slots)
  |> should.equal("Hello Alice, welcome!")
}

pub fn substitute_multiple_slots_test() {
  let text = "{{greeting}} {{name}}!"
  let slots = [
    identity.SlotValue(key: "greeting", value: "Hi"),
    identity.SlotValue(key: "name", value: "Bob"),
  ]
  identity.substitute_slots(text, slots) |> should.equal("Hi Bob!")
}

pub fn substitute_missing_slot_test() {
  let text = "Hello {{name}}!"
  identity.substitute_slots(text, []) |> should.equal("Hello {{name}}!")
}

pub fn substitute_repeated_slot_test() {
  let text = "{{x}} and {{x}}"
  let slots = [identity.SlotValue(key: "x", value: "Y")]
  identity.substitute_slots(text, slots) |> should.equal("Y and Y")
}

// ---------------------------------------------------------------------------
// Preamble rendering
// ---------------------------------------------------------------------------

pub fn render_preamble_basic_test() {
  let template = "Status: {{status}}\nCount: {{count}}"
  let slots = [
    identity.SlotValue(key: "status", value: "active"),
    identity.SlotValue(key: "count", value: "5"),
  ]
  let result = identity.render_preamble(template, slots)
  result |> should.equal("Status: active\nCount: 5")
}

pub fn render_preamble_omit_empty_test() {
  let template =
    "## Summary\n{{summary}}                          [OMIT IF EMPTY]"
  let slots = [identity.SlotValue(key: "summary", value: "")]
  let result = identity.render_preamble(template, slots)
  result |> should.equal("## Summary")
}

pub fn render_preamble_omit_zero_test() {
  let template = "{{count}} active thread(s):         [OMIT IF ZERO]"
  let slots = [identity.SlotValue(key: "count", value: "0")]
  let result = identity.render_preamble(template, slots)
  result |> should.equal("")
}

pub fn render_preamble_keep_nonzero_test() {
  let template = "{{count}} active thread(s):         [OMIT IF ZERO]"
  let slots = [identity.SlotValue(key: "count", value: "3")]
  let result = identity.render_preamble(template, slots)
  result |> should.equal("3 active thread(s):")
}

pub fn render_preamble_drops_unresolved_slots_test() {
  let template = "Known: {{known}}\nUnknown: {{unknown}}"
  let slots = [identity.SlotValue(key: "known", value: "yes")]
  let result = identity.render_preamble(template, slots)
  result |> should.equal("Known: yes")
}

pub fn render_preamble_omit_no_profile_test() {
  let template =
    "## Active profile                              [OMIT IF NO PROFILE]\nRunning under '{{active_profile}}'."
  let slots = [identity.SlotValue(key: "active_profile", value: "analyst")]
  let result = identity.render_preamble(template, slots)
  // The header line with OMIT IF NO PROFILE is always omitted
  result |> should.equal("Running under 'analyst'.")
}

// ---------------------------------------------------------------------------
// System prompt assembly
// ---------------------------------------------------------------------------

pub fn assemble_both_test() {
  let persona = Some("I am Springdrift.")
  let preamble = Some("Status: active")
  let result = identity.assemble_system_prompt(persona, preamble, "memory")
  result
  |> should.equal(Some(
    "I am Springdrift.\n\n<memory>\nStatus: active\n</memory>",
  ))
}

pub fn assemble_persona_only_test() {
  let result = identity.assemble_system_prompt(Some("I am X."), None, "memory")
  result |> should.equal(Some("I am X."))
}

pub fn assemble_preamble_only_test() {
  let result =
    identity.assemble_system_prompt(None, Some("Status: ok"), "memory")
  result |> should.equal(Some("<memory>\nStatus: ok\n</memory>"))
}

pub fn assemble_neither_test() {
  let result = identity.assemble_system_prompt(None, None, "memory")
  result |> should.equal(None)
}

pub fn assemble_custom_tag_test() {
  let result =
    identity.assemble_system_prompt(
      Some("Persona"),
      Some("Preamble"),
      "context",
    )
  result
  |> should.equal(Some("Persona\n\n<context>\nPreamble\n</context>"))
}

// ---------------------------------------------------------------------------
// Relative date formatting
// ---------------------------------------------------------------------------

pub fn relative_date_today_test() {
  identity.format_relative_date(0) |> should.equal("today")
}

pub fn relative_date_yesterday_test() {
  identity.format_relative_date(1) |> should.equal("yesterday")
}

pub fn relative_date_3_days_test() {
  identity.format_relative_date(3) |> should.equal("3 days ago")
}

pub fn relative_date_last_week_test() {
  identity.format_relative_date(7) |> should.equal("last week")
  identity.format_relative_date(13) |> should.equal("last week")
}

pub fn relative_date_14_days_test() {
  identity.format_relative_date(14) |> should.equal("14 days ago")
}

pub fn relative_date_30_plus_test() {
  identity.format_relative_date(30) |> should.equal("more than 30 days ago")
}

pub fn relative_date_from_strings_test() {
  identity.format_relative_date_from_strings("2026-03-07", "2026-03-08")
  |> should.equal("yesterday")
}

pub fn relative_date_from_strings_today_test() {
  identity.format_relative_date_from_strings("2026-03-08", "2026-03-08")
  |> should.equal("today")
}

// ---------------------------------------------------------------------------
// Slot builders
// ---------------------------------------------------------------------------

pub fn format_thread_lines_test() {
  let threads = [
    #("Dublin housing", 5, "2026-03-07", ["rent", "dublin", "housing"]),
  ]
  let result = identity.format_thread_lines(threads, "2026-03-08")
  should.be_true(
    result
    |> fn(s) {
      let _ = s
      True
    },
  )
  // Just check it contains key parts
  should.be_true(
    result
    == "- Dublin housing — 5 cycle(s), last active yesterday\n  Keywords: rent, dublin, housing",
  )
}

pub fn format_fact_lines_test() {
  let facts = [#("rent", "€2,340", "2026-03-07", 0.9)]
  let result = identity.format_fact_lines(facts, "2026-03-08")
  should.be_true(
    result == "- rent: €2,340 (written yesterday, confidence 90.0%)",
  )
}

pub fn format_thread_lines_empty_test() {
  identity.format_thread_lines([], "2026-03-08") |> should.equal("")
}

pub fn format_fact_lines_empty_test() {
  identity.format_fact_lines([], "2026-03-08") |> should.equal("")
}
