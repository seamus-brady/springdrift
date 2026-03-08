import cbr/log as cbr_log
import cbr/types.{type CbrCase, CbrCase, CbrOutcome, CbrProblem, CbrSolution}
import gleam/json
import gleam/list
import gleeunit/should
import simplifile

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/cbr_log_test_" <> suffix
  let _ = simplifile.create_directory_all(dir)
  // Clean any existing files
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

fn make_case(case_id: String, intent: String, domain: String) -> CbrCase {
  CbrCase(
    case_id:,
    timestamp: "2026-03-08T10:00:00",
    schema_version: 1,
    problem: CbrProblem(
      user_input: "test query",
      intent:,
      domain:,
      entities: ["Dublin"],
      keywords: ["property", "market"],
      query_complexity: "simple",
    ),
    solution: CbrSolution(
      approach: "direct lookup",
      agents_used: ["researcher"],
      tools_used: ["web_search"],
      steps: ["search", "summarize"],
    ),
    outcome: CbrOutcome(
      status: "success",
      confidence: 0.9,
      assessment: "Good result",
      pitfalls: ["stale data"],
    ),
    embedding: [],
    source_narrative_id: "cycle-001",
  )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn encode_decode_roundtrip_test() {
  let c = make_case("case-rt1", "research", "property")
  let encoded = json.to_string(cbr_log.encode_case(c))
  let assert Ok(decoded) = json.parse(encoded, cbr_log.case_decoder())
  decoded.case_id |> should.equal("case-rt1")
  decoded.problem.intent |> should.equal("research")
  decoded.problem.domain |> should.equal("property")
  decoded.problem.entities |> should.equal(["Dublin"])
  decoded.problem.keywords |> should.equal(["property", "market"])
  decoded.solution.approach |> should.equal("direct lookup")
  decoded.solution.agents_used |> should.equal(["researcher"])
  decoded.outcome.status |> should.equal("success")
  decoded.outcome.confidence |> should.equal(0.9)
  decoded.outcome.pitfalls |> should.equal(["stale data"])
  decoded.source_narrative_id |> should.equal("cycle-001")
}

pub fn load_date_empty_dir_test() {
  let dir = test_dir("empty")
  let cases = cbr_log.load_date(dir, "2026-03-08")
  cases |> should.equal([])
}

pub fn load_all_empty_dir_test() {
  let dir = test_dir("all_empty")
  let cases = cbr_log.load_all(dir)
  cases |> should.equal([])
}

pub fn load_all_nonexistent_dir_test() {
  let cases = cbr_log.load_all("/tmp/cbr_nonexistent_xyz")
  cases |> should.equal([])
}

pub fn write_and_load_test() {
  let dir = test_dir("write_load")
  let c1 = make_case("case-wl1", "research", "property")
  let c2 = make_case("case-wl2", "analysis", "finance")

  // Write cases directly to a known date file
  let json1 = json.to_string(cbr_log.encode_case(c1))
  let json2 = json.to_string(cbr_log.encode_case(c2))
  let _ =
    simplifile.write(dir <> "/2026-03-08.jsonl", json1 <> "\n" <> json2 <> "\n")

  let cases = cbr_log.load_date(dir, "2026-03-08")
  list.length(cases) |> should.equal(2)
  let assert [first, second] = cases
  first.case_id |> should.equal("case-wl1")
  second.case_id |> should.equal("case-wl2")
}

pub fn load_all_multiple_files_test() {
  let dir = test_dir("multi")
  let c1 = make_case("case-m1", "research", "property")
  let c2 = make_case("case-m2", "analysis", "finance")

  let json1 = json.to_string(cbr_log.encode_case(c1))
  let json2 = json.to_string(cbr_log.encode_case(c2))
  let _ = simplifile.write(dir <> "/2026-03-07.jsonl", json1 <> "\n")
  let _ = simplifile.write(dir <> "/2026-03-08.jsonl", json2 <> "\n")

  let cases = cbr_log.load_all(dir)
  list.length(cases) |> should.equal(2)
  // Sorted by date — 03-07 first
  let assert [first, second] = cases
  first.case_id |> should.equal("case-m1")
  second.case_id |> should.equal("case-m2")
}

pub fn malformed_line_skipped_test() {
  let dir = test_dir("malformed")
  let c = make_case("case-ok", "research", "property")
  let good = json.to_string(cbr_log.encode_case(c))
  let content = "not valid json\n" <> good <> "\n{\"bad\": true}\n"
  let _ = simplifile.write(dir <> "/2026-03-08.jsonl", content)

  let cases = cbr_log.load_date(dir, "2026-03-08")
  list.length(cases) |> should.equal(1)
  let assert [parsed] = cases
  parsed.case_id |> should.equal("case-ok")
}

pub fn lenient_decoder_null_optional_fields_test() {
  // JSON with optional fields set to null — decoder should use defaults
  let with_nulls =
    "{\"case_id\":\"case-min\",\"timestamp\":\"2026-03-08T10:00:00\","
    <> "\"schema_version\":null,\"embedding\":null,\"source_narrative_id\":null,"
    <> "\"problem\":{\"user_input\":null,\"intent\":null,\"domain\":null,\"entities\":null,\"keywords\":null,\"query_complexity\":null},"
    <> "\"solution\":{\"approach\":null,\"agents_used\":null,\"tools_used\":null,\"steps\":null},"
    <> "\"outcome\":{\"status\":null,\"confidence\":null,\"assessment\":null,\"pitfalls\":null}}"
  let assert Ok(decoded) = json.parse(with_nulls, cbr_log.case_decoder())
  decoded.case_id |> should.equal("case-min")
  decoded.schema_version |> should.equal(1)
  decoded.embedding |> should.equal([])
  decoded.source_narrative_id |> should.equal("")
  decoded.problem.user_input |> should.equal("")
  decoded.problem.intent |> should.equal("")
  decoded.problem.keywords |> should.equal([])
  decoded.solution.approach |> should.equal("")
  decoded.solution.agents_used |> should.equal([])
  decoded.outcome.status |> should.equal("success")
  decoded.outcome.confidence |> should.equal(0.0)
  decoded.outcome.pitfalls |> should.equal([])
}
