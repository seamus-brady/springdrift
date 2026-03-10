//// Artifact types — metadata for stored tool results.
////
//// ArtifactRecord is written to JSONL with content.
//// ArtifactMeta is the metadata-only view used in ETS and query results.

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
