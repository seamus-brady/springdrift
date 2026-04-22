//// Coverage for the think-error classifier and user-facing renderer.
//// These functions sit between raw provider errors (ugly, full of
//// request_ids and implementation detail) and the operator's chat
//// surface (short, actionable, no leakage).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive/llm
import gleam/string
import gleeunit/should

pub fn classify_400_bad_request_test() {
  llm.classify_think_error(
    "API error (400): {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"messages.76: tool_use ids...\"}}",
  )
  |> should.equal(llm.ClientError)
}

pub fn classify_401_auth_test() {
  llm.classify_think_error("401 Unauthorized: invalid API key")
  |> should.equal(llm.AuthError)
}

pub fn classify_403_forbidden_test() {
  llm.classify_think_error("HTTP 403 Forbidden")
  |> should.equal(llm.AuthError)
}

pub fn classify_429_rate_limit_test() {
  llm.classify_think_error("429 Too Many Requests — rate limit exceeded")
  |> should.equal(llm.RateLimit)
}

pub fn classify_overloaded_test() {
  llm.classify_think_error("529: model overloaded, please retry")
  |> should.equal(llm.RateLimit)
}

pub fn classify_timeout_test() {
  llm.classify_think_error("request timed out after 30s")
  |> should.equal(llm.NetworkError)
}

pub fn classify_network_error_test() {
  llm.classify_think_error("connection refused on socket")
  |> should.equal(llm.NetworkError)
}

pub fn classify_unknown_fallback_test() {
  llm.classify_think_error("some totally unrecognised error string")
  |> should.equal(llm.Unknown)
}

// ---------------------------------------------------------------------------
// Renderer — sanitised user-facing text only
// ---------------------------------------------------------------------------

pub fn render_user_error_does_not_leak_raw_payload_test() {
  // None of the canned texts should ever contain request_ids, JSON
  // fragments, 'toolu_' ids, or HTTP status codes.
  let renderings = [
    llm.render_user_error(llm.ClientError),
    llm.render_user_error(llm.AuthError),
    llm.render_user_error(llm.RateLimit),
    llm.render_user_error(llm.NetworkError),
    llm.render_user_error(llm.InternalCrash),
    llm.render_user_error(llm.Unknown),
  ]
  let forbidden = [
    "toolu_", "req_", "{\"", "request_id", "invalid_request_error",
  ]
  let leaks =
    renderings
    |> list_any_contains_any(forbidden)
  leaks |> should.equal(False)
}

pub fn render_auth_error_names_the_operator_action_test() {
  let text = llm.render_user_error(llm.AuthError)
  string.contains(text, "API key") |> should.equal(True)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn list_any_contains_any(haystacks: List(String), needles: List(String)) -> Bool {
  case haystacks {
    [] -> False
    [h, ..rest] ->
      case any_needle_in(h, needles) {
        True -> True
        False -> list_any_contains_any(rest, needles)
      }
  }
}

fn any_needle_in(haystack: String, needles: List(String)) -> Bool {
  case needles {
    [] -> False
    [n, ..rest] ->
      case string.contains(haystack, n) {
        True -> True
        False -> any_needle_in(haystack, rest)
      }
  }
}
