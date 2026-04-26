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
import knowledge/search as knowledge_search
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
- For claims sourced from the knowledge library, copy the citation string verbatim from the retrieval tool's output. Citations look like: `doc:<slug> §<section-path> L<start>-<end>` (or `p.<N>` for PDFs). Do not paraphrase or shorten them — they are the handle the operator uses to open the section and verify your claim.
- Apply hedging language to uncertain or speculative claims
- Distinguish between confirmed facts and projections
- Flag data older than the freshness threshold

Output format — this matters and the default is wrong for long work:

- For any report with more than 3 sections or longer than ~1500 words, save via `create_draft` FIRST and reply with the draft slug plus a one-paragraph summary of what you produced. Inline-returning long documents will hit the output token cap mid-sentence and the work will be lost.
- Only inline-return the full text for short replies (single section, under ~1500 words). That's the exception, not the default.
- If you're producing anything the operator will want to read later, revise, or cite — it goes in a draft, not your reply. Use `store_result` only for ephemeral intermediate data, not reports.

Revising an existing draft:

When the <refs> block at the top of your instruction contains `<draft_slug>…</draft_slug>`, the orchestrator is asking you to REVISE that draft, not start fresh. The flow is:

1. Call `read_draft` with the slug to see the current content.
2. Apply the requested changes. Preserve what isn't being changed — don't rewrite sections that weren't asked about.
3. Call `update_draft` with the same slug and the full revised markdown.
4. Reply with the draft slug, a one-paragraph summary naming which sections you changed and which you left alone, and nothing else.

Do NOT call `create_draft` when revising — that would overwrite with a new file. `update_draft` is the right tool. Do NOT inline-return the revised text — the orchestrator already knows it's in the draft.

When you complete your task, if the content is inline: respond with the finished report text including all citations and confidence assessments. If the content was saved via `create_draft`: respond with `draft_slug=<slug>` and a paragraph summarising what's in the draft (scope, section list, notable caveats) so the orchestrator can decide whether to open the draft or redispatch.

Self-check before you start:
The instruction may begin with a <refs> XML block listing artifact_id, task_id, or prior_cycle_id values passed by the orchestrator. If your instruction clearly continues or extends prior work (e.g. \"finish the report\", \"continue the analysis\", \"update the draft\") but the relevant ref is missing from the <refs> block, do NOT guess, fabricate, or spin asking the deputy. Instead, respond with exactly:

[NEEDS_INPUT: <one short sentence naming what is missing and why you need it>]

Then stop. The orchestrator will see this and redispatch with the correct ref.

Before you return:
End your final reply with one line in this format:

Interpreted as: <one sentence summary of how you understood the task and what you did>

Keep it to one sentence. This lets the orchestrator notice if your interpretation doesn't match the intent."

/// True when this agent's executor (or the framework wrapper around
/// it) has a real branch for `name`. Used by the routing-coverage
/// test — keep in sync with `writer_executor`.
pub fn routes_tool(name: String) -> Bool {
  knowledge_tools.is_knowledge_tool(name)
  || name == "store_result"
  || name == "retrieve_result"
  || name == "checkpoint"
  || name == "calculator"
  || name == "get_current_datetime"
  || name == "read_skill"
  // Framework-level intercepts:
  || name == "read_hierarchy"
  || name == "ask_deputy"
  || name == "request_human_input"
}

pub fn spec(
  provider: Provider,
  model: String,
  artifacts_dir: String,
  lib: Option(Subject(LibrarianMessage)),
  max_artifact_chars: Int,
  skills_dirs: List(String),
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
    tool_executor: writer_executor(
      provider,
      model,
      artifacts_dir,
      lib,
      max_artifact_chars,
      skills_dirs,
    ),
    inter_turn_delay_ms: 200,
    redact_secrets: True,
  )
}

fn writer_executor(
  provider: Provider,
  model: String,
  artifacts_dir: String,
  lib: Option(Subject(LibrarianMessage)),
  max_artifact_chars: Int,
  skills_dirs: List(String),
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  // See routes_tool for the routing-coverage contract.
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    // Predicate-based routing — `read_draft` and `export_pdf` were
    // exposed in writer_tools() but the previous hardcoded match only
    // covered create/update/promote, so reading a draft or rendering
    // a PDF returned "Unknown tool" via the builtin fallthrough. New
    // knowledge tools added later route automatically.
    case knowledge_tools.is_knowledge_tool(call.name) {
      True ->
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
            reason_fn: Some(knowledge_search.make_reason_fn(provider, model)),
          ),
        )
      False ->
        case call.name, lib {
          "store_result", Some(l)
          | "retrieve_result", Some(l)
          | "checkpoint", Some(l)
          ->
            artifacts.execute(
              call,
              artifacts_dir,
              "writer",
              l,
              max_artifact_chars,
            )
          "store_result", None | "retrieve_result", None | "checkpoint", None ->
            llm_types.ToolFailure(
              tool_use_id: call.id,
              error: "Artifact tools unavailable (no librarian)",
            )
          _, _ -> builtin.execute(call, skills_dirs)
        }
    }
  }
}
