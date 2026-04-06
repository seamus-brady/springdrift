// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/http/request
import gleam/http/response as http_response
import gleam/string
import gleeunit/should
import scheduler/delivery
import scheduler/types.{FileDelivery, WebhookDelivery}
import simplifile

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn mock_sender_ok(_req: request.Request(String)) {
  Ok(http_response.Response(status: 200, headers: [], body: "ok"))
}

fn mock_sender_500(_req: request.Request(String)) {
  Ok(http_response.Response(status: 500, headers: [], body: "error"))
}

fn unique_dir(suffix: String) -> String {
  "/tmp/springdrift_delivery_test_" <> suffix
}

fn cleanup(dir: String) -> Nil {
  let _ = simplifile.delete(dir)
  Nil
}

// ---------------------------------------------------------------------------
// File delivery
// ---------------------------------------------------------------------------

pub fn file_delivery_creates_file_test() {
  let dir = unique_dir("creates_file")
  cleanup(dir)
  let config = FileDelivery(directory: dir, format: "markdown")
  let result = delivery.deliver("Report content", "my-job", config)
  result |> should.be_ok
  let assert Ok(path) = result
  let assert Ok(content) = simplifile.read(path)
  content |> should.equal("Report content")
  cleanup(dir)
}

pub fn file_delivery_md_extension_test() {
  let dir = unique_dir("md_ext")
  cleanup(dir)
  let config = FileDelivery(directory: dir, format: "markdown")
  let assert Ok(path) = delivery.deliver("x", "j", config)
  should.be_true(string.ends_with(path, ".md"))
  cleanup(dir)
}

pub fn file_delivery_json_extension_test() {
  let dir = unique_dir("json_ext")
  cleanup(dir)
  let config = FileDelivery(directory: dir, format: "json")
  let assert Ok(path) = delivery.deliver("{}", "j", config)
  should.be_true(string.ends_with(path, ".json"))
  cleanup(dir)
}

pub fn file_delivery_html_extension_test() {
  let dir = unique_dir("html_ext")
  cleanup(dir)
  let config = FileDelivery(directory: dir, format: "html")
  let assert Ok(path) = delivery.deliver("<h1>Hi</h1>", "j", config)
  should.be_true(string.ends_with(path, ".html"))
  cleanup(dir)
}

// ---------------------------------------------------------------------------
// Webhook delivery — mock sender
// ---------------------------------------------------------------------------

pub fn webhook_delivery_ok_test() {
  let config =
    WebhookDelivery(
      url: "http://localhost:9999/hook",
      method: "POST",
      headers: [],
    )
  let result =
    delivery.deliver_with_sender("payload", "wh-job", config, mock_sender_ok)
  result |> should.be_ok
  let assert Ok(url) = result
  url |> should.equal("http://localhost:9999/hook")
}

pub fn webhook_delivery_500_returns_error_test() {
  let config =
    WebhookDelivery(
      url: "http://localhost:9999/hook",
      method: "POST",
      headers: [],
    )
  let result =
    delivery.deliver_with_sender("payload", "wh-job", config, mock_sender_500)
  result |> should.be_error
}

pub fn webhook_delivery_invalid_url_returns_error_test() {
  let config = WebhookDelivery(url: "not-a-url", method: "POST", headers: [])
  let result =
    delivery.deliver_with_sender("payload", "wh-job", config, mock_sender_ok)
  result |> should.be_error
}

// ---------------------------------------------------------------------------
// Content-type behaviour
// ---------------------------------------------------------------------------

pub fn webhook_default_content_type_is_json_test() {
  let config =
    WebhookDelivery(
      url: "http://localhost:9999/hook",
      method: "POST",
      headers: [],
    )
  // Use a capturing sender that echoes the content-type back in the body
  let sender = fn(req: request.Request(String)) {
    let ct = case request.get_header(req, "content-type") {
      Ok(v) -> v
      Error(_) -> "none"
    }
    Ok(http_response.Response(status: 200, headers: [], body: ct))
  }
  let assert Ok(_) =
    delivery.deliver_with_sender("body", "ct-job", config, sender)
  // Since deliver_with_sender returns Ok(url) on 2xx, we verify via a
  // sender that asserts inside the closure.
  // Alternatively, use a sender that fails if content-type is wrong:
  let assert_sender = fn(req: request.Request(String)) {
    case request.get_header(req, "content-type") {
      Ok("application/json") ->
        Ok(http_response.Response(status: 200, headers: [], body: "ok"))
      _ -> Ok(http_response.Response(status: 500, headers: [], body: "bad ct"))
    }
  }
  let result =
    delivery.deliver_with_sender("body", "ct-job", config, assert_sender)
  result |> should.be_ok
}

pub fn webhook_custom_content_type_respected_test() {
  let config =
    WebhookDelivery(url: "http://localhost:9999/hook", method: "POST", headers: [
      #("Content-Type", "text/markdown"),
    ])
  let assert_sender = fn(req: request.Request(String)) {
    case request.get_header(req, "content-type") {
      Ok("text/markdown") ->
        Ok(http_response.Response(status: 200, headers: [], body: "ok"))
      _ -> Ok(http_response.Response(status: 500, headers: [], body: "bad ct"))
    }
  }
  let result =
    delivery.deliver_with_sender("body", "ct-job", config, assert_sender)
  result |> should.be_ok
}

// ---------------------------------------------------------------------------
// deliver_with_sender passes request correctly
// ---------------------------------------------------------------------------

pub fn deliver_with_sender_passes_body_test() {
  let config =
    WebhookDelivery(
      url: "http://localhost:9999/hook",
      method: "POST",
      headers: [],
    )
  let assert_sender = fn(req: request.Request(String)) {
    case req.body == "my report body" {
      True -> Ok(http_response.Response(status: 200, headers: [], body: "ok"))
      False -> Ok(http_response.Response(status: 500, headers: [], body: "bad"))
    }
  }
  let result =
    delivery.deliver_with_sender(
      "my report body",
      "body-job",
      config,
      assert_sender,
    )
  result |> should.be_ok
}

pub fn deliver_with_sender_passes_custom_headers_test() {
  let config =
    WebhookDelivery(url: "http://localhost:9999/hook", method: "POST", headers: [
      #("x-api-key", "key123"),
    ])
  let assert_sender = fn(req: request.Request(String)) {
    case request.get_header(req, "x-api-key") {
      Ok("key123") ->
        Ok(http_response.Response(status: 200, headers: [], body: "ok"))
      _ -> Ok(http_response.Response(status: 500, headers: [], body: "bad"))
    }
  }
  let result =
    delivery.deliver_with_sender("body", "hdr-job", config, assert_sender)
  result |> should.be_ok
}

// ---------------------------------------------------------------------------
// File delivery via deliver_with_sender still works (ignores sender)
// ---------------------------------------------------------------------------

pub fn deliver_with_sender_file_ignores_sender_test() {
  let dir = unique_dir("with_sender_file")
  cleanup(dir)
  let config = FileDelivery(directory: dir, format: "markdown")
  // Even with a 500-returning sender, file delivery should succeed
  let result =
    delivery.deliver_with_sender("content", "fj", config, mock_sender_500)
  result |> should.be_ok
  cleanup(dir)
}
