# File Uploads — Operator File Upload via Web GUI

**Status**: Planned
**Priority**: Medium — enables document ingestion workflows
**Effort**: Medium (~300-400 lines)

## Problem

The operator has no way to give the agent files through the web GUI. To
share a document, PDF, or data file, the operator must either paste the
content into the chat (losing formatting, limited by message size) or
place the file on disk and tell the agent where to find it (requires
shell access, breaks the web GUI workflow).

## Proposed Solution

### 1. Upload Endpoint

Add a file upload HTTP endpoint to `web/gui.gleam`:

- `POST /api/upload` — multipart form upload
- Authenticated (same bearer token as other endpoints)
- Size limit (configurable, default 10MB — matches existing `read_file` limit)
- Store uploaded files in `.springdrift/uploads/` with UUID filenames
- Return upload metadata (ID, original filename, size, content type)

### 2. Chat Integration

When a file is uploaded:

- Create an artifact record in the artifact store (reuse existing
  infrastructure — 50KB content truncation for indexing, full file on disk)
- Inject a system message into the conversation: "Operator uploaded
  {filename} ({size}). Artifact ID: {id}. Use `retrieve_result` to
  read the content."
- The agent can then process the file using existing tools

### 3. Supported Formats

Start with text-based formats the agent can process:

- Plain text, Markdown, CSV, JSON, TOML, YAML
- PDF (text extraction — may need an Erlang/OTP PDF library or
  external tool)
- Source code files

Binary formats (images, archives) stored but not processable without
additional tooling.

### 4. Web GUI Changes

- Add an upload button/drop zone to the chat interface in `web/html.gleam`
- Show upload progress and confirmation
- Display uploaded files in the conversation as clickable references

## Open Questions

- Should uploads go through D' safety evaluation? The content is
  operator-provided, so the input gate fast-accept path may be appropriate.
- PDF text extraction — use an existing Erlang library or shell out to
  `pdftotext`?
- Should the TUI also support file references (e.g. `/upload path/to/file`)?
- Interaction with the planned document library feature?
