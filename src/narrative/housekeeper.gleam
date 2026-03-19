//// Housekeeper — supervised GenServer for periodic ETS/memory maintenance.
////
//// Three tick intervals:
////   - ShortTick (6h default): trim narrative entries outside retention window
////   - MediumTick (12h default): fact conflict resolution + thread pruning
////   - LongTick (24h default): CBR dedup/pruning + DAG trim + artifact trim
////
//// The Housekeeper is non-critical: startup failure is logged and ignored.
//// All decisions are derived from ETS data via the Librarian — no persistent state.

import facts/log as facts_log
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import narrative/housekeeping
import narrative/librarian.{type LibrarianMessage}
import narrative/log as narrative_log
import slog

@external(erlang, "springdrift_ffi", "days_ago_date")
fn days_ago_date(days: Int) -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_timestamp() -> String

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

pub type HousekeeperConfig {
  HousekeeperConfig(
    short_tick_ms: Int,
    medium_tick_ms: Int,
    long_tick_ms: Int,
    narrative_days: Int,
    cbr_days: Int,
    dag_days: Int,
    artifact_days: Int,
    dedup_similarity: Float,
    pruning_confidence: Float,
    fact_confidence: Float,
    cbr_pruning_days: Int,
    thread_pruning_days: Int,
  )
}

pub fn default_config() -> HousekeeperConfig {
  HousekeeperConfig(
    short_tick_ms: 21_600_000,
    medium_tick_ms: 43_200_000,
    long_tick_ms: 86_400_000,
    narrative_days: 90,
    cbr_days: 180,
    dag_days: 30,
    artifact_days: 60,
    dedup_similarity: 0.92,
    pruning_confidence: 0.3,
    fact_confidence: 0.7,
    cbr_pruning_days: 60,
    thread_pruning_days: 7,
  )
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

pub type HousekeeperMessage {
  ShortTick
  MediumTick
  LongTick
  RunAll(reply_to: Subject(HousekeeperReport))
  Shutdown
}

pub type HousekeeperReport {
  HousekeeperReport(
    cases_deduplicated: Int,
    cases_pruned: Int,
    facts_resolved: Int,
    threads_pruned: Int,
    narrative_entries_evicted: Int,
    dag_nodes_evicted: Int,
    artifacts_evicted: Int,
  )
}

pub fn empty_report() -> HousekeeperReport {
  HousekeeperReport(
    cases_deduplicated: 0,
    cases_pruned: 0,
    facts_resolved: 0,
    threads_pruned: 0,
    narrative_entries_evicted: 0,
    dag_nodes_evicted: 0,
    artifacts_evicted: 0,
  )
}

pub fn format_report(report: HousekeeperReport) -> String {
  "Housekeeper: "
  <> int.to_string(report.narrative_entries_evicted)
  <> " narrative evicted, "
  <> int.to_string(report.cases_deduplicated)
  <> " cases deduplicated, "
  <> int.to_string(report.cases_pruned)
  <> " cases pruned, "
  <> int.to_string(report.facts_resolved)
  <> " fact conflicts resolved, "
  <> int.to_string(report.threads_pruned)
  <> " threads pruned, "
  <> int.to_string(report.dag_nodes_evicted)
  <> " DAG nodes evicted, "
  <> int.to_string(report.artifacts_evicted)
  <> " artifacts evicted"
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

type HousekeeperState {
  HousekeeperState(
    self: Subject(HousekeeperMessage),
    librarian: Subject(LibrarianMessage),
    narrative_dir: String,
    facts_dir: String,
    config: HousekeeperConfig,
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the Housekeeper GenServer. Non-critical — returns Error on failure.
pub fn start(
  librarian: Subject(LibrarianMessage),
  narrative_dir: String,
  facts_dir: String,
  config: HousekeeperConfig,
) -> Result(Subject(HousekeeperMessage), Nil) {
  let setup: Subject(Subject(HousekeeperMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(HousekeeperMessage) = process.new_subject()
    process.send(setup, self)

    let state =
      HousekeeperState(self:, librarian:, narrative_dir:, facts_dir:, config:)

    // Schedule initial ticks
    process.send_after(self, config.short_tick_ms, ShortTick)
    process.send_after(self, config.medium_tick_ms, MediumTick)
    process.send_after(self, config.long_tick_ms, LongTick)

    slog.info("narrative/housekeeper", "start", "Housekeeper ready", None)
    loop(state)
  })

  case process.receive(setup, 5000) {
    Ok(subj) -> Ok(subj)
    Error(_) -> {
      slog.log_error(
        "narrative/housekeeper",
        "start",
        "Housekeeper failed to start within 5s",
        None,
      )
      Error(Nil)
    }
  }
}

/// Run all housekeeping passes synchronously. Blocks until complete.
pub fn run_all(housekeeper: Subject(HousekeeperMessage)) -> HousekeeperReport {
  let reply_to = process.new_subject()
  process.send(housekeeper, RunAll(reply_to:))
  case process.receive(reply_to, 60_000) {
    Ok(report) -> report
    Error(_) -> empty_report()
  }
}

// ---------------------------------------------------------------------------
// Message loop
// ---------------------------------------------------------------------------

fn loop(state: HousekeeperState) -> Nil {
  case process.receive(state.self, 120_000) {
    Error(_) -> loop(state)
    Ok(msg) ->
      case msg {
        Shutdown -> {
          slog.info(
            "narrative/housekeeper",
            "shutdown",
            "Housekeeper stopped",
            None,
          )
          Nil
        }

        ShortTick -> {
          let evicted = run_narrative_window(state)
          case evicted > 0 {
            True ->
              slog.info(
                "narrative/housekeeper",
                "short_tick",
                "Trimmed " <> int.to_string(evicted) <> " narrative entries",
                None,
              )
            False -> Nil
          }
          process.send_after(state.self, state.config.short_tick_ms, ShortTick)
          loop(state)
        }

        MediumTick -> {
          let facts_resolved = run_fact_conflicts(state)
          let threads_pruned = run_thread_pruning(state)
          case facts_resolved + threads_pruned > 0 {
            True ->
              slog.info(
                "narrative/housekeeper",
                "medium_tick",
                int.to_string(facts_resolved)
                  <> " fact conflicts, "
                  <> int.to_string(threads_pruned)
                  <> " threads pruned",
                None,
              )
            False -> Nil
          }
          process.send_after(
            state.self,
            state.config.medium_tick_ms,
            MediumTick,
          )
          loop(state)
        }

        LongTick -> {
          let dedup = run_cbr_dedup(state)
          let pruned = run_cbr_pruning(state)
          let dag = run_dag_trim(state)
          let artifacts = run_artifact_trim(state)
          let total = dedup + pruned + dag + artifacts
          case total > 0 {
            True ->
              slog.info(
                "narrative/housekeeper",
                "long_tick",
                int.to_string(dedup)
                  <> " CBR dedup, "
                  <> int.to_string(pruned)
                  <> " CBR pruned, "
                  <> int.to_string(dag)
                  <> " DAG evicted, "
                  <> int.to_string(artifacts)
                  <> " artifacts evicted",
                None,
              )
            False -> Nil
          }
          process.send_after(state.self, state.config.long_tick_ms, LongTick)
          loop(state)
        }

        RunAll(reply_to:) -> {
          let narrative_entries_evicted = run_narrative_window(state)
          let facts_resolved = run_fact_conflicts(state)
          let threads_pruned = run_thread_pruning(state)
          let cases_deduplicated = run_cbr_dedup(state)
          let cases_pruned = run_cbr_pruning(state)
          let dag_nodes_evicted = run_dag_trim(state)
          let artifacts_evicted = run_artifact_trim(state)
          let report =
            HousekeeperReport(
              cases_deduplicated:,
              cases_pruned:,
              facts_resolved:,
              threads_pruned:,
              narrative_entries_evicted:,
              dag_nodes_evicted:,
              artifacts_evicted:,
            )
          slog.info(
            "narrative/housekeeper",
            "run_all",
            format_report(report),
            None,
          )
          process.send(reply_to, report)
          loop(state)
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Pass implementations
// ---------------------------------------------------------------------------

fn run_narrative_window(state: HousekeeperState) -> Int {
  let cutoff = days_ago_date(state.config.narrative_days)
  librarian.trim_narrative_window(state.librarian, cutoff)
}

fn run_fact_conflicts(state: HousekeeperState) -> Int {
  let all_facts = librarian.get_all_facts(state.librarian)
  let conflict_results = housekeeping.find_fact_conflicts(all_facts)
  let count = list.length(conflict_results)
  let timestamp = get_timestamp()
  list.each(conflict_results, fn(c: housekeeping.ConflictResult) {
    let original =
      list.find(all_facts, fn(f) { f.fact_id == c.supersede_fact_id })
    case original {
      Ok(orig) -> {
        let superseded_fact =
          housekeeping.make_superseded_fact(
            orig,
            c.keep_fact_id,
            "housekeeping",
            timestamp,
          )
        facts_log.append(state.facts_dir, superseded_fact)
        librarian.supersede_fact(state.librarian, superseded_fact)
      }
      Error(_) -> Nil
    }
  })
  count
}

fn run_thread_pruning(state: HousekeeperState) -> Int {
  let thread_cutoff = days_ago_date(state.config.thread_pruning_days)
  let thread_index = librarian.load_thread_index(state.librarian)
  let results =
    housekeeping.find_prunable_threads(thread_index.threads, thread_cutoff)
  let count = list.length(results)
  case count > 0 {
    True -> {
      let cleaned = housekeeping.apply_thread_pruning(thread_index, results)
      narrative_log.save_thread_index(state.narrative_dir, cleaned)
      librarian.notify_thread_index(state.librarian, cleaned)
    }
    False -> Nil
  }
  count
}

fn run_cbr_dedup(state: HousekeeperState) -> Int {
  let all_cases = librarian.load_all_cases(state.librarian)
  let results =
    housekeeping.find_duplicate_cases(all_cases, state.config.dedup_similarity)
  let count = list.length(results)
  list.each(results, fn(d: housekeeping.DedupResult) {
    librarian.remove_case(state.librarian, d.supersede_id)
  })
  count
}

fn run_cbr_pruning(state: HousekeeperState) -> Int {
  let cutoff = days_ago_date(state.config.cbr_pruning_days)
  let cases = librarian.load_all_cases(state.librarian)
  let results =
    housekeeping.find_prunable_cases(
      cases,
      cutoff,
      state.config.pruning_confidence,
    )
  let count = list.length(results)
  list.each(results, fn(p: housekeeping.PruneResult) {
    librarian.remove_case(state.librarian, p.case_id)
  })
  count
}

fn run_dag_trim(state: HousekeeperState) -> Int {
  let cutoff = days_ago_date(state.config.dag_days)
  librarian.trim_dag_window(state.librarian, cutoff)
}

fn run_artifact_trim(state: HousekeeperState) -> Int {
  let cutoff = days_ago_date(state.config.artifact_days)
  librarian.trim_artifact_window(state.librarian, cutoff)
}
