// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import narrative/librarian.{type LibrarianMessage}
import paths
import tools/artifacts
import tools/builtin
import tools/knowledge as knowledge_tools

const system_prompt = "You are a writer agent within a multi-agent system. You receive instructions from the orchestrating agent, not directly from the user.

Your job is to synthesise research findings into structured, well-cited reports.

You have access to: calculator, get_current_datetime, read_skill.

When writing reports:
- Structure content with clear sections and headings
- Cite sources inline with name, date, and URL where available
- Apply hedging language to uncertain or speculative claims
- Distinguish between confirmed facts and projections
- Flag data older than the freshness threshold

Output format — this matters and the default is wrong for long work:

- For any report with more than 3 sections or longer than ~1500 words, save via `create_draft` FIRST and reply with the draft slug plus a one-paragraph summary of what you produced. Inline-returning long documents will hit the output token cap mid-sentence and the work will be lost.
- Only inline-return the full text for short replies (single section, under ~1500 words). That's the exception, not the default.
- If you're producing anything the operator will want to read later, revise, or cite — it goes in a draft, not your reply. Use `store_result` only for ephemeral intermediate data, not reports.

When you complete your task, if the content is inline: respond with the finished report text including all citations and confidence assessments. If the content was saved via `create_draft`: respond with `draft_slug=<slug>` and a paragraph summarising what's in the draft (scope, section list, notable caveats) so the orchestrator can decide whether to open the draft or redispatch.

Self-check before you start:
The instruction may begin with a <refs> XML block listing artifact_id, task_id, or prior_cycle_id values passed by the orchestrator. If your instruction clearly continues or extends prior work (e.g. \"finish the report\", \"continue the analysis\", \"update the draft\") but the relevant ref is missing from the <refs> block, do NOT guess, fabricate, or spin asking the deputy. Instead, respond with exactly:

[NEEDS_INPUT: <one short sentence naming what is missing and why you need it>]

Then stop. The orchestrator will see this and redispatch with the correct ref.

Before you return:
End your final reply with one line in this format:

Interpreted as: <one sentence summary of how you understood the task and what you did>

Keep it to one sentence. This lets the orchestrator notice if your interpretation doesn't match the intent."

pub fn spec(
  provider: Provider,
  model: String,
  artifacts_dir: String,
  lib: Option(Subject(LibrarianMessage)),
  max_artifact_chars: Int,
) -> AgentSpec {
  let tools =
    list.flatten([
      knowledge_tools.writer_tools(),
      artifacts.all(),
      builtin.agent_tools(),
    ])

  AgentSpec(
    name: "writer",
    human_name: "Writer",
    description: "Synthesise research findings into structured, well-cited reports. Applies hedging language to uncertain claims, flags stale data, and distinguishes confirmed facts from projections.",
    system_prompt:,
    provider:,
    model:,
    max_tokens: 4096,
    max_turns: 5,
    max_consecutive_errors: 2,
    max_context_messages: None,
    tools:,
    restart: Permanent,
    tool_executor: writer_executor(artifacts_dir, lib, max_artifact_chars),
    inter_turn_delay_ms: 200,
    redact_secrets: True,
  )
}

fn writer_executor(
  artifacts_dir: String,
  lib: Option(Subject(LibrarianMessage)),
  max_artifact_chars: Int,
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case call.name {
      "create_draft" | "update_draft" | "promote_draft" ->
        knowledge_tools.execute(
          call,
          knowledge_tools.KnowledgeConfig(
            knowledge_dir: paths.knowledge_dir(),
            indexes_dir: paths.knowledge_indexes_dir(),
            sources_dir: paths.knowledge_sources_dir(),
            journal_dir: paths.knowledge_journal_dir(),
            notes_dir: paths.knowledge_notes_dir(),
            drafts_dir: paths.knowledge_drafts_dir(),
            exports_dir: paths.knowledge_exports_dir(),
            embed_fn: None,
          ),
        )
      _ ->
        case call.name, lib {
          "store_result", Some(l) | "retrieve_result", Some(l) ->
            artifacts.execute(
              call,
              artifacts_dir,
              "writer",
              l,
              max_artifact_chars,
            )
          "store_result", None | "retrieve_result", None ->
            llm_types.ToolFailure(
              tool_use_id: call.id,
              error: "Artifact tools unavailable (no librarian)",
            )
          _, _ -> builtin.execute(call)
        }
    }
  }
}
