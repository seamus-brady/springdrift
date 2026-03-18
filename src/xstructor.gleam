//// XStructor — XML-Schema-Validated Structured LLM Output.
////
//// Replaces brittle JSON parsing + repair heuristics with XSD-validated XML.
//// The LLM receives a schema and example, generates XML, and the response is
//// validated against the schema. If invalid, the validation error is fed back
//// and the LLM retries (up to max_retries times).

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import llm/provider.{type Provider}
import llm/request
import llm/response
import llm/types.{type Message, Assistant, Message, TextContent, User}
import slog

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "xstructor_ffi", "write_schema_file")
fn do_write_schema_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "xstructor_ffi", "compile_schema")
fn do_compile_schema(file_path: String) -> Result(SchemaState, String)

@external(erlang, "xstructor_ffi", "validate_xml")
fn do_validate_xml(xml: String, schema: SchemaState) -> Result(String, String)

@external(erlang, "xstructor_ffi", "extract_elements")
fn do_extract_elements(xml: String) -> List(#(String, String))

/// Opaque Erlang schema state from xmerl_xsd:process_schema/1.
pub type SchemaState

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type XStructorConfig {
  XStructorConfig(
    schema: SchemaState,
    system_prompt: String,
    xml_example: String,
    max_retries: Int,
    max_tokens: Int,
  )
}

pub type XStructorResult {
  XStructorResult(
    xml: String,
    elements: Dict(String, String),
    retries_used: Int,
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Write a schema file to disk, compile it, and return the schema state.
pub fn compile_schema(
  schema_dir: String,
  name: String,
  content: String,
) -> Result(SchemaState, String) {
  let path = schema_dir <> "/" <> name
  case do_write_schema_file(path, content) {
    Error(e) -> Error("Failed to write schema " <> name <> ": " <> e)
    Ok(_) -> do_compile_schema(path)
  }
}

/// Generate validated XML via LLM with schema validation and retry.
pub fn generate(
  config: XStructorConfig,
  user_prompt: String,
  provider: Provider,
  model: String,
) -> Result(XStructorResult, String) {
  let messages = [
    Message(role: User, content: [TextContent(text: user_prompt)]),
  ]
  do_generate(config, messages, provider, model, 0)
}

/// Strip code fences and XML declarations from LLM response text.
pub fn clean_response(text: String) -> String {
  text
  |> string.trim
  |> strip_code_fences
  |> strip_xml_declaration
  |> string.trim
}

/// Extract a flat dict from validated XML.
pub fn extract(xml: String) -> Result(Dict(String, String), String) {
  let pairs = do_extract_elements(xml)
  case pairs {
    [] -> Error("No elements extracted from XML")
    _ -> Ok(dict.from_list(pairs))
  }
}

/// Extract a list of string values for repeated elements with indexed paths.
/// Given elements like {"root.items.0": "a", "root.items.1": "b"},
/// extract_list(elements, "root.items") returns ["a", "b"].
pub fn extract_list(
  elements: Dict(String, String),
  prefix: String,
) -> List(String) {
  extract_list_loop(elements, prefix, 0, [])
}

/// Validate XML against a compiled schema.
pub fn validate(xml: String, schema: SchemaState) -> Result(String, String) {
  do_validate_xml(xml, schema)
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn do_generate(
  config: XStructorConfig,
  messages: List(Message),
  provider: Provider,
  model: String,
  attempt: Int,
) -> Result(XStructorResult, String) {
  let req =
    request.new(model, config.max_tokens)
    |> request.with_system(config.system_prompt)
    |> request.with_messages(messages)

  case provider.chat(req) {
    Error(e) -> Error("LLM error: " <> llm_error_to_string(e))
    Ok(resp) -> {
      let text = response.text(resp)
      let cleaned = clean_response(text)
      case do_validate_xml(cleaned, config.schema) {
        Ok(_) -> {
          case extract(cleaned) {
            Ok(elements) ->
              Ok(XStructorResult(
                xml: cleaned,
                elements: elements,
                retries_used: attempt,
              ))
            Error(e) -> Error("Extraction failed: " <> e)
          }
        }
        Error(validation_error) -> {
          case attempt < config.max_retries {
            True -> {
              slog.debug(
                "xstructor",
                "generate",
                "Validation failed (attempt "
                  <> int.to_string(attempt + 1)
                  <> "/"
                  <> int.to_string(config.max_retries)
                  <> "): "
                  <> string.slice(validation_error, 0, 200),
                None,
              )
              // Build retry messages: append assistant response + user error feedback
              let retry_messages =
                list.append(messages, [
                  Message(role: Assistant, content: [TextContent(text: text)]),
                  Message(role: User, content: [
                    TextContent(
                      text: "Your XML was invalid. Validation error:\n"
                      <> validation_error
                      <> "\n\nPlease fix the XML and try again. Respond with ONLY the corrected XML, no explanation.",
                    ),
                  ]),
                ])
              do_generate(config, retry_messages, provider, model, attempt + 1)
            }
            False -> {
              slog.warn(
                "xstructor",
                "generate",
                "All retries exhausted. Last error: "
                  <> string.slice(validation_error, 0, 200),
                None,
              )
              Error(
                "Validation failed after "
                <> int.to_string(config.max_retries)
                <> " retries: "
                <> validation_error,
              )
            }
          }
        }
      }
    }
  }
}

fn strip_code_fences(text: String) -> String {
  let trimmed = string.trim(text)
  case string.starts_with(trimmed, "```") {
    True -> {
      // Remove opening fence line
      let after_open = case string.split(trimmed, "\n") {
        [_, ..rest] -> string.join(rest, "\n")
        _ -> trimmed
      }
      // Remove closing fence
      let trimmed_end = string.trim(after_open)
      case string.ends_with(trimmed_end, "```") {
        True -> {
          let lines = string.split(after_open, "\n")
          let without_last =
            list.take(lines, int.max(0, list.length(lines) - 1))
          string.join(without_last, "\n")
        }
        False -> after_open
      }
    }
    False -> trimmed
  }
}

fn strip_xml_declaration(text: String) -> String {
  let trimmed = string.trim(text)
  case string.starts_with(trimmed, "<?xml") {
    True -> {
      case string.split_once(trimmed, "?>") {
        Ok(#(_, rest)) -> string.trim(rest)
        Error(_) -> trimmed
      }
    }
    False -> trimmed
  }
}

fn extract_list_loop(
  elements: Dict(String, String),
  prefix: String,
  idx: Int,
  acc: List(String),
) -> List(String) {
  let key = prefix <> "." <> int.to_string(idx)
  case dict.get(elements, key) {
    Ok(value) -> extract_list_loop(elements, prefix, idx + 1, [value, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

fn llm_error_to_string(error: types.LlmError) -> String {
  case error {
    types.ApiError(status_code, message) ->
      "API error " <> int.to_string(status_code) <> ": " <> message
    types.NetworkError(reason) -> "Network error: " <> reason
    types.ConfigError(reason) -> "Config error: " <> reason
    types.DecodeError(reason) -> "Decode error: " <> reason
    types.TimeoutError -> "Timeout"
    types.RateLimitError(message) -> "Rate limit: " <> message
    types.UnknownError(reason) -> "Unknown error: " <> reason
  }
}
