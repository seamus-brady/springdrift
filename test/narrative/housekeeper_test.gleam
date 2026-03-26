import gleam/erlang/process
import gleam/option
import gleam/string
import gleeunit/should
import narrative/housekeeper
import narrative/librarian
import narrative/types.{
  type NarrativeEntry, Conversation, Entities, Intent, Metrics, Narrative,
  NarrativeEntry, Outcome, Success,
}
import simplifile

fn setup_dirs() -> #(String, String, String, String) {
  let id = generate_uuid()
  let base = "/tmp/springdrift_housekeeper_test/" <> id
  let narrative_dir = base <> "/narrative"
  let cbr_dir = base <> "/cbr"
  let facts_dir = base <> "/facts"
  let artifacts_dir = base <> "/artifacts"
  let _ = simplifile.create_directory_all(narrative_dir)
  let _ = simplifile.create_directory_all(cbr_dir)
  let _ = simplifile.create_directory_all(facts_dir)
  let _ = simplifile.create_directory_all(artifacts_dir)
  #(narrative_dir, cbr_dir, facts_dir, artifacts_dir)
}

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

fn make_entry(cycle_id: String, timestamp: String) -> NarrativeEntry {
  NarrativeEntry(
    schema_version: 1,
    cycle_id: cycle_id,
    parent_cycle_id: option.None,
    timestamp: timestamp,
    entry_type: Narrative,
    summary: "Test entry " <> cycle_id,
    intent: Intent(classification: Conversation, description: "", domain: ""),
    outcome: Outcome(status: Success, confidence: 0.8, assessment: "ok"),
    delegation_chain: [],
    decisions: [],
    keywords: ["test"],
    topics: [],
    entities: Entities(
      locations: [],
      organisations: [],
      data_points: [],
      temporal_references: [],
    ),
    sources: [],
    thread: option.None,
    metrics: Metrics(
      total_duration_ms: 0,
      input_tokens: 0,
      output_tokens: 0,
      thinking_tokens: 0,
      tool_calls: 0,
      agent_delegations: 0,
      dprime_evaluations: 0,
      model_used: "test",
    ),
    observations: [],
    redacted: False,
  )
}

fn start_librarian(
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  artifacts_dir: String,
) -> process.Subject(librarian.LibrarianMessage) {
  librarian.start(
    narrative_dir,
    cbr_dir,
    facts_dir,
    artifacts_dir,
    narrative_dir <> "/planner",
    0,
    librarian.default_cbr_config(),
  )
}

pub fn housekeeper_starts_and_stops_test() {
  let #(narrative_dir, cbr_dir, facts_dir, artifacts_dir) = setup_dirs()
  let lib = start_librarian(narrative_dir, cbr_dir, facts_dir, artifacts_dir)
  let config =
    housekeeper.HousekeeperConfig(
      ..housekeeper.default_config(),
      short_tick_ms: 999_999_999,
      medium_tick_ms: 999_999_999,
      long_tick_ms: 999_999_999,
    )
  case housekeeper.start(lib, narrative_dir, facts_dir, config) {
    Ok(subj) -> {
      process.send(subj, housekeeper.Shutdown)
      process.sleep(100)
      should.be_true(True)
    }
    Error(_) -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn housekeeper_run_all_returns_empty_report_test() {
  let #(narrative_dir, cbr_dir, facts_dir, artifacts_dir) = setup_dirs()
  let lib = start_librarian(narrative_dir, cbr_dir, facts_dir, artifacts_dir)
  let config =
    housekeeper.HousekeeperConfig(
      ..housekeeper.default_config(),
      short_tick_ms: 999_999_999,
      medium_tick_ms: 999_999_999,
      long_tick_ms: 999_999_999,
    )
  case housekeeper.start(lib, narrative_dir, facts_dir, config) {
    Ok(subj) -> {
      let report = housekeeper.run_all(subj)
      should.equal(report.narrative_entries_evicted, 0)
      should.equal(report.cases_deduplicated, 0)
      should.equal(report.cases_pruned, 0)
      should.equal(report.facts_resolved, 0)
      should.equal(report.threads_pruned, 0)
      should.equal(report.dag_nodes_evicted, 0)
      should.equal(report.artifacts_evicted, 0)
      process.send(subj, housekeeper.Shutdown)
    }
    Error(_) -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn housekeeper_trims_old_narrative_entries_test() {
  let #(narrative_dir, cbr_dir, facts_dir, artifacts_dir) = setup_dirs()
  let lib = start_librarian(narrative_dir, cbr_dir, facts_dir, artifacts_dir)
  // Add an old entry (200 days ago)
  let old_entry = make_entry("old-cycle", "2025-01-01T10:00:00")
  process.send(lib, librarian.IndexEntry(entry: old_entry))
  // Add a recent entry
  let new_entry = make_entry("new-cycle", "2026-03-18T10:00:00")
  process.send(lib, librarian.IndexEntry(entry: new_entry))
  process.sleep(100)
  let config =
    housekeeper.HousekeeperConfig(
      ..housekeeper.default_config(),
      narrative_days: 90,
      short_tick_ms: 999_999_999,
      medium_tick_ms: 999_999_999,
      long_tick_ms: 999_999_999,
    )
  case housekeeper.start(lib, narrative_dir, facts_dir, config) {
    Ok(subj) -> {
      let report = housekeeper.run_all(subj)
      should.equal(report.narrative_entries_evicted, 1)
      process.send(subj, housekeeper.Shutdown)
    }
    Error(_) -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn housekeeper_default_config_test() {
  let config = housekeeper.default_config()
  should.equal(config.short_tick_ms, 21_600_000)
  should.equal(config.medium_tick_ms, 43_200_000)
  should.equal(config.long_tick_ms, 86_400_000)
  should.equal(config.narrative_days, 90)
  should.equal(config.dag_days, 30)
  should.equal(config.artifact_days, 60)
}

pub fn housekeeper_format_report_test() {
  let report =
    housekeeper.HousekeeperReport(
      cases_deduplicated: 2,
      cases_pruned: 1,
      facts_resolved: 3,
      threads_pruned: 0,
      narrative_entries_evicted: 5,
      dag_nodes_evicted: 10,
      artifacts_evicted: 4,
    )
  let formatted = housekeeper.format_report(report)
  should.be_true(string.contains(formatted, "5 narrative evicted"))
  should.be_true(string.contains(formatted, "2 cases deduplicated"))
  should.be_true(string.contains(formatted, "10 DAG nodes evicted"))
}

pub fn housekeeper_empty_report_test() {
  let report = housekeeper.empty_report()
  should.equal(report.cases_deduplicated, 0)
  should.equal(report.narrative_entries_evicted, 0)
  should.equal(report.dag_nodes_evicted, 0)
  should.equal(report.artifacts_evicted, 0)
}

pub fn housekeeper_default_config_has_budget_debounce_test() {
  let config = housekeeper.default_config()
  should.equal(config.budget_dedup_debounce_ms, 1_800_000)
}

pub fn housekeeper_budget_triggered_dedup_accepted_test() {
  // BudgetTriggeredDedup should be handled without crashing
  let #(narrative_dir, cbr_dir, facts_dir, artifacts_dir) = setup_dirs()
  let lib = start_librarian(narrative_dir, cbr_dir, facts_dir, artifacts_dir)
  let config =
    housekeeper.HousekeeperConfig(
      ..housekeeper.default_config(),
      short_tick_ms: 999_999_999,
      medium_tick_ms: 999_999_999,
      long_tick_ms: 999_999_999,
      // Set debounce to 0 so the message is always accepted
      budget_dedup_debounce_ms: 0,
    )
  case housekeeper.start(lib, narrative_dir, facts_dir, config) {
    Ok(subj) -> {
      // Send BudgetTriggeredDedup — should not crash
      process.send(subj, housekeeper.BudgetTriggeredDedup)
      // Give it time to process
      process.sleep(100)
      // Verify still alive by sending RunAll
      let report = housekeeper.run_all(subj)
      should.equal(report.cases_deduplicated, 0)
      process.send(subj, housekeeper.Shutdown)
    }
    Error(_) -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}

pub fn housekeeper_budget_triggered_dedup_debounced_test() {
  // Two rapid BudgetTriggeredDedup messages — second should be debounced
  let #(narrative_dir, cbr_dir, facts_dir, artifacts_dir) = setup_dirs()
  let lib = start_librarian(narrative_dir, cbr_dir, facts_dir, artifacts_dir)
  let config =
    housekeeper.HousekeeperConfig(
      ..housekeeper.default_config(),
      short_tick_ms: 999_999_999,
      medium_tick_ms: 999_999_999,
      long_tick_ms: 999_999_999,
      // 10 second debounce — second message will be within debounce
      budget_dedup_debounce_ms: 10_000,
    )
  case housekeeper.start(lib, narrative_dir, facts_dir, config) {
    Ok(subj) -> {
      // Send first BudgetTriggeredDedup (accepted — last_budget_dedup_ms is 0)
      process.send(subj, housekeeper.BudgetTriggeredDedup)
      process.sleep(50)
      // Send second (should be debounced since <10s have passed)
      process.send(subj, housekeeper.BudgetTriggeredDedup)
      process.sleep(50)
      // Verify still alive
      let report = housekeeper.run_all(subj)
      should.equal(report.cases_deduplicated, 0)
      process.send(subj, housekeeper.Shutdown)
    }
    Error(_) -> should.fail()
  }
  process.send(lib, librarian.Shutdown)
}
