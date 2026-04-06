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
