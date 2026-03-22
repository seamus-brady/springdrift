//// D' deliberative layer — situation model, candidate generation, multi-candidate
//// evaluation, and modification explanations.
////
//// Implements spec §4: the full planning cycle that activates when the reactive
//// layer passes a request through with non-zero D'.

import cycle_log
import dprime/engine
import dprime/scorer
import dprime/types.{
  type Candidate, type DprimeConfig, type DprimeState, type Forecast,
  type GateResult, Accept, Candidate, Deliberative, GateResult, Modify, Reject,
}
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/string
import llm/provider.{type Provider}
import llm/request
import llm/response
import paths
import slog
import xstructor
import xstructor/schemas

/// Build a situation model — a structured summary of the user's request.
/// Returns a natural-language description covering what the user wants,
/// context available, and consequences of acting/not acting.
pub fn build_situation_model(
  instruction: String,
  history_context: String,
  provider: Provider,
  model: String,
  cycle_id: String,
  verbose: Bool,
  redact: Bool,
) -> String {
  slog.debug(
    "dprime/deliberative",
    "build_situation_model",
    "Building situation model",
    Some(cycle_id),
  )
  let system =
    "Summarise the user's request in terms of: (1) what they want done, (2) what context you have, (3) potential consequences of acting, (4) potential consequences of not acting. Be concise and factual."
  let req =
    request.new(model, 512)
    |> request.with_system(system)
    |> request.with_user_message(
      "Request: " <> instruction <> "\n\nHistory context: " <> history_context,
    )

  case verbose {
    True -> cycle_log.log_llm_request(cycle_id, req)
    False -> Nil
  }

  case provider.chat(req) {
    Ok(resp) -> {
      case verbose {
        True -> cycle_log.log_llm_response(cycle_id, resp, redact)
        False -> Nil
      }
      response.text(resp)
    }
    Error(_) -> {
      slog.warn(
        "dprime/deliberative",
        "build_situation_model",
        "LLM error building situation model, using structured fallback",
        Some(cycle_id),
      )
      "Instruction: "
      <> instruction
      <> "\nContext: No additional situation context available."
    }
  }
}

/// Generate N candidate approaches for handling the request.
/// Returns a list of Candidate with description and projected outcome.
pub fn generate_candidates(
  situation_model: String,
  n: Int,
  provider: Provider,
  model: String,
  cycle_id: String,
  verbose: Bool,
) -> List(Candidate) {
  slog.debug(
    "dprime/deliberative",
    "generate_candidates",
    "Generating " <> int.to_string(n) <> " candidates",
    Some(cycle_id),
  )
  case verbose {
    True ->
      slog.debug(
        "dprime/deliberative",
        "generate_candidates",
        "Situation model: " <> string.slice(situation_model, 0, 500),
        Some(cycle_id),
      )
    False -> Nil
  }

  let base_prompt =
    "Given this situation, propose "
    <> int.to_string(n)
    <> " distinct approaches the agent could take. For each, describe: (a) what the agent would do, (b) what the resulting situation would look like."

  let system =
    schemas.build_system_prompt(
      base_prompt,
      schemas.candidates_xsd,
      schemas.candidates_example,
    )

  // Compile the candidates schema
  let schema_result =
    xstructor.compile_schema(
      paths.schemas_dir(),
      "candidates.xsd",
      schemas.candidates_xsd,
    )

  case schema_result {
    Error(e) -> {
      slog.warn(
        "dprime/deliberative",
        "generate_candidates",
        "Failed to compile candidates schema: "
          <> e
          <> ", using situation model as single candidate",
        Some(cycle_id),
      )
      [Candidate(description: situation_model, projected_outcome: "")]
    }
    Ok(schema) -> {
      let config =
        xstructor.XStructorConfig(
          schema:,
          system_prompt: system,
          xml_example: schemas.candidates_example,
          max_retries: 1,
          max_tokens: 1024,
        )

      case xstructor.generate(config, situation_model, provider, model) {
        Ok(result) -> {
          let candidates = extract_candidates(result.elements)
          case candidates {
            [] -> {
              slog.warn(
                "dprime/deliberative",
                "generate_candidates",
                "No candidates extracted from XML, using situation model as single candidate",
                Some(cycle_id),
              )
              [Candidate(description: situation_model, projected_outcome: "")]
            }
            _ -> candidates
          }
        }
        Error(e) -> {
          slog.warn(
            "dprime/deliberative",
            "generate_candidates",
            "XStructor generation failed: "
              <> e
              <> ", using situation model as single candidate",
            Some(cycle_id),
          )
          [Candidate(description: situation_model, projected_outcome: "")]
        }
      }
    }
  }
}

/// Determine how many candidates to generate based on reactive D' score.
pub fn candidate_count(reactive_dprime: Float, config: DprimeConfig) -> Int {
  case reactive_dprime <. config.modify_threshold {
    True -> 1
    False -> int.min(3, config.max_candidates)
  }
}

/// Evaluate candidates against all features, selecting the best one.
/// Returns a GateResult with the decision based on the winning candidate.
pub fn evaluate_candidates(
  candidates: List(Candidate),
  state: DprimeState,
  canary_result: Option(types.ProbeResult),
  provider: Provider,
  model: String,
  cycle_id: String,
  verbose: Bool,
) -> GateResult {
  slog.debug(
    "dprime/deliberative",
    "evaluate_candidates",
    "Evaluating "
      <> int.to_string(list.length(candidates))
      <> " candidates against all features",
    Some(cycle_id),
  )

  let results =
    list.map(candidates, fn(candidate) {
      let action_text =
        candidate.description
        <> case candidate.projected_outcome {
          "" -> ""
          outcome -> "\nProjected outcome: " <> outcome
        }
      let forecasts =
        scorer.score_features(
          action_text,
          "",
          state.config.features,
          provider,
          model,
          cycle_id,
          verbose,
        )
      let score =
        engine.compute_dprime(
          forecasts,
          state.config.features,
          state.config.tiers,
        )
      #(candidate, forecasts, score)
    })

  // Select candidate with lowest D'
  let assert [first, ..rest] = results
  let #(_best_candidate, best_forecasts, best_score) =
    list.fold(rest, first, fn(best, current) {
      let #(_, _, best_score) = best
      let #(_, _, current_score) = current
      case current_score <. best_score {
        True -> current
        False -> best
      }
    })

  slog.info(
    "dprime/deliberative",
    "evaluate_candidates",
    "Best candidate D' score: " <> float.to_string(best_score),
    Some(cycle_id),
  )

  let decision =
    engine.gate_decision(
      best_score,
      state.current_modify_threshold,
      state.current_reject_threshold,
    )

  let explanation = case decision {
    Accept -> "Deliberative accept: D' score below modify threshold"
    Modify ->
      "Deliberative modify: D' score between thresholds — concerns identified"
    Reject -> "Deliberative reject: D' score exceeds reject threshold"
  }

  GateResult(
    decision:,
    dprime_score: best_score,
    forecasts: best_forecasts,
    explanation:,
    layer: Deliberative,
    canary_result:,
  )
}

/// Generate a human-readable modification explanation from per-feature scores.
/// Identifies the most salient concerns and asks the LLM to explain them.
pub fn explain_modification(
  forecasts: List(Forecast),
  features: List(types.Feature),
  provider: Provider,
  model: String,
  cycle_id: String,
  verbose: Bool,
  redact: Bool,
) -> String {
  // Rank features by discrepancy score (importance × magnitude)
  let scored =
    list.filter_map(forecasts, fn(f) {
      case list.find(features, fn(feat) { feat.name == f.feature_name }) {
        Ok(feat) -> {
          let score = engine.importance_weight(feat.importance) * f.magnitude
          case score > 0 {
            True ->
              Ok(
                feat.name
                <> " (score: "
                <> int.to_string(score)
                <> "): "
                <> f.rationale,
              )
            False -> Error(Nil)
          }
        }
        Error(_) -> Error(Nil)
      }
    })

  case scored {
    [] -> "No specific concerns identified"
    concerns -> {
      let concerns_text = string.join(concerns, "\n")
      let system =
        "The agent has flagged these concerns about the request. Explain them clearly to the user and suggest how they might modify their request. Be specific and constructive. Do not use the word 'norm' or 'discrepancy'. Do not mention scores or numbers."
      let req =
        request.new(model, 512)
        |> request.with_system(system)
        |> request.with_user_message(concerns_text)

      case verbose {
        True -> cycle_log.log_llm_request(cycle_id, req)
        False -> Nil
      }

      case provider.chat(req) {
        Ok(resp) -> {
          case verbose {
            True -> cycle_log.log_llm_response(cycle_id, resp, redact)
            False -> Nil
          }
          response.text(resp)
        }
        Error(_) -> {
          slog.warn(
            "dprime/deliberative",
            "explain_modification",
            "LLM error generating explanation",
            Some(cycle_id),
          )
          "Safety concerns identified: " <> concerns_text
        }
      }
    }
  }
}

/// Post-execution D' re-check. Scores the result against features and
/// returns the new D' score. Caller compares against pre-execution score
/// to determine if the action was effective.
pub fn post_execution_check(
  result_text: String,
  original_instruction: String,
  state: DprimeState,
  provider: Provider,
  model: String,
  cycle_id: String,
  verbose: Bool,
) -> GateResult {
  slog.debug(
    "dprime/deliberative",
    "post_execution_check",
    "Running post-execution D' re-check",
    Some(cycle_id),
  )
  let context =
    "Original action: " <> original_instruction <> "\nResult: " <> result_text

  let forecasts =
    scorer.score_features(
      "Evaluate the result of executing this action",
      context,
      state.config.features,
      provider,
      model,
      cycle_id,
      verbose,
    )
  let score =
    engine.compute_dprime(forecasts, state.config.features, state.config.tiers)

  let decision =
    engine.gate_decision(
      score,
      state.current_modify_threshold,
      state.current_reject_threshold,
    )

  let explanation = case decision {
    Accept -> "Post-execution check: D' decreased or acceptable"
    Modify -> "Post-execution check: D' unchanged, action may be ineffective"
    Reject -> "Post-execution check: D' increased, action counterproductive"
  }

  GateResult(
    decision:,
    dprime_score: score,
    forecasts:,
    explanation:,
    layer: Deliberative,
    canary_result: option.None,
  )
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

/// Extract Candidate values from XStructor result elements.
/// Elements have dotted paths like:
///   candidates.candidate.0.description
///   candidates.candidate.0.projected_outcome
///   candidates.candidate.1.description
///   ...
fn extract_candidates(elements: dict.Dict(String, String)) -> List(Candidate) {
  extract_candidates_loop(elements, 0, [])
}

fn extract_candidates_loop(
  elements: dict.Dict(String, String),
  idx: Int,
  acc: List(Candidate),
) -> List(Candidate) {
  let prefix = "candidates.candidate." <> int.to_string(idx)
  case dict.get(elements, prefix <> ".description") {
    Ok(desc) -> {
      let outcome = case dict.get(elements, prefix <> ".projected_outcome") {
        Ok(o) -> o
        Error(_) -> ""
      }
      extract_candidates_loop(elements, idx + 1, [
        Candidate(description: desc, projected_outcome: outcome),
        ..acc
      ])
    }
    Error(_) -> list.reverse(acc)
  }
}
