//// Pure authentication helpers — extracted for testability.
////
//// These functions work on standard gleam/http/request types (not mist-specific)
//// so they can be unit-tested without a running HTTP server.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Check whether a request is authorized given an expected token.
/// Returns True if:
///   - No token is required (token is None), OR
///   - The Authorization header matches "Bearer <token>", OR
///   - The "token" query parameter matches.
pub fn check_auth(req: Request(a), token: Option(String)) -> Bool {
  case token {
    None -> True
    Some(expected) ->
      check_bearer(req, expected) || check_query_token(req, expected)
  }
}

/// Check the Authorization: Bearer header.
pub fn check_bearer(req: Request(a), expected: String) -> Bool {
  case request.get_header(req, "authorization") {
    Ok(header) -> header == "Bearer " <> expected
    Error(_) -> False
  }
}

/// Check the ?token= query parameter.
pub fn check_query_token(req: Request(a), expected: String) -> Bool {
  case request.get_query(req) {
    Ok(params) ->
      case list.key_find(params, "token") {
        Ok(t) -> t == expected
        Error(_) -> False
      }
    Error(_) -> False
  }
}

/// Extract a bearer token from an Authorization header value.
/// Returns Some(token) if the header starts with "Bearer ", None otherwise.
pub fn parse_bearer(header_value: String) -> Option(String) {
  case string.starts_with(header_value, "Bearer ") {
    True -> Some(string.drop_start(header_value, 7))
    False -> None
  }
}

/// Startup posture for the web GUI based on token presence + the
/// explicit no-auth opt-out. Returned by `decide_startup`; the caller
/// uses it to either proceed with auth, proceed bound to localhost
/// only, or halt with a clear operator-facing error.
pub type StartupPosture {
  /// Token is set. Proceed normally with bearer auth on every route.
  AuthRequired(token: String)
  /// Operator explicitly opted out of auth. Bind to 127.0.0.1 only —
  /// even if a future bind-config tries to expose the GUI on a public
  /// interface, that doesn't change here.
  NoAuthLocalhostOnly
  /// No token set and no explicit opt-out. Refuse to start.
  RefuseToStart(reason: String)
}

/// Decide how the GUI should start given the token (Option, from the
/// SPRINGDRIFT_WEB_TOKEN env var) and the operator's explicit opt-out
/// (Bool, from `--web-no-auth` or `[web] no_auth`). Pure function so
/// tests can drive every branch.
pub fn decide_startup(
  env_token: Option(String),
  no_auth_opt_out: Bool,
) -> StartupPosture {
  case env_token, no_auth_opt_out {
    Some(""), _ ->
      RefuseToStart(
        "SPRINGDRIFT_WEB_TOKEN is set but empty. "
        <> "Either set it to a non-empty token or pass "
        <> "--web-no-auth to bind the GUI to 127.0.0.1 without auth.",
      )
    Some(token), _ -> AuthRequired(token)
    None, True -> NoAuthLocalhostOnly
    None, False ->
      RefuseToStart(
        "Web GUI auth is required by default. "
        <> "Set SPRINGDRIFT_WEB_TOKEN to a non-empty token before "
        <> "starting the GUI, or pass --web-no-auth to opt out and "
        <> "bind to 127.0.0.1 only (localhost-dev only). Refusing "
        <> "to start an unauthenticated GUI silently.",
      )
  }
}
