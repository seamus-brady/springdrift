import embedding/client
import embedding/types
import gleam/float
import gleeunit/should

// ---------------------------------------------------------------------------
// Cosine similarity tests
// ---------------------------------------------------------------------------

pub fn cosine_identical_vectors_test() {
  let v = [1.0, 2.0, 3.0]
  let sim = client.cosine_similarity(v, v)
  // Should be very close to 1.0
  should.be_true(sim >. 0.999)
}

pub fn cosine_orthogonal_vectors_test() {
  let a = [1.0, 0.0, 0.0]
  let b = [0.0, 1.0, 0.0]
  let sim = client.cosine_similarity(a, b)
  // Should be 0.0
  should.be_true(float.absolute_value(sim) <. 0.001)
}

pub fn cosine_opposite_vectors_test() {
  let a = [1.0, 2.0, 3.0]
  let b = [-1.0, -2.0, -3.0]
  let sim = client.cosine_similarity(a, b)
  // Should be close to -1.0
  should.be_true(sim <. -0.999)
}

pub fn cosine_empty_vectors_test() {
  let sim = client.cosine_similarity([], [])
  should.equal(sim, 0.0)
}

pub fn cosine_mismatched_lengths_test() {
  let sim = client.cosine_similarity([1.0, 2.0], [1.0])
  should.equal(sim, 0.0)
}

pub fn cosine_similar_vectors_test() {
  let a = [1.0, 2.0, 3.0]
  let b = [1.1, 2.1, 2.9]
  let sim = client.cosine_similarity(a, b)
  // Should be high but not 1.0
  should.be_true(sim >. 0.99)
  should.be_true(sim <. 1.0)
}

pub fn cosine_zero_vector_test() {
  let a = [0.0, 0.0, 0.0]
  let b = [1.0, 2.0, 3.0]
  let sim = client.cosine_similarity(a, b)
  should.equal(sim, 0.0)
}

// ---------------------------------------------------------------------------
// Config tests
// ---------------------------------------------------------------------------

pub fn default_config_test() {
  let config = types.default_config()
  config.model |> should.equal("nomic-embed-text")
  config.base_url |> should.equal("http://localhost:11434")
  config.dimensions |> should.equal(768)
  config.fallback |> should.equal("symbolic")
}

// ---------------------------------------------------------------------------
// Circuit breaker state tests
// ---------------------------------------------------------------------------

pub fn embedding_state_constructors_test() {
  // Just verify the types construct correctly
  let _available = types.Available
  let _degraded = types.Degraded(failures: 2)
  let _unavailable = types.Unavailable(since: "2026-03-08T10:00:00")
  Nil
}

// ---------------------------------------------------------------------------
// Error type tests
// ---------------------------------------------------------------------------

pub fn error_constructors_test() {
  let _e1 = types.NotReachable(reason: "connection refused")
  let _e2 = types.ModelNotFound(model: "nomic-embed-text")
  let _e3 = types.DimensionMismatch(expected: 768, got: 512)
  let _e4 = types.HttpError(status: 500, body: "Internal Server Error")
  let _e5 = types.NetworkError(reason: "timeout")
  let _e6 = types.DecodeError(reason: "invalid json")
  Nil
}

// ---------------------------------------------------------------------------
// Health check result types
// ---------------------------------------------------------------------------

pub fn health_check_result_constructors_test() {
  let _healthy = types.Healthy(model: "nomic-embed-text", dimensions: 768)
  let _unhealthy = types.Unhealthy(error: types.NotReachable(reason: "refused"))
  Nil
}
