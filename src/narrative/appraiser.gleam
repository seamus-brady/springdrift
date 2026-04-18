//// Appraiser — fire-and-forget pre-mortem and post-mortem generation.
////
//// Pre-mortems predict failure modes before task execution begins.
//// Post-mortems evaluate quality after task completion, failure, or abandonment.
//// Both follow the Archivist pattern: spawn_unlinked, XStructor-validated output,
//// JSONL persistence, Librarian notification. Failures never affect the user.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import cbr/log as cbr_log
import cbr/types as cbr_types
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider}
import narrative/appraisal_types.{
  type AppraisalVerdict, type EndeavourPostMortem, type PostMortem,
  type PreMortem, AbandonedWithLearnings, Achieved, NotAchieved,
  PartiallyAchieved,
}
import narrative/librarian.{type LibrarianMessage}
import paths
import planner/log as planner_log
import planner/types as planner_types
import slog
import xstructor
import xstructor/schemas

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub type AppraiserContext {
  AppraiserContext(
    provider: Provider,
    model: String,
    max_tokens: Int,
    planner_dir: String,
    cbr_dir: String,
    librarian: Subject(LibrarianMessage),
    cognitive: Option(Subject(agent_types.CognitiveMessage)),
    min_complexity: String,
    min_steps: Int,
  )
}

// ---------------------------------------------------------------------------
// Threshold checks
// ---------------------------------------------------------------------------

/// Should this task get a pre-mortem?
pub fn should_pre_mortem(
  task: planner_types.PlannerTask,
  ctx: AppraiserContext,
) -> Bool {
  // Already has one
  case task.pre_mortem {
    Some(_) -> False
    None ->
      complexity_meets_threshold(task.complexity, ctx.min_complexity)
      || list.length(task.plan_steps) >= ctx.min_steps
      || option.is_some(task.endeavour_id)
  }
}

/// Should this task get a full LLM post-mortem (vs deterministic)?
pub fn should_full_post_mortem(
  task: planner_types.PlannerTask,
  ctx: AppraiserContext,
) -> Bool {
  case task.status {
    // Always full for failures and abandonment
    planner_types.Failed | planner_types.Abandoned -> True
    // Threshold check for completions
    _ ->
      complexity_meets_threshold(task.complexity, ctx.min_complexity)
      || list.length(task.plan_steps) >= ctx.min_steps
  }
}

fn complexity_meets_threshold(actual: String, minimum: String) -> Bool {
  complexity_rank(actual) >= complexity_rank(minimum)
}

fn complexity_rank(c: String) -> Int {
  case string.lowercase(c) {
    "simple" -> 1
    "medium" -> 2
    "complex" -> 3
    _ -> 2
  }
}

// ---------------------------------------------------------------------------
// Pre-mortem
// ---------------------------------------------------------------------------

/// Spawn a fire-and-forget pre-mortem evaluation.
pub fn spawn_pre_mortem(
  task: planner_types.PlannerTask,
  ctx: AppraiserContext,
) -> Nil {
  case should_pre_mortem(task, ctx) {
    False -> Nil
    True -> {
      let task_id = task.task_id
      process.spawn_unlinked(fn() {
        do_pre_mortem(task, ctx)
        Nil
      })
      slog.debug(
        "narrative/appraiser",
        "spawn_pre_mortem",
        "Spawned pre-mortem for task " <> task_id,
        None,
      )
      Nil
    }
  }
}

fn do_pre_mortem(task: planner_types.PlannerTask, ctx: AppraiserContext) -> Nil {
  // Query CBR for similar pitfall cases
  let pitfall_context = query_pitfall_cases(task, ctx.librarian)

  // Build the reflection prompt
  let steps_text =
    list.map(task.plan_steps, fn(s) {
      int.to_string(s.index) <> ". " <> s.description
    })
    |> string.join("\n")
  let risks_text = case task.risks {
    [] -> "None identified"
    rs -> string.join(rs, "\n- ")
  }

  let prompt =
    "Task: "
    <> task.title
    <> "\nDescription: "
    <> task.description
    <> "\nComplexity: "
    <> task.complexity
    <> "\nSteps:\n"
    <> steps_text
    <> "\nKnown risks:\n- "
    <> risks_text
    <> pitfall_context
    <> "\n\nAssume this task fails. Why did it fail? Identify:\n"
    <> "1. Specific failure modes (what could go wrong)\n"
    <> "2. Blind spot assumptions (what are we assuming that could be wrong)\n"
    <> "3. Dependencies at risk (external factors that could break)\n"
    <> "4. Information gaps (what do we not know that we need to know)"

  // XStructor generation
  let schema_result =
    xstructor.compile_schema(
      paths.schemas_dir(),
      "pre_mortem.xsd",
      schemas.pre_mortem_xsd,
    )

  case schema_result {
    Error(e) -> {
      slog.warn(
        "narrative/appraiser",
        "do_pre_mortem",
        "Schema compile failed: " <> e,
        None,
      )
      Nil
    }
    Ok(schema) -> {
      let system =
        schemas.build_system_prompt(
          "You are a pre-mortem analyst. Given a task plan, imagine it has failed and explain why. Be specific and concrete — not generic risks.",
          schemas.pre_mortem_xsd,
          schemas.pre_mortem_example,
        )
      let config =
        xstructor.XStructorConfig(
          schema:,
          system_prompt: system,
          xml_example: schemas.pre_mortem_example,
          max_retries: 2,
          max_tokens: ctx.max_tokens,
        )
      case xstructor.generate(config, prompt, ctx.provider, ctx.model) {
        Error(e) -> {
          slog.warn(
            "narrative/appraiser",
            "do_pre_mortem",
            "XStructor failed: " <> e,
            None,
          )
          Nil
        }
        Ok(result) -> {
          let pm = extract_pre_mortem(result.elements, task.task_id)
          // Persist
          let op =
            planner_types.AddPreMortem(task_id: task.task_id, pre_mortem: pm)
          planner_log.append_task_op(ctx.planner_dir, op)
          librarian.notify_task_op(ctx.librarian, op)
          slog.info(
            "narrative/appraiser",
            "do_pre_mortem",
            "Pre-mortem complete for "
              <> task.task_id
              <> " ("
              <> int.to_string(list.length(pm.failure_modes))
              <> " failure modes)",
            None,
          )
          Nil
        }
      }
    }
  }
}

fn extract_pre_mortem(
  elements: dict.Dict(String, String),
  task_id: String,
) -> PreMortem {
  let failure_modes =
    xstructor.extract_list(elements, "pre_mortem.failure_modes.mode")
  let blind_spots =
    xstructor.extract_list(elements, "pre_mortem.blind_spots.assumption")
  let deps =
    xstructor.extract_list(
      elements,
      "pre_mortem.dependencies_at_risk.dependency",
    )
  let gaps = xstructor.extract_list(elements, "pre_mortem.information_gaps.gap")
  appraisal_types.PreMortem(
    task_id:,
    failure_modes:,
    blind_spot_assumptions: blind_spots,
    dependencies_at_risk: deps,
    information_gaps: gaps,
    similar_pitfall_case_ids: [],
    created_at: get_datetime(),
  )
}

fn query_pitfall_cases(
  task: planner_types.PlannerTask,
  _lib: Subject(LibrarianMessage),
) -> String {
  // Build keywords from task for CBR query
  let _keywords =
    string.split(task.title, " ")
    |> list.filter(fn(w) { string.length(w) > 3 })
  // For now, return empty context — CBR query integration can be added later
  // when the librarian's recall_cases is exposed as a public function
  ""
}

// ---------------------------------------------------------------------------
// Post-mortem
// ---------------------------------------------------------------------------

/// Spawn a fire-and-forget post-mortem evaluation.
pub fn spawn_post_mortem(
  task: planner_types.PlannerTask,
  ctx: AppraiserContext,
) -> Nil {
  // Skip if already has a post-mortem
  case task.post_mortem {
    Some(_) -> Nil
    None -> {
      let task_id = task.task_id
      process.spawn_unlinked(fn() {
        do_post_mortem(task, ctx)
        Nil
      })
      slog.debug(
        "narrative/appraiser",
        "spawn_post_mortem",
        "Spawned post-mortem for task " <> task_id,
        None,
      )
      Nil
    }
  }
}

fn do_post_mortem(task: planner_types.PlannerTask, ctx: AppraiserContext) -> Nil {
  let pm = case should_full_post_mortem(task, ctx) {
    False -> {
      // Deterministic: simple completed task → Achieved
      appraisal_types.deterministic_achieved(task.task_id, get_datetime())
    }
    True -> {
      // Full LLM evaluation
      case generate_post_mortem(task, ctx) {
        Ok(pm) -> pm
        Error(_) -> {
          // Fallback: deterministic based on status
          let verdict = case task.status {
            planner_types.Abandoned -> AbandonedWithLearnings
            planner_types.Failed -> NotAchieved
            _ -> Achieved
          }
          appraisal_types.PostMortem(
            task_id: task.task_id,
            verdict:,
            prediction_comparisons: [],
            lessons_learned: [],
            contributing_factors: [],
            created_at: get_datetime(),
          )
        }
      }
    }
  }

  // Persist
  let op = planner_types.AddPostMortem(task_id: task.task_id, post_mortem: pm)
  planner_log.append_task_op(ctx.planner_dir, op)
  librarian.notify_task_op(ctx.librarian, op)

  // Create CBR case from post-mortem
  create_cbr_case(task, pm, ctx)

  // Send sensory event
  case ctx.cognitive {
    None -> Nil
    Some(cog) -> {
      let verdict_str = appraisal_types.verdict_to_string(pm.verdict)
      process.send(
        cog,
        agent_types.QueuedSensoryEvent(event: agent_types.SensoryEvent(
          name: "post_mortem",
          title: task.title <> " — " <> verdict_str,
          body: "Task "
            <> task.task_id
            <> " post-mortem: "
            <> verdict_str
            <> case pm.lessons_learned {
            [first, ..] -> ". Key lesson: " <> first
            [] -> ""
          },
          fired_at: get_datetime(),
        )),
      )
      Nil
    }
  }

  slog.info(
    "narrative/appraiser",
    "do_post_mortem",
    "Post-mortem complete for "
      <> task.task_id
      <> ": "
      <> appraisal_types.verdict_to_string(pm.verdict),
    None,
  )
  Nil
}

fn generate_post_mortem(
  task: planner_types.PlannerTask,
  ctx: AppraiserContext,
) -> Result(PostMortem, String) {
  // Gather narrative entries for this task's cycles
  let narrative_context = case task.cycle_ids {
    [] -> ""
    ids -> {
      let entries = librarian.load_by_cycle_ids(ctx.librarian, ids)
      case entries {
        [] -> ""
        es ->
          "\n\nNarrative from task cycles:\n"
          <> string.join(list.map(es, fn(e) { "- " <> e.summary }), "\n")
      }
    }
  }

  // Build pre-mortem comparison context
  let pre_mortem_context = case task.pre_mortem {
    None -> ""
    Some(pm) ->
      "\n\nPre-mortem predictions:\n- Failure modes: "
      <> string.join(pm.failure_modes, "; ")
      <> "\n- Blind spots: "
      <> string.join(pm.blind_spot_assumptions, "; ")
      <> "\n- Dependencies at risk: "
      <> string.join(pm.dependencies_at_risk, "; ")
      <> "\n- Information gaps: "
      <> string.join(pm.information_gaps, "; ")
  }

  let steps_text =
    list.map(task.plan_steps, fn(s) {
      let check = case s.status {
        planner_types.Complete -> "[x]"
        _ -> "[ ]"
      }
      check <> " " <> int.to_string(s.index) <> ". " <> s.description
    })
    |> string.join("\n")

  let status_str = case task.status {
    planner_types.Complete -> "Complete"
    planner_types.Failed -> "Failed"
    planner_types.Abandoned -> "Abandoned"
    _ -> "Unknown"
  }

  let risks_text = case task.materialised_risks {
    [] -> "None materialised"
    rs -> string.join(rs, "; ")
  }

  let prompt =
    "Task: "
    <> task.title
    <> "\nStatus: "
    <> status_str
    <> "\nComplexity: "
    <> task.complexity
    <> "\nSteps:\n"
    <> steps_text
    <> "\nMaterialised risks: "
    <> risks_text
    <> narrative_context
    <> pre_mortem_context
    <> "\n\nEvaluate this task's outcome. Was the goal achieved? "
    <> "Compare pre-mortem predictions against what actually happened. "
    <> "What lessons were learned? What factors contributed to the outcome?"
    <> "\n\nVerdict must be one of: achieved, partially_achieved, not_achieved, abandoned_with_learnings"

  let schema_result =
    xstructor.compile_schema(
      paths.schemas_dir(),
      "post_mortem.xsd",
      schemas.post_mortem_xsd,
    )

  case schema_result {
    Error(e) -> Error("Schema compile failed: " <> e)
    Ok(schema) -> {
      let system =
        schemas.build_system_prompt(
          "You are a post-mortem analyst. Evaluate whether a task achieved its goal. Be honest — do not inflate success. If it was abandoned, focus on what was learned.",
          schemas.post_mortem_xsd,
          schemas.post_mortem_example,
        )
      let config =
        xstructor.XStructorConfig(
          schema:,
          system_prompt: system,
          xml_example: schemas.post_mortem_example,
          max_retries: 2,
          max_tokens: ctx.max_tokens,
        )
      case xstructor.generate(config, prompt, ctx.provider, ctx.model) {
        Error(e) -> Error("XStructor failed: " <> e)
        Ok(result) -> Ok(extract_post_mortem(result.elements, task.task_id))
      }
    }
  }
}

fn extract_post_mortem(
  elements: dict.Dict(String, String),
  task_id: String,
) -> PostMortem {
  let verdict_str = case dict.get(elements, "post_mortem.verdict") {
    Ok(v) -> v
    Error(_) -> "not_achieved"
  }
  let lessons =
    xstructor.extract_list(elements, "post_mortem.lessons_learned.lesson")
  let factors =
    xstructor.extract_list(elements, "post_mortem.contributing_factors.factor")
  let comparisons = extract_comparisons(elements, 0, [])

  appraisal_types.PostMortem(
    task_id:,
    verdict: appraisal_types.verdict_from_string(verdict_str),
    prediction_comparisons: comparisons,
    lessons_learned: lessons,
    contributing_factors: factors,
    created_at: get_datetime(),
  )
}

fn extract_comparisons(
  elements: dict.Dict(String, String),
  idx: Int,
  acc: List(appraisal_types.PredictionComparison),
) -> List(appraisal_types.PredictionComparison) {
  let prefix =
    "post_mortem.prediction_comparisons.comparison." <> int.to_string(idx)
  let pred_key = prefix <> ".prediction"
  let real_key = prefix <> ".reality"
  let acc_key = prefix <> ".accurate"
  case dict.get(elements, pred_key) {
    Error(_) -> acc
    Ok(prediction) -> {
      let reality = case dict.get(elements, real_key) {
        Ok(r) -> r
        Error(_) -> ""
      }
      let accurate = case dict.get(elements, acc_key) {
        Ok("true") -> True
        _ -> False
      }
      let comp =
        appraisal_types.PredictionComparison(prediction:, reality:, accurate:)
      extract_comparisons(elements, idx + 1, list.append(acc, [comp]))
    }
  }
}

// ---------------------------------------------------------------------------
// CBR case creation from post-mortem
// ---------------------------------------------------------------------------

fn create_cbr_case(
  task: planner_types.PlannerTask,
  pm: PostMortem,
  ctx: AppraiserContext,
) -> Nil {
  let category = case pm.verdict {
    NotAchieved | AbandonedWithLearnings -> Some(cbr_types.Pitfall)
    Achieved -> Some(cbr_types.Strategy)
    PartiallyAchieved -> Some(cbr_types.Troubleshooting)
  }

  let status_str = appraisal_types.verdict_to_string(pm.verdict)
  let confidence = case pm.verdict {
    Achieved -> 0.8
    PartiallyAchieved -> 0.6
    NotAchieved -> 0.7
    AbandonedWithLearnings -> 0.5
  }

  let steps_text =
    list.map(task.plan_steps, fn(s) { s.description })
    |> string.join("; ")
  let keywords =
    string.split(task.title, " ")
    |> list.filter(fn(w) { string.length(w) > 3 })
    |> list.map(string.lowercase)
    |> list.unique()

  let case_record =
    cbr_types.CbrCase(
      case_id: "cbr-appraisal-" <> generate_uuid(),
      timestamp: get_datetime(),
      schema_version: 1,
      problem: cbr_types.CbrProblem(
        user_input: task.title,
        intent: task.description,
        domain: task.complexity,
        entities: [],
        keywords:,
        query_complexity: task.complexity,
      ),
      solution: cbr_types.CbrSolution(
        approach: steps_text,
        agents_used: [],
        tools_used: [],
        steps: list.map(task.plan_steps, fn(s) { s.description }),
      ),
      outcome: cbr_types.CbrOutcome(
        status: status_str,
        confidence:,
        assessment: string.join(pm.lessons_learned, ". "),
        pitfalls: pm.contributing_factors,
      ),
      source_narrative_id: task.task_id,
      profile: None,
      redacted: False,
      category:,
      usage_stats: None,
      strategy_id: None,
    )

  cbr_log.append(ctx.cbr_dir, case_record)
  librarian.notify_new_case(ctx.librarian, case_record)
  Nil
}

// ---------------------------------------------------------------------------
// Endeavour post-mortem
// ---------------------------------------------------------------------------

/// Spawn a fire-and-forget endeavour post-mortem evaluation.
pub fn spawn_endeavour_post_mortem(
  endeavour: planner_types.Endeavour,
  ctx: AppraiserContext,
) -> Nil {
  case endeavour.post_mortem {
    Some(_) -> Nil
    None -> {
      let eid = endeavour.endeavour_id
      process.spawn_unlinked(fn() {
        do_endeavour_post_mortem(endeavour, ctx)
        Nil
      })
      slog.debug(
        "narrative/appraiser",
        "spawn_endeavour_post_mortem",
        "Spawned endeavour post-mortem for " <> eid,
        None,
      )
      Nil
    }
  }
}

fn do_endeavour_post_mortem(
  endeavour: planner_types.Endeavour,
  ctx: AppraiserContext,
) -> Nil {
  // Gather task post-mortems
  let task_verdicts =
    list.filter_map(endeavour.task_ids, fn(tid) {
      case librarian.get_task_by_id(ctx.librarian, tid) {
        Ok(task) ->
          case task.post_mortem {
            Some(pm) -> Ok(#(tid, pm.verdict))
            None ->
              // No post-mortem yet — infer from status
              case task.status {
                planner_types.Complete -> Ok(#(tid, Achieved))
                planner_types.Failed -> Ok(#(tid, NotAchieved))
                planner_types.Abandoned -> Ok(#(tid, AbandonedWithLearnings))
                _ -> Error(Nil)
              }
          }
        Error(_) -> Error(Nil)
      }
    })

  let criteria_text = case endeavour.success_criteria {
    [] -> "No explicit success criteria defined"
    cs -> "Success criteria:\n- " <> string.join(cs, "\n- ")
  }

  let task_summary =
    list.map(task_verdicts, fn(tv) {
      tv.0 <> ": " <> appraisal_types.verdict_to_string(tv.1)
    })
    |> string.join("\n- ")

  let status_str = case endeavour.status {
    planner_types.EndeavourComplete -> "Complete"
    planner_types.EndeavourFailed -> "Failed"
    planner_types.EndeavourAbandoned -> "Abandoned"
    _ -> "Other"
  }

  let prompt =
    "Endeavour: "
    <> endeavour.title
    <> "\nGoal: "
    <> endeavour.goal
    <> "\nStatus: "
    <> status_str
    <> "\n"
    <> criteria_text
    <> "\nTask outcomes:\n- "
    <> task_summary
    <> "\n\nSynthesise: was the endeavour's goal achieved? "
    <> "Evaluate each success criterion. What was learned across all tasks?"
    <> "\n\nVerdict must be one of: achieved, partially_achieved, not_achieved, abandoned_with_learnings"

  let schema_result =
    xstructor.compile_schema(
      paths.schemas_dir(),
      "endeavour_post_mortem.xsd",
      schemas.endeavour_post_mortem_xsd,
    )

  case schema_result {
    Error(e) -> {
      slog.warn(
        "narrative/appraiser",
        "do_endeavour_post_mortem",
        "Schema compile failed: " <> e,
        None,
      )
      Nil
    }
    Ok(schema) -> {
      let system =
        schemas.build_system_prompt(
          "You are an endeavour-level post-mortem analyst. Synthesise across multiple task outcomes to evaluate whether the endeavour achieved its goal.",
          schemas.endeavour_post_mortem_xsd,
          schemas.endeavour_post_mortem_example,
        )
      let config =
        xstructor.XStructorConfig(
          schema:,
          system_prompt: system,
          xml_example: schemas.endeavour_post_mortem_example,
          max_retries: 2,
          max_tokens: ctx.max_tokens,
        )
      case xstructor.generate(config, prompt, ctx.provider, ctx.model) {
        Error(e) -> {
          slog.warn(
            "narrative/appraiser",
            "do_endeavour_post_mortem",
            "XStructor failed: " <> e,
            None,
          )
          Nil
        }
        Ok(result) -> {
          let epm =
            extract_endeavour_post_mortem(
              result.elements,
              endeavour.endeavour_id,
              task_verdicts,
            )
          let op =
            planner_types.AddEndeavourPostMortem(
              endeavour_id: endeavour.endeavour_id,
              post_mortem: epm,
            )
          planner_log.append_endeavour_op(ctx.planner_dir, op)
          librarian.notify_endeavour_op(ctx.librarian, op)

          // Sensory event
          case ctx.cognitive {
            None -> Nil
            Some(cog) -> {
              let verdict_str = appraisal_types.verdict_to_string(epm.verdict)
              process.send(
                cog,
                agent_types.QueuedSensoryEvent(event: agent_types.SensoryEvent(
                  name: "endeavour_post_mortem",
                  title: endeavour.title <> " — " <> verdict_str,
                  body: epm.synthesis,
                  fired_at: get_datetime(),
                )),
              )
              Nil
            }
          }

          slog.info(
            "narrative/appraiser",
            "do_endeavour_post_mortem",
            "Endeavour post-mortem complete for "
              <> endeavour.endeavour_id
              <> ": "
              <> appraisal_types.verdict_to_string(epm.verdict),
            None,
          )
          Nil
        }
      }
    }
  }
}

fn extract_endeavour_post_mortem(
  elements: dict.Dict(String, String),
  endeavour_id: String,
  task_verdicts: List(#(String, AppraisalVerdict)),
) -> EndeavourPostMortem {
  let verdict_str = case dict.get(elements, "endeavour_post_mortem.verdict") {
    Ok(v) -> v
    Error(_) -> "not_achieved"
  }
  let goal_achieved = case
    dict.get(elements, "endeavour_post_mortem.goal_achieved")
  {
    Ok("true") -> True
    _ -> False
  }
  let synthesis = case dict.get(elements, "endeavour_post_mortem.synthesis") {
    Ok(s) -> s
    Error(_) -> ""
  }

  appraisal_types.EndeavourPostMortem(
    endeavour_id:,
    verdict: appraisal_types.verdict_from_string(verdict_str),
    goal_achieved:,
    criteria_results: [],
    task_verdicts:,
    synthesis:,
    created_at: get_datetime(),
  )
}
