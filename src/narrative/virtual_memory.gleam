//// Virtual Memory — Letta-style managed context window.
////
//// A structured, fixed-budget context block injected into every LLM request.
//// The Curator owns the virtual memory window and serialises it into a compact
//// XML string prepended to the system prompt as a <memory> block.
////
//// Slots:
////   core             — always resident, identity + preferences (~300 tokens)
////   narrative_thread — active thread summary (~400 tokens)
////   working_memory   — keyed facts for this session (~500 tokens)
////   cbr_cases        — retrieved similar cases (~600 tokens)
////   agent_scratchpad — prior agent results this cycle (~400 tokens)
////   total budget     — ~2200 tokens

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/int
import gleam/list
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type VirtualMemory {
  VirtualMemory(
    core: CoreSlot,
    constitution: ConstitutionSlot,
    narrative_thread: ThreadSlot,
    working_memory: WorkingSlot,
    cbr_cases: CbrSlot,
    agent_scratchpad: ScratchSlot,
  )
}

/// Constitution — today's stats and agent health.
pub type ConstitutionSlot {
  ConstitutionSlot(
    today_cycles: Int,
    today_success_rate: Float,
    agent_health: String,
  )
}

/// Core identity — always resident, never evicted.
pub type CoreSlot {
  CoreSlot(
    identity: String,
    preferences: List(String),
    instructions: List(String),
  )
}

/// Active narrative thread summary.
pub type ThreadSlot {
  ThreadSlot(thread_name: String, summary: String, cycle_count: Int)
}

/// Working memory — keyed facts from this session.
pub type WorkingEntry {
  WorkingEntry(key: String, value: String, scope: String)
}

pub type WorkingSlot {
  WorkingSlot(entries: List(WorkingEntry))
}

/// Retrieved CBR cases for the current query.
pub type CbrSlotEntry {
  CbrSlotEntry(
    case_id: String,
    intent: String,
    approach: String,
    score: Float,
    category: String,
  )
}

pub type CbrSlot {
  CbrSlot(cases: List(CbrSlotEntry))
}

/// Agent results from earlier in the current cycle.
pub type ScratchEntry {
  ScratchEntry(agent_id: String, summary: String)
}

pub type ScratchSlot {
  ScratchSlot(entries: List(ScratchEntry))
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// Create an empty VirtualMemory with all slots cleared.
pub fn empty() -> VirtualMemory {
  VirtualMemory(
    core: CoreSlot(identity: "", preferences: [], instructions: []),
    constitution: ConstitutionSlot(
      today_cycles: 0,
      today_success_rate: 0.0,
      agent_health: "All agents nominal",
    ),
    narrative_thread: ThreadSlot(thread_name: "", summary: "", cycle_count: 0),
    working_memory: WorkingSlot(entries: []),
    cbr_cases: CbrSlot(cases: []),
    agent_scratchpad: ScratchSlot(entries: []),
  )
}

// ---------------------------------------------------------------------------
// Slot setters
// ---------------------------------------------------------------------------

pub fn set_constitution(
  vm: VirtualMemory,
  slot: ConstitutionSlot,
) -> VirtualMemory {
  VirtualMemory(..vm, constitution: slot)
}

pub fn set_core(
  vm: VirtualMemory,
  identity: String,
  preferences: List(String),
  instructions: List(String),
) -> VirtualMemory {
  VirtualMemory(..vm, core: CoreSlot(identity:, preferences:, instructions:))
}

pub fn set_thread(
  vm: VirtualMemory,
  thread_name: String,
  summary: String,
  cycle_count: Int,
) -> VirtualMemory {
  VirtualMemory(
    ..vm,
    narrative_thread: ThreadSlot(thread_name:, summary:, cycle_count:),
  )
}

pub fn set_working_memory(
  vm: VirtualMemory,
  entries: List(WorkingEntry),
) -> VirtualMemory {
  VirtualMemory(..vm, working_memory: WorkingSlot(entries:))
}

pub fn add_working_entry(
  vm: VirtualMemory,
  key: String,
  value: String,
  scope: String,
) -> VirtualMemory {
  let entry = WorkingEntry(key:, value:, scope:)
  // Replace existing entry with same key
  let filtered =
    list.filter(vm.working_memory.entries, fn(e: WorkingEntry) { e.key != key })
  VirtualMemory(..vm, working_memory: WorkingSlot(entries: [entry, ..filtered]))
}

pub fn remove_working_entry(vm: VirtualMemory, key: String) -> VirtualMemory {
  let filtered =
    list.filter(vm.working_memory.entries, fn(e: WorkingEntry) { e.key != key })
  VirtualMemory(..vm, working_memory: WorkingSlot(entries: filtered))
}

pub fn set_cbr_cases(
  vm: VirtualMemory,
  cases: List(CbrSlotEntry),
) -> VirtualMemory {
  VirtualMemory(..vm, cbr_cases: CbrSlot(cases:))
}

pub fn set_scratchpad(
  vm: VirtualMemory,
  entries: List(ScratchEntry),
) -> VirtualMemory {
  VirtualMemory(..vm, agent_scratchpad: ScratchSlot(entries:))
}

pub fn clear_scratchpad(vm: VirtualMemory) -> VirtualMemory {
  VirtualMemory(..vm, agent_scratchpad: ScratchSlot(entries: []))
}

// ---------------------------------------------------------------------------
// Serialisation — compact XML for system prompt injection
// ---------------------------------------------------------------------------

/// Serialise the virtual memory to an XML string for system prompt injection.
/// Returns "" if all slots are empty (zero overhead when unused).
pub fn to_system_prompt(vm: VirtualMemory) -> String {
  let core_xml = render_core(vm.core)
  let constitution_xml = render_constitution(vm.constitution)
  let thread_xml = render_thread(vm.narrative_thread)
  let working_xml = render_working(vm.working_memory)
  let cbr_xml = render_cbr(vm.cbr_cases)
  let scratch_xml = render_scratch(vm.agent_scratchpad)

  let sections =
    [core_xml, constitution_xml, thread_xml, working_xml, cbr_xml, scratch_xml]
    |> list.filter(fn(s) { s != "" })

  case sections {
    [] -> ""
    _ -> "<memory>\n" <> string.join(sections, "\n") <> "\n</memory>"
  }
}

fn render_constitution(slot: ConstitutionSlot) -> String {
  case slot.today_cycles {
    0 -> ""
    n ->
      "<constitution>"
      <> "\n  <today cycles=\""
      <> int.to_string(n)
      <> "\" success_rate=\""
      <> float_to_string(slot.today_success_rate)
      <> "\"/>"
      <> case slot.agent_health {
        "All agents nominal" -> ""
        h -> "\n  <agent_health>" <> h <> "</agent_health>"
      }
      <> "\n</constitution>"
  }
}

fn render_core(slot: CoreSlot) -> String {
  case slot.identity {
    "" -> ""
    identity -> {
      let prefs = case slot.preferences {
        [] -> ""
        ps ->
          "\n  <preferences>"
          <> string.join(
            list.map(ps, fn(p) { "\n    <pref>" <> p <> "</pref>" }),
            "",
          )
          <> "\n  </preferences>"
      }
      let instrs = case slot.instructions {
        [] -> ""
        is ->
          "\n  <instructions>"
          <> string.join(
            list.map(is, fn(i) { "\n    <instr>" <> i <> "</instr>" }),
            "",
          )
          <> "\n  </instructions>"
      }
      "<core>\n  <identity>"
      <> identity
      <> "</identity>"
      <> prefs
      <> instrs
      <> "\n</core>"
    }
  }
}

fn render_thread(slot: ThreadSlot) -> String {
  case slot.thread_name {
    "" -> ""
    name ->
      "<active_thread name=\""
      <> name
      <> "\" cycles=\""
      <> int.to_string(slot.cycle_count)
      <> "\">\n  "
      <> slot.summary
      <> "\n</active_thread>"
  }
}

fn render_working(slot: WorkingSlot) -> String {
  case slot.entries {
    [] -> ""
    entries ->
      "<working_memory>"
      <> string.join(
        list.map(entries, fn(e: WorkingEntry) {
          "\n  <fact key=\""
          <> e.key
          <> "\" scope=\""
          <> e.scope
          <> "\">"
          <> e.value
          <> "</fact>"
        }),
        "",
      )
      <> "\n</working_memory>"
  }
}

fn render_cbr(slot: CbrSlot) -> String {
  case slot.cases {
    [] -> ""
    cases -> {
      // Group cases by category for organised presentation
      let grouped = group_by_category(cases)
      "<similar_cases>"
      <> string.join(
        list.map(grouped, fn(group) {
          let #(category, entries) = group
          let header = case category {
            "" -> ""
            cat -> "\n  <!-- " <> cat <> " -->"
          }
          header
          <> string.join(
            list.map(entries, fn(c: CbrSlotEntry) {
              "\n  <case id=\""
              <> c.case_id
              <> "\" intent=\""
              <> c.intent
              <> "\" score=\""
              <> float_to_string(c.score)
              <> case c.category {
                "" -> ""
                cat -> "\" category=\"" <> cat
              }
              <> "\">"
              <> c.approach
              <> "</case>"
            }),
            "",
          )
        }),
        "",
      )
      <> "\n</similar_cases>"
    }
  }
}

/// Group cases by category, preserving order within each group.
/// Category order: Pitfalls first (most important to know), then Strategies,
/// Troubleshooting, CodePattern, DomainKnowledge, uncategorised last.
fn group_by_category(
  cases: List(CbrSlotEntry),
) -> List(#(String, List(CbrSlotEntry))) {
  let category_order = [
    "Pitfalls to Avoid", "Strategies", "Troubleshooting", "Code Patterns",
    "Domain Knowledge", "",
  ]
  let categorised =
    list.map(cases, fn(c) {
      let label = case c.category {
        "pitfall" -> "Pitfalls to Avoid"
        "strategy" -> "Strategies"
        "troubleshooting" -> "Troubleshooting"
        "code_pattern" -> "Code Patterns"
        "domain_knowledge" -> "Domain Knowledge"
        _ -> ""
      }
      #(label, c)
    })
  list.filter_map(category_order, fn(cat) {
    let entries =
      list.filter_map(categorised, fn(pair) {
        case pair.0 == cat {
          True -> Ok(pair.1)
          False -> Error(Nil)
        }
      })
    case entries {
      [] -> Error(Nil)
      _ -> Ok(#(cat, entries))
    }
  })
}

fn render_scratch(slot: ScratchSlot) -> String {
  case slot.entries {
    [] -> ""
    entries ->
      "<agent_results>"
      <> string.join(
        list.map(entries, fn(e: ScratchEntry) {
          "\n  <result agent=\""
          <> e.agent_id
          <> "\">"
          <> e.summary
          <> "</result>"
        }),
        "",
      )
      <> "\n</agent_results>"
  }
}

@external(erlang, "erlang", "float_to_binary")
fn float_to_string(f: Float) -> String
