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
import slog

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "sha256_hex")
fn sha256_hex(input: String) -> String

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn cognitive_tools() -> List(llm_types.Tool) {
  [
    list_documents_tool(),
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
    read_section_tool(),
    save_to_library_tool(),
  ]
}

pub fn writer_tools() -> List(llm_types.Tool) {
  [create_draft_tool(), update_draft_tool(), promote_draft_tool()]
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
    "Search mode: keyword or embedding (default: embedding)",
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

fn read_section_tool() -> llm_types.Tool {
  tool.new("read_section")
  |> tool.with_description(
    "Read a specific section from an indexed document without loading the full document. Context-efficient for large papers and books.",
  )
  |> tool.add_string_param("doc_id", "Document identifier", True)
  |> tool.add_string_param(
    "section",
    "Section title or path (e.g. 'introduction', 'methods', '3.2')",
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
  || name == "write_journal"
  || name == "write_note"
  || name == "read_note"
  || name == "search_library"
  || name == "read_section"
  || name == "save_to_library"
  || name == "create_draft"
  || name == "update_draft"
  || name == "promote_draft"
  || name == "approve_export"
  || name == "reject_export"
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
  )
}

pub fn execute(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  slog.debug("knowledge", "execute", "tool=" <> call.name, None)
  case call.name {
    "list_documents" -> run_list_documents(call, cfg)
    "write_journal" -> run_write_journal(call, cfg)
    "write_note" -> run_write_note(call, cfg)
    "read_note" -> run_read_note(call, cfg)
    "search_library" -> run_search_library(call, cfg)
    "read_section" -> run_read_section(call, cfg)
    "save_to_library" -> run_save_to_library(call, cfg)
    "create_draft" -> run_create_draft(call, cfg)
    "update_draft" -> run_update_draft(call, cfg)
    "promote_draft" -> run_promote_draft(call, cfg)
    "approve_export" -> run_approve_export(call, cfg)
    "reject_export" -> run_reject_export(call, cfg)
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
      let results =
        search.search(
          query,
          docs,
          cfg.indexes_dir,
          mode,
          int.min(20, int.max(1, max_results)),
          domain_filter,
          None,
          cfg.embed_fn,
        )
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

fn run_read_section(
  call: llm_types.ToolCall,
  cfg: KnowledgeConfig,
) -> llm_types.ToolResult {
  let decoder = {
    use doc_id <- decode.field("doc_id", decode.string)
    use section <- decode.field("section", decode.string)
    decode.success(#(doc_id, section))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Missing doc_id or section",
      )
    Ok(#(doc_id, section)) ->
      case indexer.load_index(cfg.indexes_dir, doc_id) {
        Error(reason) ->
          llm_types.ToolFailure(tool_use_id: call.id, error: reason)
        Ok(idx) ->
          case indexer.find_section_with_path(idx.root, section) {
            None ->
              llm_types.ToolFailure(
                tool_use_id: call.id,
                error: "Section '"
                  <> section
                  <> "' not found in document "
                  <> doc_id,
              )
            Some(#(node, parent_path)) -> {
              // Look up the DocumentMeta so we can build a stable
              // slug-based citation. If the lookup misses (shouldn't
              // happen in practice but is safe), fall back to doc_id.
              let docs = knowledge_log.resolve(cfg.knowledge_dir)
              let slug = case list.find(docs, fn(m) { m.doc_id == doc_id }) {
                Ok(meta) -> search.doc_slug_for(meta)
                Error(_) -> doc_id
              }
              // Section path: breadcrumb from root, with the matched
              // node's own title appended. Root-only matches yield
              // just the node title (no " / " prefix).
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

/// Shared transition logic. Finds the export by slug, verifies it's in
/// an expected source state (Promoted), appends an UpdateStatus op,
/// and writes a slog line recording the note/reason. Emits a clean
/// error if the export doesn't exist or is already in a terminal
/// state.
fn transition_export_status(
  cfg: KnowledgeConfig,
  call_id: String,
  slug: String,
  new_status: types.DocStatus,
  action: String,
  note: String,
) -> llm_types.ToolResult {
  let docs = knowledge_log.resolve(cfg.knowledge_dir)
  // Exports are identified by doc_type=Export and title=slug
  // (promote_draft writes the slug into the title field).
  let match =
    list.find(docs, fn(m) { m.doc_type == types.Export && m.title == slug })
  case match {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call_id,
        error: "No export with slug '" <> slug <> "' found",
      )
    Ok(meta) ->
      case meta.status {
        types.Approved ->
          llm_types.ToolFailure(
            tool_use_id: call_id,
            error: "Export '" <> slug <> "' is already Approved",
          )
        types.Rejected ->
          llm_types.ToolFailure(
            tool_use_id: call_id,
            error: "Export '" <> slug <> "' is already Rejected",
          )
        _ -> {
          let updated =
            types.DocumentMeta(
              ..meta,
              op: types.UpdateStatus,
              status: new_status,
              updated_at: get_datetime(),
              version: meta.version + 1,
            )
          knowledge_log.append(cfg.knowledge_dir, updated)
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
          llm_types.ToolSuccess(
            tool_use_id: call_id,
            content: "Export '" <> slug <> "' " <> action <> ".",
          )
        }
      }
  }
}
