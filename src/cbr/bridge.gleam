//// CBR ↔ paperwings bridge — encodes CbrCase as VSA vectors for hybrid retrieval.
////
//// Translates between Springdrift's CbrCase world and paperwings' VectorSpace
//// world. Implements retain (encode + index) and retrieve (VSA distance +
//// inverted index + Reciprocal Rank Fusion).
////
//// Three retrieval signals, fused with RRF:
////   1. VSA structural distance — role-filler bound vectors bundled per case
////   2. Inverted index — token overlap (keywords, entities, tools, agents)
////   3. Semantic embedding — optional, via EmbedFn closure (ortex/ONNX)

import cbr/types.{type CbrCase, type CbrQuery, type ScoredCase, ScoredCase}
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import paperwings
import paperwings/error.{type MemoryError}
import paperwings/vector.{type Vector}
import paperwings/vector_space.{type VectorSpace}
import slog

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// The paperwings-backed CBR store. Owned by the Librarian.
pub type CaseBase {
  CaseBase(
    // VSA case vectors — one bundled vector per case, keyed by case_id
    cases: VectorSpace,
    // Role vectors — stable column headers for VSA encoding
    roles: VectorSpace,
    // Filler vectors — categorical values (intent:research, domain:property, etc.)
    fillers: VectorSpace,
    // Inverted index — token → list of case_ids
    index: Dict(String, List(String)),
    // Configuration
    vsa_dimensions: Int,
  )
}

/// Optional semantic embedding function (ortex/ONNX).
/// Takes text, returns float vector. None = VSA + index only.
pub type EmbedFn =
  fn(String) -> Result(List(Float), String)

// ---------------------------------------------------------------------------
// Role names — stable feature identifiers
// ---------------------------------------------------------------------------

const role_names = [
  "intent", "domain", "status", "approach", "keyword", "entity", "tool", "agent",
]

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Create a new empty CaseBase. Called at Librarian startup.
pub fn new(storage_path: String, vsa_dimensions: Int) -> CaseBase {
  CaseBase(
    cases: paperwings.new_space(
      vsa_dimensions,
      paperwings.binary,
      storage_path,
      "cases",
    ),
    roles: paperwings.new_space(
      vsa_dimensions,
      paperwings.binary,
      storage_path,
      "roles",
    ),
    fillers: paperwings.new_space(
      vsa_dimensions,
      paperwings.binary,
      storage_path,
      "fillers",
    ),
    index: dict.new(),
    vsa_dimensions:,
  )
}

/// Initialise role vectors. Must be called once after new() or load().
/// Idempotent — skips roles that already exist.
pub fn ensure_roles(base: CaseBase) -> CaseBase {
  let roles =
    list.fold(role_names, base.roles, fn(space, name) {
      case vector_space.get_vector(space, name) {
        Ok(_) -> space
        Error(_) -> {
          let #(updated, _, _) = paperwings.add_to_space(space, Some(name))
          updated
        }
      }
    })
  CaseBase(..base, roles:)
}

/// Save all VectorSpaces to disk.
pub fn save(base: CaseBase) -> Result(Nil, MemoryError) {
  use _ <- result.try(vector_space.save(base.cases))
  use _ <- result.try(vector_space.save(base.roles))
  vector_space.save(base.fillers)
}

/// Load a CaseBase from disk. Returns a fresh one if files don't exist.
pub fn load(storage_path: String, vsa_dimensions: Int) -> CaseBase {
  let cases =
    vector_space.load(storage_path, "cases")
    |> result.unwrap(paperwings.new_space(
      vsa_dimensions,
      paperwings.binary,
      storage_path,
      "cases",
    ))
  let roles =
    vector_space.load(storage_path, "roles")
    |> result.unwrap(paperwings.new_space(
      vsa_dimensions,
      paperwings.binary,
      storage_path,
      "roles",
    ))
  let fillers =
    vector_space.load(storage_path, "fillers")
    |> result.unwrap(paperwings.new_space(
      vsa_dimensions,
      paperwings.binary,
      storage_path,
      "fillers",
    ))
  CaseBase(cases:, roles:, fillers:, index: dict.new(), vsa_dimensions:)
}

/// Rebuild the inverted index from a list of cases (after loading metadata).
pub fn rebuild_index(base: CaseBase, cases: List(CbrCase)) -> CaseBase {
  let index =
    list.fold(cases, dict.new(), fn(idx, c) {
      let tokens = case_tokens(c)
      list.fold(tokens, idx, fn(idx2, tok) {
        let existing = dict.get(idx2, tok) |> result.unwrap([])
        dict.insert(idx2, tok, [c.case_id, ..existing])
      })
    })
  CaseBase(..base, index:)
}

// ---------------------------------------------------------------------------
// Retain — encode a new case into the CaseBase
// ---------------------------------------------------------------------------

/// Encode a CbrCase into the CaseBase's three stores (VSA, index).
/// Returns the updated CaseBase.
pub fn retain_case(base: CaseBase, cbr_case: CbrCase) -> CaseBase {
  // Step 1: Encode features as VSA vector
  let case_vec_result = encode_case(base, cbr_case)

  let base = case case_vec_result {
    Ok(vec) -> {
      // Insert case vector
      let #(cases, _) =
        vector_space.insert_vector(base.cases, vec, Some(cbr_case.case_id))
      CaseBase(..base, cases:)
    }
    Error(e) -> {
      slog.warn(
        "cbr/bridge",
        "retain_case",
        "VSA encoding failed: " <> e.message,
        Some(cbr_case.case_id),
      )
      base
    }
  }

  // Step 2: Update inverted index
  let tokens = case_tokens(cbr_case)
  let index =
    list.fold(tokens, base.index, fn(idx, tok) {
      let existing = dict.get(idx, tok) |> result.unwrap([])
      dict.insert(idx, tok, [cbr_case.case_id, ..existing])
    })

  // Step 3: Ensure filler vectors exist for new values
  let fillers = ensure_fillers(base.fillers, cbr_case)

  CaseBase(..base, index:, fillers:)
}

// ---------------------------------------------------------------------------
// Retrieve — find similar cases
// ---------------------------------------------------------------------------

/// Retrieve cases matching a query, scored by RRF fusion of VSA distance
/// and inverted index overlap. Returns ScoredCase list (descending score).
pub fn retrieve_cases(
  base: CaseBase,
  query: CbrQuery,
  metadata: Dict(String, CbrCase),
) -> List(ScoredCase) {
  let max_results = query.max_results

  // Signal 1: VSA structural similarity
  let vsa_ranked = vsa_rank(base, query)

  // Signal 2: Inverted index token overlap
  let index_ranked = index_rank(base, query)

  // Fuse with Reciprocal Rank Fusion (k=60)
  let fused = reciprocal_rank_fusion([vsa_ranked, index_ranked], 60)

  // Map case_ids back to full CbrCase via metadata lookup
  fused
  |> list.take(max_results)
  |> list.filter_map(fn(scored_id) {
    case dict.get(metadata, scored_id.0) {
      Ok(cbr_case) -> Ok(ScoredCase(score: scored_id.1, cbr_case:))
      Error(_) -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// VSA encoding
// ---------------------------------------------------------------------------

/// Encode a CbrCase as a bundled VSA vector of role⊗filler bindings.
fn encode_case(base: CaseBase, c: CbrCase) -> Result(Vector, MemoryError) {
  // Build feature bindings
  let features = [
    #("intent", c.problem.intent),
    #("domain", c.problem.domain),
    #("status", c.outcome.status),
    #("approach", string.slice(c.solution.approach, 0, 50)),
  ]

  // Single-value features: bind role ⊗ filler
  let single_bindings =
    list.filter_map(features, fn(pair) {
      let #(role_name, value) = pair
      case value {
        "" -> Error(Nil)
        _ -> {
          case get_or_create_binding(base, role_name, value) {
            Ok(bound) -> Ok(bound)
            Error(_) -> Error(Nil)
          }
        }
      }
    })

  // Multi-value features: bind role ⊗ filler for each, then bundle
  let multi_features = [
    #("keyword", c.problem.keywords),
    #("entity", c.problem.entities),
    #("tool", c.solution.tools_used),
    #("agent", c.solution.agents_used),
  ]

  let multi_bindings =
    list.filter_map(multi_features, fn(pair) {
      let #(role_name, values) = pair
      let bindings =
        list.filter_map(values, fn(v) {
          case v {
            "" -> Error(Nil)
            _ -> {
              case get_or_create_binding(base, role_name, v) {
                Ok(bound) -> Ok(bound)
                Error(_) -> Error(Nil)
              }
            }
          }
        })
      case bindings {
        [] -> Error(Nil)
        [single] -> Ok(single)
        [first, ..rest] -> {
          // Bundle all bindings for this role
          list.fold(rest, Ok(first), fn(acc, b) {
            case acc {
              Ok(bundled) -> paperwings.bundle(bundled, b)
              Error(e) -> Error(e)
            }
          })
          |> result.replace_error(Nil)
        }
      }
    })

  let all_bindings = list.append(single_bindings, multi_bindings)

  case all_bindings {
    [] ->
      // No features — return a random vector (will have low similarity to everything)
      Ok(paperwings.new_vector(base.vsa_dimensions, paperwings.binary))
    [single] -> Ok(single)
    [first, ..rest] ->
      list.fold(rest, Ok(first), fn(acc, b) {
        case acc {
          Ok(bundled) -> paperwings.bundle(bundled, b)
          Error(e) -> Error(e)
        }
      })
  }
}

/// Get or create a role⊗filler binding.
fn get_or_create_binding(
  base: CaseBase,
  role_name: String,
  filler_value: String,
) -> Result(Vector, MemoryError) {
  let filler_key = role_name <> ":" <> string.lowercase(filler_value)

  // Get role vector
  use role_vec <- result.try(vector_space.get_vector(base.roles, role_name))

  // Get or create filler vector
  let filler_vec = case vector_space.get_vector(base.fillers, filler_key) {
    Ok(v) -> v
    Error(_) -> {
      // Create and insert new filler
      let #(_, _, v) = paperwings.add_to_space(base.fillers, Some(filler_key))
      v
    }
  }

  // Bind role ⊗ filler
  paperwings.bind(role_vec, filler_vec)
}

/// Ensure filler vectors exist for all values in a case.
fn ensure_fillers(fillers: VectorSpace, c: CbrCase) -> VectorSpace {
  let pairs = [
    #("intent", [c.problem.intent]),
    #("domain", [c.problem.domain]),
    #("status", [c.outcome.status]),
    #("approach", [string.slice(c.solution.approach, 0, 50)]),
    #("keyword", c.problem.keywords),
    #("entity", c.problem.entities),
    #("tool", c.solution.tools_used),
    #("agent", c.solution.agents_used),
  ]

  list.fold(pairs, fillers, fn(space, pair) {
    let #(role_name, values) = pair
    list.fold(values, space, fn(s, v) {
      case v {
        "" -> s
        _ -> {
          let key = role_name <> ":" <> string.lowercase(v)
          case vector_space.get_vector(s, key) {
            Ok(_) -> s
            Error(_) -> {
              let #(updated, _, _) = paperwings.add_to_space(s, Some(key))
              updated
            }
          }
        }
      }
    })
  })
}

// ---------------------------------------------------------------------------
// VSA ranking
// ---------------------------------------------------------------------------

/// Rank all cases by VSA distance to the query vector.
fn vsa_rank(base: CaseBase, query: CbrQuery) -> List(#(String, Int)) {
  // Build query vector from query features
  let query_case =
    types.CbrCase(
      case_id: "__query__",
      timestamp: "",
      schema_version: 1,
      problem: types.CbrProblem(
        user_input: "",
        intent: query.intent,
        domain: query.domain,
        entities: query.entities,
        keywords: query.keywords,
        query_complexity: "",
      ),
      solution: types.CbrSolution(
        approach: "",
        agents_used: [],
        tools_used: [],
        steps: [],
      ),
      outcome: types.CbrOutcome(
        status: "",
        confidence: 0.0,
        assessment: "",
        pitfalls: [],
      ),
      source_narrative_id: "",
      profile: None,
    )

  case encode_case(base, query_case) {
    Error(_) -> []
    Ok(query_vec) -> {
      // Score all case vectors by distance
      let entries = vector_space.to_list(base.cases)
      let scored =
        list.filter_map(entries, fn(entry) {
          let #(case_id, case_vec) = entry
          case paperwings.vector_distance(query_vec, case_vec) {
            Ok(dist) -> Ok(#(case_id, dist))
            Error(_) -> Error(Nil)
          }
        })

      // Sort by distance ascending (smaller = more similar)
      let sorted = list.sort(scored, fn(a, b) { float.compare(a.1, b.1) })

      // Return as ranked list (position 1 = best)
      list.index_map(sorted, fn(entry, idx) { #(entry.0, idx + 1) })
    }
  }
}

// ---------------------------------------------------------------------------
// Inverted index ranking
// ---------------------------------------------------------------------------

/// Extract tokens for the inverted index from a CbrCase.
fn case_tokens(c: CbrCase) -> List(String) {
  let kw_tokens = list.map(c.problem.keywords, string.lowercase)
  let entity_tokens = list.map(c.problem.entities, string.lowercase)
  let tool_tokens = list.map(c.solution.tools_used, string.lowercase)
  let agent_tokens = list.map(c.solution.agents_used, string.lowercase)
  let intent_tokens = case c.problem.intent {
    "" -> []
    i -> [string.lowercase(i)]
  }
  let domain_tokens = case c.problem.domain {
    "" -> []
    d -> [string.lowercase(d)]
  }
  list.flatten([
    kw_tokens,
    entity_tokens,
    tool_tokens,
    agent_tokens,
    intent_tokens,
    domain_tokens,
  ])
  |> list.unique
}

/// Rank cases by token overlap with query.
fn index_rank(base: CaseBase, query: CbrQuery) -> List(#(String, Int)) {
  let query_tokens =
    list.flatten([
      list.map(query.keywords, string.lowercase),
      list.map(query.entities, string.lowercase),
      case query.intent {
        "" -> []
        i -> [string.lowercase(i)]
      },
      case query.domain {
        "" -> []
        d -> [string.lowercase(d)]
      },
    ])
    |> list.unique

  // Count how many query tokens each case matches
  let hit_counts =
    list.fold(query_tokens, dict.new(), fn(counts, tok) {
      case dict.get(base.index, tok) {
        Error(_) -> counts
        Ok(case_ids) ->
          list.fold(case_ids, counts, fn(c, id) {
            let current = dict.get(c, id) |> result.unwrap(0)
            dict.insert(c, id, current + 1)
          })
      }
    })

  // Sort by hit count descending
  let sorted =
    dict.to_list(hit_counts)
    |> list.sort(fn(a, b) { int.compare(b.1, a.1) })

  // Return ranked (position 1 = best)
  list.index_map(sorted, fn(entry, idx) { #(entry.0, idx + 1) })
}

// ---------------------------------------------------------------------------
// Reciprocal Rank Fusion
// ---------------------------------------------------------------------------

/// Fuse multiple ranked lists using RRF. Each input is a list of
/// (case_id, rank) tuples. Returns (case_id, score) sorted by score desc.
fn reciprocal_rank_fusion(
  ranked_lists: List(List(#(String, Int))),
  k: Int,
) -> List(#(String, Float)) {
  let k_float = int.to_float(k)
  let scores =
    list.fold(ranked_lists, dict.new(), fn(scores, ranked) {
      list.fold(ranked, scores, fn(s, entry) {
        let #(case_id, rank) = entry
        let rrf_score = 1.0 /. { k_float +. int.to_float(rank) }
        let current = dict.get(s, case_id) |> result.unwrap(0.0)
        dict.insert(s, case_id, current +. rrf_score)
      })
    })

  dict.to_list(scores)
  |> list.sort(fn(a, b) {
    case a.1 >. b.1 {
      True -> order.Lt
      False ->
        case a.1 <. b.1 {
          True -> order.Gt
          False -> order.Eq
        }
    }
  })
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

/// Destroy all ETS tables in the CaseBase. Call on shutdown.
pub fn destroy(base: CaseBase) -> Nil {
  vector_space.destroy(base.cases)
  vector_space.destroy(base.roles)
  vector_space.destroy(base.fillers)
}

/// Remove a case from the CaseBase (for pruning/dedup).
pub fn remove_case(base: CaseBase, case_id: String) -> CaseBase {
  // Remove from case vectors
  let cases = case vector_space.delete_vector(base.cases, case_id) {
    Ok(s) -> s
    Error(_) -> base.cases
  }

  // Remove from inverted index
  let index =
    dict.map_values(base.index, fn(_tok, ids) {
      list.filter(ids, fn(id) { id != case_id })
    })

  CaseBase(..base, cases:, index:)
}

/// Get the number of cases in the CaseBase.
pub fn case_count(base: CaseBase) -> Int {
  vector_space.vector_count(base.cases)
}

/// Get VSA distance between two cases (for dedup).
pub fn case_distance(
  base: CaseBase,
  case_id_a: String,
  case_id_b: String,
) -> Result(Float, MemoryError) {
  use vec_a <- result.try(vector_space.get_vector(base.cases, case_id_a))
  use vec_b <- result.try(vector_space.get_vector(base.cases, case_id_b))
  paperwings.vector_distance(vec_a, vec_b)
}
