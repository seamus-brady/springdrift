//// Embedding — Ollama-backed semantic embedding for CBR case retrieval.
////
//// Calls Ollama's /api/embeddings endpoint over HTTP. The embedding function
//// maps text → List(Float) vectors used as a retrieval signal in the CaseBase.
////
//// start_serving verifies Ollama is reachable and the model is loaded.
//// If either check fails, it returns an error. The caller (springdrift.gleam)
//// is expected to panic — embeddings are not optional once configured.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string

/// Verify Ollama is running and the configured model responds.
/// Makes a real embedding call with a probe string. Returns Error if
/// anything is wrong — caller should crash.
pub fn start_serving(base_url: String, model: String) -> Result(Nil, String) {
  case embed(base_url, model, "probe") {
    Ok(vec) ->
      case list.is_empty(vec) {
        True -> Error("Ollama returned empty embedding for model: " <> model)
        False -> Ok(Nil)
      }
    Error(e) -> Error(e)
  }
}

/// Build an embed_fn closure that captures the base_url and model.
pub fn make_embed_fn(
  base_url: String,
  model: String,
) -> fn(String) -> Result(List(Float), String) {
  fn(text: String) -> Result(List(Float), String) {
    embed(base_url, model, text)
  }
}

/// Embed a text string via Ollama's /api/embeddings endpoint.
pub fn embed(
  base_url: String,
  model: String,
  text: String,
) -> Result(List(Float), String) {
  let body =
    json.object([#("model", json.string(model)), #("prompt", json.string(text))])
    |> json.to_string

  let req_result =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
    |> set_url(base_url <> "/api/embeddings")

  case req_result {
    Error(e) -> Error("Bad Ollama URL: " <> e)
    Ok(req) ->
      case httpc.send(req) {
        Error(e) ->
          Error(
            "Ollama unreachable at " <> base_url <> ": " <> string.inspect(e),
          )
        Ok(resp) ->
          case resp.status {
            200 -> parse_embedding(resp.body)
            status ->
              Error(
                "Ollama returned HTTP "
                <> string.inspect(status)
                <> ": "
                <> resp.body,
              )
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn parse_embedding(body: String) -> Result(List(Float), String) {
  let decoder = {
    use embedding <- decode.field("embedding", decode.list(decode.float))
    decode.success(embedding)
  }

  json.parse(body, decoder)
  |> result.replace_error("Failed to parse Ollama embedding response: " <> body)
}

fn set_url(
  req: request.Request(String),
  url: String,
) -> Result(request.Request(String), String) {
  case request.to(url) {
    Ok(parsed) ->
      Ok(
        req
        |> request.set_scheme(parsed.scheme)
        |> request.set_host(parsed.host)
        |> request.set_port(option.unwrap(parsed.port, 11_434))
        |> request.set_path(parsed.path),
      )
    Error(_) -> Error("Invalid URL: " <> url)
  }
}
