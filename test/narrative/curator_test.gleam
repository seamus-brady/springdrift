// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{
  type AgentResult, type AgentTask, AgentResult, AgentTask, ExtractedFact,
  GenericFindings, ResearcherFindings,
}
import facts/types as facts_types
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import identity
import narrative/curator
import narrative/librarian
import narrative/types as narrative_types
import narrative/virtual_memory.{CbrSlotEntry}
import simplifile

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/curator_test_" <> suffix
  let _ = simplifile.create_directory_all(dir)
  case simplifile.read_directory(dir) {
    Ok(files) ->
      list.each(files, fn(f) {
        let _ = simplifile.delete(dir <> "/" <> f)
        Nil
      })
    Error(_) -> Nil
  }
  dir
}

fn start_both(suffix: String) {
  let dir = test_dir(suffix)
  let cbr_dir = dir <> "/cbr"
  let facts_dir = dir <> "/facts"
  let _ = simplifile.create_directory_all(cbr_dir)
  let _ = simplifile.create_directory_all(facts_dir)
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      facts_dir,
      dir <> "/artifacts",
      dir <> "/planner",
      0,
      librarian.default_cbr_config(),
    )
  let assert Ok(cur) = curator.start(lib, dir, cbr_dir, facts_dir)
  #(lib, cur)
}

fn make_task(cycle_id: String, context: String) -> AgentTask {
  let reply_to = process.new_subject()
  AgentTask(
    task_id: "task-001",
    tool_use_id: "tool-001",
    instruction: "Do research",
    context:,
    parent_cycle_id: cycle_id,
    reply_to:,
    depth: 1,
    max_turns_override: option.None,
  )
}

fn make_result(agent_id: String, cycle_id: String, text: String) -> AgentResult {
  AgentResult(
    final_text: text,
    agent_id:,
    cycle_id:,
    findings: GenericFindings(notes: [text]),
  )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn curator_starts_and_shuts_down_test() {
  let #(_lib, cur) = start_both("start_stop")
  // Just verify it starts and can receive shutdown
  process.send(cur, curator.Shutdown)
}

pub fn curator_virtual_context_starts_empty_test() {
  let #(lib, cur) = start_both("ctx_empty")
  let ctx = curator.get_virtual_context(cur)
  ctx |> should.equal("")
  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_write_back_stores_in_scratchpad_test() {
  let #(lib, cur) = start_both("write_back")
  let result = make_result("agent-1", "cycle-001", "Research complete")
  curator.write_back_result(cur, "cycle-001", result)
  process.sleep(200)

  // Verify it was written to the Librarian's scratchpad
  let results = librarian.read_cycle_results(lib, "cycle-001")
  list.length(results) |> should.equal(1)
  let assert [r] = results
  r.final_text |> should.equal("Research complete")

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_clear_cycle_clears_scratchpad_test() {
  let #(lib, cur) = start_both("clear_cycle")
  let result = make_result("agent-1", "cycle-001", "Done")
  curator.write_back_result(cur, "cycle-001", result)
  process.sleep(200)

  // Verify present
  let before = librarian.read_cycle_results(lib, "cycle-001")
  list.length(before) |> should.equal(1)

  // Clear
  curator.clear_cycle(cur, "cycle-001")
  process.sleep(200)

  let after = librarian.read_cycle_results(lib, "cycle-001")
  after |> should.equal([])

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_inject_context_no_prior_results_test() {
  let #(lib, cur) = start_both("inject_empty")
  let task = make_task("cycle-001", "Original context")

  let enriched = curator.inject_context(cur, task)
  // No prior results — context should be unchanged
  enriched.context |> should.equal("Original context")

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_inject_context_with_prior_results_test() {
  let #(lib, cur) = start_both("inject_prior")

  // Write a prior result
  let result = make_result("researcher-1", "cycle-001", "Found 3 sources")
  curator.write_back_result(cur, "cycle-001", result)
  process.sleep(200)

  // Now inject context for a new task in the same cycle
  let task = make_task("cycle-001", "Original context")
  let enriched = curator.inject_context(cur, task)

  // Context should include prior results
  should.be_true(string.contains(enriched.context, "prior_agent_results"))
  should.be_true(string.contains(enriched.context, "researcher-1"))
  should.be_true(string.contains(enriched.context, "Found 3 sources"))
  // Original context preserved
  should.be_true(string.contains(enriched.context, "Original context"))

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_write_back_extracts_facts_test() {
  let #(lib, cur) = start_both("extract_facts")

  let result =
    AgentResult(
      final_text: "Research done",
      agent_id: "researcher-1",
      cycle_id: "cycle-001",
      findings: ResearcherFindings(
        sources: [],
        facts: [
          ExtractedFact(label: "avg_rent", value: "€2,340", confidence: 0.9),
          ExtractedFact(
            label: "low_confidence",
            value: "maybe",
            confidence: 0.3,
          ),
        ],
        data_points: [],
        dead_ends: [],
      ),
    )
  curator.write_back_result(cur, "cycle-001", result)
  // Wait for three actor hops: test→curator, curator→librarian (scratchpad),
  // curator→librarian (fact). Then verify scratchpad first (synchronous).
  process.sleep(300)
  // Verify scratchpad write happened (proves Curator processed our message)
  let scratchpad = librarian.read_cycle_results(lib, "cycle-001")
  list.length(scratchpad) |> should.equal(1)

  // Now check the extracted fact — retry with backoff since it's async
  process.sleep(200)
  let all_facts = librarian.get_all_facts(lib)

  // At least the high-confidence fact should be present
  let rent_facts =
    list.filter(all_facts, fn(f: facts_types.MemoryFact) { f.key == "avg_rent" })
  list.length(rent_facts) |> should.equal(1)
  let assert [rf] = rent_facts
  rf.value |> should.equal("€2,340")
  rf.source |> should.equal("curator_write")

  // Low-confidence fact should NOT be indexed
  let low_facts =
    list.filter(all_facts, fn(f: facts_types.MemoryFact) {
      f.key == "low_confidence"
    })
  list.length(low_facts) |> should.equal(0)

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

// ---------------------------------------------------------------------------
// Virtual memory slot tests
// ---------------------------------------------------------------------------

pub fn curator_set_core_identity_test() {
  let #(lib, cur) = start_both("vm_core")
  curator.set_core_identity(cur, "Research Assistant", ["concise"], [
    "cite sources",
  ])
  process.sleep(50)

  let ctx = curator.get_virtual_context(cur)
  should.be_true(string.contains(ctx, "<memory>"))
  should.be_true(string.contains(ctx, "<core>"))
  should.be_true(string.contains(ctx, "Research Assistant"))
  should.be_true(string.contains(ctx, "concise"))
  should.be_true(string.contains(ctx, "cite sources"))

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_set_active_thread_test() {
  let #(lib, cur) = start_both("vm_thread")
  curator.set_active_thread(cur, "Rent Research", "Tracking prices", 5)
  process.sleep(50)

  let ctx = curator.get_virtual_context(cur)
  should.be_true(string.contains(ctx, "<active_thread"))
  should.be_true(string.contains(ctx, "Rent Research"))
  should.be_true(string.contains(ctx, "Tracking prices"))

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_update_working_memory_test() {
  let #(lib, cur) = start_both("vm_working")
  curator.update_working_memory(cur, "rent", "€2,340", "session")
  process.sleep(50)

  let ctx = curator.get_virtual_context(cur)
  should.be_true(string.contains(ctx, "<working_memory>"))
  should.be_true(string.contains(ctx, "rent"))
  should.be_true(string.contains(ctx, "€2,340"))

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_remove_working_memory_test() {
  let #(lib, cur) = start_both("vm_rm_working")
  curator.update_working_memory(cur, "rent", "€2,340", "session")
  curator.update_working_memory(cur, "pop", "1.4M", "persistent")
  process.sleep(50)
  curator.remove_working_memory(cur, "rent")
  process.sleep(50)

  let ctx = curator.get_virtual_context(cur)
  should.be_true(string.contains(ctx, "pop"))
  should.be_false(string.contains(ctx, "rent"))

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_set_cbr_cases_test() {
  let #(lib, cur) = start_both("vm_cbr")
  curator.set_cbr_cases(cur, [
    CbrSlotEntry(
      case_id: "case-001",
      intent: "research",
      approach: "web search",
      score: 0.85,
      category: "",
    ),
  ])
  process.sleep(50)

  let ctx = curator.get_virtual_context(cur)
  should.be_true(string.contains(ctx, "<similar_cases>"))
  should.be_true(string.contains(ctx, "case-001"))

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_write_back_populates_vm_scratchpad_test() {
  let #(lib, cur) = start_both("vm_scratch")
  let result = make_result("agent-1", "cycle-001", "Found 3 sources")
  curator.write_back_result(cur, "cycle-001", result)
  process.sleep(200)

  let ctx = curator.get_virtual_context(cur)
  should.be_true(string.contains(ctx, "<agent_results>"))
  should.be_true(string.contains(ctx, "agent-1"))

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_clear_cycle_clears_vm_scratchpad_test() {
  let #(lib, cur) = start_both("vm_clear_scratch")
  let result = make_result("agent-1", "cycle-001", "Done")
  curator.write_back_result(cur, "cycle-001", result)
  process.sleep(200)

  // Verify scratchpad is populated
  let before = curator.get_virtual_context(cur)
  should.be_true(string.contains(before, "<agent_results>"))

  // Clear
  curator.clear_cycle(cur, "cycle-001")
  process.sleep(100)

  let after = curator.get_virtual_context(cur)
  should.be_false(string.contains(after, "agent_results"))

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_all_vm_slots_populated_test() {
  let #(lib, cur) = start_both("vm_all")
  curator.set_core_identity(cur, "Assistant", ["concise"], ["cite sources"])
  curator.set_active_thread(cur, "Research", "Tracking", 3)
  curator.update_working_memory(cur, "rent", "€2,340", "session")
  curator.set_cbr_cases(cur, [
    CbrSlotEntry(
      case_id: "c1",
      intent: "research",
      approach: "web search",
      score: 0.9,
      category: "",
    ),
  ])
  process.sleep(50)

  let result = make_result("r1", "cycle-001", "3 sources found")
  curator.write_back_result(cur, "cycle-001", result)
  process.sleep(200)

  let ctx = curator.get_virtual_context(cur)
  should.be_true(string.contains(ctx, "<memory>"))
  should.be_true(string.contains(ctx, "<core>"))
  should.be_true(string.contains(ctx, "<active_thread"))
  should.be_true(string.contains(ctx, "<working_memory>"))
  should.be_true(string.contains(ctx, "<similar_cases>"))
  should.be_true(string.contains(ctx, "<agent_results>"))
  should.be_true(string.contains(ctx, "</memory>"))

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

// ---------------------------------------------------------------------------
// Build system prompt
// ---------------------------------------------------------------------------

pub fn build_system_prompt_fallback_when_no_identity_test() {
  let dir = test_dir("sysprompt_fallback")
  let cbr_dir = dir <> "/cbr"
  let facts_dir = dir <> "/facts"
  let _ = simplifile.create_directory_all(cbr_dir)
  let _ = simplifile.create_directory_all(facts_dir)
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      facts_dir,
      dir <> "/artifacts",
      dir <> "/planner",
      0,
      librarian.default_cbr_config(),
    )
  // Use empty identity dirs to force fallback (no priv/ lookup)
  let assert Ok(cur) =
    curator.start_with_identity(
      lib,
      dir,
      cbr_dir,
      facts_dir,
      [],
      "memory",
      "Springdrift",
      "",
    )
  let prompt = curator.build_system_prompt(cur, "You are helpful.", option.None)
  prompt |> should.equal("You are helpful.")
  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn build_system_prompt_with_persona_test() {
  let dir = test_dir("sysprompt_persona")
  let identity_dir = dir <> "/identity"
  let _ = simplifile.create_directory_all(identity_dir)
  let _ = simplifile.write(identity_dir <> "/persona.md", "I am Springdrift.")
  let cbr_dir = dir <> "/cbr"
  let facts_dir = dir <> "/facts"
  let _ = simplifile.create_directory_all(cbr_dir)
  let _ = simplifile.create_directory_all(facts_dir)
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      facts_dir,
      dir <> "/artifacts",
      dir <> "/planner",
      0,
      librarian.default_cbr_config(),
    )
  let assert Ok(cur) =
    curator.start_with_identity(
      lib,
      dir,
      cbr_dir,
      facts_dir,
      [identity_dir],
      "memory",
      "Springdrift",
      "",
    )
  let prompt = curator.build_system_prompt(cur, "fallback", option.None)
  should.be_true(string.contains(prompt, "I am Springdrift."))
  should.be_true(!string.contains(prompt, "fallback"))
  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

// ---------------------------------------------------------------------------
// Preamble budget tests
// ---------------------------------------------------------------------------

pub fn preamble_budget_plenty_of_room_test() {
  // With a large budget, all slots pass through unchanged
  let slots = [
    identity.SlotValue(key: "agent_name", value: "Test"),
    identity.SlotValue(key: "sensorium", value: "<sensorium/>"),
    identity.SlotValue(key: "recent_narrative", value: "Some narrative text"),
    identity.SlotValue(key: "active_threads", value: "Thread A"),
    identity.SlotValue(key: "memory_health", value: "Nominal"),
  ]
  let result = curator.apply_preamble_budget(slots, 10_000)
  // All values should be preserved (order may differ due to priority sort)
  let values =
    list.map(result, fn(s) { s.value })
    |> list.sort(string.compare)
  should.be_true(list.contains(values, "Test"))
  should.be_true(list.contains(values, "<sensorium/>"))
  should.be_true(list.contains(values, "Some narrative text"))
  should.be_true(list.contains(values, "Thread A"))
  should.be_true(list.contains(values, "Nominal"))
}

pub fn preamble_budget_trims_low_priority_test() {
  // Budget only fits high-priority slots — low-priority ones get cleared
  let slots = [
    identity.SlotValue(key: "agent_name", value: "Bot"),
    identity.SlotValue(key: "sensorium", value: "<sensorium/>"),
    identity.SlotValue(key: "recent_narrative", value: "A long narrative..."),
    identity.SlotValue(key: "active_threads", value: "Thread detail"),
    identity.SlotValue(key: "memory_health", value: "Nominal"),
  ]
  // Budget = 20 chars: enough for "Bot" (3) + "<sensorium/>" (12) = 15, not enough for all
  let result = curator.apply_preamble_budget(slots, 20)
  let find = fn(key) {
    list.find(result, fn(s) { s.key == key })
    |> option.from_result
  }
  // High priority: agent_name (pri=1) and sensorium (pri=2) should survive
  let assert option.Some(name) = find("agent_name")
  name.value |> should.equal("Bot")
  let assert option.Some(sensor) = find("sensorium")
  sensor.value |> should.equal("<sensorium/>")
  // Low priority: memory_health (pri=10) should be cleared
  let assert option.Some(health) = find("memory_health")
  health.value |> should.equal("")
}

pub fn preamble_budget_zero_clears_all_test() {
  let slots = [
    identity.SlotValue(key: "agent_name", value: "Bot"),
    identity.SlotValue(key: "sensorium", value: "<sensorium/>"),
  ]
  let result = curator.apply_preamble_budget(slots, 0)
  list.each(result, fn(s) { s.value |> should.equal("") })
}

// ---------------------------------------------------------------------------
// Sensorium pure renderer tests
// ---------------------------------------------------------------------------

pub fn render_sensorium_clock_no_prior_test() {
  let result =
    curator.render_sensorium_clock(
      "2026-03-19T14:30:00",
      "2026-03-19T12:15:00",
      [],
      "abc12345",
    )
  should.be_true(string.contains(result, "now=\"2026-03-19T14:30:00\""))
  should.be_true(string.contains(result, "session_uptime="))
  should.be_true(string.contains(result, "cycle_id=\"abc12345\""))
  should.be_false(string.contains(result, "last_cycle="))
}

pub fn render_sensorium_clock_with_elapsed_test() {
  let entries = [
    narrative_entry_stub("2026-03-19T14:25:00"),
  ]
  let result =
    curator.render_sensorium_clock(
      "2026-03-19T14:30:00",
      "2026-03-19T12:00:00",
      entries,
      "def67890",
    )
  should.be_true(string.contains(result, "now=\"2026-03-19T14:30:00\""))
  should.be_true(string.contains(result, "session_uptime="))
  should.be_true(string.contains(result, "last_cycle="))
}

pub fn render_sensorium_situation_user_test() {
  let result = curator.render_sensorium_situation("user", 0, 6, option.None)
  should.be_true(string.contains(result, "input=\"user\""))
  should.be_true(string.contains(result, "queue_depth=\"0\""))
  should.be_true(string.contains(result, "conversation_depth=\"6\""))
  should.be_false(string.contains(result, "thread="))
}

pub fn render_sensorium_situation_scheduler_queued_test() {
  let result =
    curator.render_sensorium_situation(
      "scheduler",
      2,
      12,
      option.Some("CBR implementation"),
    )
  should.be_true(string.contains(result, "input=\"scheduler\""))
  should.be_true(string.contains(result, "queue_depth=\"2\""))
  should.be_true(string.contains(result, "conversation_depth=\"12\""))
  should.be_true(string.contains(result, "thread=\"CBR implementation\""))
}

pub fn render_sensorium_schedule_empty_test() {
  let result = curator.render_sensorium_schedule(option.None)
  result |> should.equal("")
}

fn empty_perf() -> curator.PerformanceSummary {
  curator.PerformanceSummary(
    success_rate: 0.0,
    recent_failures: [],
    cost_trend: "stable",
    cbr_hit_rate: 0.0,
  )
}

pub fn render_sensorium_vitals_test() {
  let constitution =
    virtual_memory.ConstitutionSlot(
      today_cycles: 5,
      today_success_rate: 0.8,
      agent_health: "All agents nominal",
    )
  let result =
    curator.render_sensorium_vitals(
      constitution,
      2,
      "",
      "",
      option.None,
      0.0,
      empty_perf(),
      0,
      0,
    )
  should.be_true(string.contains(result, "cycles_today=\"5\""))
  should.be_true(string.contains(result, "agents_active=\"2\""))
  should.be_false(string.contains(result, "agent_health="))
  should.be_false(string.contains(result, "last_failure="))
  // Performance summary attrs present
  should.be_true(string.contains(result, "success_rate=\"0.0\""))
  should.be_true(string.contains(result, "cost_trend=\"stable\""))
  should.be_true(string.contains(result, "cbr_hit_rate=\"0.0\""))
}

pub fn render_sensorium_vitals_health_issue_test() {
  let constitution =
    virtual_memory.ConstitutionSlot(
      today_cycles: 3,
      today_success_rate: 0.6,
      agent_health: "researcher restarting",
    )
  let result =
    curator.render_sensorium_vitals(
      constitution,
      1,
      "researcher restarting",
      "",
      option.None,
      0.0,
      empty_perf(),
      0,
      0,
    )
  should.be_true(string.contains(
    result,
    "agent_health=\"researcher restarting\"",
  ))
  should.be_true(string.contains(result, "agents_active=\"1\""))
}

pub fn render_sensorium_vitals_with_failure_test() {
  let constitution =
    virtual_memory.ConstitutionSlot(
      today_cycles: 5,
      today_success_rate: 0.6,
      agent_health: "All agents nominal",
    )
  let result =
    curator.render_sensorium_vitals(
      constitution,
      2,
      "",
      "researcher timeout 2h ago",
      option.None,
      0.0,
      empty_perf(),
      0,
      0,
    )
  should.be_true(string.contains(
    result,
    "last_failure=\"researcher timeout 2h ago\"",
  ))
}

pub fn render_sensorium_vitals_with_perf_test() {
  let constitution =
    virtual_memory.ConstitutionSlot(
      today_cycles: 10,
      today_success_rate: 0.8,
      agent_health: "All agents nominal",
    )
  let perf =
    curator.PerformanceSummary(
      success_rate: 0.75,
      recent_failures: ["timeout on fetch (weather)", "parse error (news)"],
      cost_trend: "increasing",
      cbr_hit_rate: 0.6,
    )
  let result =
    curator.render_sensorium_vitals(
      constitution,
      3,
      "",
      "",
      option.None,
      0.0,
      perf,
      0,
      0,
    )
  should.be_true(string.contains(result, "success_rate=\"0.75\""))
  should.be_true(string.contains(result, "cost_trend=\"increasing\""))
  should.be_true(string.contains(result, "cbr_hit_rate=\"0.6\""))
  should.be_true(string.contains(result, "recent_failures=\""))
  should.be_true(string.contains(result, "timeout on fetch (weather)"))
  should.be_true(string.contains(result, "parse error (news)"))
}

// ---------------------------------------------------------------------------
// compute_performance_summary tests
// ---------------------------------------------------------------------------

pub fn compute_performance_summary_empty_test() {
  let perf = curator.compute_performance_summary([])
  should.equal(perf.success_rate, 0.0)
  should.equal(perf.recent_failures, [])
  should.equal(perf.cost_trend, "stable")
  should.equal(perf.cbr_hit_rate, 0.0)
}

pub fn compute_performance_summary_all_success_test() {
  let entries = [
    narrative_entry_stub("2026-03-28T10:00:00Z"),
    narrative_entry_stub("2026-03-28T09:00:00Z"),
  ]
  let perf = curator.compute_performance_summary(entries)
  should.equal(perf.success_rate, 1.0)
  should.equal(perf.recent_failures, [])
}

pub fn compute_performance_summary_mixed_test() {
  let success = narrative_entry_stub("2026-03-28T10:00:00Z")
  let failure =
    narrative_types.NarrativeEntry(
      ..narrative_entry_stub("2026-03-28T09:00:00Z"),
      outcome: narrative_types.Outcome(
        status: narrative_types.Failure,
        confidence: 0.5,
        assessment: "web_search timed out",
      ),
      intent: narrative_types.Intent(
        classification: narrative_types.Exploration,
        description: "test",
        domain: "weather",
      ),
    )
  let entries = [success, failure]
  let perf = curator.compute_performance_summary(entries)
  should.equal(perf.success_rate, 0.5)
  should.equal(list.length(perf.recent_failures), 1)
  let assert [first_failure] = perf.recent_failures
  should.be_true(string.contains(first_failure, "web_search timed out"))
  should.be_true(string.contains(first_failure, "weather"))
}

pub fn compute_performance_summary_cost_trend_test() {
  // 6 entries: first 3 (recent) have high tokens, last 3 (older) have low tokens
  let high_entry =
    narrative_types.NarrativeEntry(
      ..narrative_entry_stub("2026-03-28T10:00:00Z"),
      metrics: narrative_types.Metrics(
        total_duration_ms: 0,
        input_tokens: 5000,
        output_tokens: 2000,
        thinking_tokens: 0,
        tool_calls: 0,
        agent_delegations: 0,
        dprime_evaluations: 0,
        model_used: "",
      ),
    )
  let low_entry =
    narrative_types.NarrativeEntry(
      ..narrative_entry_stub("2026-03-28T08:00:00Z"),
      metrics: narrative_types.Metrics(
        total_duration_ms: 0,
        input_tokens: 1000,
        output_tokens: 500,
        thinking_tokens: 0,
        tool_calls: 0,
        agent_delegations: 0,
        dprime_evaluations: 0,
        model_used: "",
      ),
    )
  let entries = [
    high_entry,
    high_entry,
    high_entry,
    low_entry,
    low_entry,
    low_entry,
  ]
  let perf = curator.compute_performance_summary(entries)
  should.equal(perf.cost_trend, "increasing")
}

// ---------------------------------------------------------------------------
// Budget truncation detection tests
// ---------------------------------------------------------------------------

pub fn budget_caused_truncation_no_truncation_test() {
  let slots = [
    identity.SlotValue(key: "a", value: "hello"),
    identity.SlotValue(key: "b", value: "world"),
  ]
  // Same slots — no truncation
  curator.budget_caused_truncation(slots, slots)
  |> should.be_false
}

pub fn budget_caused_truncation_slot_cleared_test() {
  let original = [
    identity.SlotValue(key: "a", value: "hello"),
    identity.SlotValue(key: "b", value: "world"),
  ]
  let budgeted = [
    identity.SlotValue(key: "a", value: "hello"),
    identity.SlotValue(key: "b", value: ""),
  ]
  curator.budget_caused_truncation(original, budgeted)
  |> should.be_true
}

pub fn budget_caused_truncation_slot_shortened_test() {
  let original = [
    identity.SlotValue(key: "a", value: "hello world this is a long string"),
  ]
  let budgeted = [
    identity.SlotValue(key: "a", value: "hello world"),
  ]
  curator.budget_caused_truncation(original, budgeted)
  |> should.be_true
}

pub fn budget_caused_truncation_empty_original_not_truncated_test() {
  let original = [
    identity.SlotValue(key: "a", value: ""),
    identity.SlotValue(key: "b", value: "hello"),
  ]
  let budgeted = [
    identity.SlotValue(key: "a", value: ""),
    identity.SlotValue(key: "b", value: "hello"),
  ]
  // Originally empty slot → not counted as truncation
  curator.budget_caused_truncation(original, budgeted)
  |> should.be_false
}

pub fn budget_caused_truncation_slot_missing_in_budgeted_test() {
  let original = [
    identity.SlotValue(key: "a", value: "hello"),
  ]
  let budgeted = []
  // Slot gone entirely — treat as truncated
  curator.budget_caused_truncation(original, budgeted)
  |> should.be_true
}

// ---------------------------------------------------------------------------
// Sensorium test helpers
// ---------------------------------------------------------------------------

fn narrative_entry_stub(ts: String) -> narrative_types.NarrativeEntry {
  narrative_types.NarrativeEntry(
    schema_version: 1,
    cycle_id: "test-cycle",
    parent_cycle_id: option.None,
    timestamp: ts,
    entry_type: narrative_types.Narrative,
    summary: "Test entry",
    intent: narrative_types.Intent(
      classification: narrative_types.Exploration,
      description: "test",
      domain: "test",
    ),
    outcome: narrative_types.Outcome(
      status: narrative_types.Success,
      confidence: 0.9,
      assessment: "ok",
    ),
    delegation_chain: [],
    decisions: [],
    keywords: [],
    topics: [],
    entities: narrative_types.Entities(
      locations: [],
      organisations: [],
      data_points: [],
      temporal_references: [],
    ),
    sources: [],
    thread: option.None,
    metrics: narrative_types.Metrics(
      total_duration_ms: 0,
      input_tokens: 0,
      output_tokens: 0,
      thinking_tokens: 0,
      tool_calls: 0,
      agent_delegations: 0,
      dprime_evaluations: 0,
      model_used: "",
    ),
    observations: [],
    redacted: False,
    strategy_used: option.None,
  )
}
