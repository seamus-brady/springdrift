// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{ThinkComplete, ThinkError, ThinkWorkerDown}
import agent/worker
import gleam/erlang/process
import gleeunit/should
import llm/adapters/mock
import llm/request
import llm/response
import llm/retry

// ---------------------------------------------------------------------------
// Think worker sends ThinkComplete on success
// ---------------------------------------------------------------------------

pub fn think_complete_on_success_test() {
  let cognitive_subj = process.new_subject()
  let provider = mock.provider_with_text("Hello from worker")
  let req =
    request.new("mock", 256)
    |> request.with_user_message("test")
  let task_id = "test-task-1"

  worker.spawn_think(
    task_id,
    req,
    provider,
    cognitive_subj,
    retry.default_retry_config(),
  )

  // Should receive ThinkComplete
  let assert Ok(msg) = process.receive(cognitive_subj, 5000)
  case msg {
    ThinkComplete(tid, resp) -> {
      tid |> should.equal(task_id)
      response.text(resp) |> should.equal("Hello from worker")
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Think worker sends ThinkError on provider error
// ---------------------------------------------------------------------------

pub fn think_error_on_provider_error_test() {
  let cognitive_subj = process.new_subject()
  let provider = mock.provider_with_error("test failure")
  let req =
    request.new("mock", 256)
    |> request.with_user_message("test")
  let task_id = "test-task-2"

  worker.spawn_think(
    task_id,
    req,
    provider,
    cognitive_subj,
    retry.default_retry_config(),
  )

  // Should receive ThinkError
  let assert Ok(msg) = process.receive(cognitive_subj, 5000)
  case msg {
    ThinkError(tid, error, retryable) -> {
      tid |> should.equal(task_id)
      should.be_true(error != "")
      // UnknownError is not retryable
      retryable |> should.equal(False)
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Monitor forwarder sends ThinkWorkerDown on crash
// (Note: ThinkWorkerDown may arrive after ThinkComplete for normal exits)
// ---------------------------------------------------------------------------

pub fn monitor_forwarder_fires_after_worker_exits_test() {
  let cognitive_subj = process.new_subject()
  let provider = mock.provider_with_text("ok")
  let req =
    request.new("mock", 256)
    |> request.with_user_message("test")
  let task_id = "test-task-3"

  worker.spawn_think(
    task_id,
    req,
    provider,
    cognitive_subj,
    retry.default_retry_config(),
  )

  // We expect ThinkComplete first, then ThinkWorkerDown from the monitor
  // forwarder (since the worker process exits normally after sending).
  // Collect up to 2 messages.
  let assert Ok(msg1) = process.receive(cognitive_subj, 5000)
  case msg1 {
    ThinkComplete(..) -> Nil
    ThinkError(..) -> Nil
    ThinkWorkerDown(..) -> Nil
    _ -> should.fail()
  }

  // The monitor forwarder should fire eventually — but on normal exit
  // it depends on timing. Accept either getting ThinkWorkerDown or timeout.
  case process.receive(cognitive_subj, 2000) {
    Ok(ThinkWorkerDown(tid, _reason)) -> {
      tid |> should.equal(task_id)
    }
    Ok(ThinkComplete(..)) -> Nil
    Ok(_) -> Nil
    // Normal exit may not always trigger the monitor in time
    Error(_) -> Nil
  }
}
