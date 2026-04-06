//// Tests for the communications agent — types, tools, log, and safety.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import comms/log as comms_log
import comms/types as comms_types
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import llm/types.{ToolCall, ToolFailure, ToolSuccess}
import simplifile
import tools/comms

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/comms_test_" <> suffix
  let _ = simplifile.create_directory_all(dir)
  // Clean any leftover files
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

fn test_config() -> comms_types.CommsConfig {
  comms_types.CommsConfig(
    enabled: True,
    inbox_id: "test-inbox-123",
    api_key_env: "AGENTMAIL_API_KEY",
    from_address: "test@agentmail.io",
    allowed_recipients: ["alice@example.com", "bob@example.com"],
    from_name: "Test Agent",
    max_outbound_per_hour: 20,
  )
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn comms_tools_defined_test() {
  let tools = comms.all()
  should.equal(list.length(tools), 4)
}

pub fn send_email_tool_exists_test() {
  let names = list.map(comms.all(), fn(t) { t.name })
  list.contains(names, "send_email") |> should.be_true
}

pub fn list_contacts_tool_exists_test() {
  let names = list.map(comms.all(), fn(t) { t.name })
  list.contains(names, "list_contacts") |> should.be_true
}

pub fn check_inbox_tool_exists_test() {
  let names = list.map(comms.all(), fn(t) { t.name })
  list.contains(names, "check_inbox") |> should.be_true
}

pub fn read_message_tool_exists_test() {
  let names = list.map(comms.all(), fn(t) { t.name })
  list.contains(names, "read_message") |> should.be_true
}

// ---------------------------------------------------------------------------
// is_comms_tool
// ---------------------------------------------------------------------------

pub fn is_comms_tool_send_email_test() {
  comms.is_comms_tool("send_email") |> should.be_true
}

pub fn is_comms_tool_list_contacts_test() {
  comms.is_comms_tool("list_contacts") |> should.be_true
}

pub fn is_comms_tool_check_inbox_test() {
  comms.is_comms_tool("check_inbox") |> should.be_true
}

pub fn is_comms_tool_read_message_test() {
  comms.is_comms_tool("read_message") |> should.be_true
}

pub fn is_comms_tool_unknown_test() {
  comms.is_comms_tool("web_search") |> should.be_false
}

// ---------------------------------------------------------------------------
// Allowlist enforcement
// ---------------------------------------------------------------------------

pub fn send_email_rejects_unlisted_recipient_test() {
  let config = test_config()
  let dir = test_dir("allowlist")
  let call =
    ToolCall(
      id: "tc-001",
      name: "send_email",
      input_json: "{\"to\": \"evil@hacker.com\", \"subject\": \"test\", \"body\": \"hi\"}",
    )
  let result = comms.execute(call, config, dir, None)
  case result {
    ToolFailure(error: err, ..) -> {
      should.be_true(string.contains(err, "not on the allowed contacts list"))
    }
    ToolSuccess(..) -> should.fail()
  }
}

pub fn send_email_rejects_case_insensitive_test() {
  let config = test_config()
  let dir = test_dir("allowlist_case")
  // "ALICE@EXAMPLE.COM" should match "alice@example.com" in the allowlist
  // (This tests that the allowlist check normalizes case)
  // But sending will still fail because we don't have a real API — so we test
  // that it passes the allowlist check and reaches the API call stage
  let call =
    ToolCall(
      id: "tc-002",
      name: "send_email",
      input_json: "{\"to\": \"ALICE@EXAMPLE.COM\", \"subject\": \"test\", \"body\": \"hi\"}",
    )
  let result = comms.execute(call, config, dir, None)
  case result {
    ToolFailure(error: err, ..) -> {
      // Should NOT say "not on the allowed contacts list"
      // It should fail at the API call stage (no API key set)
      should.be_false(string.contains(err, "not on the allowed contacts list"))
    }
    ToolSuccess(..) -> Nil
  }
}

pub fn list_contacts_returns_allowed_test() {
  let config = test_config()
  let dir = test_dir("contacts")
  let call = ToolCall(id: "tc-003", name: "list_contacts", input_json: "{}")
  let result = comms.execute(call, config, dir, None)
  case result {
    ToolSuccess(content: content, ..) -> {
      should.be_true(string.contains(content, "alice@example.com"))
      should.be_true(string.contains(content, "bob@example.com"))
    }
    ToolFailure(..) -> should.fail()
  }
}

pub fn list_contacts_empty_test() {
  let config = comms_types.CommsConfig(..test_config(), allowed_recipients: [])
  let dir = test_dir("contacts_empty")
  let call = ToolCall(id: "tc-004", name: "list_contacts", input_json: "{}")
  let result = comms.execute(call, config, dir, None)
  case result {
    ToolSuccess(content: content, ..) -> {
      should.be_true(string.contains(content, "No contacts configured"))
    }
    ToolFailure(..) -> should.fail()
  }
}

pub fn send_email_invalid_input_test() {
  let config = test_config()
  let dir = test_dir("invalid")
  let call =
    ToolCall(id: "tc-005", name: "send_email", input_json: "{\"oops\": true}")
  let result = comms.execute(call, config, dir, None)
  case result {
    ToolFailure(error: err, ..) -> {
      should.be_true(string.contains(err, "Invalid send_email input"))
    }
    ToolSuccess(..) -> should.fail()
  }
}

pub fn unknown_tool_test() {
  let config = test_config()
  let dir = test_dir("unknown")
  let call = ToolCall(id: "tc-006", name: "not_a_tool", input_json: "{}")
  let result = comms.execute(call, config, dir, None)
  case result {
    ToolFailure(error: err, ..) -> {
      should.be_true(string.contains(err, "Unknown comms tool"))
    }
    ToolSuccess(..) -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// JSONL log round-trip
// ---------------------------------------------------------------------------

pub fn log_append_and_load_test() {
  let dir = test_dir("log_roundtrip")
  let msg =
    comms_types.CommsMessage(
      message_id: "msg-001",
      thread_id: "thr-001",
      channel: comms_types.Email,
      direction: comms_types.Outbound,
      from: "agent@test.com",
      to: "alice@example.com",
      subject: "Test email",
      body_text: "Hello Alice",
      timestamp: "2026-03-28T10:00:00Z",
      status: comms_types.Sent,
      cycle_id: Some("cycle-001"),
    )
  comms_log.append(dir, msg)

  // Load by today's date should find it
  let loaded = comms_log.load_date(dir, get_date())
  should.equal(list.length(loaded), 1)
  let assert [first] = loaded
  should.equal(first.message_id, "msg-001")
  should.equal(first.to, "alice@example.com")
  should.equal(first.subject, "Test email")
  should.equal(first.body_text, "Hello Alice")
  should.equal(first.cycle_id, Some("cycle-001"))
}

pub fn log_handles_all_statuses_test() {
  let dir = test_dir("log_statuses")
  let base =
    comms_types.CommsMessage(
      message_id: "msg-base",
      thread_id: "thr-001",
      channel: comms_types.Email,
      direction: comms_types.Outbound,
      from: "agent@test.com",
      to: "alice@example.com",
      subject: "Test",
      body_text: "Body",
      timestamp: "2026-03-28T10:00:00Z",
      status: comms_types.Sent,
      cycle_id: None,
    )
  // Append with different statuses
  comms_log.append(
    dir,
    comms_types.CommsMessage(..base, message_id: "m1", status: comms_types.Sent),
  )
  comms_log.append(
    dir,
    comms_types.CommsMessage(
      ..base,
      message_id: "m2",
      status: comms_types.Delivered,
    ),
  )
  comms_log.append(
    dir,
    comms_types.CommsMessage(
      ..base,
      message_id: "m3",
      status: comms_types.Failed("timeout"),
    ),
  )
  comms_log.append(
    dir,
    comms_types.CommsMessage(
      ..base,
      message_id: "m4",
      status: comms_types.Pending,
    ),
  )
  comms_log.append(
    dir,
    comms_types.CommsMessage(
      ..base,
      message_id: "m5",
      direction: comms_types.Inbound,
      status: comms_types.Delivered,
    ),
  )

  let loaded = comms_log.load_date(dir, get_date())
  should.equal(list.length(loaded), 5)
}
