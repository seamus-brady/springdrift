//// Embedding client — generates vector embeddings via Ollama's /api/embeddings.
////
//// Reuses the same HTTP infrastructure as the local LLM adapter. The only
//// new endpoint is POST /api/embeddings. No new dependencies.

import embedding/types.{
  type EmbeddingConfig, type EmbeddingError, type EmbeddingResult, DecodeError,
  DimensionMismatch, EmbeddingResult, HttpError, NetworkError,
}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import slog

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "http_post")
fn http_post(
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), String)

@external(erlang, "springdrift_ffi", "cosine_similarity")
pub fn cosine_similarity(a: List(Float), b: List(Float)) -> Float

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Generate an embedding vector for the given text.
pub fn embed(
  config: EmbeddingConfig,
  text: String,
) -> Result(EmbeddingResult, EmbeddingError) {
  let url = config.base_url <> "/api/embeddings"
  let body =
    json.object([
      #("model", json.string(config.model)),
      #("prompt", json.string(text)),
    ])
    |> json.to_string()

  case http_post(url, [], body) {
    Error(reason) -> Error(NetworkError(reason:))
    Ok(#(status_code, response_body)) ->
      case status_code {
        200 -> decode_embedding(response_body, config)
        code -> Error(HttpError(status: code, body: response_body))
      }
  }
}

// ---------------------------------------------------------------------------
// Response decoding
// ---------------------------------------------------------------------------

fn decode_embedding(
  body: String,
  config: EmbeddingConfig,
) -> Result(EmbeddingResult, EmbeddingError) {
  let decoder = {
    use embedding <- decode.field("embedding", decode.list(decode.float))
    decode.success(embedding)
  }

  case json.parse(body, decoder) {
    Error(_) ->
      Error(DecodeError(reason: "Failed to decode embedding response: " <> body))
    Ok(embedding) -> {
      let dims = list.length(embedding)
      case dims == config.dimensions {
        True -> Ok(EmbeddingResult(embedding:, model: config.model))
        False -> {
          slog.warn(
            "embedding/client",
            "embed",
            "Dimension mismatch: expected "
              <> string.inspect(config.dimensions)
              <> ", got "
              <> string.inspect(dims),
            None,
          )
          Error(DimensionMismatch(expected: config.dimensions, got: dims))
        }
      }
    }
  }
}
