//// Communications tools — send email, check inbox, read messages.
////
//// All outbound email is gated by:
//// 1. Hard allowlist check (in this module, before any API call)
//// 2. D' deterministic pre-filter (regex rules on message body)
//// 3. D' LLM scorer (agent override features for comms)
////
//// These tools are NOT D'-exempt — they are external-facing.

import comms/email
import comms/log as comms_log
import comms/types as comms_types
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import slog

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_timestamp() -> String

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [
    send_email_tool(),
    list_contacts_tool(),
    check_inbox_tool(),
    read_message_tool(),
  ]
}

fn send_email_tool() -> Tool {
  tool.new("send_email")
  |> tool.with_description(
    "Send an email via the agent's inbox. The recipient MUST be on the allowed "
    <> "contacts list — check with list_contacts first. Write in professional "
    <> "email tone. Never include system internals, debug info, or raw JSON.",
  )
  |> tool.add_string_param("to", "Recipient email address", True)
  |> tool.add_string_param("subject", "Email subject line", True)
  |> tool.add_string_param("body", "Email body text", True)
  |> tool.build()
}

fn list_contacts_tool() -> Tool {
  tool.new("list_contacts")
  |> tool.with_description(
    "List all email addresses the agent is allowed to contact. "
    <> "Always check this before sending email.",
  )
  |> tool.build()
}

fn check_inbox_tool() -> Tool {
  tool.new("check_inbox")
  |> tool.with_description(
    "List recent messages in the agent's email inbox. Returns sender, "
    <> "subject, date, and message_id for each message.",
  )
  |> tool.add_integer_param(
    "limit",
    "Maximum messages to return (default: 10, max: 50)",
    False,
  )
  |> tool.add_string_param(
    "after",
    "Only return messages after this ISO timestamp (optional)",
    False,
  )
  |> tool.build()
}

fn read_message_tool() -> Tool {
  tool.new("read_message")
  |> tool.with_description(
    "Read the full content of a specific email message by ID. "
    <> "Use check_inbox first to find message IDs.",
  )
  |> tool.add_string_param("message_id", "The message ID to read", True)
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

/// Execute a comms tool call. The config carries the allowlist and API settings.
/// The comms_dir is where JSONL logs are written.
/// The cycle_id is attached to logged messages for audit trail.
pub fn execute(
  call: ToolCall,
  config: comms_types.CommsConfig,
  comms_dir: String,
  cycle_id: Option(String),
) -> ToolResult {
  slog.debug("comms", "execute", "tool=" <> call.name, cycle_id)
  case call.name {
    "send_email" -> run_send_email(call, config, comms_dir, cycle_id)
    "list_contacts" -> run_list_contacts(call, config)
    "check_inbox" -> run_check_inbox(call, config)
    "read_message" -> run_read_message(call, config)
    _ ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Unknown comms tool: " <> call.name,
      )
  }
}

// ---------------------------------------------------------------------------
// send_email
// ---------------------------------------------------------------------------

fn run_send_email(
  call: ToolCall,
  config: comms_types.CommsConfig,
  comms_dir: String,
  cycle_id: Option(String),
) -> ToolResult {
  let decoder = {
    use to <- decode.field("to", decode.string)
    use subject <- decode.field("subject", decode.string)
    use body <- decode.field("body", decode.string)
    decode.success(#(to, subject, body))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid send_email input: requires to, subject, body",
      )
    Ok(#(to, subject, body)) -> {
      // Layer 1: Hard allowlist check
      let normalised_to = string.lowercase(string.trim(to))
      let allowed =
        list.map(config.allowed_recipients, fn(r) {
          string.lowercase(string.trim(r))
        })
      case list.contains(allowed, normalised_to) {
        False ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Recipient '"
              <> to
              <> "' is not on the allowed contacts list. Use list_contacts to see allowed recipients.",
          )
        True -> {
          // Send via AgentMail
          case
            email.send_message(
              config.inbox_id,
              config.api_key_env,
              to,
              subject,
              body,
            )
          {
            Error(reason) ->
              ToolFailure(
                tool_use_id: call.id,
                error: "Send failed: " <> reason,
              )
            Ok(result) -> {
              // Log to JSONL
              let msg =
                comms_types.CommsMessage(
                  message_id: result.message_id,
                  thread_id: result.thread_id,
                  channel: comms_types.Email,
                  direction: comms_types.Outbound,
                  from: config.from_name,
                  to:,
                  subject:,
                  body_text: body,
                  timestamp: get_timestamp(),
                  status: comms_types.Sent,
                  cycle_id:,
                )
              comms_log.append(comms_dir, msg)
              ToolSuccess(
                tool_use_id: call.id,
                content: "Email sent to "
                  <> to
                  <> " (message_id: "
                  <> result.message_id
                  <> ", thread_id: "
                  <> result.thread_id
                  <> ")",
              )
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// list_contacts
// ---------------------------------------------------------------------------

fn run_list_contacts(
  call: ToolCall,
  config: comms_types.CommsConfig,
) -> ToolResult {
  case config.allowed_recipients {
    [] ->
      ToolSuccess(
        tool_use_id: call.id,
        content: "No contacts configured. Add email addresses to [comms] allowed_recipients in config.toml.",
      )
    recipients -> {
      let lines =
        list.index_map(recipients, fn(addr, i) {
          int.to_string(i + 1) <> ". " <> addr
        })
      ToolSuccess(
        tool_use_id: call.id,
        content: "Allowed contacts:\n" <> string.join(lines, "\n"),
      )
    }
  }
}

// ---------------------------------------------------------------------------
// check_inbox
// ---------------------------------------------------------------------------

fn run_check_inbox(
  call: ToolCall,
  config: comms_types.CommsConfig,
) -> ToolResult {
  let decoder = {
    use limit <- decode.optional_field("limit", 10, decode.int)
    use after <- decode.optional_field("after", "", decode.string)
    decode.success(#(limit, after))
  }
  let #(limit, after) = case json.parse(call.input_json, decoder) {
    Ok(params) -> params
    Error(_) -> #(10, "")
  }
  let clamped = int.min(50, int.max(1, limit))
  let after_opt = case after {
    "" -> None
    ts -> Some(ts)
  }
  case
    email.list_messages(config.inbox_id, config.api_key_env, clamped, after_opt)
  {
    Error(reason) ->
      ToolFailure(tool_use_id: call.id, error: "Inbox check failed: " <> reason)
    Ok(messages) ->
      case messages {
        [] ->
          ToolSuccess(tool_use_id: call.id, content: "No messages in inbox.")
        _ -> {
          let lines =
            list.map(messages, fn(m) {
              m.message_id
              <> " ["
              <> m.timestamp
              <> "] from="
              <> m.from
              <> " subject=\""
              <> string.slice(m.subject, 0, 60)
              <> "\""
              <> case m.preview {
                "" -> ""
                p -> " — " <> string.slice(p, 0, 80)
              }
            })
          ToolSuccess(
            tool_use_id: call.id,
            content: "Inbox ("
              <> int.to_string(list.length(messages))
              <> " messages):\n"
              <> string.join(lines, "\n"),
          )
        }
      }
  }
}

// ---------------------------------------------------------------------------
// read_message
// ---------------------------------------------------------------------------

fn run_read_message(
  call: ToolCall,
  config: comms_types.CommsConfig,
) -> ToolResult {
  let decoder = {
    use message_id <- decode.field("message_id", decode.string)
    decode.success(message_id)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid read_message input: requires message_id",
      )
    Ok(message_id) ->
      case email.get_message(config.inbox_id, config.api_key_env, message_id) {
        Error(reason) ->
          ToolFailure(tool_use_id: call.id, error: "Read failed: " <> reason)
        Ok(msg) ->
          ToolSuccess(
            tool_use_id: call.id,
            content: "From: "
              <> msg.from
              <> "\nTo: "
              <> msg.to
              <> "\nSubject: "
              <> msg.subject
              <> "\nDate: "
              <> msg.timestamp
              <> "\n\n"
              <> msg.text,
          )
      }
  }
}

/// Check if a tool name is a comms tool.
pub fn is_comms_tool(name: String) -> Bool {
  name == "send_email"
  || name == "list_contacts"
  || name == "check_inbox"
  || name == "read_message"
}
