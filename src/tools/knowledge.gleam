//// Knowledge tools — document library operations for the cognitive loop
//// and researcher/writer agents.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import knowledge/indexer
import knowledge/log as knowledge_log
import knowledge/search
import knowledge/types
import knowledge/workspace
import llm/tool
import llm/types as llm_types
import paths
import sandbox/podman_ffi
import slog

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "sha256_hex")
fn sha256_hex(input: String) -> String

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Hard cap on a single `read_range` call. Keeps a runaway request from
/// flooding the agent's context window with thousands of lines. Operators
/// who legitimately need more should chunk into multiple calls.
pub const read_range_max_lines: Int = 2000

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn cognitive_tools() -> List(llm_types.Tool) {
  [
    list_documents_tool(),
    list_intray_tool(),
    write_journal_tool(),
    write_note_tool(),
    read_note_tool(),
    approve_export_tool(),
    reject_export_tool(),
  ]
}

pub fn researcher_tools() -> List(llm_types.Tool) {
  [
    search_library_tool(),
    document_info_tool(),
    list_sections_tool(),
    read_section_by_id_tool(),
    read_range_tool(),
    save_to_library_tool(),
  ]
}

pub fn writer_tools() -> List(llm_types.Tool) {
  [
    create_draft_tool(),
    read_draft_tool(),
    update_draft_tool(),
    promote_draft_tool(),
    export_pdf_tool(),
  ]
}

fn list_documents_tool() -> llm_types.Tool {
  tool.new("list_documents")
  |> tool.with_description(
    "List documents in the knowledge library. Filter by type (source, journal, note, draft, export) or domain.",
  )
  |> tool.add_string_param(
    "type",
    "Filter by type: source, journal, note, draft, export (optional)",
    False,
  )
  |> tool.add_string_param("domain", "Filter by domain (optional)", False)
  |> tool.build()
}

fn list_intray_tool() -> llm_types.Tool {
  tool.new("list_intray")
  |> tool.with_description(
    "List files currently in the knowledge intray — uploads or "
    <> "email attachments waiting to be normalised into sources/. "
    <> "Returns each file with its size, deposit time, and whether "
    <> "intake.process has converted it. Use when the operator "
    <> "mentions an upload that hasn't shown up in the library, or "
    <> "when the sensorium reports pending intray entries.",
  )
  |> tool.build()
}

fn write_journal_tool() -> llm_types.Tool {
  tool.new("write_journal")
  |> tool.with_description(
    "Append a freeform entry to today's journal. Use for reflections, observations, and session notes — not every cycle, but when something is worth recording.",
  )
  |> tool.add_string_param("content", "The journal entry (markdown)", True)
  |> tool.build()
}

fn write_note_tool() -> llm_types.Tool {
  tool.new("write_note")
  |> tool.with_description(
    "Create or update a working note. Use for scratch documents, running lists, research notes, comparison tables. Persists across sessions.",
  )
  |> tool.add_string_param(
    "slug",
    "Note identifier (creates if new, updates if exists)",
    True,
  )
  |> tool.add_string_param(
    "content",
    "Full note content in markdown (replaces on update)",
    True,
  )
  |> tool.build()
}

fn read_note_tool() -> llm_types.Tool {
  tool.new("read_note")
  |> tool.with_description("Read a working note by its slug identifier.")
  |> tool.add_string_param("slug", "The note identifier", True)
  |> tool.build()
}

fn search_library_tool() -> llm_types.Tool {
  tool.new("search_library")
  |> tool.with_description(
    "Search the document library for relevant passages. Returns "
    <> "ranked results with provenance (document, section, line/page). "
    <> "Use embedding mode (default) for semantic search, keyword for "
    <> "exact phrases.\n\nBy default, results exclude Promoted exports "
    <> "awaiting operator approval and Rejected exports (never "
    <> "citeable). Set include_pending=true to see Promoted exports "
    <> "in results — useful when deciding whether to continue revising "
    <> "a draft, not useful for citation.",
  )
  |> tool.add_string_param("query", "The search query", True)
  |> tool.add_string_param(
    "mode",
    "Search mode. `keyword` (exact phrases), `embedding` (semantic, "
      <> "default), or `reasoning` (LLM reasons over all sections — "
      <> "slower and costs a model call, use only when embedding "
      <> "misses). Modes `keyword` and `embedding` auto-escalate to "
      <> "reasoning when they return no results, if the instance has "
      <> "an LLM configured for tier-3 retrieval.",
    False,
  )
  |> tool.add_integer_param(
    "max_results",
    "Maximum results (1-20, default 5)",
    False,
  )
  |> tool.add_string_param("domain", "Filter by domain (optional)", False)
  |> tool.add_boolean_param(
    "include_pending",
    "Include Promoted-but-not-yet-Approved exports in results. Default false.",
    False,
  )
  |> tool.build()
}

fn document_info_tool() -> llm_types.Tool {
  tool.new("document_info")
  |> tool.with_description(
    "Inspect a document's shape before deciding how to read it. "
    <> "Returns title, total line count, top-level section count, and a "
    <> "structured-vs-flat signal. Call this FIRST when you receive a new "
    <> "doc_id and don't yet know whether it has chapters/sections or is "
    <> "a single block of text. Cheap — no LLM, no embedding, just metadata.",
  )
  |> tool.add_string_param("doc_id", "Document identifier", True)
  |> tool.build()
}

fn list_sections_tool() -> llm_types.Tool {
  tool.new("list_sections")
  |> tool.with_description(
    "Enumerate the section tree of a structured document. Returns a flat "
    <> "list of (section_id, title, depth, path, line span) for each node. "
    <> "Use after `document_info` confirms the document is structured. "
    <> "Pick a section_id from the result and pass it to "
    <> "`read_section_by_id` — that's how you avoid the silent-wrong-answer "
    <> "mode of substring-matching titles. Returns an empty list for flat "
    <> "documents (no headings detected); use `read_range` for those.",
  )
  |> tool.add_string_param("doc_id", "Document identifier", True)
  |> tool.add_integer_param(
    "max_depth",
    "Optional cap on tree depth (e.g. 1 = chapters only, 2 = chapters + "
      <> "sections). Omit for the full tree.",
    False,
  )
  |> tool.build()
}

fn read_section_by_id_tool() -> llm_types.Tool {
  tool.new("read_section_by_id")
  |> tool.with_description(
    "Read a specific section by its exact UUID from `list_sections`. "
    <> "Does NOT do fuzzy title matching — pass a real section_id or get "
    <> "an error. This is the safe sibling of the old `read_section` tool, "
    <> "which substring-matched titles and could silently return the wrong "
    <> "section. Returns the section's content with a structured citation.",
  )
  |> tool.add_string_param("doc_id", "Document identifier", True)
  |> tool.add_string_param(
    "section_id",
    "Exact section UUID from `list_sections`",
    True,
  )
  |> tool.build()
}

fn read_range_tool() -> llm_types.Tool {
  tool.new("read_range")
  |> tool.with_description(
    "Read a line range from a document's source markdown. The universal "
    <> "primitive — works on any document, structured or flat. Use for "
    <> "documents with no section tree (memos, scraped pages, OCR output) "
    <> "or to read context around a search hit's line span. "
    <> "Lines are 1-indexed and inclusive. Capped at "
    <> int.to_string(read_range_max_lines)
    <> " lines per call to keep "
    <> "context windows sane — chunk larger reads into multiple calls.",
  )
  |> tool.add_string_param("doc_id", "Document identifier", True)
  |> tool.add_integer_param(
    "start_line",
    "First line to read (1-indexed)",
    True,
  )
  |> tool.add_integer_param(
    "end_line",
    "Last line to read (inclusive, 1-indexed). Clamped to total document length.",
    True,
  )
  |> tool.build()
}

fn save_to_library_tool() -> llm_types.Tool {
  tool.new("save_to_library")
  |> tool.with_description(
    "Save content as a permanent knowledge source. Use for papers, articles, and reference material worth keeping. The content is indexed into a searchable tree structure.",
  )
  |> tool.add_string_param("content", "The document content in markdown", True)
  |> tool.add_string_param(
    "domain",
    "Classification domain (e.g. legal, research, finance)",
    True,
  )
  |> tool.add_string_param("title", "Document title", True)
  |> tool.add_string_param(
    "source_url",
    "Original source URL (optional)",
    False,
  )
  |> tool.build()
}

fn create_draft_tool() -> llm_types.Tool {
  tool.new("create_draft")
  |> tool.with_description(
    "Create a new draft report. Drafts can be revised over multiple sessions before being promoted to exports.",
  )
  |> tool.add_string_param("slug", "Draft identifier", True)
  |> tool.add_string_param("content", "Draft content in markdown", True)
  |> tool.build()
}

fn read_draft_tool() -> llm_types.Tool {
  tool.new("read_draft")
  |> tool.with_description(
    "Read an existing draft by slug. Use this before `update_draft` "
    <> "when you've been asked to revise a prior draft — you need to "
    <> "see what's currently in it before producing the revised "
    <> "version. The draft is returned as-is (full markdown).",
  )
  |> tool.add_string_param("slug", "Draft identifier to read", True)
  |> tool.build()
}

fn update_draft_tool() -> llm_types.Tool {
  tool.new("update_draft")
  |> tool.with_description("Revise an existing draft report.")
  |> tool.add_string_param("slug", "Draft identifier", True)
  |> tool.add_string_param(
    "content",
    "Updated draft content (replaces previous content)",
    True,
  )
  |> tool.build()
}

fn promote_draft_tool() -> llm_types.Tool {
  tool.new("promote_draft")
  |> tool.with_description(
    "Promote a draft to an export. The draft content is copied to "
    <> "exports/ and marked with status=Promoted (pending operator "
    <> "approval). Promoted exports are NOT cited by search_library by "
    <> "default — they become canonical only after the operator runs "
    <> "approve_export.",
  )
  |> tool.add_string_param("slug", "Draft identifier to promote", True)
  |> tool.build()
}

fn export_pdf_tool() -> llm_types.Tool {
  tool.new("export_pdf")
  |> tool.with_description(
    "Render a promoted export from markdown to PDF. The PDF lands "
    <> "alongside the markdown in exports/<slug>.pdf. Requires the "
    <> "host to have pandoc and tectonic installed; if either is "
    <> "missing the tool returns a clear install hint. Only call "
    <> "this on slugs that have already been promoted — drafts have "
    <> "no exports/<slug>.md yet, so the call would fail with a "
    <> "confusing 'no input' error. Generation runs synchronously "
    <> "(typically 1-5s for a real document) so do not call it "
    <> "speculatively. Re-running on the same slug overwrites the "
    <> "PDF — useful after a re-promote.",
  )
  |> tool.add_string_param(
    "slug",
    "Promoted-export slug. The markdown at exports/<slug>.md is "
      <> "the input; the output is exports/<slug>.pdf.",
    True,
  )
  |> tool.build()
}

fn approve_export_tool() -> llm_types.Tool {
  tool.new("approve_export")
  |> tool.with_description(
    "Operator tool: approve a Promoted export so it becomes canonical "
    <> "and citeable by search_library. Only call this when the "
    <> "operator has explicitly asked you to approve the export. "
    <> "Agents must not self-approve their own drafts.",
  )
  |> tool.add_string_param("slug", "Export slug (same as the draft)", True)
  |> tool.add_string_param(
    "note",
    "Optional approval note (recorded in the audit log)",
    False,
  )
  |> tool.build()
}

fn reject_export_tool() -> llm_types.Tool {
  tool.new("reject_export")
  |> tool.with_description(
    "Operator tool: reject a Promoted export. Records the reason and "
    <> "marks the export as Rejected (never citeable). The draft "
    <> "itself is untouched and can be revised and re-promoted. Only "
    <> "call when the operator has explicitly asked you to reject.",
  )
  |> tool.add_string_param("slug", "Export slug", True)
  |> tool.add_string_param(
    "reason",
    "Short reason for rejection (required; appears in the audit log)",
    True,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Tool name checks
// ---------------------------------------------------------------------------

pub fn is_knowledge_tool(name: String) -> Bool {
  name == "list_documents"
  || name == "list_intray"
  || name == "write_journal"
  || name == "write_note"
  || name == "read_note"
  || name == "search_library"
  || name == "document_info"
  || name == "list_sections"
  || name == "read_section_by_id"
  || name == "read_range"
  || name == "save_to_library"
  || name == "create_draft"
  || name == "read_draft"
  || name == "update_draft"
  || name == "promote_draft"
  || name == "approve_export"
  || name == "reject_export"
  || name == "export_pdf"
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub type KnowledgeConfig {
  KnowledgeConfig(
    knowledge_dir: String,
    indexes_dir: String,
    sources_dir: String,
    journal_dir: String,
    notes_dir: String,
    drafts_dir: String,
    exports_dir: String,
    embed_fn: Option(fn(String) -> Result(List(Float), String)),
    /// Tier 3 reasoning retrieval. When set, search_library falls back
    /// to an LLM reason-over-tree pass when keyword + embedding return
    /// nothing. None disables tier 3 (keyword + embedding only).
    reason_fn: Option(fn(String) -> Result(String, String)),
  )
}

pub fn execute(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  slog.debug("knowledge", "execute", "tool=" <> call.name, None)
  case call.name {
    "list_documents" -> run_list_documents(call, cfg)
    "list_intray" -> run_list_intray(call, cfg)
    "write_journal" -> run_write_journal(call, cfg)
    "write_note" -> run_write_note(call, cfg)
    "read_note" -> run_read_note(call, cfg)
    "search_library" -> run_search_library(call, cfg)
    "document_info" -> run_document_info(call, cfg)
    "list_sections" -> run_list_sections(call, cfg)
    "read_section_by_id" -> run_read_section_by_id(call, cfg)
    "read_range" -> run_read_range(call, cfg)
    "save_to_library" -> run_save_to_library(call, cfg)
    "create_draft" -> run_create_draft(call, cfg)
    "read_draft" -> run_read_draft(call, cfg)
    "update_draft" -> run_update_draft(call, cfg)
    "promote_draft" -> run_promote_draft(call, cfg)
    "approve_export" -> run_approve_export(call, cfg)
    "reject_export" -> run_reject_export(call, cfg)
    "export_pdf" -> run_export_pdf(call, cfg)
    _ ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Unknown tool: " <> call.name,
      )
  }
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

fn run_list_documents(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use type_str <- decode.optional_field("type", "", decode.string)
    use domain <- decode.optional_field("domain", "", decode.string)
    decode.success(#(type_str, domain))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(tool_use_id: call.id, error: "Invalid input")
    Ok(#(type_str, domain)) -> {
      let docs = knowledge_log.resolve(cfg.knowledge_dir)
      let filtered = case type_str {
        "" -> docs
        t ->
          case types.doc_type_from_string(t) {
            Ok(dt) -> list.filter(docs, fn(m) { m.doc_type == dt })
            Error(_) -> docs
          }
      }
      let filtered2 = case domain {
        "" -> filtered
        d -> list.filter(filtered, fn(m) { m.domain == d })
      }
      let lines =
        list.map(filtered2, fn(m) {
          types.doc_type_to_string(m.doc_type)
          <> " | "
          <> m.domain
          <> " | "
          <> m.title
          <> " ["
          <> types.doc_status_to_string(m.status)
          <> "] (id: "
          <> m.doc_id
          <> ")"
        })
      let result = case lines {
        [] -> "No documents found."
        _ ->
          int.to_string(list.length(lines))
          <> " document(s):\n"
          <> string.join(lines, "\n")
      }
      llm_types.ToolSuccess(tool_use_id: call.id, content: result)
    }
  }
}

/// Discoverability tool for files waiting in the intray. The
/// presence of a file there means it has not yet been normalised
/// (intake.process removes files on success). So this list answers
/// the operator's "I uploaded X — where is it?" without needing a
/// new normalisation-status field.
fn run_list_intray(
  call: llm_types.ToolCall,
  _cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let intray = paths.knowledge_intray_dir()
  case simplifile.read_directory(intray) {
    Error(_) ->
      // Dir doesn't exist (yet) — treat as empty rather than failing.
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Intray is empty (no pending files).",
      )
    Ok(files) ->
      case files {
        [] ->
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Intray is empty (no pending files).",
          )
        _ -> {
          let lines =
            list.map(files, fn(filename) {
              let size = file_size(intray <> "/" <> filename)
              filename <> " (" <> format_bytes(size) <> ")"
            })
          let header =
            int.to_string(list.length(files)) <> " file(s) pending in intray:\n"
          let footer =
            "\n\nFiles sit here until intake.process normalises them. "
            <> "If a file is stuck, the binary needed to convert it "
            <> "may not be installed on the host (e.g. unpdf for "
            <> ".pdf, pandoc for .docx/.epub/.html). "
            <> "The deposit handler logs a specific failure reason; "
            <> "check the operator chat for the upload result."
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: header <> string.join(lines, "\n") <> footer,
          )
        }
      }
  }
}

/// Format byte counts as human-friendly. Used by list_intray and
/// nowhere else for now — kept local so it doesn't proliferate.
fn format_bytes(n: Int) -> String {
  case n {
    n if n < 1024 -> int.to_string(n) <> " B"
    n if n < 1_048_576 -> int.to_string(n / 1024) <> " KB"
    n -> int.to_string(n / 1_048_576) <> " MB"
  }
}

@external(erlang, "springdrift_ffi", "file_size")
fn file_size(path: String) -> Int

fn run_write_journal(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use content <- decode.field("content", decode.string)
    decode.success(content)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(tool_use_id: call.id, error: "Missing content")
    Ok(content) ->
      case workspace.write_journal(cfg.journal_dir, content) {
        Ok(_) ->
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Journal entry written.",
          )
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
      }
  }
}

fn run_write_note(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use slug <- decode.field("slug", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(#(slug, content))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Missing slug or content",
      )
    Ok(#(slug, content)) ->
      case workspace.write_note(cfg.notes_dir, slug, content) {
        Ok(_) ->
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Note '" <> slug <> "' saved.",
          )
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
      }
  }
}

fn run_read_note(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use slug <- decode.field("slug", decode.string)
    decode.success(slug)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(tool_use_id: call.id, error: "Missing slug")
    Ok(slug) ->
      case workspace.read_note(cfg.notes_dir, slug) {
        Ok(content) -> llm_types.ToolSuccess(tool_use_id: call.id, content:)
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
      }
  }
}

fn run_search_library(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use query <- decode.field("query", decode.string)
    use mode_str <- decode.optional_field("mode", "embedding", decode.string)
    use max <- decode.optional_field("max_results", 5, decode.int)
    use domain <- decode.optional_field("domain", "", decode.string)
    use include_pending <- decode.optional_field(
      "include_pending",
      False,
      decode.bool,
    )
    decode.success(#(query, mode_str, max, domain, include_pending))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(tool_use_id: call.id, error: "Missing query")
    Ok(#(query, mode_str, max_results, domain, include_pending)) -> {
      let mode = case mode_str {
        "keyword" -> search.Keyword
        "reasoning" -> search.Reasoning
        _ -> search.Embedding
      }
      let domain_filter = case domain {
        "" -> None
        d -> Some(d)
      }
      let all_docs = knowledge_log.resolve(cfg.knowledge_dir)
      // Approval gate: Rejected exports are never citeable; Promoted
      // exports (pending operator approval) are excluded unless the
      // caller explicitly opts in with include_pending=true. Sources,
      // drafts, notes, and other non-export types are unaffected.
      let docs =
        list.filter(all_docs, fn(m) {
          case m.doc_type, m.status {
            types.Export, types.Rejected -> False
            types.Export, types.Promoted -> include_pending
            _, _ -> True
          }
        })
      let cap = int.min(20, int.max(1, max_results))
      // Tier 3 logic:
      //   mode=reasoning  → skip tiers 1/2, go straight to LLM
      //   mode=keyword/embedding → run tier 1 or 2; if empty AND
      //     reason_fn is available, auto-escalate to tier 3
      //   (no reason_fn configured → behaves exactly as before)
      let results = case mode, cfg.reason_fn {
        search.Reasoning, Some(rf) ->
          search.reason_over_documents(query, docs, cfg.indexes_dir, rf, cap)
        search.Reasoning, None -> {
          // Caller asked for reasoning but the instance doesn't have
          // an LLM wired up — fall back to embedding/keyword rather
          // than returning nothing unhelpful.
          search.search(
            query,
            docs,
            cfg.indexes_dir,
            search.Embedding,
            cap,
            domain_filter,
            None,
            cfg.embed_fn,
          )
        }
        _, _ -> {
          let initial =
            search.search(
              query,
              docs,
              cfg.indexes_dir,
              mode,
              cap,
              domain_filter,
              None,
              cfg.embed_fn,
            )
          case initial, cfg.reason_fn {
            [], Some(rf) -> {
              slog.info(
                "knowledge",
                "search_library",
                "Tiers 1/2 returned no results — escalating to Tier 3 reasoning",
                None,
              )
              search.reason_over_documents(
                query,
                docs,
                cfg.indexes_dir,
                rf,
                cap,
              )
            }
            _, _ -> initial
          }
        }
      }
      let formatted = case results {
        [] -> "No results found."
        _ ->
          list.index_map(results, fn(r, i) {
            int.to_string(i + 1)
            <> ". "
            <> search.format_result(r)
            <> "\n   Citation: "
            <> search.format_citation(r)
          })
          |> string.join("\n\n")
      }
      llm_types.ToolSuccess(tool_use_id: call.id, content: formatted)
    }
  }
}

// ---------------------------------------------------------------------------
// document_info / list_sections / read_section_by_id / read_range
//
// These four tools replace the old `read_section` (substring-matching on
// section titles), which could silently return the wrong section when a
// short query matched multiple node titles. The new flow is two-step for
// structured docs (list → read by id) and one-step for flat docs (read
// by line range), with `document_info` as the cheap "what kind of doc is
// this?" probe.
// ---------------------------------------------------------------------------

/// Look up a DocumentMeta by doc_id. Used by every tool below to resolve
/// the markdown source path and the citation slug. Returns Error with a
/// user-readable message when the doc_id isn't in the knowledge log.
fn lookup_meta(
  cfg: KnowledgeConfig,
  doc_id: String,
) -> Result(types.DocumentMeta, String) {
  let docs = knowledge_log.resolve(cfg.knowledge_dir)
  case list.find(docs, fn(m: types.DocumentMeta) { m.doc_id == doc_id }) {
    Ok(meta) -> Ok(meta)
    Error(_) -> Error("Document not found: " <> doc_id)
  }
}

/// Read the source markdown for a document. The `path` field on
/// DocumentMeta is relative to `knowledge_dir`. Returns the line list
/// (split on `\n`) so callers can slice ranges or count lines.
fn read_source_lines(
  cfg: KnowledgeConfig,
  meta: types.DocumentMeta,
) -> Result(List(String), String) {
  let full_path = cfg.knowledge_dir <> "/" <> meta.path
  case simplifile.read(full_path) {
    Ok(content) -> Ok(string.split(content, "\n"))
    Error(reason) -> Error("Failed to read source: " <> string.inspect(reason))
  }
}

/// Walk a tree depth-first looking for a node with the given UUID.
/// Returns the matched node and its breadcrumb path of ancestor titles.
fn find_node_by_id(
  node: types.TreeNode,
  target_id: String,
  parent_path: String,
) -> Option(#(types.TreeNode, String)) {
  case node.id == target_id {
    True -> Some(#(node, parent_path))
    False -> {
      let child_path = case parent_path {
        "" -> node.title
        _ -> parent_path <> " / " <> node.title
      }
      list.fold(node.children, None, fn(acc, child) {
        case acc {
          Some(_) -> acc
          None -> find_node_by_id(child, target_id, child_path)
        }
      })
    }
  }
}

/// Walk the tree and emit a flat description of every node, capped to
/// `max_depth` (None = no cap). Each entry carries the node's id, title,
/// depth, breadcrumb path, and source line span — everything the caller
/// needs to pick a section to read or to display to the LLM.
fn collect_sections(
  node: types.TreeNode,
  parent_path: String,
  max_depth: Option(Int),
  acc: List(SectionEntry),
) -> List(SectionEntry) {
  let entry =
    SectionEntry(
      id: node.id,
      title: node.title,
      depth: node.depth,
      path: parent_path,
      line_start: node.source.line_start,
      line_end: node.source.line_end,
    )
  let acc = [entry, ..acc]
  let descend = case max_depth {
    Some(cap) -> node.depth < cap
    None -> True
  }
  case descend {
    False -> acc
    True -> {
      let child_path = case parent_path {
        "" -> node.title
        _ -> parent_path <> " / " <> node.title
      }
      list.fold(node.children, acc, fn(a, child) {
        collect_sections(child, child_path, max_depth, a)
      })
    }
  }
}

type SectionEntry {
  SectionEntry(
    id: String,
    title: String,
    depth: Int,
    path: String,
    line_start: Int,
    line_end: Int,
  )
}

fn run_document_info(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use doc_id <- decode.field("doc_id", decode.string)
    decode.success(doc_id)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(tool_use_id: call.id, error: "Missing doc_id")
    Ok(doc_id) ->
      case lookup_meta(cfg, doc_id) {
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
        Ok(meta) ->
          case indexer.load_index(cfg.indexes_dir, doc_id) {
            Error(reason) ->
              llm_types.ToolFailure(tool_use_id: call.id, error: reason)
            Ok(idx) -> {
              let total_lines = case read_source_lines(cfg, meta) {
                Ok(lines) -> list.length(lines)
                Error(_) -> 0
              }
              let top_level_count = list.length(idx.root.children)
              // Heuristic: a doc with 2+ top-level sections OR more than
              // a handful of total nodes is "structured" enough that
              // list_sections will be useful. A flat blob has a single
              // root with all content underneath.
              let structured = top_level_count >= 2 || idx.node_count >= 4
              let body =
                "doc_id: "
                <> meta.doc_id
                <> "\ntitle: "
                <> meta.title
                <> "\ntype: "
                <> types.doc_type_to_string(meta.doc_type)
                <> "\ndomain: "
                <> meta.domain
                <> "\nstatus: "
                <> types.doc_status_to_string(meta.status)
                <> "\npath: "
                <> meta.path
                <> "\ntotal_lines: "
                <> int.to_string(total_lines)
                <> "\nnode_count: "
                <> int.to_string(idx.node_count)
                <> "\ntop_level_sections: "
                <> int.to_string(top_level_count)
                <> "\nstructured: "
                <> case structured {
                  True -> "true (use list_sections)"
                  False -> "false (use read_range or search_library)"
                }
              llm_types.ToolSuccess(tool_use_id: call.id, content: body)
            }
          }
      }
  }
}

fn run_list_sections(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use doc_id <- decode.field("doc_id", decode.string)
    use max_depth <- decode.optional_field("max_depth", -1, decode.int)
    decode.success(#(doc_id, max_depth))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(tool_use_id: call.id, error: "Missing doc_id")
    Ok(#(doc_id, max_depth_raw)) -> {
      let max_depth = case max_depth_raw {
        n if n < 0 -> None
        n -> Some(n)
      }
      case indexer.load_index(cfg.indexes_dir, doc_id) {
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
        Ok(idx) -> {
          let entries = collect_sections(idx.root, "", max_depth, [])
          // Drop the synthetic root node entry — callers want the
          // navigable sections, not the document container.
          let body_entries =
            list.filter(entries, fn(e: SectionEntry) { e.depth > 0 })
          case body_entries {
            [] ->
              llm_types.ToolSuccess(
                tool_use_id: call.id,
                content: "No sections — this document is flat (no headings "
                  <> "detected). Use `read_range` or `search_library` "
                  <> "instead.",
              )
            _ -> {
              // Reverse: collect_sections accumulates head-first, so the
              // list is currently last-seen-first. Restore document order.
              let ordered = list.reverse(body_entries)
              let lines =
                list.map(ordered, fn(e: SectionEntry) {
                  let indent = string.repeat("  ", e.depth - 1)
                  indent
                  <> "[depth "
                  <> int.to_string(e.depth)
                  <> "] "
                  <> e.title
                  <> "  (id="
                  <> e.id
                  <> ", L"
                  <> int.to_string(e.line_start)
                  <> "-"
                  <> int.to_string(e.line_end)
                  <> ")"
                })
              let header =
                int.to_string(list.length(ordered))
                <> " section(s) — pass an `id` to `read_section_by_id`:\n\n"
              llm_types.ToolSuccess(
                tool_use_id: call.id,
                content: header <> string.join(lines, "\n"),
              )
            }
          }
        }
      }
    }
  }
}

fn run_read_section_by_id(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use doc_id <- decode.field("doc_id", decode.string)
    use section_id <- decode.field("section_id", decode.string)
    decode.success(#(doc_id, section_id))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Missing doc_id or section_id",
      )
    Ok(#(doc_id, section_id)) ->
      case indexer.load_index(cfg.indexes_dir, doc_id) {
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
        Ok(idx) ->
          case find_node_by_id(idx.root, section_id, "") {
            None ->
              llm_types.ToolFailure(
                tool_use_id: call.id,
                error: "section_id '"
                  <> section_id
                  <> "' not found in document "
                  <> doc_id
                  <> ". Call `list_sections` to see valid section IDs.",
              )
            Some(#(node, parent_path)) -> {
              let slug = case lookup_meta(cfg, doc_id) {
                Ok(meta) -> search.doc_slug_for(meta)
                Error(_) -> doc_id
              }
              let section_or_path = case parent_path {
                "" -> node.title
                _ -> parent_path <> " / " <> node.title
              }
              let citation =
                search.format_citation_from_parts(
                  slug,
                  section_or_path,
                  node.source.line_start,
                  node.source.line_end,
                  node.source.page,
                )
              let header =
                "## " <> node.title <> "\nCitation: " <> citation <> "\n\n"
              llm_types.ToolSuccess(
                tool_use_id: call.id,
                content: header <> node.content,
              )
            }
          }
      }
  }
}

fn run_read_range(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use doc_id <- decode.field("doc_id", decode.string)
    use start_line <- decode.field("start_line", decode.int)
    use end_line <- decode.field("end_line", decode.int)
    decode.success(#(doc_id, start_line, end_line))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Missing doc_id, start_line, or end_line",
      )
    Ok(#(doc_id, start_raw, end_raw)) ->
      case lookup_meta(cfg, doc_id) {
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
        Ok(meta) ->
          case read_source_lines(cfg, meta) {
            Error(reason) ->
              llm_types.ToolFailure(tool_use_id: call.id, error: reason)
            Ok(lines) -> {
              let total = list.length(lines)
              // Clamp + sanity-check. start at least 1, end at most
              // total, end >= start. A request of 1..0 or backwards is
              // a caller error worth returning rather than silently
              // ignoring — the LLM should know its arithmetic was off.
              let start = case start_raw {
                n if n < 1 -> 1
                n -> n
              }
              let end_clamped = case end_raw {
                n if n > total -> total
                n -> n
              }
              case end_clamped < start {
                True ->
                  llm_types.ToolFailure(
                    tool_use_id: call.id,
                    error: "end_line ("
                      <> int.to_string(end_raw)
                      <> ") is before start_line ("
                      <> int.to_string(start_raw)
                      <> ") after clamping to document length "
                      <> int.to_string(total),
                  )
                False ->
                  case end_clamped - start + 1 > read_range_max_lines {
                    True ->
                      llm_types.ToolFailure(
                        tool_use_id: call.id,
                        error: "Requested range ("
                          <> int.to_string(end_clamped - start + 1)
                          <> " lines) exceeds the per-call cap of "
                          <> int.to_string(read_range_max_lines)
                          <> ". Chunk into multiple calls.",
                      )
                    False -> {
                      let slice =
                        lines
                        |> list.drop(start - 1)
                        |> list.take(end_clamped - start + 1)
                      let slug = search.doc_slug_for(meta)
                      let citation =
                        "doc:"
                        <> slug
                        <> " L"
                        <> int.to_string(start)
                        <> "-"
                        <> int.to_string(end_clamped)
                      let header = "Citation: " <> citation <> "\n\n"
                      llm_types.ToolSuccess(
                        tool_use_id: call.id,
                        content: header <> string.join(slice, "\n"),
                      )
                    }
                  }
              }
            }
          }
      }
  }
}

fn run_save_to_library(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use content <- decode.field("content", decode.string)
    use domain <- decode.field("domain", decode.string)
    use title <- decode.field("title", decode.string)
    use source_url <- decode.optional_field("source_url", "", decode.string)
    decode.success(#(content, domain, title, source_url))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Missing content, domain, or title",
      )
    Ok(#(content, domain, title, source_url)) -> {
      let doc_id = generate_uuid()
      let slug =
        title
        |> string.lowercase
        |> string.replace(" ", "-")
        |> string.slice(0, 50)
      let path = "sources/" <> domain <> "/" <> slug <> ".md"
      let full_path = cfg.sources_dir <> "/" <> domain <> "/" <> slug <> ".md"

      let _ = simplifile.create_directory_all(cfg.sources_dir <> "/" <> domain)
      case simplifile.write(full_path, content) {
        Error(reason) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Failed to write: " <> string.inspect(reason),
          )
        Ok(_) -> {
          let idx = indexer.index_markdown(doc_id, content)
          indexer.save_index(cfg.indexes_dir, idx)
          let meta =
            types.DocumentMeta(
              op: types.Create,
              doc_id:,
              doc_type: types.Source,
              domain:,
              title:,
              path:,
              status: types.Normalised,
              content_hash: sha256_hex(content),
              node_count: idx.node_count,
              created_at: get_datetime(),
              updated_at: get_datetime(),
              source_url: case source_url {
                "" -> None
                url -> Some(url)
              },
              version: 1,
            )
          knowledge_log.append(cfg.knowledge_dir, meta)
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Saved to library: "
              <> title
              <> " ("
              <> int.to_string(idx.node_count)
              <> " sections indexed, id: "
              <> doc_id
              <> ")",
          )
        }
      }
    }
  }
}

import simplifile

fn run_create_draft(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use slug <- decode.field("slug", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(#(slug, content))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Missing slug or content",
      )
    Ok(#(slug, content)) ->
      case workspace.write_draft(cfg.drafts_dir, slug, content) {
        Ok(_) ->
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Draft '" <> slug <> "' created.",
          )
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
      }
  }
}

fn run_read_draft(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use slug <- decode.field("slug", decode.string)
    decode.success(slug)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(tool_use_id: call.id, error: "Missing slug")
    Ok(slug) ->
      case workspace.read_draft(cfg.drafts_dir, slug) {
        Ok(content) ->
          llm_types.ToolSuccess(tool_use_id: call.id, content: content)
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
      }
  }
}

fn run_update_draft(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use slug <- decode.field("slug", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(#(slug, content))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Missing slug or content",
      )
    Ok(#(slug, content)) ->
      case workspace.write_draft(cfg.drafts_dir, slug, content) {
        Ok(_) ->
          llm_types.ToolSuccess(
            tool_use_id: call.id,
            content: "Draft '" <> slug <> "' updated.",
          )
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
      }
  }
}

fn run_promote_draft(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use slug <- decode.field("slug", decode.string)
    decode.success(slug)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(tool_use_id: call.id, error: "Missing slug")
    Ok(slug) ->
      case workspace.read_draft(cfg.drafts_dir, slug) {
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
        Ok(content) -> {
          let _ = simplifile.create_directory_all(cfg.exports_dir)
          let export_path = cfg.exports_dir <> "/" <> slug <> ".md"
          case simplifile.write(export_path, content) {
            Error(reason) ->
              llm_types.ToolFailure(
                tool_use_id: call.id,
                error: "Failed to promote: " <> string.inspect(reason),
              )
            Ok(_) -> {
              let doc_id = generate_uuid()
              // Status: Promoted means the export exists but awaits
              // operator approval. Search filters these out by
              // default — the operator must explicitly approve before
              // the content becomes a canonical source the agent
              // will cite.
              let meta =
                types.DocumentMeta(
                  op: types.Create,
                  doc_id:,
                  doc_type: types.Export,
                  domain: "",
                  title: slug,
                  path: "exports/" <> slug <> ".md",
                  status: types.Promoted,
                  content_hash: sha256_hex(content),
                  node_count: 0,
                  created_at: get_datetime(),
                  updated_at: get_datetime(),
                  source_url: None,
                  version: 1,
                )
              knowledge_log.append(cfg.knowledge_dir, meta)
              llm_types.ToolSuccess(
                tool_use_id: call.id,
                content: "Draft '"
                  <> slug
                  <> "' promoted to export. Status: Promoted (pending "
                  <> "operator approval). The operator can approve via "
                  <> "`approve_export` or reject with `reject_export`.",
              )
            }
          }
        }
      }
  }
}

// ---------------------------------------------------------------------------
// export_pdf — render a promoted export from markdown to PDF
// ---------------------------------------------------------------------------

/// Pandoc + tectonic invocation timeout. Most documents render in
/// 1-5s; tectonic's first-run package fetches can push this longer
/// on a cold install, so the timeout is generous. Configurable later
/// if real workloads need it.
const export_pdf_timeout_ms: Int = 60_000

fn run_export_pdf(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use slug <- decode.field("slug", decode.string)
    decode.success(slug)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid input — expected { \"slug\": \"<name>\" }",
      )
    Ok(slug) -> {
      let safe_slug = sanitise_slug(slug)
      case safe_slug {
        "" ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Invalid slug — empty after sanitisation",
          )
        s -> {
          let md_path = cfg.exports_dir <> "/" <> s <> ".md"
          case simplifile.is_file(md_path) {
            Ok(False) | Error(_) ->
              llm_types.ToolFailure(
                tool_use_id: call.id,
                error: "No promoted export at "
                  <> md_path
                  <> ". Promote the draft first via promote_draft, then "
                  <> "call export_pdf on the same slug.",
              )
            Ok(True) -> do_export_pdf(call.id, cfg.exports_dir, s)
          }
        }
      }
    }
  }
}

fn do_export_pdf(
  call_id: String,
  exports_dir: String,
  slug: String,
) -> llm_types.ToolResult {
  let md_path = exports_dir <> "/" <> slug <> ".md"
  let pdf_path = exports_dir <> "/" <> slug <> ".pdf"
  // pandoc + tectonic. Args go through podman_ffi.run_cmd which now
  // uses spawn_executable + argv (PR #144), so slug content is
  // literal — no shell injection surface.
  case
    podman_ffi.run_cmd(
      "pandoc",
      [md_path, "-o", pdf_path, "--pdf-engine=tectonic"],
      export_pdf_timeout_ms,
    )
  {
    Error(reason) ->
      llm_types.ToolFailure(
        tool_use_id: call_id,
        error: "PDF generation failed to start: "
          <> reason
          <> ". This usually means pandoc is not installed on the host. "
          <> "See operators-manual §Install for setup steps.",
      )
    Ok(result) ->
      case result.exit_code {
        0 -> {
          let size = file_size(pdf_path)
          slog.info(
            "tools/knowledge",
            "export_pdf",
            "Generated " <> pdf_path <> " (" <> int.to_string(size) <> " bytes)",
            None,
          )
          llm_types.ToolSuccess(
            tool_use_id: call_id,
            content: "Exported '"
              <> slug
              <> ".pdf' ("
              <> format_bytes(size)
              <> "). Path: "
              <> pdf_path,
          )
        }
        _ -> {
          // Non-zero exit. Distinguish the common case ("tectonic
          // not installed" — pandoc reports it via stderr containing
          // a specific phrase) from a genuine LaTeX compile error.
          // The merged stdout/stderr (PR #144) lives in result.stdout.
          let combined = result.stdout
          case
            string.contains(combined, "tectonic: not found")
            || string.contains(combined, "tectonic not found")
            || string.contains(combined, "could not find executable: tectonic")
            || string.contains(combined, "pdf-engine \"tectonic\" not found")
          {
            True ->
              llm_types.ToolFailure(
                tool_use_id: call_id,
                error: "Cannot generate PDF — `tectonic` is not installed "
                  <> "on the host. Install it: `brew install tectonic` on "
                  <> "macOS, or download the binary from "
                  <> "https://tectonic-typesetting.github.io/ on Linux. "
                  <> "After install, re-run export_pdf.",
              )
            False ->
              llm_types.ToolFailure(
                tool_use_id: call_id,
                error: "PDF generation failed (exit "
                  <> int.to_string(result.exit_code)
                  <> "). pandoc/tectonic stderr:\n"
                  <> string.slice(combined, 0, 500),
              )
          }
        }
      }
  }
}

/// Strip a slug of anything that could escape exports_dir. The slug
/// is operator-supplied via the LLM, so we don't trust it. Allow
/// only filename-safe characters; replace everything else with `_`.
/// Empty result means the slug is unusable.
fn sanitise_slug(slug: String) -> String {
  let trimmed = string.trim(slug)
  let stripped =
    trimmed
    |> string.replace("/", "_")
    |> string.replace("\\", "_")
    |> string.replace("..", "_")
    |> string.replace(" ", "_")
  case stripped {
    "" -> ""
    s -> s
  }
}

// (file_size FFI defined earlier in the module — used by both
// list_intray and export_pdf for size reporting.)

// ---------------------------------------------------------------------------
// approve_export / reject_export — operator-driven approval workflow
// ---------------------------------------------------------------------------

fn run_approve_export(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use slug <- decode.field("slug", decode.string)
    use note <- decode.optional_field("note", "", decode.string)
    decode.success(#(slug, note))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(tool_use_id: call.id, error: "Missing slug")
    Ok(#(slug, note)) ->
      transition_export_status(
        cfg,
        call.id,
        slug,
        types.Approved,
        "approved",
        note,
      )
  }
}

fn run_reject_export(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use slug <- decode.field("slug", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(#(slug, reason))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Missing slug or reason",
      )
    Ok(#(slug, reason)) ->
      case string.trim(reason) {
        "" ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Rejection reason must not be empty",
          )
        trimmed ->
          transition_export_status(
            cfg,
            call.id,
            slug,
            types.Rejected,
            "rejected",
            trimmed,
          )
      }
  }
}

/// Shared transition logic, value-returning variant. Used by the
/// tool runners (which wrap the result as a ToolResult) and by the
/// web GUI (which needs a structured Ok/Error for the
/// ApprovalResult message). Returns Ok(success_message) on a clean
/// transition, Error(reason) when the export is missing or already
/// terminal.
pub fn transition_export(
  knowledge_dir: String,
  slug: String,
  new_status: types.DocStatus,
  action: String,
  note: String,
) -> Result(String, String) {
  let docs = knowledge_log.resolve(knowledge_dir)
  // Exports are identified by doc_type=Export and title=slug
  // (promote_draft writes the slug into the title field).
  let match =
    list.find(docs, fn(m) { m.doc_type == types.Export && m.title == slug })
  case match {
    Error(_) -> Error("No export with slug '" <> slug <> "' found")
    Ok(meta) ->
      case meta.status {
        types.Approved -> Error("Export '" <> slug <> "' is already Approved")
        types.Rejected -> Error("Export '" <> slug <> "' is already Rejected")
        _ -> {
          let updated =
            types.DocumentMeta(
              ..meta,
              op: types.UpdateStatus,
              status: new_status,
              updated_at: get_datetime(),
              version: meta.version + 1,
            )
          knowledge_log.append(knowledge_dir, updated)
          // Audit trail: the note/reason goes into slog so the
          // operator (and future queries) can trace the decision
          // even though DocStatus itself can't carry the text.
          slog.info(
            "knowledge",
            "approval",
            "Export '"
              <> slug
              <> "' "
              <> action
              <> case note {
              "" -> ""
              n -> ": " <> n
            },
            option.None,
          )
          Ok("Export '" <> slug <> "' " <> action <> ".")
        }
      }
  }
}

/// Tool-result wrapper around transition_export. Keeps the existing
/// tool runners' shape unchanged.
fn transition_export_status(
  cfg: KnowledgeConfig,
  call_id: String,
  slug: String,
  new_status: types.DocStatus,
  action: String,
  note: String,
) -> llm_types.ToolResult {
  case transition_export(cfg.knowledge_dir, slug, new_status, action, note) {
    Ok(message) -> llm_types.ToolSuccess(tool_use_id: call_id, content: message)
    Error(reason) -> llm_types.ToolFailure(tool_use_id: call_id, error: reason)
  }
}
