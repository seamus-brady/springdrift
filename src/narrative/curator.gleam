//// Curator — supervised actor managing memory housekeeping, virtual context
//// window (Letta layer), and inter-agent context injection.
////
//// The Curator starts after the Librarian and before the cognitive loop. It
//// owns three distinct responsibilities:
////
//// 1. Periodic housekeeping: dedup, pruning, conflict resolution, compaction
//// 2. Virtual context window: managed Letta-style memory slots injected into
////    every LLM request
//// 3. Inter-agent context injection: enriches agent tasks with prior results
////    and intercepts agent results for write-back
////
//// The Curator communicates with the Librarian for ETS queries and scratchpad
//// operations. It does not own any ETS tables itself — the Librarian is the
//// single owner of all memory indexes.

import agent/types as agent_types
import facts/log as facts_log
import facts/types as facts_types
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import identity
import narrative/housekeeping
import narrative/librarian
import narrative/log as narrative_log
import narrative/virtual_memory.{
  type CbrSlotEntry, type VirtualMemory, ScratchEntry,
}
import paths
import scheduler/types as scheduler_types
import slog

// ---------------------------------------------------------------------------
// Housekeeping config
// ---------------------------------------------------------------------------

pub type HousekeepingConfig {
  HousekeepingConfig(
    tick_ms: Int,
    interval_ticks: Int,
    dedup_similarity: Float,
    pruning_confidence: Float,
    fact_confidence: Float,
    cbr_pruning_days: Int,
    thread_pruning_days: Int,
  )
}

pub fn default_housekeeping_config() -> HousekeepingConfig {
  HousekeepingConfig(
    tick_ms: 86_400_000,
    interval_ticks: 60,
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

pub type CuratorMessage {
  /// Inject context into an agent task before dispatch.
  InjectContext(
    task: agent_types.AgentTask,
    reply_to: Subject(agent_types.AgentTask),
  )
  /// Write back an agent result after completion.
  WriteBackResult(cycle_id: String, result: agent_types.AgentResult)
  /// Clear the scratchpad for a completed cycle.
  ClearCycle(cycle_id: String)
  /// Request the current virtual memory context string.
  GetVirtualContext(reply_to: Subject(String))
  /// Set the core identity slot in virtual memory.
  SetCoreIdentity(
    identity: String,
    preferences: List(String),
    instructions: List(String),
  )
  /// Update the active narrative thread slot.
  SetActiveThread(thread_name: String, summary: String, cycle_count: Int)
  /// Add or update a working memory entry.
  UpdateWorkingMemory(key: String, value: String, scope: String)
  /// Remove a working memory entry.
  RemoveWorkingMemory(key: String)
  /// Set CBR cases for the current query.
  SetCbrCases(cases: List(CbrSlotEntry))
  /// Build the system prompt from persona + rendered preamble.
  BuildSystemPrompt(fallback_prompt: String, reply_to: Subject(String))
  /// Trigger a housekeeping pass (manual or timer-driven).
  RunHousekeeping
  /// Update constitution cache (called by Archivist after each cycle).
  UpdateConstitution(
    today_cycles: Int,
    today_success_rate: Float,
    agent_health: String,
  )
  /// Update agent health only (called on lifecycle events).
  UpdateAgentHealth(health: String)
  /// Set the scheduler subject (called after scheduler starts).
  SetScheduler(scheduler: Subject(scheduler_types.SchedulerMessage))
  /// Shutdown the Curator.
  Shutdown
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

type CuratorState {
  CuratorState(
    self: Subject(CuratorMessage),
    librarian: Subject(librarian.LibrarianMessage),
    narrative_dir: String,
    cbr_dir: String,
    facts_dir: String,
    housekeeping_config: HousekeepingConfig,
    housekeeping_ticks: Int,
    vm: VirtualMemory,
    identity_dirs: List(String),
    memory_tag: String,
    active_profile: Option(String),
    agent_name: String,
    agent_version: String,
    scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the Curator actor. Returns a Subject for sending messages.
pub fn start(
  librarian: Subject(librarian.LibrarianMessage),
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
) -> Result(Subject(CuratorMessage), Nil) {
  start_with_identity(
    librarian,
    narrative_dir,
    cbr_dir,
    facts_dir,
    paths.default_identity_dirs(),
    "memory",
    None,
    "Springdrift",
    "",
    default_housekeeping_config(),
  )
}

/// Start the Curator with explicit identity config.
pub fn start_with_identity(
  librarian: Subject(librarian.LibrarianMessage),
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  identity_dirs: List(String),
  memory_tag: String,
  active_profile: Option(String),
  agent_name: String,
  agent_version: String,
  housekeeping_config: HousekeepingConfig,
) -> Result(Subject(CuratorMessage), Nil) {
  let setup: Subject(Subject(CuratorMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(CuratorMessage) = process.new_subject()
    process.send(setup, self)

    let state =
      CuratorState(
        self:,
        librarian:,
        narrative_dir:,
        cbr_dir:,
        facts_dir:,
        housekeeping_config:,
        housekeeping_ticks: 0,
        vm: virtual_memory.empty(),
        identity_dirs:,
        memory_tag:,
        active_profile:,
        agent_name:,
        agent_version:,
        scheduler: None,
      )

    slog.info("narrative/curator", "start", "Curator ready", None)

    loop(state)
  })

  case process.receive(setup, 30_000) {
    Ok(subj) -> Ok(subj)
    Error(_) -> {
      slog.log_error(
        "narrative/curator",
        "start",
        "Curator failed to start within 30s",
        None,
      )
      Error(Nil)
    }
  }
}

/// Inject context into an agent task. Blocks until reply.
pub fn inject_context(
  curator: Subject(CuratorMessage),
  task: agent_types.AgentTask,
) -> agent_types.AgentTask {
  let reply_to = process.new_subject()
  process.send(curator, InjectContext(task:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(enriched) -> enriched
    Error(_) -> task
  }
}

/// Write back an agent result (fire-and-forget).
pub fn write_back_result(
  curator: Subject(CuratorMessage),
  cycle_id: String,
  result: agent_types.AgentResult,
) -> Nil {
  process.send(curator, WriteBackResult(cycle_id:, result:))
}

/// Set the scheduler reference (fire-and-forget).
pub fn set_scheduler(
  curator: Subject(CuratorMessage),
  scheduler: Subject(scheduler_types.SchedulerMessage),
) -> Nil {
  process.send(curator, SetScheduler(scheduler:))
}

/// Clear the scratchpad for a cycle (fire-and-forget).
pub fn clear_cycle(curator: Subject(CuratorMessage), cycle_id: String) -> Nil {
  process.send(curator, ClearCycle(cycle_id:))
}

/// Get the current virtual memory context. Blocks until reply.
pub fn get_virtual_context(curator: Subject(CuratorMessage)) -> String {
  let reply_to = process.new_subject()
  process.send(curator, GetVirtualContext(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(ctx) -> ctx
    Error(_) -> ""
  }
}

/// Set the core identity slot in virtual memory (fire-and-forget).
pub fn set_core_identity(
  curator: Subject(CuratorMessage),
  identity: String,
  preferences: List(String),
  instructions: List(String),
) -> Nil {
  process.send(curator, SetCoreIdentity(identity:, preferences:, instructions:))
}

/// Update the active narrative thread slot (fire-and-forget).
pub fn set_active_thread(
  curator: Subject(CuratorMessage),
  thread_name: String,
  summary: String,
  cycle_count: Int,
) -> Nil {
  process.send(curator, SetActiveThread(thread_name:, summary:, cycle_count:))
}

/// Add or update a working memory entry (fire-and-forget).
pub fn update_working_memory(
  curator: Subject(CuratorMessage),
  key: String,
  value: String,
  scope: String,
) -> Nil {
  process.send(curator, UpdateWorkingMemory(key:, value:, scope:))
}

/// Remove a working memory entry (fire-and-forget).
pub fn remove_working_memory(
  curator: Subject(CuratorMessage),
  key: String,
) -> Nil {
  process.send(curator, RemoveWorkingMemory(key:))
}

/// Set CBR cases for the current query (fire-and-forget).
pub fn set_cbr_cases(
  curator: Subject(CuratorMessage),
  cases: List(CbrSlotEntry),
) -> Nil {
  process.send(curator, SetCbrCases(cases:))
}

/// Build the system prompt from identity files + memory state.
/// Falls back to `fallback_prompt` if no identity files exist.
/// Blocks until reply.
pub fn build_system_prompt(
  curator: Subject(CuratorMessage),
  fallback_prompt: String,
) -> String {
  let reply_to = process.new_subject()
  process.send(curator, BuildSystemPrompt(fallback_prompt:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(prompt) -> prompt
    Error(_) -> fallback_prompt
  }
}

/// Trigger a housekeeping pass (fire-and-forget).
pub fn run_housekeeping(curator: Subject(CuratorMessage)) -> Nil {
  process.send(curator, RunHousekeeping)
}

/// Update constitution cache (fire-and-forget). Called by the Archivist.
pub fn update_constitution(
  curator: Subject(CuratorMessage),
  today_cycles: Int,
  today_success_rate: Float,
  agent_health: String,
) -> Nil {
  process.send(
    curator,
    UpdateConstitution(today_cycles:, today_success_rate:, agent_health:),
  )
}

/// Update agent health only (fire-and-forget). Called on lifecycle events.
pub fn update_agent_health(
  curator: Subject(CuratorMessage),
  health: String,
) -> Nil {
  process.send(curator, UpdateAgentHealth(health:))
}

// ---------------------------------------------------------------------------
// Message loop
// ---------------------------------------------------------------------------

fn loop(state: CuratorState) -> Nil {
  case process.receive(state.self, 60_000) {
    Error(_) -> {
      // Timeout — idle heartbeat; check if housekeeping is due
      let ticks = state.housekeeping_ticks + 1
      case ticks >= state.housekeeping_config.interval_ticks {
        True -> {
          do_housekeeping(state)
          loop(CuratorState(..state, housekeeping_ticks: 0))
        }
        False -> loop(CuratorState(..state, housekeeping_ticks: ticks))
      }
    }
    Ok(msg) ->
      case msg {
        Shutdown -> {
          slog.info("narrative/curator", "shutdown", "Curator stopped", None)
          Nil
        }

        SetScheduler(scheduler:) ->
          loop(CuratorState(..state, scheduler: Some(scheduler)))

        InjectContext(task:, reply_to:) -> {
          let enriched = do_inject_context(state, task)
          process.send(reply_to, enriched)
          loop(state)
        }

        WriteBackResult(cycle_id:, result:) -> {
          do_write_back(state, cycle_id, result)
          // Update agent scratchpad slot in VM
          let scratch_entry =
            ScratchEntry(
              agent_id: result.agent_id,
              summary: truncate(result.final_text, 200),
            )
          let current_entries = state.vm.agent_scratchpad.entries
          let updated_vm =
            virtual_memory.set_scratchpad(
              state.vm,
              list.append(current_entries, [scratch_entry]),
            )
          loop(CuratorState(..state, vm: updated_vm))
        }

        ClearCycle(cycle_id:) -> {
          librarian.clear_cycle_scratchpad(state.librarian, cycle_id)
          // Clear the scratchpad slot in VM
          let updated_vm = virtual_memory.clear_scratchpad(state.vm)
          loop(CuratorState(..state, vm: updated_vm))
        }

        GetVirtualContext(reply_to:) -> {
          process.send(reply_to, virtual_memory.to_system_prompt(state.vm))
          loop(state)
        }

        SetCoreIdentity(identity:, preferences:, instructions:) -> {
          let updated_vm =
            virtual_memory.set_core(
              state.vm,
              identity,
              preferences,
              instructions,
            )
          loop(CuratorState(..state, vm: updated_vm))
        }

        SetActiveThread(thread_name:, summary:, cycle_count:) -> {
          let updated_vm =
            virtual_memory.set_thread(
              state.vm,
              thread_name,
              summary,
              cycle_count,
            )
          loop(CuratorState(..state, vm: updated_vm))
        }

        UpdateWorkingMemory(key:, value:, scope:) -> {
          let updated_vm =
            virtual_memory.add_working_entry(state.vm, key, value, scope)
          loop(CuratorState(..state, vm: updated_vm))
        }

        RemoveWorkingMemory(key:) -> {
          let updated_vm = virtual_memory.remove_working_entry(state.vm, key)
          loop(CuratorState(..state, vm: updated_vm))
        }

        SetCbrCases(cases:) -> {
          let updated_vm = virtual_memory.set_cbr_cases(state.vm, cases)
          loop(CuratorState(..state, vm: updated_vm))
        }

        BuildSystemPrompt(fallback_prompt:, reply_to:) -> {
          let prompt = do_build_system_prompt(state, fallback_prompt)
          process.send(reply_to, prompt)
          loop(state)
        }

        RunHousekeeping -> {
          do_housekeeping(state)
          loop(state)
        }

        UpdateConstitution(today_cycles:, today_success_rate:, agent_health:) -> {
          let slot =
            virtual_memory.ConstitutionSlot(
              today_cycles:,
              today_success_rate:,
              agent_health:,
            )
          let new_vm = virtual_memory.set_constitution(state.vm, slot)
          loop(CuratorState(..state, vm: new_vm))
        }

        UpdateAgentHealth(health:) -> {
          let old = state.vm.constitution
          let slot =
            virtual_memory.ConstitutionSlot(..old, agent_health: health)
          let new_vm = virtual_memory.set_constitution(state.vm, slot)
          loop(CuratorState(..state, vm: new_vm))
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Context injection
// ---------------------------------------------------------------------------

fn do_inject_context(
  state: CuratorState,
  task: agent_types.AgentTask,
) -> agent_types.AgentTask {
  // Read prior agent results for this cycle from the scratchpad
  let prior_results =
    librarian.read_cycle_results(state.librarian, task.parent_cycle_id)

  case prior_results {
    [] -> task
    results -> {
      // Build context summary from prior results
      let context_lines =
        results
        |> format_prior_results()
      let enriched_context =
        task.context
        <> "\n\n<prior_agent_results>\n"
        <> context_lines
        <> "\n</prior_agent_results>"
      agent_types.AgentTask(..task, context: enriched_context)
    }
  }
}

fn format_prior_results(results: List(agent_types.AgentResult)) -> String {
  results
  |> do_format_results("", 1)
}

fn do_format_results(
  results: List(agent_types.AgentResult),
  acc: String,
  n: Int,
) -> String {
  case results {
    [] -> acc
    [r, ..rest] -> {
      let entry =
        "["
        <> int.to_string(n)
        <> "] Agent "
        <> r.agent_id
        <> ": "
        <> truncate(r.final_text, 500)
      let separator = case acc {
        "" -> ""
        _ -> "\n"
      }
      do_format_results(rest, acc <> separator <> entry, n + 1)
    }
  }
}

fn truncate(text: String, max_len: Int) -> String {
  case string.length(text) > max_len {
    True -> string.slice(text, 0, max_len) <> "..."
    False -> text
  }
}

// ---------------------------------------------------------------------------
// Write-back
// ---------------------------------------------------------------------------

fn do_write_back(
  state: CuratorState,
  cycle_id: String,
  result: agent_types.AgentResult,
) -> Nil {
  // Write to scratchpad for subsequent agents in this cycle
  librarian.write_agent_result(state.librarian, cycle_id, result)

  // Extract high-confidence facts from ResearcherFindings
  case result.findings {
    agent_types.ResearcherFindings(facts:, ..) -> {
      write_extracted_facts(state, cycle_id, result.agent_id, facts)
    }
    _ -> Nil
  }
}

fn write_extracted_facts(
  state: CuratorState,
  cycle_id: String,
  agent_id: String,
  facts: List(agent_types.ExtractedFact),
) -> Nil {
  case facts {
    [] -> Nil
    [fact, ..rest] -> {
      case fact.confidence >=. state.housekeeping_config.fact_confidence {
        True -> {
          let memory_fact =
            make_memory_fact(
              cycle_id,
              agent_id,
              fact.label,
              fact.value,
              fact.confidence,
            )
          librarian.notify_new_fact(state.librarian, memory_fact)
        }
        False -> Nil
      }
      write_extracted_facts(state, cycle_id, agent_id, rest)
    }
  }
}

fn make_memory_fact(
  cycle_id: String,
  agent_id: String,
  key: String,
  value: String,
  confidence: Float,
) -> facts_types.MemoryFact {
  facts_types.MemoryFact(
    schema_version: 1,
    fact_id: generate_id(),
    timestamp: get_timestamp(),
    cycle_id:,
    agent_id: Some(agent_id),
    key:,
    value:,
    scope: facts_types.Session,
    operation: facts_types.Write,
    supersedes: None,
    confidence:,
    source: "curator_write",
  )
}

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_id() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_timestamp() -> String

// ---------------------------------------------------------------------------
// Housekeeping — stub for Phase 6
// ---------------------------------------------------------------------------

fn do_housekeeping(state: CuratorState) -> Nil {
  slog.info(
    "narrative/curator",
    "housekeeping",
    "Starting housekeeping pass",
    None,
  )

  // 1. CBR deduplication
  let all_cases = librarian.load_all_cases(state.librarian)
  let dedup_results =
    housekeeping.find_duplicate_cases(
      all_cases,
      state.housekeeping_config.dedup_similarity,
      None,
    )
  let dedup_count = list.length(dedup_results)
  list.each(dedup_results, fn(d: housekeeping.DedupResult) {
    librarian.remove_case(state.librarian, d.supersede_id)
  })

  // 2. CBR pruning
  let cutoff_date = days_ago_date(state.housekeeping_config.cbr_pruning_days)
  let remaining_cases = librarian.load_all_cases(state.librarian)
  let prune_results =
    housekeeping.find_prunable_cases(
      remaining_cases,
      cutoff_date,
      state.housekeeping_config.pruning_confidence,
    )
  let prune_count = list.length(prune_results)
  list.each(prune_results, fn(p: housekeeping.PruneResult) {
    librarian.remove_case(state.librarian, p.case_id)
  })

  // 3. Fact conflict resolution
  let all_facts = librarian.get_all_facts(state.librarian)
  let conflict_results = housekeeping.find_fact_conflicts(all_facts)
  let conflict_count = list.length(conflict_results)
  let timestamp = get_timestamp()
  list.each(conflict_results, fn(c: housekeeping.ConflictResult) {
    // Find the original fact to build the superseded record
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
        // Write to JSONL
        facts_log.append(state.facts_dir, superseded_fact)
        // Update Librarian indices
        librarian.supersede_fact(state.librarian, superseded_fact)
      }
      Error(_) -> Nil
    }
  })

  // 4. Thread pruning — remove single-cycle old threads with no signal
  let thread_cutoff =
    days_ago_date(state.housekeeping_config.thread_pruning_days)
  let thread_index = librarian.load_thread_index(state.librarian)
  let thread_prune_results =
    housekeeping.find_prunable_threads(thread_index.threads, thread_cutoff)
  let thread_prune_count = list.length(thread_prune_results)
  case thread_prune_count > 0 {
    True -> {
      let cleaned_index =
        housekeeping.apply_thread_pruning(thread_index, thread_prune_results)
      narrative_log.save_thread_index(state.narrative_dir, cleaned_index)
      librarian.notify_thread_index(state.librarian, cleaned_index)
    }
    False -> Nil
  }

  let report =
    housekeeping.HousekeepingReport(
      cases_deduplicated: dedup_count,
      cases_pruned: prune_count,
      facts_resolved: conflict_count,
      threads_pruned: thread_prune_count,
    )
  slog.info(
    "narrative/curator",
    "housekeeping",
    housekeeping.format_report(report),
    None,
  )
}

@external(erlang, "springdrift_ffi", "days_ago_date")
fn days_ago_date(days: Int) -> String

fn get_today_date() -> String {
  days_ago_date(0)
}

// ---------------------------------------------------------------------------
// System prompt assembly from identity files
// ---------------------------------------------------------------------------

fn do_build_system_prompt(state: CuratorState, fallback: String) -> String {
  let persona = identity.load_persona(state.identity_dirs)
  let template = identity.load_preamble_template(state.identity_dirs)

  case persona, template {
    None, None -> fallback
    _, _ -> {
      let rendered_preamble = case template {
        None -> None
        Some(tmpl) -> {
          let slots = build_preamble_slots(state)
          let rendered = identity.render_preamble(tmpl, slots)
          case rendered {
            "" -> None
            text -> Some(text)
          }
        }
      }
      case
        identity.assemble_system_prompt(
          persona,
          rendered_preamble,
          state.memory_tag,
        )
      {
        Some(prompt) -> prompt
        None -> fallback
      }
    }
  }
}

fn build_preamble_slots(state: CuratorState) -> List(identity.SlotValue) {
  let today = get_today_date()

  // Query Librarian for counts
  let thread_count = librarian.get_thread_count(state.librarian)
  let fact_count = librarian.get_persistent_fact_count(state.librarian)
  let case_count = librarian.get_case_count(state.librarian)

  // Query thread index and format top 5 threads
  let thread_index = librarian.load_thread_index(state.librarian)
  let active_threads_text =
    thread_index.threads
    |> list.sort(fn(a, b) { string.compare(b.last_cycle_at, a.last_cycle_at) })
    |> list.take(5)
    |> list.map(fn(t) {
      "- "
      <> t.thread_name
      <> " ("
      <> int.to_string(t.cycle_count)
      <> " cycles, last: "
      <> t.last_cycle_at
      <> ")"
    })
    |> string.join("\n")

  // Query persistent facts and format 3 most recent
  let all_facts = librarian.get_all_facts(state.librarian)
  let recent_fact_text =
    all_facts
    |> list.filter(fn(f) { f.scope == facts_types.Persistent })
    |> list.filter(fn(f) { f.operation == facts_types.Write })
    |> list.sort(fn(a, b) { string.compare(b.timestamp, a.timestamp) })
    |> list.take(3)
    |> list.map(fn(f) {
      "- "
      <> f.key
      <> " = "
      <> f.value
      <> " (confidence: "
      <> float.to_string(f.confidence)
      <> ")"
    })
    |> string.join("\n")

  // Query recent narrative entries for context continuity
  let recent_entries = librarian.get_recent(state.librarian, 5)
  let last_session_summary = case recent_entries {
    [entry, ..] -> entry.summary
    _ -> ""
  }
  let recent_narrative_text =
    recent_entries
    |> list.reverse
    |> list.map(fn(e) {
      let time = string.slice(e.timestamp, 11, 5)
      let thread_info = case e.thread {
        Some(t) -> " [" <> t.thread_name <> "]"
        None -> ""
      }
      "- " <> time <> thread_info <> ": " <> string.slice(e.summary, 0, 200)
    })
    |> string.join("\n")

  // Build slot values
  [
    identity.SlotValue(key: "session_status", value: "Active session"),
    identity.SlotValue(key: "last_session_date", value: today),
    identity.SlotValue(key: "last_session_summary", value: last_session_summary),
    identity.SlotValue(
      key: "active_thread_count",
      value: int.to_string(thread_count),
    ),
    identity.SlotValue(key: "active_threads", value: active_threads_text),
    identity.SlotValue(
      key: "persistent_fact_count",
      value: int.to_string(fact_count),
    ),
    identity.SlotValue(key: "recent_fact_sample", value: recent_fact_text),
    identity.SlotValue(key: "cbr_case_count", value: int.to_string(case_count)),
    identity.SlotValue(
      key: "today_cycles",
      value: int.to_string(state.vm.constitution.today_cycles),
    ),
    identity.SlotValue(
      key: "today_success_rate",
      value: float.to_string(state.vm.constitution.today_success_rate),
    ),
    identity.SlotValue(
      key: "agent_health",
      value: case state.vm.constitution.agent_health {
        "All agents nominal" -> ""
        h -> h
      },
    ),
    identity.SlotValue(key: "recent_narrative", value: recent_narrative_text),
    identity.SlotValue(
      key: "open_commitments",
      value: build_open_commitments(state.scheduler),
    ),
    identity.SlotValue(key: "memory_health", value: "Nominal"),
    identity.SlotValue(key: "active_profile", value: case state.active_profile {
      Some(name) -> name
      None -> ""
    }),
    identity.SlotValue(key: "profile_agents", value: ""),
    identity.SlotValue(key: "agent_name", value: state.agent_name),
    identity.SlotValue(key: "agent_version", value: state.agent_version),
  ]
}

fn build_open_commitments(
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
) -> String {
  case scheduler {
    None -> ""
    Some(sched) -> {
      let reply_to = process.new_subject()
      process.send(
        sched,
        scheduler_types.GetJobs(
          query: scheduler_types.JobQuery(
            kinds: [],
            statuses: [scheduler_types.Pending, scheduler_types.Running],
            for_: None,
            overdue_only: False,
            max_results: 10,
          ),
          reply_to:,
        ),
      )
      case process.receive(reply_to, 2000) {
        Error(_) -> ""
        Ok(jobs) ->
          case jobs {
            [] -> ""
            _ ->
              list.map(jobs, fn(j) {
                j.title
                <> " ("
                <> scheduler_types.encode_job_kind(j.kind)
                <> case j.due_at {
                  Some(due) -> ", due " <> due
                  None -> ""
                }
                <> ")"
              })
              |> string.join(", ")
          }
      }
    }
  }
}
