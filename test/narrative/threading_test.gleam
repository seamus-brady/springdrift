// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{None, Some}
import gleeunit/should
import narrative/threading
import narrative/types.{
  type NarrativeEntry, type ThreadState, DataPoint, DataQuery, Entities, Intent,
  Metrics, Narrative, NarrativeEntry, Outcome, Success, ThreadIndex, ThreadState,
}

fn make_entry(
  cycle_id: String,
  domain: String,
  locations: List(String),
  keywords: List(String),
) -> NarrativeEntry {
  NarrativeEntry(
    schema_version: 1,
    cycle_id:,
    parent_cycle_id: None,
    timestamp: "2026-03-06T12:00:00Z",
    entry_type: Narrative,
    summary: "Test entry",
    intent: Intent(classification: DataQuery, description: "", domain:),
    outcome: Outcome(status: Success, confidence: 0.9, assessment: "ok"),
    delegation_chain: [],
    decisions: [],
    keywords:,
    topics: [],
    entities: Entities(
      locations:,
      organisations: [],
      data_points: [],
      temporal_references: [],
    ),
    sources: [],
    thread: None,
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

fn make_thread_state(
  thread_id: String,
  thread_name: String,
  domains: List(String),
  locations: List(String),
  keywords: List(String),
) -> ThreadState {
  ThreadState(
    thread_id:,
    thread_name:,
    created_at: "2026-03-01T00:00:00Z",
    last_cycle_id: "prev-cycle",
    last_cycle_at: "2026-03-05T12:00:00Z",
    cycle_count: 3,
    locations:,
    domains:,
    keywords:,
    topics: [],
    last_data_points: [],
  )
}

// ---------------------------------------------------------------------------
// score_overlap
// ---------------------------------------------------------------------------

pub fn score_overlap_location_match_test() {
  let entry = make_entry("c1", "weather", ["Dublin"], ["rain"])
  let ts =
    make_thread_state("t1", "Dublin Weather", ["weather"], ["Dublin"], ["rain"])
  // location=3 (Dublin), domain=1*2 (weather), keyword=1 (rain) = 6
  threading.score_overlap(entry, ts)
  |> should.equal(6)
}

pub fn score_overlap_no_match_test() {
  let entry = make_entry("c1", "finance", ["London"], ["stocks"])
  let ts =
    make_thread_state("t1", "Dublin Weather", ["weather"], ["Dublin"], ["rain"])
  threading.score_overlap(entry, ts)
  |> should.equal(0)
}

pub fn score_overlap_keyword_only_test() {
  let entry = make_entry("c1", "", [], ["rain", "wind"])
  let ts =
    make_thread_state("t1", "Weather", ["weather"], [], ["rain", "temperature"])
  // keyword=1 (rain) only
  threading.score_overlap(entry, ts)
  |> should.equal(1)
}

pub fn score_overlap_multiple_locations_test() {
  let entry = make_entry("c1", "property", ["Dublin", "Cork"], ["prices"])
  let ts =
    make_thread_state(
      "t1",
      "Property",
      ["property"],
      ["Dublin", "Cork", "Galway"],
      ["prices"],
    )
  // locations=2*3=6, domain=2, keyword=1 = 9
  threading.score_overlap(entry, ts)
  |> should.equal(9)
}

pub fn score_overlap_case_insensitive_test() {
  let entry = make_entry("c1", "", [], ["Rain", "WIND"])
  let ts = make_thread_state("t1", "Weather", [], [], ["rain", "wind"])
  // keywords: 2*1 = 2
  threading.score_overlap(entry, ts)
  |> should.equal(2)
}

// ---------------------------------------------------------------------------
// do_assign — new thread creation
// ---------------------------------------------------------------------------

pub fn assign_creates_new_thread_when_empty_index_test() {
  let entry = make_entry("c1", "weather", ["Dublin"], ["rain"])
  let index = ThreadIndex(threads: [])
  let #(updated_entry, updated_index) =
    threading.do_assign(entry, index, threading.default_config())

  // Entry should have a thread assigned
  should.be_true(option.is_some(updated_entry.thread))
  let assert Some(thread) = updated_entry.thread
  thread.position |> should.equal(1)
  thread.previous_cycle_id |> should.equal(None)
  thread.continuity_note |> should.equal("New thread started.")

  // Index should have 1 thread
  updated_index.threads |> list.length |> should.equal(1)
  let assert [ts] = updated_index.threads
  ts.cycle_count |> should.equal(1)
  ts.last_cycle_id |> should.equal("c1")
}

pub fn assign_creates_new_thread_when_no_match_test() {
  let entry = make_entry("c1", "finance", ["London"], ["stocks"])
  let ts =
    make_thread_state("t1", "Dublin Weather", ["weather"], ["Dublin"], ["rain"])
  let index = ThreadIndex(threads: [ts])
  let #(updated_entry, updated_index) =
    threading.do_assign(entry, index, threading.default_config())

  // Should create new thread (score=0 < threshold=4)
  let assert Some(thread) = updated_entry.thread
  thread.position |> should.equal(1)
  thread.thread_id |> should.not_equal("t1")
  updated_index.threads |> list.length |> should.equal(2)
}

// ---------------------------------------------------------------------------
// do_assign — existing thread matching
// ---------------------------------------------------------------------------

pub fn assign_joins_existing_thread_when_above_threshold_test() {
  let entry = make_entry("c2", "weather", ["Dublin"], ["rain", "forecast"])
  let ts =
    make_thread_state("t1", "Dublin Weather", ["weather"], ["Dublin"], ["rain"])
  let index = ThreadIndex(threads: [ts])
  let #(updated_entry, updated_index) =
    threading.do_assign(entry, index, threading.default_config())

  // Score = location(3) + domain(2) + keyword(1) = 6 >= 4
  let assert Some(thread) = updated_entry.thread
  thread.thread_id |> should.equal("t1")
  thread.position |> should.equal(4)
  thread.previous_cycle_id |> should.equal(Some("prev-cycle"))

  // Thread state updated
  updated_index.threads |> list.length |> should.equal(1)
  let assert [updated_ts] = updated_index.threads
  updated_ts.cycle_count |> should.equal(4)
  updated_ts.last_cycle_id |> should.equal("c2")
}

pub fn assign_picks_best_matching_thread_test() {
  let entry = make_entry("c3", "property", ["Cork"], ["prices"])
  let ts1 =
    make_thread_state("t1", "Dublin Weather", ["weather"], ["Dublin"], ["rain"])
  let ts2 =
    make_thread_state("t2", "Cork Property", ["property"], ["Cork"], [
      "prices",
      "market",
    ])
  let index = ThreadIndex(threads: [ts1, ts2])
  let #(updated_entry, _) =
    threading.do_assign(entry, index, threading.default_config())

  let assert Some(thread) = updated_entry.thread
  thread.thread_id |> should.equal("t2")
}

// ---------------------------------------------------------------------------
// Thread naming
// ---------------------------------------------------------------------------

pub fn new_thread_name_from_domain_and_location_test() {
  let entry = make_entry("c1", "weather", ["Dublin"], [])
  let index = ThreadIndex(threads: [])
  let #(updated_entry, _) =
    threading.do_assign(entry, index, threading.default_config())
  let assert Some(thread) = updated_entry.thread
  thread.thread_name |> should.equal("weather — Dublin")
}

pub fn new_thread_name_domain_only_test() {
  let entry = make_entry("c1", "finance", [], [])
  let index = ThreadIndex(threads: [])
  let #(updated_entry, _) =
    threading.do_assign(entry, index, threading.default_config())
  let assert Some(thread) = updated_entry.thread
  thread.thread_name |> should.equal("finance")
}

pub fn new_thread_name_location_only_test() {
  let entry = make_entry("c1", "", ["Cork"], [])
  let index = ThreadIndex(threads: [])
  let #(updated_entry, _) =
    threading.do_assign(entry, index, threading.default_config())
  let assert Some(thread) = updated_entry.thread
  thread.thread_name |> should.equal("Cork")
}

// ---------------------------------------------------------------------------
// Continuity notes with data point comparison
// ---------------------------------------------------------------------------

pub fn continuity_note_with_data_change_test() {
  let old_dp =
    DataPoint(
      label: "Temperature",
      value: "12",
      unit: "C",
      period: "today",
      source: "met",
    )
  let ts =
    ThreadState(
      ..make_thread_state("t1", "Dublin Weather", ["weather"], ["Dublin"], [
        "temperature",
      ]),
      last_data_points: [old_dp],
    )
  let new_dp = DataPoint(..old_dp, value: "15")
  let entry =
    NarrativeEntry(
      ..make_entry("c2", "weather", ["Dublin"], ["temperature"]),
      entities: Entities(
        locations: ["Dublin"],
        organisations: [],
        data_points: [new_dp],
        temporal_references: [],
      ),
    )
  let index = ThreadIndex(threads: [ts])
  let #(updated_entry, _) =
    threading.do_assign(entry, index, threading.default_config())
  let assert Some(thread) = updated_entry.thread
  // Should mention location continuity and data change
  should.be_true(string.contains(thread.continuity_note, "Dublin"))
  should.be_true(string.contains(thread.continuity_note, "Temperature"))
}

// ---------------------------------------------------------------------------
// Thread state updates
// ---------------------------------------------------------------------------

pub fn thread_state_merges_new_keywords_test() {
  let entry = make_entry("c2", "weather", ["Dublin"], ["forecast", "rain"])
  let ts =
    make_thread_state("t1", "Dublin Weather", ["weather"], ["Dublin"], ["rain"])
  let index = ThreadIndex(threads: [ts])
  let #(_, updated_index) =
    threading.do_assign(entry, index, threading.default_config())
  let assert [updated_ts] = updated_index.threads
  // "rain" already exists, "forecast" is new
  should.be_true(list.contains(updated_ts.keywords, "rain"))
  should.be_true(list.contains(updated_ts.keywords, "forecast"))
}

import gleam/list
import gleam/string
