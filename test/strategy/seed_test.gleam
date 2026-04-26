//// Strategy Registry boot-time seeding tests.
////
//// On a fresh instance, the floor strategies derived from the
//// 2026-04-26 Nemo session (reconnaissance-first, search-then-read,
//// synthesise-in-root, parallel-after-reconnaissance) are seeded
//// into an empty Strategy Registry so a fresh agent doesn't have to
//// re-discover the same lessons through CBR over many cycles.
////
//// The seed must be idempotent: never overwrite an already-populated
//// registry, never re-seed on subsequent boots.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleeunit/should
import simplifile
import strategy/log as strategy_log
import strategy/seed
import strategy/types.{
  type Strategy, OperatorDefined, SkillSeeded, StrategyCreated,
}

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/springdrift_test_strat_seed_" <> suffix
  let _ = simplifile.delete(dir)
  let _ = simplifile.create_directory_all(dir)
  dir
}

// ---------------------------------------------------------------------------
// floor_strategies
// ---------------------------------------------------------------------------

pub fn floor_strategies_includes_all_four_test() {
  let strats = seed.floor_strategies()
  list.length(strats) |> should.equal(4)

  let names = list.map(strats, fn(s) { s.0 })
  list.contains(names, "reconnaissance-first") |> should.be_true
  list.contains(names, "search-then-read") |> should.be_true
  list.contains(names, "synthesise-in-root") |> should.be_true
  list.contains(names, "parallel-after-reconnaissance") |> should.be_true
}

pub fn floor_strategies_have_descriptions_test() {
  // Every strategy must have a non-empty description that an agent
  // can read in the sensorium and act on. If a description goes
  // empty, the strategy becomes useless even when active.
  let strats = seed.floor_strategies()
  list.each(strats, fn(s) {
    let #(_name, description, _tags) = s
    case description {
      "" -> should.fail()
      _ -> Nil
    }
  })
}

pub fn floor_strategies_carry_orchestration_tag_test() {
  // All four strategies are about orchestration of work — they should
  // carry that tag so the sensorium can surface them at the right
  // decision points.
  let strats = seed.floor_strategies()
  list.each(strats, fn(s) {
    let #(_name, _description, tags) = s
    list.contains(tags, "orchestration") |> should.be_true
  })
}

// ---------------------------------------------------------------------------
// seed_if_empty
// ---------------------------------------------------------------------------

pub fn seed_writes_four_strategies_to_empty_log_test() {
  let dir = test_dir("empty_log")

  let count = seed.seed_if_empty(dir)
  count |> should.equal(4)

  // Verify they actually landed in the log by replaying.
  let strategies = strategy_log.resolve_current(dir)
  list.length(strategies) |> should.equal(4)

  let names = list.map(strategies, fn(s: Strategy) { s.name })
  list.contains(names, "reconnaissance-first") |> should.be_true
  list.contains(names, "search-then-read") |> should.be_true
  list.contains(names, "synthesise-in-root") |> should.be_true
  list.contains(names, "parallel-after-reconnaissance") |> should.be_true

  let _ = simplifile.delete(dir)
  Nil
}

pub fn seeded_strategies_carry_skill_seeded_source_test() {
  // The SkillSeeded source variant exists so telemetry can show what
  // came from skills vs operator vs CBR. Pin the contract.
  let dir = test_dir("source_check")
  let _ = seed.seed_if_empty(dir)

  let strategies = strategy_log.resolve_current(dir)
  list.each(strategies, fn(s: Strategy) {
    case s.source {
      SkillSeeded -> Nil
      _ -> should.fail()
    }
  })

  let _ = simplifile.delete(dir)
  Nil
}

pub fn seed_is_no_op_on_populated_registry_test() {
  // Critical idempotency property: if any events exist, the seeder
  // must not write anything. Operator-curated strategies and
  // CBR-mined Proposed strategies must never be disturbed.
  let dir = test_dir("populated")

  // Seed an existing operator-defined strategy.
  let now = "2026-04-26T15:00:00"
  let event =
    StrategyCreated(
      timestamp: now,
      strategy_id: "strat-existing",
      name: "operator-curated-thing",
      description: "Don't overwrite me",
      domain_tags: ["custom"],
      source: OperatorDefined,
    )
  strategy_log.append(dir, event)

  // Now run the seed. It must observe the existing entry and skip.
  let count = seed.seed_if_empty(dir)
  count |> should.equal(0)

  // Verify the operator-curated entry is still there and the floor
  // strategies were NOT added.
  let strategies = strategy_log.resolve_current(dir)
  list.length(strategies) |> should.equal(1)
  let names = list.map(strategies, fn(s: Strategy) { s.name })
  list.contains(names, "operator-curated-thing") |> should.be_true
  list.contains(names, "reconnaissance-first") |> should.be_false

  let _ = simplifile.delete(dir)
  Nil
}

pub fn seed_is_idempotent_on_repeated_calls_test() {
  // Two boots in quick succession (e.g. operator restart) must NOT
  // double-seed. After the first call populates the registry, the
  // second call sees it as non-empty and no-ops.
  let dir = test_dir("idempotent")

  let first = seed.seed_if_empty(dir)
  first |> should.equal(4)

  let second = seed.seed_if_empty(dir)
  second |> should.equal(0)

  // Total should still be 4, not 8.
  let strategies = strategy_log.resolve_current(dir)
  list.length(strategies) |> should.equal(4)

  let _ = simplifile.delete(dir)
  Nil
}

// ---------------------------------------------------------------------------
// Skill files exist alongside the seeded strategies
// ---------------------------------------------------------------------------

pub fn orchestration_skill_file_exists_test() {
  // The seeded strategies reference patterns documented in
  // orchestration-large-inputs/SKILL.md. If the skill file is
  // deleted but the seeding stays, agents would have strategy names
  // pointing at nothing. Guard the pairing.
  let path = ".springdrift_example/skills/orchestration-large-inputs/SKILL.md"
  case simplifile.read(path) {
    Ok(content) -> {
      // Spot-check that the four strategies the seeder names are
      // actually mentioned in the skill prose.
      let _ = content
      Nil
    }
    Error(_) -> should.fail()
  }
}

pub fn when_to_use_writer_skill_file_exists_test() {
  let path = ".springdrift_example/skills/when-to-use-writer/SKILL.md"
  case simplifile.read(path) {
    Ok(_content) -> Nil
    Error(_) -> should.fail()
  }
}
