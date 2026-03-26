import gleam/string
import gleeunit/should
import narrative/virtual_memory.{CbrSlotEntry, ScratchEntry, WorkingEntry}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

pub fn empty_vm_produces_empty_prompt_test() {
  let vm = virtual_memory.empty()
  let result = virtual_memory.to_system_prompt(vm)
  result |> should.equal("")
}

// ---------------------------------------------------------------------------
// Core slot
// ---------------------------------------------------------------------------

pub fn core_slot_renders_identity_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.set_core("Research Assistant", [], [])
  let result = virtual_memory.to_system_prompt(vm)
  should.be_true(string.contains(result, "<memory>"))
  should.be_true(string.contains(result, "<core>"))
  should.be_true(string.contains(result, "Research Assistant"))
  should.be_true(string.contains(result, "</core>"))
  should.be_true(string.contains(result, "</memory>"))
}

pub fn core_slot_renders_preferences_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.set_core("Agent", ["markdown format", "concise"], [])
  let result = virtual_memory.to_system_prompt(vm)
  should.be_true(string.contains(result, "markdown format"))
  should.be_true(string.contains(result, "concise"))
  should.be_true(string.contains(result, "<preferences>"))
}

pub fn core_slot_renders_instructions_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.set_core("Agent", [], ["Always cite sources"])
  let result = virtual_memory.to_system_prompt(vm)
  should.be_true(string.contains(result, "Always cite sources"))
  should.be_true(string.contains(result, "<instructions>"))
}

// ---------------------------------------------------------------------------
// Thread slot
// ---------------------------------------------------------------------------

pub fn thread_slot_renders_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.set_thread(
      "Dublin Rent Research",
      "Tracking rental prices in Dublin",
      5,
    )
  let result = virtual_memory.to_system_prompt(vm)
  should.be_true(string.contains(result, "<active_thread"))
  should.be_true(string.contains(result, "Dublin Rent Research"))
  should.be_true(string.contains(result, "Tracking rental prices"))
  should.be_true(string.contains(result, "cycles=\"5\""))
}

pub fn empty_thread_not_rendered_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.set_thread("", "", 0)
  let result = virtual_memory.to_system_prompt(vm)
  result |> should.equal("")
}

// ---------------------------------------------------------------------------
// Working memory
// ---------------------------------------------------------------------------

pub fn working_memory_renders_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.add_working_entry("rent", "€2,340", "session")
    |> virtual_memory.add_working_entry("pop", "1.4M", "persistent")
  let result = virtual_memory.to_system_prompt(vm)
  should.be_true(string.contains(result, "<working_memory>"))
  should.be_true(string.contains(result, "key=\"rent\""))
  should.be_true(string.contains(result, "€2,340"))
  should.be_true(string.contains(result, "key=\"pop\""))
}

pub fn working_memory_overwrite_same_key_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.add_working_entry("rent", "€2,340", "session")
    |> virtual_memory.add_working_entry("rent", "€2,500", "session")
  let entries = vm.working_memory.entries
  // Should have exactly one entry for "rent"
  should.equal(1, list_length(entries))
  let assert [e] = entries
  e.value |> should.equal("€2,500")
}

pub fn working_memory_remove_entry_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.add_working_entry("rent", "€2,340", "session")
    |> virtual_memory.add_working_entry("pop", "1.4M", "persistent")
    |> virtual_memory.remove_working_entry("rent")
  let entries = vm.working_memory.entries
  should.equal(1, list_length(entries))
  let assert [e] = entries
  e.key |> should.equal("pop")
}

pub fn set_working_memory_replaces_all_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.add_working_entry("old", "value", "session")
    |> virtual_memory.set_working_memory([
      WorkingEntry(key: "new1", value: "v1", scope: "session"),
      WorkingEntry(key: "new2", value: "v2", scope: "persistent"),
    ])
  should.equal(2, list_length(vm.working_memory.entries))
}

// ---------------------------------------------------------------------------
// CBR cases
// ---------------------------------------------------------------------------

pub fn cbr_slot_renders_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.set_cbr_cases([
      CbrSlotEntry(
        case_id: "case-001",
        intent: "research",
        approach: "web search + summarise",
        score: 0.85,
        category: "",
      ),
    ])
  let result = virtual_memory.to_system_prompt(vm)
  should.be_true(string.contains(result, "<similar_cases>"))
  should.be_true(string.contains(result, "case-001"))
  should.be_true(string.contains(result, "research"))
  should.be_true(string.contains(result, "web search"))
}

// ---------------------------------------------------------------------------
// Scratchpad
// ---------------------------------------------------------------------------

pub fn scratchpad_renders_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.set_scratchpad([
      ScratchEntry(agent_id: "researcher-1", summary: "Found 3 sources"),
    ])
  let result = virtual_memory.to_system_prompt(vm)
  should.be_true(string.contains(result, "<agent_results>"))
  should.be_true(string.contains(result, "researcher-1"))
  should.be_true(string.contains(result, "Found 3 sources"))
}

pub fn clear_scratchpad_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.set_scratchpad([
      ScratchEntry(agent_id: "agent-1", summary: "Done"),
    ])
    |> virtual_memory.clear_scratchpad()
  let result = virtual_memory.to_system_prompt(vm)
  // Scratchpad cleared — should not render agent_results
  should.be_false(string.contains(result, "agent_results"))
}

// ---------------------------------------------------------------------------
// Combined rendering
// ---------------------------------------------------------------------------

pub fn all_slots_populated_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.set_core("Assistant", ["concise"], ["cite sources"])
    |> virtual_memory.set_thread("Rent Research", "Tracking rents", 3)
    |> virtual_memory.add_working_entry("rent", "€2,340", "session")
    |> virtual_memory.set_cbr_cases([
      CbrSlotEntry(
        case_id: "c1",
        intent: "research",
        approach: "web search",
        score: 0.9,
        category: "",
      ),
    ])
    |> virtual_memory.set_scratchpad([
      ScratchEntry(agent_id: "r1", summary: "3 sources found"),
    ])
  let result = virtual_memory.to_system_prompt(vm)
  // All sections should be present
  should.be_true(string.contains(result, "<memory>"))
  should.be_true(string.contains(result, "<core>"))
  should.be_true(string.contains(result, "<active_thread"))
  should.be_true(string.contains(result, "<working_memory>"))
  should.be_true(string.contains(result, "<similar_cases>"))
  should.be_true(string.contains(result, "<agent_results>"))
  should.be_true(string.contains(result, "</memory>"))
}

pub fn partial_slots_only_render_populated_test() {
  let vm =
    virtual_memory.empty()
    |> virtual_memory.add_working_entry("key1", "val1", "session")
  let result = virtual_memory.to_system_prompt(vm)
  // Should have memory and working_memory but not core/thread/cbr/scratch
  should.be_true(string.contains(result, "<memory>"))
  should.be_true(string.contains(result, "<working_memory>"))
  should.be_false(string.contains(result, "<core>"))
  should.be_false(string.contains(result, "<active_thread"))
  should.be_false(string.contains(result, "<similar_cases>"))
  should.be_false(string.contains(result, "<agent_results>"))
}

// Helper
fn list_length(l: List(a)) -> Int {
  case l {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}
