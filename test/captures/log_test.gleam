// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import captures/log as captures_log
import captures/types.{
  type Capture, type CaptureStatus, AgentSelf, Capture, ClarifiedToCalendar,
  ClarifyToCalendar, Created, Dismiss, Dismissed, Expire, Expired, InboundComms,
  OperatorAsk, Pending, Satisfied, Satisfy,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import simplifile

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/springdrift_test_captures_log_" <> suffix
  let _ = simplifile.delete(dir)
  let _ = simplifile.create_directory_all(dir)
  dir
}

fn make_capture(id: String, text: String, status: CaptureStatus) -> Capture {
  Capture(
    schema_version: 1,
    id: id,
    created_at: "2026-04-22T10:00:00Z",
    source_cycle_id: "cyc-001",
    text: text,
    source: AgentSelf,
    due_hint: None,
    status: status,
  )
}

// ---------------------------------------------------------------------------
// append + load round-trip
// ---------------------------------------------------------------------------

pub fn append_creates_dated_file_test() {
  let dir = test_dir("append")
  let capture = make_capture("cap-abc12345", "Follow up with operator", Pending)
  captures_log.append(dir, Created(capture))

  case simplifile.read_directory(dir) {
    Ok(files) -> {
      let matching =
        list.filter(files, fn(f) { string.ends_with(f, "-captures.jsonl") })
      should.be_true(list.length(matching) >= 1)
    }
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete(dir)
  Nil
}

pub fn roundtrip_created_op_test() {
  let dir = test_dir("roundtrip")
  let capture =
    Capture(
      schema_version: 1,
      id: "cap-xyz",
      created_at: "2026-04-22T11:00:00Z",
      source_cycle_id: "cyc-002",
      text: "Check the logs after lunch",
      source: OperatorAsk,
      due_hint: Some("after lunch"),
      status: Pending,
    )
  captures_log.append(dir, Created(capture))
  let loaded = captures_log.resolve_current(dir)

  should.equal(list.length(loaded), 1)
  case loaded {
    [first] -> {
      should.equal(first.id, "cap-xyz")
      should.equal(first.text, "Check the logs after lunch")
      should.equal(first.source, OperatorAsk)
      should.equal(first.due_hint, Some("after lunch"))
      should.equal(first.status, Pending)
    }
    _ -> should.fail()
  }

  let _ = simplifile.delete(dir)
  Nil
}

// ---------------------------------------------------------------------------
// resolve_from_list — ops applied in order
// ---------------------------------------------------------------------------

pub fn resolve_preserves_pending_test() {
  let c1 = make_capture("cap-1", "One", Pending)
  let c2 = make_capture("cap-2", "Two", Pending)
  let result = captures_log.resolve_from_list([Created(c1), Created(c2)])
  should.equal(list.length(result), 2)
}

pub fn resolve_applies_clarify_status_test() {
  let c = make_capture("cap-1", "One", Pending)
  let result =
    captures_log.resolve_from_list([
      Created(c),
      ClarifyToCalendar("cap-1", "job-xyz", "scheduled"),
    ])
  case result {
    [only] ->
      case only.status {
        ClarifiedToCalendar("job-xyz") -> Nil
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn resolve_applies_dismiss_status_test() {
  let c = make_capture("cap-1", "One", Pending)
  let result =
    captures_log.resolve_from_list([
      Created(c),
      Dismiss("cap-1", "already done"),
    ])
  case result {
    [only] ->
      case only.status {
        Dismissed("already done") -> Nil
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn resolve_applies_expire_status_test() {
  let c = make_capture("cap-1", "One", Pending)
  let result = captures_log.resolve_from_list([Created(c), Expire("cap-1")])
  case result {
    [only] ->
      case only.status {
        Expired -> Nil
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn duplicate_created_ops_are_idempotent_test() {
  let c = make_capture("cap-1", "One", Pending)
  let result =
    captures_log.resolve_from_list([Created(c), Created(c), Created(c)])
  should.equal(list.length(result), 1)
}

pub fn resolve_applies_ops_for_unknown_id_gracefully_test() {
  // Dismiss for an unknown id should not create or match anything
  let result = captures_log.resolve_from_list([Dismiss("cap-missing", "gone")])
  should.equal(list.length(result), 0)
}

// ---------------------------------------------------------------------------
// filter_pending + find_by_id
// ---------------------------------------------------------------------------

pub fn filter_pending_drops_non_pending_test() {
  let c1 = make_capture("cap-1", "One", Pending)
  let c2 = make_capture("cap-2", "Two", Dismissed("done"))
  let c3 = make_capture("cap-3", "Three", Expired)
  let pending = captures_log.filter_pending([c1, c2, c3])
  should.equal(list.length(pending), 1)
  case pending {
    [only] -> should.equal(only.id, "cap-1")
    _ -> should.fail()
  }
}

pub fn find_by_id_returns_match_test() {
  let c = make_capture("cap-hit", "Needle", Pending)
  let result = captures_log.find_by_id([c], "cap-hit")
  case result {
    Ok(found) -> should.equal(found.id, "cap-hit")
    Error(_) -> should.fail()
  }
}

pub fn find_by_id_returns_error_on_miss_test() {
  let c = make_capture("cap-hit", "Needle", Pending)
  case captures_log.find_by_id([c], "cap-miss") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// decoding from disk supports all three non-Pending statuses
// ---------------------------------------------------------------------------

pub fn decoded_statuses_roundtrip_through_disk_test() {
  let dir = test_dir("statuses")
  let c = make_capture("cap-1", "Multi", Pending)
  captures_log.append(dir, Created(c))
  captures_log.append(dir, ClarifyToCalendar("cap-1", "job-1", "note"))
  // Reading back resolves to ClarifiedToCalendar
  case captures_log.resolve_current(dir) {
    [only] ->
      case only.status {
        ClarifiedToCalendar("job-1") -> Nil
        _ -> should.fail()
      }
    _ -> should.fail()
  }
  let _ = simplifile.delete(dir)

  // Dismiss path
  let dir2 = test_dir("statuses2")
  let c2 = make_capture("cap-2", "Multi", Pending)
  captures_log.append(dir2, Created(c2))
  captures_log.append(dir2, Dismiss("cap-2", "handled"))
  case captures_log.resolve_current(dir2) {
    [only] ->
      case only.status {
        Dismissed("handled") -> Nil
        _ -> should.fail()
      }
    _ -> should.fail()
  }
  let _ = simplifile.delete(dir2)

  // Expire path (InboundComms source preserved)
  let dir3 = test_dir("statuses3")
  let c3 =
    Capture(
      schema_version: 1,
      id: "cap-3",
      created_at: "2026-04-22T11:00:00Z",
      source_cycle_id: "cyc-x",
      text: "old",
      source: InboundComms,
      due_hint: None,
      status: Pending,
    )
  captures_log.append(dir3, Created(c3))
  captures_log.append(dir3, Expire("cap-3"))
  case captures_log.resolve_current(dir3) {
    [only] -> {
      should.equal(only.source, InboundComms)
      case only.status {
        Expired -> Nil
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
  let _ = simplifile.delete(dir3)

  Nil
}

// ---------------------------------------------------------------------------
// Satisfy op — Phase 3b commitment closure
// ---------------------------------------------------------------------------

pub fn satisfy_op_transitions_to_satisfied_status_test() {
  let c = make_capture("cap-sat", "email the operator", Pending)
  let result =
    captures_log.resolve_from_list([
      Created(c),
      Satisfy("cap-sat", "sent email at 14:02"),
    ])
  case result {
    [only] ->
      case only.status {
        Satisfied(reason) -> reason |> should.equal("sent email at 14:02")
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn satisfy_op_round_trips_through_jsonl_test() {
  let dir = test_dir("satisfy_roundtrip")
  let c = make_capture("cap-round", "deliver the report", Pending)
  captures_log.append(dir, Created(c))
  captures_log.append(dir, Satisfy("cap-round", "report delivered in cycle X"))

  case captures_log.resolve_current(dir) {
    [only] ->
      case only.status {
        Satisfied(reason) ->
          reason |> should.equal("report delivered in cycle X")
        _ -> should.fail()
      }
    _ -> should.fail()
  }
  let _ = simplifile.delete(dir)
  Nil
}

pub fn satisfy_for_unknown_id_is_no_op_test() {
  // Satisfy for an id not in state should not create or corrupt anything.
  let c = make_capture("cap-a", "existing", Pending)
  let result =
    captures_log.resolve_from_list([Created(c), Satisfy("cap-zzz", "nope")])
  case result {
    [only] ->
      case only.status {
        Pending -> Nil
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}
