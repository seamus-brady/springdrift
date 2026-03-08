//// Embedding system types — circuit breaker state and configuration.

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub type EmbeddingConfig {
  EmbeddingConfig(
    model: String,
    base_url: String,
    dimensions: Int,
    fallback: String,
  )
}

/// Default embedding config — nomic-embed-text via Ollama.
pub fn default_config() -> EmbeddingConfig {
  EmbeddingConfig(
    model: "nomic-embed-text",
    base_url: "http://localhost:11434",
    dimensions: 768,
    fallback: "symbolic",
  )
}

// ---------------------------------------------------------------------------
// Circuit breaker
// ---------------------------------------------------------------------------

/// Three-state circuit breaker for embedding service availability.
pub type EmbeddingState {
  /// Normal operation — embeddings available.
  Available
  /// 1–2 consecutive failures — log warnings, still try.
  Degraded(failures: Int)
  /// 3+ failures — fall back to symbolic-only scoring.
  Unavailable(since: String)
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub type EmbeddingError {
  /// Ollama not reachable.
  NotReachable(reason: String)
  /// Model not found on Ollama.
  ModelNotFound(model: String)
  /// Embedding returned wrong dimensions.
  DimensionMismatch(expected: Int, got: Int)
  /// HTTP error from the API.
  HttpError(status: Int, body: String)
  /// Network/connection error.
  NetworkError(reason: String)
  /// JSON decode error.
  DecodeError(reason: String)
}

// ---------------------------------------------------------------------------
// Health check result
// ---------------------------------------------------------------------------

pub type HealthCheckResult {
  Healthy(model: String, dimensions: Int)
  Unhealthy(error: EmbeddingError)
}

// ---------------------------------------------------------------------------
// Embedding result
// ---------------------------------------------------------------------------

pub type EmbeddingResult {
  EmbeddingResult(embedding: List(Float), model: String)
}
