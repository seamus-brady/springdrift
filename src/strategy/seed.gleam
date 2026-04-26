//// Boot-time Strategy Registry seeding.
////
//// When a fresh instance starts and the strategy log is empty, seed
//// the floor strategies that ship as skill content
//// (`orchestration-large-inputs/SKILL.md` and `when-to-use-writer/
//// SKILL.md`). These are common knowledge — every instance should
//// have them at boot rather than re-discovering the lessons through
//// CBR over many cycles.
////
//// Idempotent: re-runs after the registry is populated are no-ops.
//// Operator-curated strategies and CBR-mined `Proposed` strategies
//// are NEVER overwritten — the seeding only fires when the registry
//// has zero events.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{None}
import slog
import strategy/log as strategy_log
import strategy/types.{type StrategyEvent, SkillSeeded, StrategyCreated}

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

/// The four floor strategies derived from the 2026-04-26 Nemo
/// session. Each is a (name, description, domain_tags) triple. The
/// strategy_id is generated at seed time so subsequent events
/// reference a stable id.
pub fn floor_strategies() -> List(#(String, String, List(String))) {
  [
    #(
      "reconnaissance-first",
      "For large documents, do one cheap delegation to map the structure"
        <> " (document_info + list_sections), checkpoint the outline as an"
        <> " artifact, then pass the artifact_id to subsequent agents via"
        <> " referenced_artifacts. Eliminates redundant bootstrapping.",
      ["orchestration", "delegation", "documents"],
    ),
    #(
      "search-then-read",
      "For documents over a few hundred lines, use search_library first to"
        <> " find relevant passages, then read_range for targeted line spans."
        <> " Sequential list_sections → read_section_by_id walks are"
        <> " inherently expensive on large books.",
      ["orchestration", "documents", "retrieval"],
    ),
    #(
      "synthesise-in-root",
      "When researcher outputs are already well-structured (tables,"
        <> " comparisons, bullet points), synthesise directly in your own"
        <> " response rather than delegating to the writer. The writer is"
        <> " for unstructured-to-narrative translation; reflexive writer"
        <> " delegation adds a token-starved layer with no benefit when"
        <> " findings are already structured.",
      ["orchestration", "delegation", "synthesis"],
    ),
    #(
      "parallel-after-reconnaissance",
      "Parallel dispatch is a force multiplier AFTER the structural-context"
        <> " cost has been paid once. Sequence: one reconnaissance delegation"
        <> " → checkpoint outline → dispatch N parallel followups, each with"
        <> " the recon artifact_id in referenced_artifacts. Without"
        <> " reconnaissance-first, parallel dispatch multiplies the redundant"
        <> " bootstrap cost N-fold instead of saving time.",
      ["orchestration", "delegation", "parallelism"],
    ),
  ]
}

/// Build a list of `StrategyCreated` events for the floor
/// strategies, suitable for appending to the strategy log. Pure
/// function — no I/O, no time dependency unless `now` is captured.
pub fn build_seed_events(now: String) -> List(StrategyEvent) {
  list.map(floor_strategies(), fn(s) {
    let #(name, description, tags) = s
    StrategyCreated(
      timestamp: now,
      strategy_id: "strat-" <> generate_uuid(),
      name:,
      description:,
      domain_tags: tags,
      source: SkillSeeded,
    )
  })
}

/// Seed the strategy log at the given directory IF it is currently
/// empty. No-op when any events exist — operator-curated and
/// CBR-mined strategies are never disturbed.
///
/// Returns the number of strategies seeded (0 when the registry was
/// already populated).
pub fn seed_if_empty(strategy_dir: String) -> Int {
  let existing = strategy_log.load_all(strategy_dir)
  case existing {
    [] -> {
      let now = get_datetime()
      let events = build_seed_events(now)
      list.each(events, fn(e) { strategy_log.append(strategy_dir, e) })
      slog.info(
        "strategy/seed",
        "seed_if_empty",
        "Seeded "
          <> int_to_string(list.length(events))
          <> " floor strategies into empty registry",
        None,
      )
      list.length(events)
    }
    _ -> 0
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String
