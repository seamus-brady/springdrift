import agent/types.{
  AgentDataPoint, AgentResult, CoderFindings, DiscoveredSource, ExtractedFact,
  GenericFindings, PlannerFindings, ResearcherFindings, WriterFindings,
}
import gleeunit/should

// ---------------------------------------------------------------------------
// AgentResult construction tests
// ---------------------------------------------------------------------------

pub fn agent_result_with_researcher_findings_test() {
  let result =
    AgentResult(
      final_text: "Found 3 sources about Dublin rent",
      agent_id: "researcher-001",
      cycle_id: "cycle-abc",
      findings: ResearcherFindings(
        sources: [
          DiscoveredSource(
            url: "https://example.com/rent",
            title: "Dublin Rent Report",
            relevance: 0.95,
          ),
        ],
        facts: [
          ExtractedFact(label: "avg_rent", value: "€2,340", confidence: 0.9),
        ],
        data_points: [
          AgentDataPoint(label: "median_rent", value: "2200", unit: "EUR"),
        ],
        dead_ends: ["daft.ie api"],
      ),
    )
  result.final_text |> should.equal("Found 3 sources about Dublin rent")
  result.agent_id |> should.equal("researcher-001")
  result.cycle_id |> should.equal("cycle-abc")
  case result.findings {
    ResearcherFindings(sources:, facts:, data_points:, dead_ends:) -> {
      should.equal(1, list_length(sources))
      should.equal(1, list_length(facts))
      should.equal(1, list_length(data_points))
      should.equal(["daft.ie api"], dead_ends)
    }
    _ -> should.fail()
  }
}

pub fn agent_result_with_planner_findings_test() {
  let result =
    AgentResult(
      final_text: "Plan created",
      agent_id: "planner-001",
      cycle_id: "cycle-def",
      findings: PlannerFindings(
        plan_steps: ["Step 1", "Step 2", "Step 3"],
        dependencies: [#("Step 2", "Step 1"), #("Step 3", "Step 2")],
        complexity: "moderate",
        risks: ["API rate limits"],
      ),
    )
  case result.findings {
    PlannerFindings(plan_steps:, dependencies:, complexity:, risks:) -> {
      should.equal(3, list_length(plan_steps))
      should.equal(2, list_length(dependencies))
      complexity |> should.equal("moderate")
      should.equal(["API rate limits"], risks)
    }
    _ -> should.fail()
  }
}

pub fn agent_result_with_coder_findings_test() {
  let result =
    AgentResult(
      final_text: "Code written",
      agent_id: "coder-001",
      cycle_id: "cycle-ghi",
      findings: CoderFindings(
        files_touched: ["src/foo.gleam", "test/foo_test.gleam"],
        patterns_used: ["gen_server", "ETS bag"],
        errors_fixed: ["type mismatch on line 42"],
        libraries: ["gleam_json"],
      ),
    )
  case result.findings {
    CoderFindings(files_touched:, patterns_used:, errors_fixed:, libraries:) -> {
      should.equal(2, list_length(files_touched))
      should.equal(2, list_length(patterns_used))
      should.equal(1, list_length(errors_fixed))
      should.equal(["gleam_json"], libraries)
    }
    _ -> should.fail()
  }
}

pub fn agent_result_with_writer_findings_test() {
  let result =
    AgentResult(
      final_text: "Report written",
      agent_id: "writer-001",
      cycle_id: "cycle-jkl",
      findings: WriterFindings(word_count: 1500, format: "markdown", sections: [
        "Introduction",
        "Analysis",
        "Conclusion",
      ]),
    )
  case result.findings {
    WriterFindings(word_count:, format:, sections:) -> {
      word_count |> should.equal(1500)
      format |> should.equal("markdown")
      should.equal(3, list_length(sections))
    }
    _ -> should.fail()
  }
}

pub fn agent_result_with_generic_findings_test() {
  let result =
    AgentResult(
      final_text: "Done",
      agent_id: "agent-001",
      cycle_id: "cycle-mno",
      findings: GenericFindings(notes: ["Completed successfully"]),
    )
  case result.findings {
    GenericFindings(notes:) -> {
      should.equal(["Completed successfully"], notes)
    }
    _ -> should.fail()
  }
}

pub fn discovered_source_test() {
  let src =
    DiscoveredSource(
      url: "https://example.com",
      title: "Example",
      relevance: 0.85,
    )
  src.url |> should.equal("https://example.com")
  src.title |> should.equal("Example")
  src.relevance |> should.equal(0.85)
}

pub fn extracted_fact_test() {
  let fact = ExtractedFact(label: "population", value: "1.4M", confidence: 0.92)
  fact.label |> should.equal("population")
  fact.value |> should.equal("1.4M")
  fact.confidence |> should.equal(0.92)
}

pub fn agent_data_point_test() {
  let dp = AgentDataPoint(label: "rent", value: "2340", unit: "EUR")
  dp.label |> should.equal("rent")
  dp.value |> should.equal("2340")
  dp.unit |> should.equal("EUR")
}

// Helper — Gleam doesn't have a generic list.length in scope here
fn list_length(l: List(a)) -> Int {
  case l {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}
