import agent/types.{
  type AgentResult, type AgentTask, AgentResult, AgentTask, ExtractedFact,
  GenericFindings, ResearcherFindings,
}
import cbr/types as cbr_types
import facts/types as facts_types
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import narrative/curator
import narrative/librarian
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
  let lib = librarian.start(dir, cbr_dir, facts_dir, dir <> "/artifacts", 0)
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

pub fn curator_housekeeping_runs_without_error_test() {
  let #(lib, cur) = start_both("housekeeping")
  // Just verify it doesn't crash
  curator.run_housekeeping(cur)
  process.sleep(50)

  // Curator should still be responsive
  let ctx = curator.get_virtual_context(cur)
  ctx |> should.equal("")

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
// Housekeeping integration tests
// ---------------------------------------------------------------------------

fn make_cbr_case(
  id: String,
  timestamp: String,
  embedding: List(Float),
  status: String,
  confidence: Float,
  pitfalls: List(String),
) -> cbr_types.CbrCase {
  cbr_types.CbrCase(
    case_id: id,
    timestamp: timestamp,
    schema_version: 1,
    problem: cbr_types.CbrProblem(
      user_input: "test",
      intent: "research",
      domain: "test",
      entities: [],
      keywords: ["test"],
      query_complexity: "simple",
    ),
    solution: cbr_types.CbrSolution(
      approach: "test",
      agents_used: [],
      tools_used: [],
      steps: [],
    ),
    outcome: cbr_types.CbrOutcome(
      status: status,
      confidence: confidence,
      assessment: "test",
      pitfalls: pitfalls,
    ),
    embedding: embedding,
    source_narrative_id: "n-" <> id,
    profile: option.None,
  )
}

pub fn curator_housekeeping_prunes_old_failures_test() {
  let #(lib, cur) = start_both("hk_prune")

  // Add an old failure case with low confidence and no pitfalls
  let old_failure =
    make_cbr_case("old-fail", "2025-01-01T10:00:00Z", [], "failure", 0.2, [])
  librarian.notify_new_case(lib, old_failure)

  // Add a good case
  let good_case =
    make_cbr_case("good", "2026-03-01T10:00:00Z", [], "success", 0.9, [])
  librarian.notify_new_case(lib, good_case)
  process.sleep(100)

  // Verify both are present
  let before = librarian.load_all_cases(lib)
  list.length(before) |> should.equal(2)

  // Run housekeeping
  curator.run_housekeeping(cur)
  process.sleep(500)

  // Old failure should be pruned
  let after = librarian.load_all_cases(lib)
  list.length(after) |> should.equal(1)
  let assert [remaining] = after
  remaining.case_id |> should.equal("good")

  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}

pub fn curator_housekeeping_deduplicates_similar_cases_test() {
  let #(lib, cur) = start_both("hk_dedup")

  // Add two nearly identical cases with the same embedding
  let case_a =
    make_cbr_case(
      "dup-a",
      "2026-03-01T10:00:00Z",
      [1.0, 0.0, 0.0],
      "success",
      0.9,
      [],
    )
  let case_b =
    make_cbr_case(
      "dup-b",
      "2026-03-02T10:00:00Z",
      [1.0, 0.0, 0.0],
      "success",
      0.9,
      [],
    )
  librarian.notify_new_case(lib, case_a)
  librarian.notify_new_case(lib, case_b)
  process.sleep(100)

  // Both present
  let before = librarian.load_all_cases(lib)
  list.length(before) |> should.equal(2)

  // Run housekeeping
  curator.run_housekeeping(cur)
  process.sleep(500)

  // Should deduplicate — keep newer, remove older
  let after = librarian.load_all_cases(lib)
  list.length(after) |> should.equal(1)
  let assert [kept] = after
  kept.case_id |> should.equal("dup-b")

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
  let lib = librarian.start(dir, cbr_dir, facts_dir, dir <> "/artifacts", 0)
  // Use empty identity dirs to force fallback (no priv/ lookup)
  let assert Ok(cur) =
    curator.start_with_identity(
      lib,
      dir,
      cbr_dir,
      facts_dir,
      [],
      "memory",
      option.None,
      "Springdrift",
      "",
      curator.default_housekeeping_config(),
    )
  let prompt = curator.build_system_prompt(cur, "You are helpful.")
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
  let lib = librarian.start(dir, cbr_dir, facts_dir, dir <> "/artifacts", 0)
  let assert Ok(cur) =
    curator.start_with_identity(
      lib,
      dir,
      cbr_dir,
      facts_dir,
      [identity_dir],
      "memory",
      option.None,
      "Springdrift",
      "",
      curator.default_housekeeping_config(),
    )
  let prompt = curator.build_system_prompt(cur, "fallback")
  should.be_true(string.contains(prompt, "I am Springdrift."))
  should.be_true(!string.contains(prompt, "fallback"))
  process.send(cur, curator.Shutdown)
  process.send(lib, librarian.Shutdown)
}
