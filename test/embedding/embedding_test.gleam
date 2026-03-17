// Embedding tests — replaced with paperwings bridge tests.
// The old Ollama embedding client tests are no longer applicable.

import cbr/bridge
import cbr/types.{type CbrCase, CbrCase, CbrOutcome, CbrProblem, CbrSolution}
import gleam/option.{None}
import gleeunit/should

fn make_test_case(id: String, intent: String, domain: String) -> CbrCase {
  CbrCase(
    case_id: id,
    timestamp: "2026-03-17T10:00:00",
    schema_version: 1,
    problem: CbrProblem(
      user_input: "test query",
      intent:,
      domain:,
      entities: [],
      keywords: ["test"],
      query_complexity: "simple",
    ),
    solution: CbrSolution(
      approach: "direct",
      agents_used: [],
      tools_used: [],
      steps: [],
    ),
    outcome: CbrOutcome(
      status: "success",
      confidence: 0.8,
      assessment: "ok",
      pitfalls: [],
    ),
    source_narrative_id: "cycle-001",
    profile: None,
  )
}

pub fn bridge_new_creates_empty_casebase_test() {
  let base = bridge.new("/tmp/bridge_test_new", 1000)
  bridge.case_count(base) |> should.equal(0)
  bridge.destroy(base)
}

pub fn bridge_retain_increases_count_test() {
  let base =
    bridge.new("/tmp/bridge_test_retain", 1000)
    |> bridge.ensure_roles
  let c = make_test_case("case-001", "research", "property")
  let base = bridge.retain_case(base, c)
  bridge.case_count(base) |> should.equal(1)
  bridge.destroy(base)
}

pub fn bridge_remove_decreases_count_test() {
  let base =
    bridge.new("/tmp/bridge_test_remove", 1000)
    |> bridge.ensure_roles
  let c = make_test_case("case-rm1", "research", "property")
  let base = bridge.retain_case(base, c)
  bridge.case_count(base) |> should.equal(1)
  let base = bridge.remove_case(base, "case-rm1")
  bridge.case_count(base) |> should.equal(0)
  bridge.destroy(base)
}
