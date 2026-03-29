//// AgentMail HTTP client — send, list, and read email messages.
////
//// Wraps the AgentMail REST API (https://api.agentmail.to/v0/).
//// API key is read from an env var (default: AGENTMAIL_API_KEY).

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import slog

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "springdrift_ffi", "http_post")
fn http_post(
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), String)

@external(erlang, "springdrift_ffi", "http_get_with_headers")
fn http_get_with_headers(
  url: String,
  headers: List(#(String, String)),
) -> Result(#(Int, String), String)

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

const api_base = "https://api.agentmail.to/v0"

/// Result of sending a message.
pub type SendResult {
  SendResult(message_id: String, thread_id: String)
}

/// Summary of an inbox message (from list endpoint).
pub type InboxMessage {
  InboxMessage(
    message_id: String,
    thread_id: String,
    from: String,
    to: String,
    subject: String,
    preview: String,
    timestamp: String,
  )
}

/// Full message content (from get endpoint).
pub type FullMessage {
  FullMessage(
    message_id: String,
    thread_id: String,
    from: String,
    to: String,
    subject: String,
    text: String,
    html: String,
    timestamp: String,
  )
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

/// Send an email via AgentMail.
pub fn send_message(
  inbox_id: String,
  api_key_env: String,
  to: String,
  subject: String,
  text: String,
) -> Result(SendResult, String) {
  case get_env(api_key_env) {
    Error(_) -> Error(api_key_env <> " not set")
    Ok(api_key) -> {
      let url = api_base <> "/inboxes/" <> inbox_id <> "/messages/send"
      let headers = auth_headers(api_key)
      let body =
        json.to_string(
          json.object([
            #("to", json.string(to)),
            #("subject", json.string(subject)),
            #("text", json.string(text)),
          ]),
        )
      case http_post(url, headers, body) {
        Error(reason) -> {
          slog.log_error(
            "comms/email",
            "send_message",
            "HTTP error: " <> reason,
            None,
          )
          Error("HTTP error: " <> reason)
        }
        Ok(#(status, resp_body)) ->
          case status >= 200 && status < 300 {
            True -> decode_send_result(resp_body)
            False -> {
              slog.log_error(
                "comms/email",
                "send_message",
                "API error "
                  <> int.to_string(status)
                  <> ": "
                  <> string.slice(resp_body, 0, 200),
                None,
              )
              Error(
                "AgentMail API error "
                <> int.to_string(status)
                <> ": "
                <> string.slice(resp_body, 0, 200),
              )
            }
          }
      }
    }
  }
}

fn decode_send_result(body: String) -> Result(SendResult, String) {
  let decoder = {
    use message_id <- decode.optional_field("message_id", "", decode.string)
    use thread_id <- decode.optional_field("thread_id", "", decode.string)
    decode.success(SendResult(message_id:, thread_id:))
  }
  case json.parse(body, decoder) {
    Ok(result) -> Ok(result)
    Error(_) -> Error("Failed to decode send response: " <> body)
  }
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

/// List recent messages in the inbox.
pub fn list_messages(
  inbox_id: String,
  api_key_env: String,
  limit: Int,
  after: Option(String),
) -> Result(List(InboxMessage), String) {
  case get_env(api_key_env) {
    Error(_) -> Error(api_key_env <> " not set")
    Ok(api_key) -> {
      let base_url =
        api_base
        <> "/inboxes/"
        <> inbox_id
        <> "/messages?limit="
        <> int.to_string(limit)
      let url = case after {
        Some(ts) -> base_url <> "&after=" <> ts
        None -> base_url
      }
      let headers = auth_headers(api_key)
      case http_get_with_headers(url, headers) {
        Error(reason) -> Error("HTTP error: " <> reason)
        Ok(#(status, resp_body)) ->
          case status >= 200 && status < 300 {
            True -> decode_message_list(resp_body)
            False ->
              Error(
                "AgentMail API error "
                <> int.to_string(status)
                <> ": "
                <> string.slice(resp_body, 0, 200),
              )
          }
      }
    }
  }
}

fn decode_message_list(body: String) -> Result(List(InboxMessage), String) {
  let msg_decoder = {
    use message_id <- decode.optional_field("message_id", "", decode.string)
    use thread_id <- decode.optional_field("thread_id", "", decode.string)
    use from <- decode.optional_field("from", "", decode.string)
    // AgentMail returns "to" as an array of strings
    use to_list <- decode.optional_field("to", [], decode.list(decode.string))
    use subject <- decode.optional_field("subject", "", decode.string)
    use preview <- decode.optional_field("preview", "", decode.string)
    use timestamp <- decode.optional_field("timestamp", "", decode.string)
    decode.success(InboxMessage(
      message_id:,
      thread_id:,
      from:,
      to: string.join(to_list, ", "),
      subject:,
      preview:,
      timestamp:,
    ))
  }
  let decoder = {
    use messages <- decode.optional_field(
      "messages",
      [],
      decode.list(msg_decoder),
    )
    decode.success(messages)
  }
  case json.parse(body, decoder) {
    Ok(msgs) -> Ok(msgs)
    Error(_) -> Error("Failed to decode message list")
  }
}

// ---------------------------------------------------------------------------
// Get
// ---------------------------------------------------------------------------

/// Get full message content by ID.
pub fn get_message(
  inbox_id: String,
  api_key_env: String,
  message_id: String,
) -> Result(FullMessage, String) {
  case get_env(api_key_env) {
    Error(_) -> Error(api_key_env <> " not set")
    Ok(api_key) -> {
      let url =
        api_base <> "/inboxes/" <> inbox_id <> "/messages/" <> message_id
      let headers = auth_headers(api_key)
      case http_get_with_headers(url, headers) {
        Error(reason) -> Error("HTTP error: " <> reason)
        Ok(#(status, resp_body)) ->
          case status >= 200 && status < 300 {
            True -> decode_full_message(resp_body)
            False ->
              Error(
                "AgentMail API error "
                <> int.to_string(status)
                <> ": "
                <> string.slice(resp_body, 0, 200),
              )
          }
      }
    }
  }
}

fn decode_full_message(body: String) -> Result(FullMessage, String) {
  let decoder = {
    use message_id <- decode.optional_field("message_id", "", decode.string)
    use thread_id <- decode.optional_field("thread_id", "", decode.string)
    use from <- decode.optional_field("from", "", decode.string)
    // AgentMail returns "to" as an array of strings
    use to_list <- decode.optional_field("to", [], decode.list(decode.string))
    use subject <- decode.optional_field("subject", "", decode.string)
    use text <- decode.optional_field("text", "", decode.string)
    use html <- decode.optional_field("html", "", decode.string)
    use timestamp <- decode.optional_field("timestamp", "", decode.string)
    decode.success(FullMessage(
      message_id:,
      thread_id:,
      from:,
      to: string.join(to_list, ", "),
      subject:,
      text:,
      html:,
      timestamp:,
    ))
  }
  case json.parse(body, decoder) {
    Ok(msg) -> Ok(msg)
    Error(_) ->
      Error("Failed to decode message: " <> string.slice(body, 0, 200))
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn auth_headers(api_key: String) -> List(#(String, String)) {
  [
    #("Authorization", "Bearer " <> api_key),
    #("Content-Type", "application/json"),
  ]
}

/// Resolve an inbox_id from an email address by listing inboxes and matching.
/// Returns the inbox_id string, or Error if not found.
pub fn resolve_inbox_id(
  api_key_env: String,
  email_address: String,
) -> Result(String, String) {
  case get_env(api_key_env) {
    Error(_) -> Error(api_key_env <> " not set")
    Ok(api_key) -> {
      let url = api_base <> "/inboxes?limit=50"
      let headers = auth_headers(api_key)
      case http_get_with_headers(url, headers) {
        Error(reason) -> Error("HTTP error: " <> reason)
        Ok(#(status, resp_body)) ->
          case status >= 200 && status < 300 {
            True -> find_inbox_by_email(resp_body, email_address)
            False ->
              Error(
                "AgentMail API error "
                <> int.to_string(status)
                <> ": "
                <> string.slice(resp_body, 0, 200),
              )
          }
      }
    }
  }
}

fn find_inbox_by_email(
  body: String,
  target_email: String,
) -> Result(String, String) {
  let inbox_decoder = {
    use inbox_id <- decode.optional_field("inbox_id", "", decode.string)
    use email <- decode.optional_field("email", "", decode.string)
    decode.success(#(inbox_id, email))
  }
  let decoder = {
    use inboxes <- decode.optional_field(
      "inboxes",
      [],
      decode.list(inbox_decoder),
    )
    decode.success(inboxes)
  }
  case json.parse(body, decoder) {
    Error(_) -> Error("Failed to decode inbox list")
    Ok(inboxes) -> {
      let target = string.lowercase(string.trim(target_email))
      case list.find(inboxes, fn(pair) { string.lowercase(pair.1) == target }) {
        Ok(#(inbox_id, _)) -> Ok(inbox_id)
        Error(_) -> Error("No inbox found for " <> target_email)
      }
    }
  }
}

/// Check if the AgentMail API key is configured.
pub fn is_configured(api_key_env: String) -> Bool {
  case get_env(api_key_env) {
    Ok(key) -> key != ""
    Error(_) -> False
  }
}
