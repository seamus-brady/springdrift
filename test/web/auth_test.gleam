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
