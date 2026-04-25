// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/http/request
import gleam/option.{None, Some}
import gleeunit/should
import web/auth

// ---------------------------------------------------------------------------
// check_auth — no token required
// ---------------------------------------------------------------------------

pub fn check_auth_no_token_required_test() {
  let req = request.new()
  auth.check_auth(req, None) |> should.be_true
}

// ---------------------------------------------------------------------------
// check_auth — bearer header
// ---------------------------------------------------------------------------

pub fn check_auth_valid_bearer_test() {
  let req =
    request.new()
    |> request.set_header("authorization", "Bearer secret-123")
  auth.check_auth(req, Some("secret-123")) |> should.be_true
}

pub fn check_auth_invalid_bearer_test() {
  let req =
    request.new()
    |> request.set_header("authorization", "Bearer wrong-token")
  auth.check_auth(req, Some("secret-123")) |> should.be_false
}

pub fn check_auth_missing_bearer_test() {
  let req = request.new()
  auth.check_auth(req, Some("secret-123")) |> should.be_false
}

// ---------------------------------------------------------------------------
// check_auth — query token
// ---------------------------------------------------------------------------

pub fn check_auth_valid_query_token_test() {
  let req = request.Request(..request.new(), query: Some("token=my-token"))
  auth.check_auth(req, Some("my-token")) |> should.be_true
}

pub fn check_auth_invalid_query_token_test() {
  let req = request.Request(..request.new(), query: Some("token=bad"))
  auth.check_auth(req, Some("my-token")) |> should.be_false
}

pub fn check_auth_neither_bearer_nor_query_test() {
  let req = request.new()
  auth.check_auth(req, Some("expected")) |> should.be_false
}

// ---------------------------------------------------------------------------
// check_bearer
// ---------------------------------------------------------------------------

pub fn check_bearer_valid_test() {
  let req =
    request.new()
    |> request.set_header("authorization", "Bearer abc")
  auth.check_bearer(req, "abc") |> should.be_true
}

pub fn check_bearer_invalid_test() {
  let req =
    request.new()
    |> request.set_header("authorization", "Bearer xyz")
  auth.check_bearer(req, "abc") |> should.be_false
}

pub fn check_bearer_missing_header_test() {
  let req = request.new()
  auth.check_bearer(req, "abc") |> should.be_false
}

pub fn check_bearer_wrong_scheme_test() {
  let req =
    request.new()
    |> request.set_header("authorization", "Basic abc")
  auth.check_bearer(req, "abc") |> should.be_false
}

// ---------------------------------------------------------------------------
// check_query_token
// ---------------------------------------------------------------------------

pub fn check_query_token_valid_test() {
  let req = request.Request(..request.new(), query: Some("token=secret"))
  auth.check_query_token(req, "secret") |> should.be_true
}

pub fn check_query_token_invalid_test() {
  let req = request.Request(..request.new(), query: Some("token=wrong"))
  auth.check_query_token(req, "secret") |> should.be_false
}

pub fn check_query_token_missing_param_test() {
  let req = request.Request(..request.new(), query: Some("other=value"))
  auth.check_query_token(req, "secret") |> should.be_false
}

pub fn check_query_token_no_query_test() {
  let req = request.new()
  auth.check_query_token(req, "secret") |> should.be_false
}

// ---------------------------------------------------------------------------
// parse_bearer
// ---------------------------------------------------------------------------

pub fn parse_bearer_valid_test() {
  auth.parse_bearer("Bearer abc") |> should.equal(Some("abc"))
}

pub fn parse_bearer_basic_scheme_test() {
  auth.parse_bearer("Basic xyz") |> should.equal(None)
}

pub fn parse_bearer_empty_string_test() {
  auth.parse_bearer("") |> should.equal(None)
}

pub fn parse_bearer_bearer_with_spaces_test() {
  auth.parse_bearer("Bearer token with spaces")
  |> should.equal(Some("token with spaces"))
}

// ---------------------------------------------------------------------------
// decide_startup — fail-closed policy for the web GUI
// ---------------------------------------------------------------------------

pub fn decide_startup_with_token_returns_auth_required_test() {
  case auth.decide_startup(Some("super-secret"), False) {
    auth.AuthRequired(token) -> token |> should.equal("super-secret")
    _ -> should.fail()
  }
}

pub fn decide_startup_token_present_ignores_no_auth_flag_test() {
  // If the operator both sets a token AND passes --web-no-auth, the
  // token wins — auth is the more conservative outcome and the no-auth
  // flag is a footgun-protector for a different scenario.
  case auth.decide_startup(Some("super-secret"), True) {
    auth.AuthRequired(token) -> token |> should.equal("super-secret")
    _ -> should.fail()
  }
}

pub fn decide_startup_empty_token_refuses_to_start_test() {
  // Empty string token is a misconfiguration (typically a shell that
  // unset the variable but still exported the name). Not safe to
  // proceed with auth required (token is "" — anyone can pass it),
  // not safe to proceed without auth either. Refuse with explanation.
  case auth.decide_startup(Some(""), False) {
    auth.RefuseToStart(reason) -> { reason != "" } |> should.be_true
    _ -> should.fail()
  }
}

pub fn decide_startup_no_token_no_optout_refuses_to_start_test() {
  // The critical case the security review was about. Default
  // behaviour MUST be to refuse, not to start without auth.
  case auth.decide_startup(None, False) {
    auth.RefuseToStart(reason) -> { reason != "" } |> should.be_true
    _ -> should.fail()
  }
}

pub fn decide_startup_no_token_with_optout_returns_localhost_only_test() {
  // Operator explicitly opted out — bind to localhost only.
  case auth.decide_startup(None, True) {
    auth.NoAuthLocalhostOnly -> Nil
    _ -> should.fail()
  }
}
