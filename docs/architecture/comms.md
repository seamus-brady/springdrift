# Communications Architecture

The communications subsystem enables Springdrift to send and receive email via
the AgentMail service. It includes an HTTP client, inbox polling, message
persistence, and a three-layer safety system for outbound messages.

---

## 1. Overview

Communications is an opt-in subsystem (`comms_enabled` config, default False).
When enabled, a specialist comms agent is registered and an inbox poller starts
monitoring for inbound messages. Outbound email passes through the strictest
safety chain in the system.

```
User/Agent ──→ Comms Agent (4 tools) ──→ Hard Allowlist ──→ D' Gate ──→ AgentMail API
                                                                            │
Inbox Poller ←──── AgentMail API ←──── External Sender                     │
    │                                                                       │
    └──→ SchedulerInput to Cognitive Loop                                  │
                                                                            ▼
                                              .springdrift/memory/comms/YYYY-MM-DD-comms.jsonl
```

## 2. AgentMail HTTP Client

`src/comms/email.gleam` wraps the AgentMail REST API (`https://api.agentmail.to/v0/`):

| Function | Endpoint | Purpose |
|---|---|---|
| `send_message` | `POST /inboxes/{id}/messages/send` | Send email with optional `in_reply_to` for threading |
| `list_messages` | `GET /inboxes/{id}/messages` | List inbox messages (with limit and after filters) |
| `get_message` | `GET /inboxes/{id}/messages/{msg_id}` | Get full message content (text + HTML) |

Authentication uses a bearer token from an environment variable (default
`AGENTMAIL_API_KEY`, configurable via `comms_api_key_env`).

### Types

- `SendResult` -- `message_id` and `thread_id` from the API
- `InboxMessage` -- summary from list endpoint (id, from, to, subject, preview, timestamp)
- `FullMessage` -- complete message with text and HTML body

## 3. Inbox Poller

`src/comms/poller.gleam` is an OTP actor that periodically checks for new messages
and routes them to the cognitive loop.

### Lifecycle

1. **Startup** -- seeds `seen_ids` from ALL messages in the comms JSONL log (no
   re-processing on restart).
2. **Tick** -- polls AgentMail `list_messages` with limit and after-timestamp filters.
3. **New message** -- messages not in `seen_ids` are:
   - Logged to comms JSONL
   - Sent as `SchedulerInput` to the cognitive loop (not `UserInput` -- inbound
     email is untrusted external input, goes through the scheduler input path)
4. **Failure** -- logged and retried next tick. `consecutive_failures` tracks
   persistent issues.

### Configuration

```gleam
pub type PollerConfig {
  PollerConfig(
    inbox_id: String,
    api_key_env: String,
    poll_interval_ms: Int,    // Default: 60000 (60s)
    from_address: String,
  )
}
```

## 4. Comms Agent

`src/agents/comms.gleam` defines the specialist comms agent:

| Property | Value |
|---|---|
| Tools | 4 (send_email, list_contacts, check_inbox, read_message) |
| max_turns | 6 |
| max_context_messages | 20 |
| Restart | Permanent |

The agent's system prompt instructs it to use professional tone, respect threading,
and never include system internals in outbound messages.

## 5. Tools

Defined in `src/tools/comms.gleam`:

| Tool | Purpose | Safety |
|---|---|---|
| `send_email` | Send email to a recipient | Hard allowlist + D' gate |
| `list_contacts` | List allowed recipients from config | No gate (read-only) |
| `check_inbox` | List recent inbox messages | No gate (read-only) |
| `read_message` | Read full message by ID | No gate (read-only) |

## 6. Three-Layer Safety

Outbound email has the strictest safety chain in the system:

### Layer 1: Hard Allowlist

The tool executor checks `comms_allowed_recipients` before any send. Recipients
not on the list are rejected immediately with no LLM evaluation. This is a
non-bypassable code-level check.

### Layer 2: Deterministic Rules

Five regex rules in `dprime.json` run before the LLM scorer:

| Rule ID | Pattern | Action | Purpose |
|---|---|---|---|
| `comms-bearer-token` | Bearer tokens, API keys | Block | Prevent credential leakage |
| `comms-localhost` | localhost/127.0.0.1 URLs | Block | Prevent internal URL exposure |
| `comms-env-var-ref` | Environment variable patterns | Block | Prevent env var leakage |
| `comms-system-json` | JSON config patterns | Escalate | Flag system config in content |
| `comms-system-jargon` | Internal system terminology | Escalate | Flag jargon for LLM review |

Block rules reject immediately. Escalate rules enrich context for the LLM scorer.

### Layer 3: Agent D' Override

The comms agent has tighter D' thresholds than the default tool gate:

| | Default tool gate | Comms override |
|---|---|---|
| Modify threshold | 0.40 | 0.30 |
| Reject threshold | 0.60 | 0.50 |

Four features evaluated:

| Feature | Importance | Purpose |
|---|---|---|
| `credential_exposure` | Critical | API keys, tokens, passwords in content |
| `internal_url_exposure` | Critical | Internal URLs, localhost references |
| `system_internals` | Medium | Agent internals, config details, cycle IDs |
| `tone_appropriateness` | Medium | Professional tone for external communication |

## 7. Message Persistence

`src/comms/log.gleam` provides append-only JSONL persistence:

- **Location**: `.springdrift/memory/comms/YYYY-MM-DD-comms.jsonl`
- **Record type**: `CommsMessage` (message_id, thread_id, direction, from, to,
  subject, body, timestamp, delivery_status)
- **Direction**: `Inbound` or `Outbound`
- **Delivery status**: `Sent`, `Delivered`, `Failed(reason)`

Both sent and received messages are logged. The poller seeds from this log on
restart to avoid re-processing.

## 8. Rate Limiting

`comms_max_outbound_per_hour` (default 20) limits outbound email volume. The
rate limit is enforced in the tool executor by counting recent outbound entries
in the comms log.

## 9. Configuration

All comms config lives in the `[comms]` TOML section:

| Field | Default | Purpose |
|---|---|---|
| `enabled` | False | Enable the comms subsystem |
| `inbox_id` | None | AgentMail inbox ID (required when enabled) |
| `api_key_env` | `"AGENTMAIL_API_KEY"` | Env var name for the API key |
| `allowed_recipients` | `[]` | Hard allowlist of email addresses |
| `from_name` | agent_name | Display name on outbound emails |
| `max_outbound_per_hour` | 20 | Rate limit for sends |
| `poll_interval_ms` | 60000 | Inbox check frequency |

## 10. Key Source Files

| File | Purpose |
|---|---|
| `comms/types.gleam` | `CommsMessage`, `CommsChannel`, `Direction`, `DeliveryStatus`, `CommsConfig` |
| `comms/email.gleam` | AgentMail HTTP client (send, list, get) |
| `comms/poller.gleam` | Inbox polling OTP actor |
| `comms/log.gleam` | JSONL persistence for sent/received messages |
| `agents/comms.gleam` | Comms agent spec and system prompt |
| `tools/comms.gleam` | Tool definitions with allowlist and rate limit enforcement |
