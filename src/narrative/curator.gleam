//// Curator — supervised actor managing virtual context window (Letta layer)
//// and inter-agent context injection.
////
//// The Curator starts after the Librarian and before the cognitive loop. It
//// owns two distinct responsibilities:
////
//// 1. Virtual context window: managed Letta-style memory slots injected into
////    every LLM request
//// 2. Inter-agent context injection: enriches agent tasks with prior results
////    and intercepts agent results for write-back
////
//// The Curator communicates with the Librarian for ETS queries and scratchpad
//// operations. It does not own any ETS tables itself — the Librarian is the
//// single owner of all memory indexes.

import agent/types as agent_types
import facts/types as facts_types
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import identity
import narrative/librarian
import narrative/types as narrative_types
import narrative/virtual_memory.{
  type CbrSlotEntry, type VirtualMemory, ScratchEntry,
}
import paths
import planner/types as planner_types
import scheduler/types as scheduler_types
import slog

// ---------------------------------------------------------------------------
// Cycle context — ephemeral per-call data from the cognitive loop
// ---------------------------------------------------------------------------

/// Ephemeral context from the cognitive loop, passed with each
/// BuildSystemPrompt call. Carries data the Curator can't derive itself.
pub type CycleContext {
  CycleContext(
    /// "user" or "scheduler"
    input_source: String,
    /// Number of inputs waiting after this one
    queue_depth: Int,
    /// ISO timestamp of when the session started
    session_since: String,
    /// Count of agents with Running status in the registry
    agents_active: Int,
    /// Total messages in conversation history (conversation depth signal)
    message_count: Int,
    /// Sensory events accumulated since last cycle
    sensory_events: List(agent_types.SensoryEvent),
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
  BuildSystemPrompt(
    fallback_prompt: String,
    context: Option(CycleContext),
    reply_to: Subject(String),
  )
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
  /// Set the preamble budget in chars (called after Curator starts).
  SetPreambleBudget(chars: Int)
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
    fact_confidence: Float,
    vm: VirtualMemory,
    identity_dirs: List(String),
    memory_tag: String,
    active_profile: Option(String),
    agent_name: String,
    agent_version: String,
    scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
    preamble_budget_chars: Int,
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
        fact_confidence: 0.7,
        vm: virtual_memory.empty(),
        identity_dirs:,
        memory_tag:,
        active_profile:,
        agent_name:,
        agent_version:,
        scheduler: None,
        preamble_budget_chars: 8000,
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
  context: Option(CycleContext),
) -> String {
  let reply_to = process.new_subject()
  process.send(
    curator,
    BuildSystemPrompt(fallback_prompt:, context:, reply_to:),
  )
  case process.receive(reply_to, 5000) {
    Ok(prompt) -> prompt
    Error(_) -> fallback_prompt
  }
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

/// Set the preamble budget in chars (fire-and-forget).
pub fn set_preamble_budget(curator: Subject(CuratorMessage), chars: Int) -> Nil {
  process.send(curator, SetPreambleBudget(chars:))
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
      loop(state)
    }
    Ok(msg) ->
      case msg {
        Shutdown -> {
          slog.info("narrative/curator", "shutdown", "Curator stopped", None)
          Nil
        }

        SetScheduler(scheduler:) ->
          loop(CuratorState(..state, scheduler: Some(scheduler)))

        SetPreambleBudget(chars:) ->
          loop(CuratorState(..state, preamble_budget_chars: chars))

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

        BuildSystemPrompt(fallback_prompt:, context:, reply_to:) -> {
          let prompt = do_build_system_prompt(state, fallback_prompt, context)
          process.send(reply_to, prompt)
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
      case fact.confidence >=. state.fact_confidence {
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

/// Milliseconds from now until an ISO 8601 datetime (negative if in the past).
@external(erlang, "springdrift_ffi", "ms_until_datetime")
fn ms_until_datetime(iso: String) -> Int

/// Format elapsed time since an ISO 8601 timestamp as a human-readable string.
fn format_elapsed_since(iso_timestamp: String) -> String {
  // ms_until_datetime returns negative for past timestamps
  let elapsed_ms = 0 - ms_until_datetime(iso_timestamp)
  case elapsed_ms {
    ms if ms < 0 -> "just now"
    ms if ms < 60_000 -> int.to_string(ms / 1000) <> "s ago"
    ms if ms < 3_600_000 -> int.to_string(ms / 60_000) <> "m ago"
    ms if ms < 86_400_000 -> {
      let hours = ms / 3_600_000
      let mins = { ms - hours * 3_600_000 } / 60_000
      int.to_string(hours) <> "h " <> int.to_string(mins) <> "m ago"
    }
    ms -> {
      let days = ms / 86_400_000
      int.to_string(days) <> "d ago"
    }
  }
}

// ---------------------------------------------------------------------------
// System prompt assembly from identity files
// ---------------------------------------------------------------------------

fn do_build_system_prompt(
  state: CuratorState,
  fallback: String,
  context: Option(CycleContext),
) -> String {
  let persona = identity.load_persona(state.identity_dirs)
  let template = identity.load_preamble_template(state.identity_dirs)

  case persona, template {
    None, None -> fallback
    _, _ -> {
      let rendered_preamble = case template {
        None -> None
        Some(tmpl) -> {
          let slots = build_preamble_slots(state, context)
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

fn build_preamble_slots(
  state: CuratorState,
  context: Option(CycleContext),
) -> List(identity.SlotValue) {
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

  // Assemble sensorium — self-describing XML perceptual input block
  let sensorium = build_sensorium(state, context, recent_entries)

  // Build slot values — session_status, last_session_date, today_cycles,
  // today_success_rate, and agent_health are now inside the sensorium XML.
  let slots = [
    identity.SlotValue(key: "sensorium", value: sensorium),
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
    identity.SlotValue(key: "recent_narrative", value: recent_narrative_text),
    identity.SlotValue(key: "memory_health", value: ""),
    identity.SlotValue(key: "active_profile", value: case state.active_profile {
      Some(name) -> name
      None -> ""
    }),
    identity.SlotValue(key: "profile_agents", value: ""),
    identity.SlotValue(key: "agent_name", value: state.agent_name),
    identity.SlotValue(key: "agent_version", value: state.agent_version),
  ]
  apply_preamble_budget(slots, state.preamble_budget_chars)
}

/// Apply a character budget to preamble slots. Slots are prioritized
/// (lower number = higher priority). When the budget is exceeded,
/// remaining lower-priority slots are cleared to "" so that existing
/// [OMIT IF EMPTY] template rules drop them naturally.
pub fn apply_preamble_budget(
  slots: List(identity.SlotValue),
  budget_chars: Int,
) -> List(identity.SlotValue) {
  let prioritized = assign_priorities(slots)
  // Sort by priority (ascending = most important first)
  let sorted = list.sort(prioritized, fn(a, b) { int.compare(a.0, b.0) })
  // Walk in priority order, accumulate chars, truncate when over
  let #(_, budgeted) =
    list.fold(sorted, #(0, []), fn(acc, entry) {
      let #(used, kept) = acc
      let #(_pri, slot) = entry
      let slot_len = string.length(slot.value)
      let remaining = budget_chars - used
      case remaining <= 0 {
        True -> #(used, [identity.SlotValue(..slot, value: ""), ..kept])
        False ->
          case slot_len <= remaining {
            True -> #(used + slot_len, [slot, ..kept])
            False -> {
              let truncated = string.slice(slot.value, 0, remaining)
              #(budget_chars, [
                identity.SlotValue(..slot, value: truncated),
                ..kept
              ])
            }
          }
      }
    })
  budgeted
}

fn assign_priorities(
  slots: List(identity.SlotValue),
) -> List(#(Int, identity.SlotValue)) {
  list.map(slots, fn(slot) {
    let pri = case slot.key {
      "agent_name" | "agent_version" -> 1
      "sensorium" -> 2
      "active_thread_count" | "cbr_case_count" | "persistent_fact_count" -> 5
      "last_session_summary" -> 6
      "recent_narrative" -> 7
      "active_threads" -> 8
      "recent_fact_sample" -> 9
      _ -> 10
    }
    #(pri, slot)
  })
}

/// Assemble the sensorium — a self-describing XML block of ambient perception.
/// Answers: what time is it, how long was I away, who woke me, what's
/// happening, is anything waiting, and is anything wrong?
fn build_sensorium(
  state: CuratorState,
  context: Option(CycleContext),
  recent_entries: List(narrative_types.NarrativeEntry),
) -> String {
  let now = get_timestamp()

  // Resolve cycle context (defaults when None)
  let input_source = case context {
    Some(ctx) -> ctx.input_source
    None -> "user"
  }
  let queue_depth = case context {
    Some(ctx) -> ctx.queue_depth
    None -> 0
  }
  let session_since = case context {
    Some(ctx) -> ctx.session_since
    None -> now
  }
  let agents_active = case context {
    Some(ctx) -> ctx.agents_active
    None -> 0
  }
  let message_count = case context {
    Some(ctx) -> ctx.message_count
    None -> 0
  }
  let agent_health = state.vm.constitution.agent_health

  // Find the most recent active thread for situation context
  let thread_index = librarian.load_thread_index(state.librarian)
  let active_thread_name =
    thread_index.threads
    |> list.sort(fn(a, b) { string.compare(b.last_cycle_at, a.last_cycle_at) })
    |> list.first
    |> option.from_result
    |> option.map(fn(t) { t.thread_name })

  // Find last failure from recent entries for vitals
  let last_failure = find_last_failure(recent_entries)

  let sensory_events = case context {
    Some(ctx) -> ctx.sensory_events
    None -> []
  }

  let clock = render_sensorium_clock(now, session_since, recent_entries)
  let situation =
    render_sensorium_situation(
      input_source,
      queue_depth,
      message_count,
      active_thread_name,
    )
  let schedule = render_sensorium_schedule(state.scheduler)
  let vitals =
    render_sensorium_vitals(
      state.vm.constitution,
      agents_active,
      agent_health,
      last_failure,
      state.scheduler,
    )
  let events = render_sensorium_events(sensory_events)

  // Query active tasks and endeavours for the <tasks> section
  let active_tasks = librarian.get_active_tasks(state.librarian)
  let endeavours = librarian.get_all_endeavours(state.librarian)
  let tasks_section = render_sensorium_tasks(active_tasks, endeavours)

  let sections =
    [clock, situation, schedule, vitals, events, tasks_section]
    |> list.filter(fn(s) { s != "" })
    |> string.join("\n")

  "<!-- Sensorium: ambient perception injected each cycle. No tool calls needed. -->\n<sensorium>\n"
  <> sections
  <> "\n</sensorium>"
}

/// Render the <clock> element with temporal orientation.
pub fn render_sensorium_clock(
  now: String,
  session_since: String,
  recent_entries: List(narrative_types.NarrativeEntry),
) -> String {
  let uptime = format_elapsed_since(session_since)
  let last_cycle_attr = case recent_entries {
    [entry, ..] ->
      " last_cycle=\"" <> format_elapsed_since(entry.timestamp) <> "\""
    _ -> ""
  }
  "  <clock now=\""
  <> now
  <> "\" session_uptime=\""
  <> uptime
  <> "\""
  <> last_cycle_attr
  <> "/>"
}

/// Render the <situation> element — who triggered this cycle, what's waiting,
/// conversation depth, and active thread context.
pub fn render_sensorium_situation(
  input_source: String,
  queue_depth: Int,
  message_count: Int,
  active_thread: Option(String),
) -> String {
  let thread_attr = case active_thread {
    Some(name) -> " thread=\"" <> name <> "\""
    None -> ""
  }
  "  <situation input=\""
  <> input_source
  <> "\" queue_depth=\""
  <> int.to_string(queue_depth)
  <> "\" conversation_depth=\""
  <> int.to_string(message_count)
  <> "\""
  <> thread_attr
  <> "/>"
}

/// Render the <schedule> element with per-job detail.
/// Returns "" when no scheduler or no active jobs.
pub fn render_sensorium_schedule(
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
) -> String {
  let jobs = query_schedule_jobs(scheduler)
  case jobs {
    [] -> ""
    _ -> {
      let pending_count =
        list.count(jobs, fn(j) { status_is_pending(j.status) })
      let overdue_count = list.count(jobs, fn(j) { is_overdue(j) })
      let job_lines =
        jobs
        |> list.map(fn(j) {
          "    <job title=\""
          <> j.title
          <> "\" kind=\""
          <> scheduler_types.encode_job_kind(j.kind)
          <> "\" status=\""
          <> job_display_status(j)
          <> "\""
          <> case j.due_at {
            Some(due) -> " due=\"" <> due <> "\""
            None -> ""
          }
          <> "/>"
        })
        |> string.join("\n")
      "  <schedule pending=\""
      <> int.to_string(pending_count)
      <> "\" overdue=\""
      <> int.to_string(overdue_count)
      <> "\">\n"
      <> job_lines
      <> "\n  </schedule>"
    }
  }
}

/// Render the <vitals> element — operational health.
/// `last_failure` is a human-readable description of the most recent failure
/// from narrative entries, or "" if none. Replaces raw success_rate float
/// which was not actionable.
pub fn render_sensorium_vitals(
  constitution: virtual_memory.ConstitutionSlot,
  agents_active: Int,
  agent_health: String,
  last_failure: String,
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
) -> String {
  let health_attr = case agent_health {
    "" -> ""
    "All agents nominal" -> ""
    h -> " agent_health=\"" <> h <> "\""
  }
  let failure_attr = case last_failure {
    "" -> ""
    f -> " last_failure=\"" <> f <> "\""
  }
  let budget = query_budget(scheduler)
  let budget_attrs = case budget {
    None -> ""
    Some(b) -> {
      let cycles_attr = case b.cycles_limit > 0 {
        True ->
          " cycles_remaining=\""
          <> int.to_string(int.max(0, b.cycles_limit - b.cycles_used))
          <> "\""
        False -> ""
      }
      let tokens_attr = case b.tokens_limit > 0 {
        True ->
          " tokens_remaining=\""
          <> int.to_string(int.max(0, b.tokens_limit - b.tokens_used))
          <> "\""
        False -> ""
      }
      cycles_attr <> tokens_attr
    }
  }
  "  <vitals cycles_today=\""
  <> int.to_string(constitution.today_cycles)
  <> "\" agents_active=\""
  <> int.to_string(agents_active)
  <> "\""
  <> health_attr
  <> failure_attr
  <> budget_attrs
  <> "/>"
}

/// Render the <events> element — sensory events accumulated between cycles.
/// Returns "" if events is empty.
pub fn render_sensorium_events(events: List(agent_types.SensoryEvent)) -> String {
  case events {
    [] -> ""
    _ -> {
      let count = list.length(events)
      let event_lines =
        events
        |> list.map(fn(e) {
          "    <event name=\""
          <> e.name
          <> "\" title=\""
          <> e.title
          <> "\" at=\""
          <> e.fired_at
          <> "\">"
          <> e.body
          <> "</event>"
        })
        |> string.join("\n")
      "  <events count=\""
      <> int.to_string(count)
      <> "\">\n"
      <> event_lines
      <> "\n  </events>"
    }
  }
}

/// Render the <tasks> element — active planner tasks and endeavours.
/// Returns "" if no active tasks.
pub fn render_sensorium_tasks(
  tasks: List(planner_types.PlannerTask),
  endeavours: List(planner_types.Endeavour),
) -> String {
  let active_tasks =
    list.filter(tasks, fn(t) {
      t.status == planner_types.Active || t.status == planner_types.Pending
    })
  let active_endeavours =
    list.filter(endeavours, fn(e) { e.status == planner_types.Open })
  case active_tasks, active_endeavours {
    [], [] -> ""
    _, _ -> {
      let endeavour_lines =
        active_endeavours
        |> list.map(fn(e) {
          let total = list.length(e.task_ids)
          let complete =
            list.count(tasks, fn(t) {
              case t.endeavour_id {
                option.Some(eid) ->
                  eid == e.endeavour_id && t.status == planner_types.Complete
                option.None -> False
              }
            })
          "    <endeavour id=\""
          <> e.endeavour_id
          <> "\" title=\""
          <> e.title
          <> "\" tasks=\""
          <> int.to_string(total)
          <> "\" complete=\""
          <> int.to_string(complete)
          <> "\"/>"
        })
        |> string.join("\n")
      let task_lines =
        active_tasks
        |> list.map(fn(t) {
          let total_steps = list.length(t.plan_steps)
          let complete_steps =
            list.count(t.plan_steps, fn(s) {
              s.status == planner_types.Complete
            })
          let progress =
            int.to_string(complete_steps) <> "/" <> int.to_string(total_steps)
          let status_str = case t.status {
            planner_types.Active -> "active"
            planner_types.Pending -> "pending"
            _ -> "other"
          }
          let endeavour_attr = case t.endeavour_id {
            option.Some(eid) -> " endeavour=\"" <> eid <> "\""
            option.None -> ""
          }
          let updated_attr =
            " updated=\"" <> format_elapsed_since(t.updated_at) <> "\""
          "    <task id=\""
          <> t.task_id
          <> "\" title=\""
          <> t.title
          <> "\" status=\""
          <> status_str
          <> "\" progress=\""
          <> progress
          <> "\""
          <> endeavour_attr
          <> updated_attr
          <> "/>"
        })
        |> string.join("\n")
      let all_lines =
        [endeavour_lines, task_lines]
        |> list.filter(fn(s) { s != "" })
        |> string.join("\n")
      "  <tasks active=\""
      <> int.to_string(list.length(active_tasks))
      <> "\" endeavours=\""
      <> int.to_string(list.length(active_endeavours))
      <> "\">\n"
      <> all_lines
      <> "\n  </tasks>"
    }
  }
}

// ---------------------------------------------------------------------------
// Sensorium helpers
// ---------------------------------------------------------------------------

fn query_schedule_jobs(
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
) -> List(scheduler_types.ScheduledJob) {
  case scheduler {
    None -> []
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
        Error(_) -> []
        Ok(jobs) -> jobs
      }
    }
  }
}

fn query_budget(
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
) -> Option(scheduler_types.BudgetStatus) {
  case scheduler {
    None -> None
    Some(sched) -> {
      let reply_to = process.new_subject()
      process.send(sched, scheduler_types.GetBudgetRemaining(reply_to:))
      case process.receive(reply_to, 2000) {
        Error(_) -> None
        Ok(b) -> Some(b)
      }
    }
  }
}

/// Find the most recent failure from narrative entries (already sorted recent-first).
/// Returns a brief human-readable description like "researcher timeout 2h ago", or "".
fn find_last_failure(entries: List(narrative_types.NarrativeEntry)) -> String {
  case entries {
    [] -> ""
    [entry, ..rest] ->
      case entry.outcome.status {
        narrative_types.Failure | narrative_types.Partial -> {
          let elapsed = format_elapsed_since(entry.timestamp)
          let assessment = string.slice(entry.outcome.assessment, 0, 40)
          assessment <> " " <> elapsed
        }
        _ -> find_last_failure(rest)
      }
  }
}

fn status_is_pending(status: scheduler_types.JobStatus) -> Bool {
  case status {
    scheduler_types.Pending -> True
    _ -> False
  }
}

fn is_overdue(job: scheduler_types.ScheduledJob) -> Bool {
  case job.due_at {
    Some(due) -> ms_until_datetime(due) < 0
    None -> False
  }
}

fn job_display_status(job: scheduler_types.ScheduledJob) -> String {
  case is_overdue(job) {
    True -> "overdue"
    False -> scheduler_types.encode_job_status(job.status)
  }
}
