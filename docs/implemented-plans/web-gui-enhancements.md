# Web GUI Enhancements — Implementation Record

**Status**: Implemented
**Date**: 2026-03-25

---

## Table of Contents

- [Overview](#overview)
- [New Admin Tabs](#new-admin-tabs)
  - [D' Safety Panel](#d-safety-panel)
  - [D' Config Panel](#d-config-panel)
- [Chat Enhancements](#chat-enhancements)
  - [Revised Badge](#revised-badge)
  - [Server-Authoritative Chat History](#server-authoritative-chat-history)
- [Protocol Additions](#protocol-additions)
- [Resume by Default](#resume-by-default)


## Overview

Multiple enhancements to the web GUI admin dashboard and chat interface, adding D' visibility, quality feedback indicators, and server-authoritative chat history.

## New Admin Tabs

### D' Safety Panel
- Real-time table of all gate decisions (input, tool, output, post_exec, deterministic)
- Columns: Time, Cycle ID, Node Type, Gate, Decision (with emoji badges), Score (color-coded)
- Live updates when tab is active — new safety notifications prepend to table
- Color coding: green (<0.35), amber (0.35-0.55), red (>0.55)
- Decision badges: ACCEPT, MODIFY, REJECT, ABORT, DETERMINISTIC_BLOCK

### D' Config Panel
- Reads dprime.json directly from disk and renders:
  - Each gate with features (name, importance, critical flag, description)
  - Thresholds (modify/reject) and canary status per gate
  - Agent overrides with per-agent tool gate features
  - Meta observer settings (rate limits, thresholds, decay)
  - Deterministic rules: enabled status, rule counts by scope, rule table (ID + scope + action)

## Chat Enhancements

### Revised Badge
- Amber "revised" badge appears on assistant messages that were modified by the output gate
- Hover tooltip: "This response was revised by the D' quality gate before delivery"
- Tracks via `wasRevised` JS state: set to true on MODIFY safety notification, consumed on next assistant message
- Persists in chat history for page reload

### Server-Authoritative Chat History
- Removed localStorage-based chat persistence
- On WebSocket connect, server sends `SessionHistory` message with full conversation from session.json
- Browser renders server history on receipt
- Single source of truth: agent's session.json
- Page refresh gets history from server again

## Protocol Additions

| Client Message | Server Message | Purpose |
|---|---|---|
| `RequestDprimeData` | `DprimeData(gates_json)` | D' gate history for today |
| `RequestDprimeConfig` | `DprimeConfigData(config_json)` | dprime.json contents |
| — | `SessionHistory(messages_json)` | Conversation history on connect |

## Resume by Default

- `gleam run` now resumes the previous session (loads session.json)
- `gleam run -- --fresh` starts clean
- Previous behaviour (`--resume` flag) replaced
