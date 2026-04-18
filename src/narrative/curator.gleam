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

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import affect/correlation as affect_correlation
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
import knowledge/log as knowledge_log
import knowledge/types as knowledge_types
import knowledge/workspace
import narrative/housekeeper
import narrative/librarian
import narrative/meta_states
import narrative/types as narrative_types
import narrative/virtual_memory.{
  type CbrSlotEntry, type VirtualMemory, ScratchEntry,
}
import paths
import planner/types as planner_types
import remembrancer/consolidation
import scheduler/types as scheduler_types
import skills.{type SkillMeta}
import skills/metrics as skills_metrics
import slog
import strategy/log as strategy_log
import strategy/types as strategy_types

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
    /// Active agent delegations for sensorium display
    active_delegations: List(agent_types.DelegationInfo),
    /// Sandbox enabled flag
    sandbox_enabled: Bool,
    /// Sandbox slot summary for sensorium display
    sandbox_slots: List(SandboxSlotSummary),
    /// Current user input text for novelty computation
    last_user_input: String,
    /// Current cycle ID for sensorium display
    cycle_id: String,
    /// Tokens consumed so far in this cycle
    cycle_tokens_in: Int,
    cycle_tokens_out: Int,
  )
}

/// Simplified sandbox slot info for sensorium rendering.
pub type SandboxSlotSummary {
  SandboxSlotSummary(slot_id: Int, status: String, host_port: Int)
}

/// Rolling performance summary computed from recent narrative entries
/// and DAG nodes. Injected into vitals for ambient self-awareness.
pub type PerformanceSummary {
  PerformanceSummary(
    /// success / total for recent entries (0.0–1.0)
    success_rate: Float,
    /// Last 3 failure descriptions (most recent first)
    recent_failures: List(String),
    /// "stable" | "increasing" | "decreasing" — token cost trend
    cost_trend: String,
    /// Proportion of recent entries with CBR case references
    cbr_hit_rate: Float,
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
  /// Set the Housekeeper subject (called after Housekeeper starts).
  SetHousekeeper(housekeeper: Subject(housekeeper.HousekeeperMessage))
  /// Update the affect reading slot (called after each cycle).
  UpdateAffectSnapshot(reading: String)
  /// Set the discovered skills list. Called once at startup; the Curator
  /// filters by `for_agent("cognitive")` and `for_context(query_domains)`
  /// each cycle when assembling the system prompt.
  SetSkills(skills: List(SkillMeta))
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
    agent_name: String,
    agent_version: String,
    scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
    preamble_budget_chars: Int,
    housekeeper: Option(Subject(housekeeper.HousekeeperMessage)),
    affect_reading: String,
    /// All discovered skills. Filtered per-cycle by `for_agent("cognitive")`
    /// and `for_context(query_domains)` when building the system prompt.
    /// Empty list = no skills available (legacy behaviour).
    skills: List(SkillMeta),
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
        agent_name:,
        agent_version:,
        scheduler: None,
        preamble_budget_chars: 8000,
        housekeeper: None,
        affect_reading: "",
        skills: [],
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

/// Update the affect reading slot (fire-and-forget).
pub fn update_affect(curator: Subject(CuratorMessage), reading: String) -> Nil {
  process.send(curator, UpdateAffectSnapshot(reading:))
  Nil
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

/// Set the Housekeeper subject (fire-and-forget). Called after Housekeeper starts.
pub fn set_housekeeper(
  curator: Subject(CuratorMessage),
  housekeeper: Subject(housekeeper.HousekeeperMessage),
) -> Nil {
  process.send(curator, SetHousekeeper(housekeeper:))
}

/// Set the discovered skills list (fire-and-forget). Called once at
/// startup after skill discovery; the Curator filters on each
/// `BuildSystemPrompt` call.
pub fn set_skills(
  curator: Subject(CuratorMessage),
  skills: List(SkillMeta),
) -> Nil {
  process.send(curator, SetSkills(skills:))
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

        SetHousekeeper(housekeeper:) ->
          loop(CuratorState(..state, housekeeper: Some(housekeeper)))

        SetSkills(skills:) -> loop(CuratorState(..state, skills: skills))

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
          let #(prompt, budget_truncated) =
            do_build_system_prompt(state, fallback_prompt, context)
          process.send(reply_to, prompt)
          // When the preamble budget truncated memory slots, trigger
          // an immediate CBR dedup via the Housekeeper (debounced there).
          case budget_truncated, state.housekeeper {
            True, Some(hk) -> process.send(hk, housekeeper.BudgetTriggeredDedup)
            _, _ -> Nil
          }
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

        UpdateAffectSnapshot(reading:) ->
          loop(CuratorState(..state, affect_reading: reading))

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
    provenance: None,
  )
}

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_id() -> String

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms() -> Int

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

/// Returns #(prompt, budget_truncated) where budget_truncated is True when
/// the preamble budget caused any memory slots to be truncated or cleared.
///
/// The assembled prompt has three parts in order: persona, an
/// `<available_skills>` block (filtered by `for_agent("cognitive")` and
/// `for_context(query_domains)`), and the rendered preamble inside the
/// memory tag. Identity and skills together describe what the agent IS
/// and CAN DO; the preamble is the live working context.
fn do_build_system_prompt(
  state: CuratorState,
  fallback: String,
  context: Option(CycleContext),
) -> #(String, Bool) {
  let persona = identity.load_persona(state.identity_dirs)
  let template = identity.load_preamble_template(state.identity_dirs)

  let query_domains = derive_query_domains(state, context)
  let scoped_skills = case state.skills {
    [] -> []
    all ->
      all
      |> skills.for_agent("cognitive")
      |> skills.for_context(query_domains)
  }
  // Record an inject event per scoped skill so the audit panel can show
  // "this skill was placed in front of the LLM N times" alongside reads.
  // We have cycle_id from CycleContext when present; if absent, skip
  // logging (no useful attribution).
  case context {
    Some(ctx) ->
      list.each(scoped_skills, fn(s: skills.SkillMeta) {
        let skill_dir = string.replace(s.path, "/SKILL.md", "")
        skills_metrics.append_inject(skill_dir, ctx.cycle_id, "cognitive")
      })
    None -> Nil
  }
  let skills_xml = case scoped_skills {
    [] -> ""
    list -> skills.to_system_prompt_xml(list)
  }

  case persona, template {
    None, None ->
      // No identity files — fall back to the legacy startup prompt
      // (which already contains the unfiltered skills XML built at boot).
      #(fallback, False)
    _, _ -> {
      let #(rendered_preamble, truncated) = case template {
        None -> #(None, False)
        Some(tmpl) -> {
          let #(slots, was_truncated) = build_preamble_slots(state, context)
          let rendered = identity.render_preamble(tmpl, slots)
          case rendered {
            "" -> #(None, was_truncated)
            text -> #(Some(text), was_truncated)
          }
        }
      }
      let assembled = case
        identity.assemble_system_prompt(
          persona,
          rendered_preamble,
          state.memory_tag,
        )
      {
        Some(p) -> p
        None -> fallback
      }
      let prompt = case skills_xml {
        "" -> assembled
        xml -> assembled <> "\n\n" <> xml
      }
      #(prompt, truncated)
    }
  }
}

/// Domain tags used by `for_context` to activate domain-scoped skills.
/// Phase 4 minimum: returns the active thread name and the agent's recent
/// narrative entries. Real Intent.domain extraction (the spec's preferred
/// source) lands in a later phase when the cycle context carries it
/// explicitly.
fn derive_query_domains(
  _state: CuratorState,
  _context: Option(CycleContext),
) -> List(String) {
  // Conservative default: empty domain list. Skills with empty `contexts`
  // still inject (no filter); skills with non-empty `contexts` won't fire
  // until the domain extraction wires up.
  []
}

/// Returns #(budgeted_slots, was_truncated).
fn build_preamble_slots(
  state: CuratorState,
  context: Option(CycleContext),
) -> #(List(identity.SlotValue), Bool) {
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
    identity.SlotValue(key: "agent_name", value: state.agent_name),
    identity.SlotValue(key: "agent_version", value: state.agent_version),
    identity.SlotValue(key: "affect_reading", value: state.affect_reading),
  ]
  let budgeted = apply_preamble_budget(slots, state.preamble_budget_chars)
  let was_truncated = budget_caused_truncation(slots, budgeted)
  #(budgeted, was_truncated)
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

/// Check whether the budget caused any non-empty slot to lose content.
/// Compares original slots against budgeted slots by key.
pub fn budget_caused_truncation(
  original: List(identity.SlotValue),
  budgeted: List(identity.SlotValue),
) -> Bool {
  list.any(original, fn(orig) {
    case orig.value {
      // Already empty — not a truncation
      "" -> False
      _ -> {
        // Find the same slot in the budgeted list
        let budgeted_value = list.find(budgeted, fn(b) { b.key == orig.key })
        case budgeted_value {
          Ok(b) -> string.length(b.value) < string.length(orig.value)
          // Slot missing entirely — treat as truncated
          Error(_) -> True
        }
      }
    }
  })
}

fn assign_priorities(
  slots: List(identity.SlotValue),
) -> List(#(Int, identity.SlotValue)) {
  list.map(slots, fn(slot) {
    let pri = case slot.key {
      "agent_name" | "agent_version" -> 1
      "sensorium" -> 2
      "affect_reading" -> 3
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

  let current_cycle_id = case context {
    Some(ctx) -> ctx.cycle_id
    None -> ""
  }
  let clock =
    render_sensorium_clock(now, session_since, recent_entries, current_cycle_id)
  let situation =
    render_sensorium_situation(
      input_source,
      queue_depth,
      message_count,
      active_thread_name,
    )
  let schedule = render_sensorium_schedule(state.scheduler)
  // Compute novelty from input and recent narrative keywords
  let novelty = case context {
    Some(ctx) -> {
      let recent_keywords_lists = list.map(recent_entries, fn(e) { e.keywords })
      meta_states.compute_novelty(ctx.last_user_input, recent_keywords_lists)
    }
    None -> 0.0
  }
  // Use a larger window for performance summary (5 entries is too few for
  // accurate success_rate — with 135 cycles/day, 5 entries can land entirely
  // in a failure cluster and report 0.2 when the true rate is 0.88)
  let perf_entries = librarian.get_recent(state.librarian, 50)
  let perf = compute_performance_summary(perf_entries)
  let vitals =
    render_sensorium_vitals(
      state.vm.constitution,
      agents_active,
      agent_health,
      last_failure,
      state.scheduler,
      novelty,
      perf,
      case context {
        Some(ctx) -> ctx.cycle_tokens_in
        None -> 0
      },
      case context {
        Some(ctx) -> ctx.cycle_tokens_out
        None -> 0
      },
    )
  let events = render_sensorium_events(sensory_events)

  // Active delegations from cognitive loop
  let delegations_list = case context {
    Some(ctx) -> ctx.active_delegations
    None -> []
  }
  let delegations = render_sensorium_delegations(delegations_list)

  // Sandbox status
  let sandbox_section = case context {
    Some(ctx) ->
      case ctx.sandbox_enabled {
        True -> "  <sandbox enabled=\"true\"/>"
        False -> ""
      }
    None -> ""
  }

  // Query active tasks and endeavours for the <tasks> section
  let active_tasks = librarian.get_active_tasks(state.librarian)
  let endeavours = librarian.get_all_endeavours(state.librarian)
  let tasks_section = render_sensorium_tasks(active_tasks, endeavours)

  let knowledge_section = render_sensorium_knowledge(state)
  let memory_section = render_sensorium_memory()
  let strategies_section = render_sensorium_strategies()
  let affect_warnings_section = render_sensorium_affect_warnings(state)
  let skill_procedures_section = render_sensorium_skill_procedures(state.skills)

  let sections =
    [
      clock, situation, schedule, vitals, sandbox_section, delegations, events,
      tasks_section, strategies_section, affect_warnings_section,
      skill_procedures_section, knowledge_section, memory_section,
    ]
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
  current_cycle_id: String,
) -> String {
  let uptime = format_elapsed_since(session_since)
  let last_cycle_attr = case recent_entries {
    [entry, ..] ->
      " last_cycle=\"" <> format_elapsed_since(entry.timestamp) <> "\""
    _ -> ""
  }
  let cycle_id_attr = case current_cycle_id {
    "" -> ""
    id -> " cycle_id=\"" <> string.slice(id, 0, 8) <> "\""
  }
  "  <clock now=\""
  <> now
  <> "\" session_uptime=\""
  <> uptime
  <> "\""
  <> cycle_id_attr
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
/// from narrative entries, or "" if none.
pub fn render_sensorium_vitals(
  constitution: virtual_memory.ConstitutionSlot,
  agents_active: Int,
  agent_health: String,
  last_failure: String,
  scheduler: Option(Subject(scheduler_types.SchedulerMessage)),
  novelty: Float,
  perf: PerformanceSummary,
  cycle_tokens_in: Int,
  cycle_tokens_out: Int,
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
  let novelty_attr = " novelty=\"" <> meta_states.format_2dp(novelty) <> "\""
  let perf_attrs =
    " success_rate=\""
    <> meta_states.format_2dp(perf.success_rate)
    <> "\" cost_trend=\""
    <> perf.cost_trend
    <> "\" cbr_hit_rate=\""
    <> meta_states.format_2dp(perf.cbr_hit_rate)
    <> "\""
  let failures_attr = case perf.recent_failures {
    [] -> ""
    fs -> " recent_failures=\"" <> string.join(fs, "; ") <> "\""
  }
  "  <vitals cycles_today=\""
  <> int.to_string(constitution.today_cycles)
  <> "\" agents_active=\""
  <> int.to_string(agents_active)
  <> "\""
  <> health_attr
  <> failure_attr
  <> perf_attrs
  <> failures_attr
  <> budget_attrs
  <> novelty_attr
  <> case cycle_tokens_in + cycle_tokens_out {
    0 -> ""
    total ->
      " cycle_tokens=\""
      <> int.to_string(total)
      <> "\" cycle_tokens_in=\""
      <> int.to_string(cycle_tokens_in)
      <> "\" cycle_tokens_out=\""
      <> int.to_string(cycle_tokens_out)
      <> "\""
  }
  <> "/>"
}

/// Render the <events> element — sensory events accumulated between cycles.
/// Returns "" if events is empty.
/// Render the <delegations> element — active agent work in progress.
/// Returns "" when no agents are executing.
pub fn render_sensorium_delegations(
  delegations: List(agent_types.DelegationInfo),
) -> String {
  case delegations {
    [] -> ""
    _ -> {
      let now_ms = monotonic_now_ms()
      let lines =
        delegations
        |> list.map(fn(d) {
          let elapsed_s = { now_ms - d.started_at_ms } / 1000
          let tokens = d.input_tokens + d.output_tokens
          let turn_str = case d.max_turns > 0 {
            True -> int.to_string(d.turn) <> "/" <> int.to_string(d.max_turns)
            False -> int.to_string(d.turn)
          }
          let tool_attr = case d.last_tool {
            "" -> ""
            t -> " last_tool=\"" <> t <> "\""
          }
          let instr_attr = case d.instruction {
            "" -> ""
            i -> " instruction=\"" <> string.slice(i, 0, 100) <> "\""
          }
          let violation_attr = case d.violation_count > 0 {
            True -> " violations=\"" <> int.to_string(d.violation_count) <> "\""
            False -> ""
          }
          "    <agent name=\""
          <> d.agent
          <> "\" turn=\""
          <> turn_str
          <> "\" tokens=\""
          <> int.to_string(tokens)
          <> "\" elapsed_s=\""
          <> int.to_string(elapsed_s)
          <> "\" depth=\""
          <> int.to_string(d.depth)
          <> "\""
          <> tool_attr
          <> instr_attr
          <> violation_attr
          <> "/>"
        })
        |> string.join("\n")
      "  <delegations count=\""
      <> int.to_string(list.length(delegations))
      <> "\">\n"
      <> lines
      <> "\n  </delegations>"
    }
  }
}

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
    list.filter(endeavours, fn(e) {
      case e.status {
        planner_types.EndeavourComplete
        | planner_types.EndeavourFailed
        | planner_types.EndeavourAbandoned -> False
        _ -> True
      }
    })
  case active_tasks, active_endeavours {
    [], [] -> ""
    _, _ -> {
      let endeavour_lines =
        active_endeavours
        |> list.map(fn(e) {
          let total_phases = list.length(e.phases)
          let complete_phases =
            list.count(e.phases, fn(p) {
              p.status == planner_types.PhaseComplete
            })
          let current_phase =
            list.find(e.phases, fn(p) {
              p.status == planner_types.PhaseInProgress
            })
          let phase_attr = case current_phase {
            Ok(p) -> " phase=\"" <> p.name <> "\""
            Error(_) -> ""
          }
          let progress = case total_phases {
            0 -> ""
            _ ->
              " progress=\""
              <> int.to_string(complete_phases)
              <> "/"
              <> int.to_string(total_phases)
              <> "\""
          }
          let active_blockers =
            list.count(e.blockers, fn(b) {
              case b.resolved_at {
                option.None -> True
                option.Some(_) -> False
              }
            })
          let blocker_attr = case active_blockers {
            0 -> ""
            n -> " blockers=\"" <> int.to_string(n) <> "\""
          }
          let next_attr = case e.next_session {
            option.Some(s) -> " next_session=\"" <> s <> "\""
            option.None -> ""
          }
          let status_attr = case e.status {
            planner_types.EndeavourBlocked -> " status=\"blocked\""
            planner_types.OnHold -> " status=\"on_hold\""
            planner_types.Draft -> " status=\"draft\""
            _ -> ""
          }
          "    <endeavour id=\""
          <> e.endeavour_id
          <> "\" title=\""
          <> e.title
          <> "\""
          <> status_attr
          <> phase_attr
          <> progress
          <> blocker_attr
          <> next_attr
          <> "/>"
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

/// Render the <memory> element — deep-memory freshness, only when the
/// Remembrancer has run at least once. Cheap: reads one small JSONL file.
/// The decayed/dormant counts are snapshots from the last run, not live
/// numbers — they go stale as consolidation falls behind, which is exactly
/// the signal we want (prompts the agent to re-consolidate).
fn render_sensorium_memory() -> String {
  let dir = paths.consolidation_log_dir()
  case consolidation.last_run(dir) {
    Error(_) -> ""
    Ok(run) -> {
      let age = format_elapsed_since(run.timestamp)
      "  <memory last_consolidation=\""
      <> run.timestamp
      <> "\" consolidation_age=\""
      <> age
      <> "\" decayed_facts=\""
      <> int.to_string(run.decayed_facts_count)
      <> "\" dormant_threads=\""
      <> int.to_string(run.dormant_threads_count)
      <> "\"/>"
    }
  }
}

/// Render the <affect_warnings> block — meta-learning Phase D. Reads
/// facts with the `affect_corr_` prefix written by the Remembrancer's
/// `analyze_affect_performance` tool and surfaces strong negative
/// correlations (high dimension → failure) so the agent sees its own
/// maladaptive patterns at every cycle. Omitted when no warnings meet
/// the threshold so new installs see no noise.
fn render_sensorium_affect_warnings(state: CuratorState) -> String {
  let warning_threshold = -0.4
  let facts = facts_log.resolve_current(state.facts_dir, None)
  let warnings =
    facts
    |> list.filter(fn(f) {
      string.starts_with(f.key, "affect_corr_")
      && f.operation == facts_types.Write
    })
    |> list.filter_map(fn(f) {
      case affect_correlation.parse_fact_value(f.value) {
        Ok(#(r, n, inconclusive)) ->
          case inconclusive || r >. warning_threshold {
            True -> Error(Nil)
            False -> Ok(#(f.key, r, n))
          }
        Error(_) -> Error(Nil)
      }
    })
  case warnings {
    [] -> ""
    _ -> {
      let rows =
        warnings
        |> list.take(5)
        |> list.map(render_affect_warning_row)
        |> string.join("\n")
      "  <affect_warnings count=\""
      <> int.to_string(list.length(warnings))
      <> "\">\n"
      <> rows
      <> "\n  </affect_warnings>"
    }
  }
}

fn render_affect_warning_row(w: #(String, Float, Int)) -> String {
  let #(key, r, n) = w
  // key looks like "affect_corr_<dimension>_<domain>"
  let parts = string.split(key, "_")
  let #(dim, domain) = case parts {
    ["affect", "corr", d, ..rest] -> #(d, string.join(rest, "-"))
    _ -> #("?", key)
  }
  "    <affect_warning dimension=\""
  <> xml_attr_escape(dim)
  <> "\" domain=\""
  <> xml_attr_escape(domain)
  <> "\" correlation=\""
  <> float.to_string(round_to_2dp(r))
  <> "\" sample_size=\""
  <> int.to_string(n)
  <> "\"/>"
}

/// Render the <strategies> element — top active strategies from the
/// Registry, ranked by Laplace-smoothed success rate. Omitted when the
/// registry is empty so new installs see no noise. Budget: at most 3
/// strategies, each on its own line.
pub fn render_sensorium_strategies() -> String {
  let dir = paths.strategy_log_dir()
  let ranked = strategy_log.active_ranked(strategy_log.resolve_current(dir))
  case ranked {
    [] -> ""
    _ -> {
      let top = list.take(ranked, 3)
      let rows =
        top
        |> list.map(render_strategy_row)
        |> string.join("\n")
      "  <strategies count=\""
      <> int.to_string(list.length(ranked))
      <> "\">\n"
      <> rows
      <> "\n  </strategies>"
    }
  }
}

/// Render the <skill_procedures> element — a quick-reference card mapping
/// action classes to the skill the agent should consult before acting.
/// Addresses Curragh's "skills as passive reference, not active procedure"
/// gap (2026-04-18). Only rows whose skill is actually loaded are emitted;
/// the whole block is omitted if none match.
pub fn render_sensorium_skill_procedures(skills: List(SkillMeta)) -> String {
  let procedures = [
    #("delegate_to_agent", "delegation-strategy"),
    #("create_task", "planner-patterns"),
    #("send_email", "email-response"),
    #("deep_memory_work", "memory-management"),
    #("web_research", "web-research"),
    #("self_diagnostic", "self-diagnostic"),
    #("appraisal", "task-appraisal"),
    #("affect_check", "affect-monitoring"),
  ]
  let loaded_ids = list.map(skills, fn(s) { s.id })
  let active = list.filter(procedures, fn(p) { list.contains(loaded_ids, p.1) })
  case active {
    [] -> ""
    _ -> {
      let rows =
        active
        |> list.map(fn(p) {
          "    <procedure action=\""
          <> xml_attr_escape(p.0)
          <> "\" skill=\""
          <> xml_attr_escape(p.1)
          <> "\"/>"
        })
        |> string.join("\n")
      "  <skill_procedures>\n" <> rows <> "\n  </skill_procedures>"
    }
  }
}

fn render_strategy_row(s: strategy_types.Strategy) -> String {
  let sr = strategy_log.success_rate(s)
  let sr_text = float.to_string(round_to_2dp(sr))
  "    <strategy id=\""
  <> xml_attr_escape(s.id)
  <> "\" name=\""
  <> xml_attr_escape(s.name)
  <> "\" success_rate=\""
  <> sr_text
  <> "\" uses=\""
  <> int.to_string(s.total_uses)
  <> "\"/>"
}

fn round_to_2dp(f: Float) -> Float {
  let hundred = 100.0
  let scaled = f *. hundred
  let floored = float.floor(scaled +. 0.5)
  floored /. hundred
}

fn xml_attr_escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
}

fn render_sensorium_knowledge(_state: CuratorState) -> String {
  let knowledge_dir = paths.knowledge_dir()
  let docs = knowledge_log.resolve(knowledge_dir)
  case docs {
    [] -> ""
    _ -> {
      let sources =
        list.count(docs, fn(m) { m.doc_type == knowledge_types.Source })
      let notes = list.count(docs, fn(m) { m.doc_type == knowledge_types.Note })
      let drafts =
        list.count(docs, fn(m) { m.doc_type == knowledge_types.Draft })
      let exports =
        list.count(docs, fn(m) { m.doc_type == knowledge_types.Export })
      let stale = list.count(docs, fn(m) { m.status == knowledge_types.Stale })
      let journal_today =
        workspace.read_journal_today(paths.knowledge_journal_dir())
      let has_journal = journal_today != ""
      let active_notes = workspace.list_notes(paths.knowledge_notes_dir())
      let active_drafts = workspace.list_drafts(paths.knowledge_drafts_dir())

      let attrs =
        "sources=\""
        <> int.to_string(sources)
        <> "\" notes=\""
        <> int.to_string(notes)
        <> "\" drafts=\""
        <> int.to_string(drafts)
        <> "\" exports=\""
        <> int.to_string(exports)
        <> "\" stale=\""
        <> int.to_string(stale)
        <> "\" journal_today=\""
        <> case has_journal {
          True -> "true"
          False -> "false"
        }
        <> "\""

      let children = []
      let children = case has_journal {
        True -> {
          let lines = string.split(journal_today, "\n---\n")
          let last_entry = case list.last(lines) {
            Ok(entry) -> string.trim(entry)
            Error(_) -> ""
          }
          case last_entry {
            "" -> children
            entry -> {
              let truncated = case string.length(entry) > 200 {
                True -> string.slice(entry, 0, 200) <> "..."
                False -> entry
              }
              list.append(children, [
                "    <recent_journal>" <> truncated <> "</recent_journal>",
              ])
            }
          }
        }
        False -> children
      }
      let children = case active_notes {
        [] -> children
        slugs ->
          list.append(children, [
            "    <active_notes>"
            <> string.join(slugs, ", ")
            <> "</active_notes>",
          ])
      }
      let children = case active_drafts {
        [] -> children
        slugs ->
          list.append(children, [
            "    <active_drafts>"
            <> string.join(slugs, ", ")
            <> "</active_drafts>",
          ])
      }

      case children {
        [] -> "  <knowledge " <> attrs <> "/>"
        _ ->
          "  <knowledge "
          <> attrs
          <> ">\n"
          <> string.join(children, "\n")
          <> "\n  </knowledge>"
      }
    }
  }
}

/// Compute rolling performance summary from recent narrative entries.
/// Entries are expected to be sorted recent-first.
pub fn compute_performance_summary(
  entries: List(narrative_types.NarrativeEntry),
) -> PerformanceSummary {
  let total = list.length(entries)
  case total {
    0 ->
      PerformanceSummary(
        success_rate: 0.0,
        recent_failures: [],
        cost_trend: "stable",
        cbr_hit_rate: 0.0,
      )
    _ -> {
      // Success rate
      let successes =
        list.count(entries, fn(e) {
          e.outcome.status == narrative_types.Success
        })
      let success_rate = int.to_float(successes) /. int.to_float(total)

      // Recent failures (up to 3)
      let recent_failures =
        entries
        |> list.filter(fn(e) {
          e.outcome.status == narrative_types.Failure
          || e.outcome.status == narrative_types.Partial
        })
        |> list.take(3)
        |> list.map(fn(e) {
          string.slice(e.outcome.assessment, 0, 60)
          <> " ("
          <> e.intent.domain
          <> ")"
        })

      // Cost trend: compare first half vs second half token usage
      let cost_trend = compute_cost_trend(entries)

      // CBR hit rate: proportion of entries that reference CBR cases
      // (entries with non-empty topics field starting with "cbr:" indicate retrieval)
      // We approximate by checking if the entry has any topics — entries with CBR
      // hits tend to have richer topic lists from the archivist
      let with_sources =
        list.count(entries, fn(e) { !list.is_empty(e.sources) })
      let cbr_hit_rate = int.to_float(with_sources) /. int.to_float(total)

      PerformanceSummary(
        success_rate:,
        recent_failures:,
        cost_trend:,
        cbr_hit_rate:,
      )
    }
  }
}

fn compute_cost_trend(entries: List(narrative_types.NarrativeEntry)) -> String {
  let len = list.length(entries)
  case len < 4 {
    True -> "stable"
    False -> {
      let half = len / 2
      let recent = list.take(entries, half)
      let older = list.drop(entries, half) |> list.take(half)
      let recent_avg = avg_tokens(recent)
      let older_avg = avg_tokens(older)
      case older_avg {
        0.0 -> "stable"
        _ -> {
          let ratio = recent_avg /. older_avg
          case ratio >. 1.3 {
            True -> "increasing"
            False ->
              case ratio <. 0.7 {
                True -> "decreasing"
                False -> "stable"
              }
          }
        }
      }
    }
  }
}

fn avg_tokens(entries: List(narrative_types.NarrativeEntry)) -> Float {
  case entries {
    [] -> 0.0
    _ -> {
      let total =
        list.fold(entries, 0, fn(acc, e) {
          acc + e.metrics.input_tokens + e.metrics.output_tokens
        })
      int.to_float(total) /. int.to_float(list.length(entries))
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
