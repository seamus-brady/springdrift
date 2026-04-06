//// Artifact types — metadata for stored tool results.
////
//// ArtifactRecord is written to JSONL with content.
//// ArtifactMeta is the metadata-only view used in ETS and query results.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

pub type ArtifactRecord {
  ArtifactRecord(
    schema_version: Int,
    artifact_id: String,
    cycle_id: String,
    stored_at: String,
    tool: String,
    url: String,
    summary: String,
    char_count: Int,
    truncated: Bool,
  )
}

/// Metadata only — no content field. Used in ETS and query results.
pub type ArtifactMeta {
  ArtifactMeta(
    artifact_id: String,
    cycle_id: String,
    stored_at: String,
    tool: String,
    url: String,
    summary: String,
    char_count: Int,
    truncated: Bool,
  )
}
