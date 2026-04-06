# Communications Agent — Specification

**Status**: Phase 1-3 Implemented (Email via AgentMail + Web Admin Tab + Inbox Poller)
**Date**: 2026-03-26 (spec), 2026-03-28 (Phase 1), 2026-03-29 (Phase 2-3, bug fixes)
**Dependencies**: Multi-tenant (planned), Scheduler (implemented), D' safety system (implemented)

---

## Implementation Status

**Phase 1 is complete.** Email sending and receiving via AgentMail HTTP API is
implemented and working. The following are implemented:

- `src/comms/types.gleam` — CommsMessage, CommsChannel (Email), Direction, DeliveryStatus, CommsConfig
- `src/comms/email.gleam` — AgentMail HTTP client (send_message, list_messages, get_message)
- `src/comms/log.gleam` — JSONL persistence in `.springdrift/memory/comms/`
- `src/tools/comms.gleam` — 4 tools (send_email, list_contacts, check_inbox, read_message) with hard allowlist
- `src/agents/comms.gleam` — Agent spec (max_turns=6, max_context=20, Permanent restart)
- `src/config.gleam` — `[comms]` section with enabled, inbox_id, api_key_env, allowed_recipients, from_name, max_outbound_per_hour
- `src/paths.gleam` — comms_dir() path
- `.springdrift_example/dprime.json` — comms agent override (tighter thresholds) + 5 deterministic output rules
- Three-layer D' safety: hard allowlist, deterministic rules, agent-specific LLM scoring
- Web admin Comms tab (table of sent/received messages from JSONL log, last 7 days)
- Bug fixes: FFI function name (get_datetime not get_timestamp), AgentMail response decoders (to field is array, lenient optional_field decoders)
- D' input gate fix: interactive input now skips structural injection heuristics (operator may paste technical content about safety systems)
- `src/comms/poller.gleam` — OTP inbox polling actor (60s default, configurable)
- Poller seeds seen_ids from JSONL on startup (no duplicate processing after restart)
- Poller routes inbound email as SchedulerInput (not UserInput) so agent distinguishes email from operator
- Comms tab deduplicates by message_id
- Auto-resolve inbox_id from from_address via AgentMail list inboxes API (no manual UUID needed)
- `comms_from_address` and `comms_poll_interval_ms` config fields added
- Comms enabled by default (disabled if no from_address or API key)

**Deferred to future phases:**

- WhatsApp channel support (Business API client, webhook inbound)
- Web GUI operator send (compose and send from admin)
- Multi-tenant wiring (per-tenant channel config, isolation)
- Channel routing (comms/router.gleam)
- Message templates (comms/templates.gleam)
- Scheduler integration for `delivery = "comms"`
- Meta observer alert delivery via comms

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Channel Types](#channel-types)
- [Message Types](#message-types)
- [D' Integration](#d-integration)
  - [Flow](#flow)
  - [Additional output gate features for comms](#additional-output-gate-features-for-comms)
  - [Deterministic pre-filter rules for comms](#deterministic-pre-filter-rules-for-comms)
- [Multi-Tenant Integration](#multi-tenant-integration)
  - [Per-tenant channel config](#per-tenant-channel-config)
  - [Tenant isolation](#tenant-isolation)
  - [User attribution](#user-attribution)
- [Scheduler Integration](#scheduler-integration)
  - [Scheduled message delivery](#scheduled-message-delivery)
  - [Alert delivery](#alert-delivery)
  - [Forecaster notifications](#forecaster-notifications)
- [Comms Agent (`agents/comms.gleam`)](#comms-agent-agentscommsgleam)
  - [Specification](#specification)
  - [Tools](#tools)
  - [System prompt](#system-prompt)
- [Inbound Message Handling](#inbound-message-handling)
  - [Email inbound (IMAP polling)](#email-inbound-imap-polling)
  - [WhatsApp inbound (webhook)](#whatsapp-inbound-webhook)
  - [Inbound D' evaluation](#inbound-d-evaluation)
- [Web GUI Updates](#web-gui-updates)
  - [Conversations Tab (new admin tab)](#conversations-tab-new-admin-tab)
  - [Message Detail View](#message-detail-view)
  - [Operator Send](#operator-send)
  - [Chat Integration](#chat-integration)
- [Persistence](#persistence)
- [Configuration](#configuration)
  - [Per-tenant (`comms.toml`)](#per-tenant-commstoml)
  - [Global config.toml additions](#global-configtoml-additions)
- [Implementation Order](#implementation-order)
- [Security Considerations](#security-considerations)
- [Relationship to Existing Components](#relationship-to-existing-components)


## Overview

A specialist communications agent that handles outbound and inbound messaging across email and WhatsApp channels. Integrates with the D' safety system (all outbound messages pass through the output gate), the scheduler (timed and recurring messages), and the multi-tenant architecture (per-tenant channel config, user attribution).

The comms agent does not replace the web chat interface — it extends the agent's reach beyond the browser to asynchronous channels where operators and stakeholders expect to receive reports, alerts, and updates.

---

## Architecture

```
agents/comms.gleam              — Specialist agent spec (tools, system prompt)
comms/types.gleam               — Channel, Message, Conversation, DeliveryStatus types
comms/router.gleam              — Channel routing: which messages go where
comms/email.gleam               — SMTP client (outbound) + IMAP/webhook (inbound)
comms/whatsapp.gleam            — WhatsApp Business API client (outbound + inbound)
comms/templates.gleam           — Message templates (reports, alerts, summaries)
comms/log.gleam                 — Append-only JSONL for all sent/received messages
```

---

## Channel Types

```gleam
pub type Channel {
  Email(config: EmailChannelConfig)
  WhatsApp(config: WhatsAppChannelConfig)
}

pub type EmailChannelConfig {
  EmailChannelConfig(
    smtp_host: String,
    smtp_port: Int,
    smtp_username: String,
    smtp_password_env: String,    // Env var name, never plaintext
    tls: Bool,
    from_address: String,
    from_name: String,
    imap_host: Option(String),    // For inbound — None if outbound-only
    imap_port: Option(Int),
    imap_poll_interval_ms: Option(Int),
  )
}

pub type WhatsAppChannelConfig {
  WhatsAppChannelConfig(
    api_base_url: String,         // WhatsApp Business API endpoint
    phone_number_id: String,
    access_token_env: String,     // Env var name
    webhook_verify_token: String, // For inbound webhook verification
    webhook_path: String,         // Path on the web server for callbacks
  )
}
```

---

## Message Types

```gleam
pub type CommsMessage {
  CommsMessage(
    id: String,                   // UUID
    channel: String,              // "email" | "whatsapp"
    direction: MessageDirection,
    from: String,                 // Address or phone number
    to: String,
    subject: Option(String),      // Email only
    body: String,
    template: Option(String),     // Template name if used
    attachments: List(Attachment),
    metadata: CommsMetadata,
    status: DeliveryStatus,
  )
}

pub type MessageDirection {
  Outbound    // Agent → external
  Inbound     // External → agent
}

pub type DeliveryStatus {
  Pending
  Sent
  Delivered
  Read          // WhatsApp read receipts
  Failed(reason: String)
  Bounced       // Email bounce
}

pub type CommsMetadata {
  CommsMetadata(
    tenant_id: String,
    triggered_by: String,         // "scheduler:{job_name}" | "agent" | "operator"
    cycle_id: Option(String),
    dprime_score: Option(Float),  // Output gate score on the message body
    dprime_decision: Option(String),
  )
}

pub type Attachment {
  Attachment(
    filename: String,
    content_type: String,
    content: String,              // Base64 encoded or file path
  )
}
```

---

## D' Integration

All outbound messages pass through the D' output gate before sending. This is non-negotiable — the agent must not send unreviewed content to external recipients.

### Flow

```
Comms Agent generates message body
  → D' output gate evaluation (deterministic pre-filter + LLM scorer)
    → ACCEPT: message sent via channel
    → MODIFY: agent revises, re-evaluates (up to max_modifications)
    → REJECT: message NOT sent, operator notified via web GUI
```

### Additional output gate features for comms

The output gate's feature set should be extended for external-facing messages:

```json
{
  "name": "recipient_appropriateness",
  "importance": "high",
  "description": "Content is appropriate for the recipient's role and relationship — do not send internal technical details to external clients",
  "critical": true
},
{
  "name": "confidentiality",
  "importance": "high",
  "description": "Message does not contain information belonging to other tenants, clients, or matters",
  "critical": true
},
{
  "name": "tone",
  "importance": "medium",
  "description": "Professional tone appropriate for the channel — email is formal, WhatsApp can be more conversational",
  "critical": false
}
```

### Deterministic pre-filter rules for comms

```json
{
  "comms_rules": [
    { "id": "no-credentials-in-email", "pattern": "\\bsk-[A-Za-z0-9_-]{20,}", "action": "block" },
    { "id": "no-internal-urls", "pattern": "localhost|127\\.0\\.0\\.1|\\:8080", "action": "block" },
    { "id": "no-raw-json", "pattern": "\\{\\\"cycle_id\\\"", "action": "escalate" },
    { "id": "no-system-internals", "pattern": "dprime|sensorium|CognitiveState", "action": "escalate" }
  ]
}
```

---

## Multi-Tenant Integration

### Per-tenant channel config

Each tenant configures their channels in their tenant data directory:

```
.springdrift/tenants/{tenant_id}/comms.toml
```

```toml
[email]
smtp_host = "smtp.example.com"
smtp_port = 587
smtp_username = "agent@example.com"
smtp_password_env = "SMTP_PASSWORD"
tls = true
from_address = "agent@example.com"
from_name = "Springdrift Agent"
# Inbound (optional)
# imap_host = "imap.example.com"
# imap_port = 993
# imap_poll_interval_ms = 60000

[whatsapp]
api_base_url = "https://graph.facebook.com/v18.0"
phone_number_id = "123456789"
access_token_env = "WHATSAPP_TOKEN"
webhook_verify_token = "springdrift-verify"
webhook_path = "/webhook/whatsapp"

[[contacts]]
name = "Alice"
email = "alice@example.com"
whatsapp = "+353861234567"
role = "operator"
# Which message types this contact receives
receives = ["scheduled_reports", "alerts", "escalations"]

[[contacts]]
name = "Team Lead"
email = "lead@example.com"
role = "stakeholder"
receives = ["weekly_summary"]
```

### Tenant isolation

- Messages from tenant A are never visible to tenant B
- Channel configs are per-tenant
- The comms JSONL log is per-tenant (`tenants/{id}/memory/comms/YYYY-MM-DD-comms.jsonl`)
- WhatsApp webhook routing uses the phone_number_id to identify the tenant
- Email inbound routing uses the to-address to identify the tenant

### User attribution

Every message records `tenant_id` and `triggered_by` in metadata. The audit trail shows who triggered what message and when.

---

## Scheduler Integration

### Scheduled message delivery

The existing scheduler can trigger the comms agent for recurring reports:

```toml
# In schedule.toml or via schedule_from_spec tool

[[task]]
name = "weekly-summary"
kind = "recurring"
interval_ms = 604800000    # Weekly
query = "Generate a weekly summary of research activity and send it to the team"
delivery = "comms"
```

When the scheduler fires a job with `delivery = "comms"`, the cognitive loop:
1. Runs the query through the normal cycle (researcher, writer, etc.)
2. Passes the result to the comms agent
3. Comms agent formats for the appropriate channel(s)
4. D' output gate evaluates
5. Message sent to configured recipients

### Alert delivery

The meta observer can trigger comms for escalations:

```gleam
EscalateToUser(title, body) →
  if comms_enabled:
    send via configured alert channel (email/WhatsApp)
  else:
    show in web GUI only (current behaviour)
```

### Forecaster notifications

When the Forecaster detects task health degradation, it can send a brief alert:
```
⚠️ Task "Q2 Research Report" health declining (D' score 0.62).
Replan suggested. Check the web admin for details.
```

---

## Comms Agent (`agents/comms.gleam`)

### Specification

| Property | Value |
|---|---|
| Tools | `send_email`, `send_whatsapp`, `list_contacts`, `get_conversation`, `draft_message` |
| max_turns | 4 |
| max_context_messages | 20 |
| Restart | Permanent |

### Tools

| Tool | Purpose |
|---|---|
| `send_email(to, subject, body, attachments)` | Send email via configured SMTP |
| `send_whatsapp(to, body, template)` | Send WhatsApp message via Business API |
| `list_contacts(filter)` | List configured contacts, optionally filtered by role or receives |
| `get_conversation(contact, channel, limit)` | Retrieve recent message history with a contact |
| `draft_message(channel, to, purpose)` | Generate a draft without sending — for review |

### System prompt

The comms agent is instructed to:
- Always use `draft_message` before `send_*` unless the message is a routine scheduled delivery
- Match tone to channel (email: formal, WhatsApp: concise)
- Never include system internals, debug info, or raw JSON in messages
- Respect contact `receives` filters — don't send alerts to contacts who only receive summaries
- Include clear context in every message — the recipient may not have the web GUI open

---

## Inbound Message Handling

### Email inbound (IMAP polling)

An OTP actor polls the configured IMAP mailbox at `imap_poll_interval_ms`:
1. Fetch unread messages
2. Match sender to known contacts
3. Route to the correct tenant's cognitive loop as a `CommsInput` message (new CognitiveMessage variant)
4. The cognitive loop treats it like a user input but with `source: "email:{address}"`
5. Response is sent back via the same channel

### WhatsApp inbound (webhook)

The web server handles WhatsApp webhook callbacks at the configured path:
1. Verify webhook signature
2. Parse incoming message
3. Match phone number to tenant + contact
4. Route to cognitive loop as `CommsInput`
5. Response sent back via WhatsApp

### Inbound D' evaluation

Inbound messages from external sources pass through the D' **input gate** — same as web GUI input. The deterministic pre-filter catches injection attempts embedded in emails or WhatsApp messages.

---

## Web GUI Updates

### Conversations Tab (new admin tab)

A new admin tab showing all comms activity for the current tenant:

| Column | Content |
|---|---|
| Time | Timestamp |
| Direction | ↗ Outbound / ↙ Inbound |
| Channel | 📧 Email / 💬 WhatsApp |
| Contact | Name and address |
| Subject | Email subject (blank for WhatsApp) |
| Status | Pending / Sent / Delivered / Read / Failed / Bounced |
| D' Score | Output gate score (outbound only) |

Click a row to expand the full message body.

### Message Detail View

Expanding a message shows:
- Full message body (rendered markdown for email, plain for WhatsApp)
- D' gate decision and explanation (if outbound)
- Triggered by (scheduler job name, agent, or operator)
- Cycle ID link (click through to inspect_cycle)
- Delivery status timeline (Pending → Sent → Delivered → Read)
- Attachments list

### Operator Send

The admin can compose and send messages directly:
- Select contact from dropdown
- Select channel (email/WhatsApp)
- Write message body
- Preview shows D' evaluation before sending
- Send button dispatches through the comms agent (so D' gate applies)

### Chat Integration

When the agent receives an inbound email or WhatsApp message, it appears in the chat interface as a notification:
```
📧 Email from alice@example.com: "Can you send me the updated research report?"
```

The agent's response (if it generates one) shows in chat with a "sent via email" or "sent via WhatsApp" badge.

---

## Persistence

All messages stored in append-only JSONL:
```
.springdrift/memory/comms/YYYY-MM-DD-comms.jsonl
```

Format matches other memory stores. The Librarian indexes comms entries in ETS for the Conversations admin tab.

Message content is subject to secret redaction (`narrative/redactor.gleam`) before persistence.

---

## Configuration

### Per-tenant (`comms.toml`)

See multi-tenant integration section above.

### Global config.toml additions

```toml
[comms]
# Enable communications agent (default: false)
# enabled = false

# Max outbound messages per hour per tenant (default: 50)
# max_outbound_per_hour = 50

# Require D' output gate ACCEPT before sending (default: true — cannot be disabled)
# dprime_required = true
```

`dprime_required = true` is a hard constraint that cannot be overridden. The agent must never send unreviewed content to external recipients.

---

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | Types, JSONL persistence, message logging | Small |
| 2 | Email outbound (SMTP client) | Medium |
| 3 | Comms agent spec + tools | Medium |
| 4 | D' integration (output gate for outbound, input gate for inbound) | Small — existing infrastructure |
| 5 | Scheduler integration (delivery = "comms") | Small |
| 6 | Web GUI: Conversations tab + message detail | Medium |
| 7 | WhatsApp outbound (Business API client) | Medium |
| 8 | Email inbound (IMAP poller) | Medium |
| 9 | WhatsApp inbound (webhook handler) | Medium |
| 10 | Operator send from admin UI | Small |
| 11 | Multi-tenant wiring (per-tenant config, isolation) | Medium — depends on multi-tenant plan |

Email outbound (Phase 2) can ship independently and provides immediate value for scheduled report delivery. WhatsApp and inbound handling are additive.

---

## Security Considerations

- **All outbound messages pass through D' output gate** — non-negotiable
- **Deterministic pre-filter** blocks credentials, internal URLs, system internals in outbound messages
- **Inbound messages pass through D' input gate** — external messages are untrusted
- **Channel credentials** stored as env var references, never in config files
- **Tenant isolation** — messages from one tenant never visible to another
- **Rate limiting** — per-tenant outbound cap prevents abuse
- **WhatsApp webhook verification** — signature validation prevents spoofed inbound
- **Email sender verification** — SPF/DKIM recommended in deployment docs
- **Attachment scanning** — future enhancement: scan inbound attachments before processing
- **Confidentiality feature** in output gate prevents cross-tenant/cross-client information leakage

---

## Relationship to Existing Components

| Component | Relationship |
|---|---|
| Scheduler | Triggers comms agent for recurring deliveries |
| D' output gate | Evaluates all outbound messages before sending |
| D' input gate | Evaluates all inbound messages before processing |
| Deterministic pre-filter | Blocks credentials and system internals in outbound |
| Meta observer | EscalateToUser can trigger alert delivery |
| Forecaster | Task health alerts via configured channel |
| Archivist | Comms cycles produce narrative entries like any other cycle |
| Multi-tenant | Per-tenant channel config, contact lists, message isolation |
| Web GUI | Conversations tab, message detail, operator send |
| Librarian | Indexes comms JSONL for admin queries |
