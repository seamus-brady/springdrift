//// Stable agent identity — persisted UUID across sessions.
////
//// Every Springdrift instance gets a stable UUID that persists in
//// `.springdrift/identity.json`. This gives the narrative corpus
//// first-person continuity across sessions.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import paths
import simplifile
import slog

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type AgentIdentity {
  AgentIdentity(agent_uuid: String, created_at: String, last_seen_at: String)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Load from disk or generate fresh. Always succeeds.
pub fn load_or_create() -> AgentIdentity {
  let path = identity_path()
  case simplifile.read(path) {
    Ok(contents) ->
      case json.parse(contents, identity_decoder()) {
        Ok(identity) -> identity
        Error(_) -> {
          slog.warn(
            "agent_identity",
            "load_or_create",
            "Corrupt identity file, regenerating",
            None,
          )
          create_and_save()
        }
      }
    Error(_) -> create_and_save()
  }
}

/// Persist (writes last_seen_at). Fire-and-forget — logs on failure.
pub fn save(identity: AgentIdentity) -> Nil {
  let path = identity_path()
  let now = get_datetime()
  let updated = AgentIdentity(..identity, last_seen_at: now)
  let json_str =
    json.to_string(
      json.object([
        #("schema_version", json.int(1)),
        #("agent_uuid", json.string(updated.agent_uuid)),
        #("created_at", json.string(updated.created_at)),
        #("last_seen_at", json.string(updated.last_seen_at)),
      ]),
    )
  case simplifile.write(path, json_str) {
    Ok(_) -> Nil
    Error(_) ->
      slog.warn("agent_identity", "save", "Failed to write identity file", None)
  }
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn identity_path() -> String {
  paths.project_dir <> "/identity.json"
}

fn create_and_save() -> AgentIdentity {
  let now = get_datetime()
  let identity =
    AgentIdentity(
      agent_uuid: generate_uuid(),
      created_at: now,
      last_seen_at: now,
    )
  save(identity)
  identity
}

fn identity_decoder() -> decode.Decoder(AgentIdentity) {
  use agent_uuid <- decode.field("agent_uuid", decode.string)
  use created_at <- decode.optional_field("created_at", "", decode.string)
  use last_seen_at <- decode.optional_field("last_seen_at", "", decode.string)
  decode.success(AgentIdentity(agent_uuid:, created_at:, last_seen_at:))
}
