import agent/types.{
  type AgentResult, AgentResult, DiscoveredSource, ExtractedFact,
  GenericFindings, ResearcherFindings,
}
import gleam/erlang/process
import gleam/list
import gleeunit/should
import narrative/librarian
import simplifile

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/librarian_scratchpad_test_" <> suffix
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

fn start_lib(suffix: String) {
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
      0,
      librarian.default_cbr_config(),
    )
  lib
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

pub fn scratchpad_starts_empty_test() {
  let lib = start_lib("sp_empty")
  let results = librarian.read_cycle_results(lib, "cycle-001")
  results |> should.equal([])
  process.send(lib, librarian.Shutdown)
}

pub fn scratchpad_write_and_read_test() {
  let lib = start_lib("sp_write_read")
  let r1 = make_result("agent-1", "cycle-001", "Research done")
  librarian.write_agent_result(lib, "cycle-001", r1)
  process.sleep(50)

  let results = librarian.read_cycle_results(lib, "cycle-001")
  list.length(results) |> should.equal(1)
  let assert [r] = results
  r.final_text |> should.equal("Research done")
  r.agent_id |> should.equal("agent-1")

  process.send(lib, librarian.Shutdown)
}

pub fn scratchpad_multiple_results_same_cycle_test() {
  let lib = start_lib("sp_multi")
  let r1 = make_result("researcher-1", "cycle-001", "Found sources")
  let r2 = make_result("planner-1", "cycle-001", "Plan created")
  librarian.write_agent_result(lib, "cycle-001", r1)
  librarian.write_agent_result(lib, "cycle-001", r2)
  process.sleep(50)

  let results = librarian.read_cycle_results(lib, "cycle-001")
  list.length(results) |> should.equal(2)

  process.send(lib, librarian.Shutdown)
}

pub fn scratchpad_different_cycles_isolated_test() {
  let lib = start_lib("sp_isolated")
  let r1 = make_result("agent-1", "cycle-001", "Cycle 1 result")
  let r2 = make_result("agent-2", "cycle-002", "Cycle 2 result")
  librarian.write_agent_result(lib, "cycle-001", r1)
  librarian.write_agent_result(lib, "cycle-002", r2)
  process.sleep(50)

  let c1 = librarian.read_cycle_results(lib, "cycle-001")
  list.length(c1) |> should.equal(1)
  let assert [res1] = c1
  res1.final_text |> should.equal("Cycle 1 result")

  let c2 = librarian.read_cycle_results(lib, "cycle-002")
  list.length(c2) |> should.equal(1)
  let assert [res2] = c2
  res2.final_text |> should.equal("Cycle 2 result")

  process.send(lib, librarian.Shutdown)
}

pub fn scratchpad_clear_removes_cycle_test() {
  let lib = start_lib("sp_clear")
  let r1 = make_result("agent-1", "cycle-001", "Result 1")
  let r2 = make_result("agent-2", "cycle-001", "Result 2")
  librarian.write_agent_result(lib, "cycle-001", r1)
  librarian.write_agent_result(lib, "cycle-001", r2)
  process.sleep(50)

  // Verify they exist
  let before = librarian.read_cycle_results(lib, "cycle-001")
  list.length(before) |> should.equal(2)

  // Clear
  librarian.clear_cycle_scratchpad(lib, "cycle-001")
  process.sleep(50)

  // Verify empty
  let after = librarian.read_cycle_results(lib, "cycle-001")
  after |> should.equal([])

  process.send(lib, librarian.Shutdown)
}

pub fn scratchpad_clear_only_affects_target_cycle_test() {
  let lib = start_lib("sp_clear_target")
  let r1 = make_result("agent-1", "cycle-001", "Cycle 1")
  let r2 = make_result("agent-2", "cycle-002", "Cycle 2")
  librarian.write_agent_result(lib, "cycle-001", r1)
  librarian.write_agent_result(lib, "cycle-002", r2)
  process.sleep(50)

  // Clear only cycle-001
  librarian.clear_cycle_scratchpad(lib, "cycle-001")
  process.sleep(50)

  let c1 = librarian.read_cycle_results(lib, "cycle-001")
  c1 |> should.equal([])

  let c2 = librarian.read_cycle_results(lib, "cycle-002")
  list.length(c2) |> should.equal(1)

  process.send(lib, librarian.Shutdown)
}

pub fn scratchpad_with_researcher_findings_test() {
  let lib = start_lib("sp_researcher")
  let result =
    AgentResult(
      final_text: "Found 2 sources",
      agent_id: "researcher-1",
      cycle_id: "cycle-001",
      findings: ResearcherFindings(
        sources: [
          DiscoveredSource(
            url: "https://example.com",
            title: "Example",
            relevance: 0.9,
          ),
        ],
        facts: [
          ExtractedFact(label: "rent", value: "€2,340", confidence: 0.85),
        ],
        data_points: [],
        dead_ends: ["failed query"],
      ),
    )
  librarian.write_agent_result(lib, "cycle-001", result)
  process.sleep(50)

  let results = librarian.read_cycle_results(lib, "cycle-001")
  list.length(results) |> should.equal(1)
  let assert [r] = results
  case r.findings {
    ResearcherFindings(sources:, facts:, dead_ends:, ..) -> {
      list.length(sources) |> should.equal(1)
      list.length(facts) |> should.equal(1)
      dead_ends |> should.equal(["failed query"])
    }
    _ -> should.fail()
  }

  process.send(lib, librarian.Shutdown)
}
