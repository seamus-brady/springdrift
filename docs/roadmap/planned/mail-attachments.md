# Mail Attachments — Send and Receive Email Attachments

**Status**: Planned
**Priority**: Medium — extends comms agent capability
**Effort**: Medium (~300-400 lines)

## Problem

The comms agent can send and receive plain text email via AgentMail, but
has no support for attachments. This limits its usefulness for real
communication workflows — sending reports, receiving documents, sharing
artifacts.

Common use cases:

- Sending a completed research report as a PDF or Markdown attachment
- Receiving a document the operator wants the agent to process
- Attaching scheduler output to delivery emails
- Sharing artifacts (web extractions, code output) via email

## Proposed Solution

### 1. Outbound Attachments

Extend `send_email` tool to accept an optional `attachments` parameter:

- Source from artifact store (by artifact ID)
- Source from document library (by document ID)
- Source from scheduler output (by job ID)
- Inline content (small text/Markdown, with size limit)

AgentMail API attachment support TBD — may require multipart upload or
base64 encoding in the JSON payload.

### 2. Inbound Attachments

When the inbox poller receives a message with attachments:

- Store each attachment in the artifact store (reuse existing 50KB
  truncation for large files)
- Include attachment metadata in the `CommsMessage` record
- The `read_message` tool should surface attachment IDs so the agent
  can retrieve content via `retrieve_result`

### 3. Safety

Attachments pass through the same three-layer D' safety as message content:

- Hard allowlist (recipient check — already in place)
- Deterministic rules: block executable attachments, check for
  credential patterns in attachment content
- Agent override D' scoring: attachment content included in the
  scored payload

Inbound attachments from unknown senders should be treated with extra
caution — the content could contain prompt injection attempts.

## Open Questions

- What file types should be supported? Start with text/Markdown/PDF?
- Size limits for outbound attachments?
- Should inbound attachments trigger automatic processing (summarisation,
  fact extraction) or wait for the agent to explicitly read them?
- AgentMail API attachment format — needs investigation
