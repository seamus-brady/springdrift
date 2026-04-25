//// Communications agent — sends and reads email via AgentMail.
////
//// The comms agent handles outbound email (to allowed recipients only)
//// and inbox reading. All outbound messages pass through the D' output
//// gate — the agent must not send unreviewed content to external recipients.
////
//// Defense in depth:
//// 1. Hard allowlist in the tool executor (not D'-bypassable)
//// 2. Deterministic regex rules (credentials, internal URLs, system internals)
//// 3. LLM-scored D' features (comms agent override, tighter thresholds)

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{type AgentSpec, AgentSpec, Permanent}
import comms/types as comms_types
import gleam/list
import gleam/option.{None, Some}
import llm/provider.{type Provider}
import llm/types as llm_types
import tools/builtin
import tools/comms

const system_prompt = "You are a communications agent responsible for sending and reading email on behalf of the operator.

## Rules

1. **Always call list_contacts before send_email** to confirm the recipient is on the allowed list. Sending to unlisted addresses will fail.
2. **Write in professional email tone.** Clear, concise, well-structured. Use proper greetings and sign-offs.
3. **Never include system internals** in emails: no cycle IDs, no D' scores, no sensorium data, no raw JSON, no debug output. Recipients are external — they don't know about the agent's architecture.
4. **Provide clear context.** The recipient may not have access to the web GUI. Every email should be self-contained and make sense on its own.
5. **For scheduled reports**, format as a proper summary with sections, key findings, and any action items.
6. **For inbox messages**, summarize the key points when reporting back to the operator.

## Tool Decision Tree

- Need to send an email? → list_contacts → send_email
- Need to check what's arrived? → check_inbox
- Need to read a specific message? → read_message (use the message_id from check_inbox)
- Asked to email someone not on the list? → Report this to the operator, do NOT attempt to send.

## Self-check before you start
The instruction may begin with a <refs> XML block listing artifact_id, task_id, or prior_cycle_id values passed by the orchestrator. If your instruction clearly references prior message content (e.g. \"reply to the message I was looking at\", \"send the report we drafted\") but the relevant ref is missing from the <refs> block, do NOT guess, fabricate, or spin asking the deputy. Instead, respond with exactly:

[NEEDS_INPUT: <one short sentence naming what is missing and why you need it>]

Then stop. The orchestrator will see this and redispatch with the correct ref.

## Before you return
End your final reply with one line in this format:

Interpreted as: <one sentence summary of how you understood the task and what you did>

Keep it to one sentence. This lets the orchestrator notice if your interpretation doesn't match the intent.
"

pub fn spec(
  provider: Provider,
  model: String,
  config: comms_types.CommsConfig,
  comms_dir: String,
  max_tokens: Int,
  max_turns: Int,
  max_errors: Int,
  skills_dirs: List(String),
) -> AgentSpec {
  let tools = list.flatten([comms.all(), builtin.agent_tools()])

  AgentSpec(
    name: "comms",
    human_name: "Communications",
    description: "Send and receive email. Can send to allowed recipients, check inbox, and read messages.",
    system_prompt:,
    provider:,
    model:,
    max_tokens:,
    max_turns:,
    max_consecutive_errors: max_errors,
    max_context_messages: Some(20),
    tools:,
    restart: Permanent,
    tool_executor: comms_executor(config, comms_dir, skills_dirs),
    inter_turn_delay_ms: 200,
    redact_secrets: True,
  )
}

fn comms_executor(
  config: comms_types.CommsConfig,
  comms_dir: String,
  skills_dirs: List(String),
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case comms.is_comms_tool(call.name) {
      True -> comms.execute(call, config, comms_dir, None)
      False -> builtin.execute(call, skills_dirs)
    }
  }
}
