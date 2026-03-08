//// Ollama health check — validates embedding service availability.
////
//// Three-step check sequence:
////   1. Reachability — GET /api/tags (is Ollama running?)
////   2. Model availability — is nomic-embed-text listed?
////   3. Probe — POST /api/embeddings with test string, validate dimensions
////
//// Each failure produces a specific, operator-actionable error.

import embedding/types.{
  type EmbeddingConfig, type EmbeddingError, type HealthCheckResult, DecodeError,
  DimensionMismatch, Healthy, HttpError, ModelNotFound, NetworkError,
  NotReachable, Unhealthy,
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

@external(erlang, "springdrift_ffi", "http_get")
fn http_get(url: String) -> Result(#(Int, String), String)

@external(erlang, "springdrift_ffi", "http_post")
fn http_post(
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), String)

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Run the full three-step health check sequence.
pub fn check(config: EmbeddingConfig) -> HealthCheckResult {
  case check_reachable(config) {
    Error(e) -> Unhealthy(error: e)
    Ok(_) ->
      case check_model_available(config) {
        Error(e) -> Unhealthy(error: e)
        Ok(_) ->
          case check_probe(config) {
            Error(e) -> Unhealthy(error: e)
            Ok(dims) -> Healthy(model: config.model, dimensions: dims)
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Step 1: Reachability
// ---------------------------------------------------------------------------

fn check_reachable(config: EmbeddingConfig) -> Result(Nil, EmbeddingError) {
  let url = config.base_url <> "/api/tags"
  case http_get(url) {
    Error(reason) -> {
      slog.log_error(
        "embedding/health",
        "check_reachable",
        "[ollama_check] FAIL: Ollama not reachable at "
          <> config.base_url
          <> " — Is Ollama running? Try: ollama serve",
        None,
      )
      Error(NotReachable(reason:))
    }
    Ok(#(status, _body)) ->
      case status >= 200 && status < 300 {
        True -> Ok(Nil)
        False -> {
          slog.log_error(
            "embedding/health",
            "check_reachable",
            "[ollama_check] FAIL: Ollama returned status "
              <> string.inspect(status),
            None,
          )
          Error(HttpError(status:, body: "Unexpected status from /api/tags"))
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Step 2: Model availability
// ---------------------------------------------------------------------------

fn check_model_available(config: EmbeddingConfig) -> Result(Nil, EmbeddingError) {
  let url = config.base_url <> "/api/tags"
  case http_get(url) {
    Error(reason) -> Error(NetworkError(reason:))
    Ok(#(_, body)) -> {
      // Parse the model list and check for our model
      let decoder = {
        use models <- decode.field("models", decode.list(model_name_decoder()))
        decode.success(models)
      }
      case json.parse(body, decoder) {
        Error(_) -> Error(DecodeError(reason: "Failed to parse /api/tags"))
        Ok(model_names) -> {
          let found =
            list.any(model_names, fn(name) {
              string.starts_with(name, config.model)
            })
          case found {
            True -> Ok(Nil)
            False -> {
              slog.log_error(
                "embedding/health",
                "check_model_available",
                "[ollama_check] FAIL: Model '"
                  <> config.model
                  <> "' not found. Run: ollama pull "
                  <> config.model,
                None,
              )
              Error(ModelNotFound(model: config.model))
            }
          }
        }
      }
    }
  }
}

fn model_name_decoder() -> decode.Decoder(String) {
  use name <- decode.field("name", decode.string)
  decode.success(name)
}

// ---------------------------------------------------------------------------
// Step 3: Probe — actual embedding call
// ---------------------------------------------------------------------------

fn check_probe(config: EmbeddingConfig) -> Result(Int, EmbeddingError) {
  let url = config.base_url <> "/api/embeddings"
  let body =
    json.object([
      #("model", json.string(config.model)),
      #("prompt", json.string("health check")),
    ])
    |> json.to_string()

  case http_post(url, [], body) {
    Error(reason) -> Error(NetworkError(reason:))
    Ok(#(status, response_body)) ->
      case status {
        200 -> {
          let decoder = {
            use embedding <- decode.field(
              "embedding",
              decode.list(decode.float),
            )
            decode.success(embedding)
          }
          case json.parse(response_body, decoder) {
            Error(_) ->
              Error(DecodeError(reason: "Failed to decode probe response"))
            Ok(embedding) -> {
              let dims = list.length(embedding)
              case dims == config.dimensions {
                True -> {
                  slog.info(
                    "embedding/health",
                    "check_probe",
                    "[ollama_check] OK: "
                      <> config.model
                      <> " — "
                      <> string.inspect(dims)
                      <> " dimensions",
                    None,
                  )
                  Ok(dims)
                }
                False -> {
                  slog.log_error(
                    "embedding/health",
                    "check_probe",
                    "[ollama_check] FAIL: Embedding returned "
                      <> string.inspect(dims)
                      <> " dimensions, expected "
                      <> string.inspect(config.dimensions)
                      <> ". Try: ollama rm "
                      <> config.model
                      <> " && ollama pull "
                      <> config.model,
                    None,
                  )
                  Error(DimensionMismatch(
                    expected: config.dimensions,
                    got: dims,
                  ))
                }
              }
            }
          }
        }
        code -> Error(HttpError(status: code, body: response_body))
      }
  }
}
