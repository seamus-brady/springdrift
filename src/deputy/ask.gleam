//// Deputy ask-for-help (Phase 2). When a specialist agent calls
//// `ask_deputy(question, context?)`, the deputy forwards the question
//// to this module. It runs a small LLM call that answers concisely
//// from memory, or returns a short "I don't know" that the framework
//// converts into an `unanswered` sensory event.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import gleam/string
import llm/provider.{type Provider}
import llm/request
import llm/response
import narrative/librarian.{type LibrarianMessage}

pub type AskAnswer {
  /// The deputy believes it has a useful answer.
  Answered(text: String)
  /// The deputy honestly can't help. Triggers `unanswered` escalation.
  Unanswered(reason: String)
}

/// Ask the deputy to answer a question from memory.
///
/// In MVP this is a single LLM call with a compact prompt. Phase 3 may
/// upgrade to a react loop with read-only memory tools so the deputy
/// can actively search before answering.
pub fn answer(
  question: String,
  context: String,
  root_agent: String,
  briefing_context: String,
  provider: Provider,
  model: String,
  max_tokens: Int,
  _librarian: Option(Subject(LibrarianMessage)),
) -> AskAnswer {
  let q = string.trim(question)
  case q {
    "" -> Unanswered("empty question")
    _ -> {
      let req =
        request.new(model, max_tokens)
        |> request.with_system(system_prompt(root_agent, briefing_context))
        |> request.with_user_message(build_user_prompt(q, context))
      case provider.chat(req) {
        Error(e) -> Unanswered("llm error: " <> response.error_message(e))
        Ok(resp) -> {
          let text = string.trim(response.text(resp))
          case text {
            "" -> Unanswered("empty response")
            _ ->
              case looks_like_dont_know(text) {
                True ->
                  Unanswered("deputy declined: " <> string.slice(text, 0, 200))
                False -> Answered(text)
              }
          }
        }
      }
    }
  }
}

fn system_prompt(root_agent: String, briefing_context: String) -> String {
  "You are a deputy serving a "
  <> root_agent
  <> " specialist delegation. You are
read-only, ephemeral, and serving one hierarchy. When the specialist asks
you a question mid-task, answer concisely from memory or admit you don't
know.

Rules:
- Cite specific sources (case_id, fact key, or cycle_id) when available.
- Keep your answer to 1-3 sentences.
- If you don't have a memory-grounded answer, say so plainly — start the
  response with the literal phrase 'I don't know'. Do not fabricate.
- Do not instruct the specialist to take specific actions. Observe, don't
  direct.

Your briefing context for this hierarchy:
"
  <> briefing_context
}

fn build_user_prompt(question: String, context: String) -> String {
  case string.trim(context) {
    "" -> question
    c -> question <> "\n\nContext: " <> c
  }
}

fn looks_like_dont_know(text: String) -> Bool {
  let lower = string.lowercase(string.trim(text))
  string.starts_with(lower, "i don't know")
  || string.starts_with(lower, "i do not know")
  || string.starts_with(lower, "unanswered")
}
