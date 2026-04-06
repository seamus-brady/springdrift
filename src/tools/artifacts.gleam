//// Artifact tools — store_result and retrieve_result for the researcher agent.
////
//// These tools let the researcher push large web content to disk (returning a
//// compact artifact ID) and retrieve it later by ID. This keeps the agent's
//// context window lean while preserving full content on disk.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import artifacts/log as artifacts_log
import artifacts/types.{ArtifactMeta, ArtifactRecord}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{Some}
import gleam/string
import llm/tool
import llm/types as llm_types
import narrative/librarian.{type LibrarianMessage}
import slog

@external(erlang, "springdrift_ffi", "generate_uuid")
fn uuid_v4() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn iso_now() -> String

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(llm_types.Tool) {
  [store_result_tool(), retrieve_result_tool()]
}

fn store_result_tool() -> llm_types.Tool {
  tool.new("store_result")
  |> tool.with_description(
    "Store a large piece of content (e.g. fetched web page) as an artifact on disk. "
    <> "Returns a compact artifact_id you can reference later without keeping the full content in context. "
    <> "Use this for content over ~2000 characters that you need to preserve but not keep in your working memory.",
  )
  |> tool.add_string_param("content", "The content to store", True)
  |> tool.add_string_param(
    "tool",
    "The tool that produced this content (e.g. fetch_url, web_search)",
    True,
  )
  |> tool.add_string_param("url", "Source URL, if applicable", False)
  |> tool.add_string_param(
    "summary",
    "Brief one-line summary of the content",
    True,
  )
  |> tool.build()
}

fn retrieve_result_tool() -> llm_types.Tool {
  tool.new("retrieve_result")
  |> tool.with_description(
    "Retrieve the full content of a previously stored artifact by its ID. "
    <> "Use this when you need to re-read content you stored earlier with store_result.",
  )
  |> tool.add_string_param(
    "artifact_id",
    "The artifact ID returned by store_result",
    True,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

pub fn execute(
  call: llm_types.ToolCall,
  artifacts_dir: String,
  cycle_id: String,
  lib: Subject(LibrarianMessage),
  max_artifact_chars: Int,
) -> llm_types.ToolResult {
  case call.name {
    "store_result" ->
      run_store_result(call, artifacts_dir, cycle_id, lib, max_artifact_chars)
    "retrieve_result" -> run_retrieve_result(call, lib)
    _ ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Unknown artifact tool: " <> call.name,
      )
  }
}

fn run_store_result(
  call: llm_types.ToolCall,
  artifacts_dir: String,
  cycle_id: String,
  lib: Subject(LibrarianMessage),
  max_artifact_chars: Int,
) -> llm_types.ToolResult {
  let decoder = {
    use content <- decode.field("content", decode.string)
    use tool_name <- decode.field("tool", decode.string)
    use url <- decode.field(
      "url",
      decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
    )
    use summary <- decode.field("summary", decode.string)
    decode.success(#(content, tool_name, url, summary))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid store_result input",
      )
    Ok(#(content, tool_name, url, summary)) -> {
      let artifact_id = "art-" <> uuid_v4()
      let now = iso_now()
      let record =
        ArtifactRecord(
          schema_version: 1,
          artifact_id:,
          cycle_id:,
          stored_at: now,
          tool: tool_name,
          url:,
          summary:,
          char_count: string.length(content),
          truncated: False,
        )
      artifacts_log.append(artifacts_dir, record, content, max_artifact_chars)
      let meta =
        ArtifactMeta(
          artifact_id:,
          cycle_id:,
          stored_at: now,
          tool: tool_name,
          url:,
          summary:,
          char_count: string.length(content),
          truncated: False,
        )
      librarian.index_artifact(lib, meta)
      slog.debug(
        "tools/artifacts",
        "store_result",
        "Stored artifact " <> artifact_id,
        Some(cycle_id),
      )
      llm_types.ToolSuccess(
        tool_use_id: call.id,
        content: "Stored as artifact_id=\""
          <> artifact_id
          <> "\" ("
          <> string.inspect(string.length(content))
          <> " chars). Reference this ID to retrieve later.",
      )
    }
  }
}

fn run_retrieve_result(
  call: llm_types.ToolCall,
  lib: Subject(LibrarianMessage),
) -> llm_types.ToolResult {
  let decoder = {
    use artifact_id <- decode.field("artifact_id", decode.string)
    decode.success(artifact_id)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "Invalid retrieve_result input",
      )
    Ok(artifact_id) -> {
      case librarian.lookup_artifact(lib, artifact_id) {
        Error(Nil) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Artifact not found: " <> artifact_id,
          )
        Ok(meta) -> {
          case
            librarian.retrieve_artifact_content(
              lib,
              artifact_id,
              meta.stored_at,
            )
          {
            Error(Nil) ->
              llm_types.ToolFailure(
                tool_use_id: call.id,
                error: "Artifact content not found on disk: " <> artifact_id,
              )
            Ok(content) -> llm_types.ToolSuccess(tool_use_id: call.id, content:)
          }
        }
      }
    }
  }
}
