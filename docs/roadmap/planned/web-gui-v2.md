# Web GUI v2 — Specification

**Status**: Planned
**Date**: 2026-03-26
**Dependencies**: Multi-tenant (planned), Comms agent (planned), Autonomous Endeavours (planned)

---

## Table of Contents

- [Overview](#overview)
- [Current Limitations](#current-limitations)
- [Non-Blocking Thinking](#non-blocking-thinking)
  - [The Problem](#the-problem)
  - [The Solution](#the-solution)
  - [Technical Implementation](#technical-implementation)
- [Workspaces](#workspaces)
  - [Concept](#concept)
  - [How It Works](#how-it-works)
  - [Persistence](#persistence)
  - [Implementation](#implementation)
- [Unified Layout](#unified-layout)
  - [The Problem](#the-problem)
  - [The Solution](#the-solution)
  - [Navigation](#navigation)
- [Document Management](#document-management)
  - [Upload](#upload)
  - [Upload Flow](#upload-flow)
  - [Supported Formats](#supported-formats)
  - [Download / Export](#download-export)
  - [Implementation](#implementation)
- [Enhanced Chat Experience](#enhanced-chat-experience)
  - [Message Actions](#message-actions)
  - [Inline D' Indicators](#inline-d-indicators)
  - [Streaming-Style Display](#streaming-style-display)
  - [Markdown Rendering Improvements](#markdown-rendering-improvements)
- [Keyboard Shortcuts](#keyboard-shortcuts)
  - [Command Palette](#command-palette)
- [Real-Time System Status Bar](#real-time-system-status-bar)
- [Mobile Responsive](#mobile-responsive)
  - [Breakpoints](#breakpoints)
  - [Mobile Layout](#mobile-layout)
- [Notification System](#notification-system)
  - [Toast Notifications](#toast-notifications)
  - [Alert Notifications](#alert-notifications)
  - [Notification Centre](#notification-centre)
- [Theme](#theme)
  - [Dark Mode (default)](#dark-mode-default)
  - [Light Mode](#light-mode)
  - [System Preference](#system-preference)
- [Technology](#technology)
  - [Current: Embedded HTML/CSS/JS in Gleam strings](#current-embedded-htmlcssjs-in-gleam-strings)
  - [Proposed: Separate frontend build](#proposed-separate-frontend-build)
- [Implementation Order](#implementation-order)
- [What This Enables](#what-this-enables)


## Overview

The current web GUI is functional but minimal — a single chat panel, a set of admin tabs, and basic notifications. It was built to prove the system works, not to be a daily-driver interface.

This spec describes the next-generation web GUI: non-blocking interaction, workspaces, document management, richer admin views, and a UI that reflects what Springdrift actually is — not a chatbot, but a knowledge worker with memory, ongoing work, and system state worth seeing.

---

## Current Limitations

1. **Blocking thinking animation.** When the agent is thinking, the chat page locks. The operator can't type a follow-up, scroll back through messages, or do anything in the chat until the response arrives. For long cycles (opus reasoning, multi-agent delegation, output gate revision loops), this means 30-60 seconds of staring at dots. (The admin page at `/admin` is separate and unaffected — this is a chat-page-only problem.)

2. **Single chat panel.** One conversation thread. No way to have parallel conversations, review past sessions, or organise work by topic.

3. **No document management.** The agent can research and produce reports, but there's no way to upload source documents, download outputs, or manage the knowledge base through the UI.

4. **Admin tabs are disconnected.** The admin dashboard is a separate page from the chat. Switching between them loses context. There's no integrated view where the operator can see the conversation AND the system state.

5. **No mobile responsiveness.** The current layout breaks on narrow screens.

6. **No keyboard shortcuts.** Power users can't navigate without a mouse.

---

## Non-Blocking Thinking

### The Problem

When `Thinking` state is active, the JS sets `isThinking = true` and shows an overlay. The input is disabled. All admin tabs freeze because the WebSocket is single-threaded from the UI perspective.

### The Solution

Thinking becomes a background state indicator, not a modal lock.

```
┌──────────────────────────────────────────────────────┐
│ Chat                                                  │
│                                                       │
│ You: Research the 2027 agent market                   │
│                                                       │
│ ┌─────────────────────────────────────────────────┐  │
│ │ ⟳ Thinking...                                    │  │
│ │ Using tool: agent_researcher                     │  │
│ │ ✅ D' ACCEPT (score: 0.00)                      │  │
│ │ 12s elapsed │ opus-4-6 │ 2,341 tokens           │  │
│ └─────────────────────────────────────────────────┘  │
│                                                       │
│ [Type a message... ]                    [Queue ↩]    │
└──────────────────────────────────────────────────────┘
```

**Key changes:**

- The thinking indicator is inline in the chat, not a modal overlay
- Live tool call notifications stream into the thinking block as they happen
- D' decisions appear in real-time within the thinking block
- Elapsed time, model, and token count update live
- **Stop button**: a prominent stop/cancel button in the thinking block. Sends a `CancelCycle` message to the cognitive loop, which cancels the active think worker and any running agent delegations. The agent returns to Idle. The cycle is logged as cancelled.
- **The input field stays active.** The operator can type and queue a follow-up message
- **The send button shows "Queue" instead of "Send"** when the agent is thinking — the message joins the input queue

### Technical Implementation

- Remove the `thinkingOverlay` CSS class that blocks interaction on the chat page
- Replace with an inline `thinking-block` div that streams notifications
- WebSocket messages continue processing during thinking state
- Input queuing already exists (`input_queue` on CognitiveState) — the UI just needs to expose it
- Note: the admin page at `/admin` is already separate and unblocked — this fix is for the chat page only

---

## Workspaces

### Concept

A workspace is a named, persistent conversation context. The operator can have multiple workspaces — one for research, one for a specific project, one for system maintenance. Each workspace has its own message history and can be resumed independently.

```
┌───────────────────────┬──────────────────────────────┐
│ Workspaces            │ Chat                          │
│                       │                               │
│ ● Q2 Market Research  │ You: What did you find on...  │
│   3 messages, 2h ago  │                               │
│                       │ Curragh: Based on the         │
│ ○ D' Tuning           │ research from Brave Search... │
│   12 messages, 1d ago │                               │
│                       │                               │
│ ○ Three-Paper Work    │                               │
│   28 messages, 2d ago │                               │
│                       │                               │
│ [+ New Workspace]     │                               │
└───────────────────────┴──────────────────────────────┘
```

### How It Works

- Each workspace maps to a **saved session** — a `session.json` file with a workspace name
- Switching workspaces sends `RestoreMessages` to the cognitive loop with that workspace's message history
- The agent's memory (narrative, CBR, facts) is shared across all workspaces — it's the same agent, same identity, same knowledge
- Only the conversation context (message history) is per-workspace
- Creating a new workspace starts a fresh conversation with the same agent

### Persistence

```
.springdrift/
├── session.json              # Active workspace (current)
└── workspaces/
    ├── q2-market-research.json
    ├── dprime-tuning.json
    └── three-paper-work.json
```

### Implementation

- New WebSocket messages: `ListWorkspaces`, `SwitchWorkspace(name)`, `CreateWorkspace(name)`, `DeleteWorkspace(name)`
- The cognitive loop receives `RestoreMessages` on workspace switch — this already exists
- Active workspace name stored in `CognitiveState` for session save routing
- Workspace list rendered in a sidebar panel

---

## Unified Layout

### The Problem

Chat and admin are separate pages (`/chat` and `/admin`). The operator loses context switching between them.

### The Solution

A single-page layout with a sidebar, main panel, and optional detail panel.

```
┌────────┬────────────────────────────┬──────────────────┐
│Sidebar │ Main Panel                 │ Detail Panel     │
│        │                            │ (toggleable)     │
│ Chat   │                            │                  │
│ ────── │ [active view content]      │ [contextual      │
│ Work-  │                            │  detail]         │
│ spaces │                            │                  │
│ ────── │                            │                  │
│ Admin  │                            │                  │
│  D'    │                            │                  │
│  Cycles│                            │                  │
│  CBR   │                            │                  │
│  Tasks │                            │                  │
│  ...   │                            │                  │
│ ────── │                            │                  │
│ Docs   │                            │                  │
└────────┴────────────────────────────┴──────────────────┘
```

**Sidebar** (always visible, collapsible):
- Chat (current workspace)
- Workspace list
- Admin sections (D' Safety, D' Config, Cycles, Narrative, Log, Planner, Skills, Conversations, Endeavours)
- Documents section

**Main Panel**:
- Whatever is selected in the sidebar — chat, an admin view, a document, an endeavour detail

**Detail Panel** (toggleable, slides in from right):
- Contextual information for the current selection
- In chat: D' decisions for the current message, active delegations
- In Cycles view: cycle detail when a row is clicked
- In Endeavours: phase detail, session history

### Navigation

- Sidebar items are clickable — instant switch, no page reload
- All views share the same WebSocket connection
- Admin data loads on demand when the tab is selected (current behaviour, preserved)
- Browser back/forward navigates between views (history API)
- URL reflects the current view: `/chat`, `/admin/dprime`, `/endeavours/q2-market`, `/docs`

---

## Document Management

### Upload

Operators can upload documents through the UI for the Learner Ingestion system (when implemented) or as reference material for conversations.

```
┌──────────────────────────────────────────────────────┐
│ Documents                                             │
│                                                       │
│ ┌─ Knowledge Base ──────────────────────────────────┐│
│ │ legal/                                             ││
│ │   ├── aamodt-plaza-1994.md    Promoted  📊 0.82   ││
│ │   └── contract-liability.md   Studied   📊 —      ││
│ │ research/                                          ││
│ │   └── gartner-agents-2026.md  Normalised           ││
│ └────────────────────────────────────────────────────┘│
│                                                       │
│ ┌─ Inbox ───────────────────────────────────────────┐│
│ │ Drop files here or click to upload                 ││
│ │                                                    ││
│ │ 📄 market-report.pdf          Pending...           ││
│ └────────────────────────────────────────────────────┘│
│                                                       │
│ ┌─ Exports ─────────────────────────────────────────┐│
│ │ q2-market-analysis-final.md   Generated 2h ago    ││
│ │ dprime-audit-report.html      Generated 1d ago    ││
│ └────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────┘
```

### Upload Flow

1. Operator drags file to inbox area (or clicks to browse)
2. File uploaded via HTTP POST to `/api/upload`
3. Server writes to `.springdrift/knowledge/inbox/`
4. If Learner Ingestion is enabled: automatic normalisation + study cycle
5. If not: file available as reference, operator can ask "read the uploaded report"

### Supported Formats

- Markdown (.md) — stored directly
- Plain text (.txt) — stored directly
- PDF (.pdf) — text extracted, stored as markdown (requires Python `pdftotext` or similar)
- Word (.docx) — text extracted, stored as markdown

### Download / Export

- Reports generated by the agent can be downloaded as markdown or HTML
- SD Audit compliance reports downloadable as HTML
- Narrative exports downloadable as JSON

### Implementation

- New HTTP endpoints: `POST /api/upload`, `GET /api/documents`, `GET /api/documents/:id`, `DELETE /api/documents/:id`
- File storage in `.springdrift/knowledge/inbox/` (for ingestion) or `.springdrift/uploads/` (for reference)
- Document list served via WebSocket message: `RequestDocuments` / `DocumentsData`
- Upload progress via WebSocket notification

---

## Enhanced Chat Experience

### Message Actions

Hover over any message to see action buttons:

```
┌─────────────────────────────────────────────────┐
│ Curragh: Based on the research...               │
│                                                  │
│ [revised] claude-opus-4-6 │ 4,521 in / 892 out │
│                                                  │
│         [📋 Copy] [🔍 Inspect] [↩ Retry]       │
└─────────────────────────────────────────────────┘
```

- **Copy**: copy message text to clipboard
- **Inspect**: open the cycle detail for this message in the detail panel (links to `inspect_cycle`)
- **Retry**: re-send the user message that triggered this response (new cycle)
- **Edit & Retry**: edit the original user message and re-send (new cycle with revised input)

### Inline D' Indicators

Instead of separate notification lines, D' decisions appear as subtle inline badges:

```
You: Tell me about napalm manufacturing
  ❌ D' REJECT (0.67) — click for detail

Curragh: I can't help with that — it involves potential harm.
```

Click the D' badge to expand the full gate decision in the detail panel — features, scores, layer, explanation.

### Streaming-Style Display

Currently the full response appears at once. For long responses, render progressively as chunks arrive (even though the backend sends the complete response, the frontend can animate it word-by-word for a more responsive feel).

### Markdown Rendering Improvements

- Code syntax highlighting (highlight.js or Prism)
- Collapsible long code blocks
- Table rendering
- Mermaid diagram support (for agent-generated architecture diagrams)
- LaTeX math rendering (for research/engineering domains)

---

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Enter` | Send message (current) |
| `Shift+Enter` | New line (current) |
| `Ctrl+/` / `Cmd+/` | Toggle sidebar |
| `Ctrl+K` / `Cmd+K` | Command palette (quick navigation) |
| `Ctrl+1-9` / `Cmd+1-9` | Switch to admin tab 1-9 |
| `Ctrl+N` / `Cmd+N` | New workspace |
| `Ctrl+W` / `Cmd+W` | Close detail panel |
| `Escape` | Stop current processing / close detail panel / clear input |
| `↑` | Edit last sent message (in input field) |
| `Ctrl+Shift+D` | Toggle D' detail panel |
| `Ctrl+.` / `Cmd+.` | Stop current processing (same as stop button) |

### Command Palette

`Ctrl+K` opens a fuzzy-search command palette:

```
┌─────────────────────────────────────┐
│ > switch workspace q2               │
│                                     │
│   Switch to: Q2 Market Research     │
│   Switch to: Q2 Budget Analysis     │
│   ──────────────────────────────    │
│   View: D' Safety                   │
│   View: Cycles                      │
│   New Workspace                     │
│   Upload Document                   │
└─────────────────────────────────────┘
```

---

## Real-Time System Status Bar

A persistent status bar at the bottom of the screen showing live system state:

```
┌──────────────────────────────────────────────────────────────────┐
│ ● Curragh │ anthropic │ 12 cycles │ D': 0/1/0 │ 🟢 healthy    │
└──────────────────────────────────────────────────────────────────┘
```

| Segment | Content |
|---|---|
| Agent name | Identity |
| Provider | Active LLM provider |
| Cycles | Today's cycle count |
| D' | Accept/Modify/Reject counts today |
| Health | Diagnostic status (from self-diagnostic skill) |

Click any segment to jump to the relevant admin view.

When the agent is thinking:
```
┌──────────────────────────────────────────────────────────────────┐
│ ⟳ Curragh │ opus-4-6 │ thinking (8s) │ agent_researcher active  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Mobile Responsive

### Breakpoints

- **Desktop** (>1200px): Full three-panel layout
- **Tablet** (768-1200px): Sidebar collapses to icons, detail panel overlays
- **Mobile** (<768px): Single panel, bottom tab bar for navigation

### Mobile Layout

```
┌──────────────────────┐
│ ← Curragh        ≡  │
│                      │
│ Chat messages        │
│ ...                  │
│                      │
│ [Type a message...]  │
│                      │
├──────────────────────┤
│ 💬  📊  📁  ⚙️     │
│ Chat Admin Docs Set  │
└──────────────────────┘
```

---

## Notification System

### Toast Notifications

Non-intrusive toasts for events that don't need immediate attention:

```
┌──────────────────────────────────┐
│ ✅ Scheduled job completed:      │
│    "daily-briefing"              │
│                          [View]  │
└──────────────────────────────────┘
```

Auto-dismiss after 5 seconds. Click to navigate to relevant view.

### Alert Notifications

For events that need attention:

```
┌──────────────────────────────────┐
│ ⚠️ D' Meta Observer Escalation  │
│    High cycle rate + repeated    │
│    rejections detected           │
│              [Investigate] [Ack] │
└──────────────────────────────────┘
```

Persist until acknowledged.

### Notification Centre

Bell icon in header showing unread count. Click to see all notifications:

```
┌─────────────────────────────────────┐
│ Notifications (3 unread)            │
│                                     │
│ ● Meta escalation — 5m ago         │
│ ● Endeavour blocked — 1h ago       │
│ ○ Scheduled job completed — 3h ago │
│ ○ CBR case deprecated — 1d ago     │
└─────────────────────────────────────┘
```

---

## Theme

### Dark Mode (default)

Current dark theme refined — proper contrast ratios, consistent spacing, no harsh whites.

### Light Mode

Toggle via settings. Important for daytime use and accessibility.

### System Preference

Follows OS dark/light preference by default. Override available in settings.

---

## Technology

### Current: Embedded HTML/CSS/JS in Gleam strings

This works for the current scope but is reaching its limit. The `html.gleam` file is already large and difficult to edit.

### Proposed: Separate frontend build

```
web/
├── index.html
├── src/
│   ├── app.js          # Main application
│   ├── router.js       # Client-side routing
│   ├── ws.js           # WebSocket connection management
│   ├── views/
│   │   ├── chat.js
│   │   ├── admin/
│   │   │   ├── dprime.js
│   │   │   ├── cycles.js
│   │   │   ├── narrative.js
│   │   │   └── ...
│   │   ├── workspaces.js
│   │   ├── documents.js
│   │   └── endeavours.js
│   ├── components/
│   │   ├── sidebar.js
│   │   ├── thinking.js
│   │   ├── message.js
│   │   ├── notification.js
│   │   └── command-palette.js
│   └── styles/
│       ├── base.css
│       ├── chat.css
│       ├── admin.css
│       └── responsive.css
├── dist/                # Built output (committed or generated)
│   ├── app.min.js
│   └── app.min.css
└── build.js             # Simple esbuild script
```

**No framework.** Vanilla JS with a simple component pattern. No React, no Vue, no Svelte. The current embedded approach proves vanilla JS is sufficient — the new version just needs better organisation.

**Build tool: esbuild** — fast, zero-config, produces a single minified bundle. The built output is embedded in `html.gleam` exactly like today, but the source is maintainable.

The Gleam server serves the built bundle. The WebSocket protocol is unchanged. No new runtime dependency.

---

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | Non-blocking thinking (inline indicator, input stays active) | Small |
| 2 | Unified layout (sidebar + main + detail panels) | Large |
| 3 | Status bar | Small |
| 4 | Keyboard shortcuts + command palette | Medium |
| 5 | Workspaces | Medium |
| 6 | Enhanced chat (message actions, inline D', markdown improvements) | Medium |
| 7 | Document management (upload, browse, download) | Medium |
| 8 | Notification system (toasts, alerts, centre) | Medium |
| 9 | Mobile responsive | Medium |
| 10 | Theme toggle (dark/light) | Small |
| 11 | Separate frontend build (esbuild, organised source) | Medium — enabler for everything else |

**Recommended start**: Phase 11 (separate build) first — it makes all subsequent phases easier. Then Phase 1 (non-blocking thinking) for immediate quality-of-life improvement. Then Phase 2 (unified layout) as the structural foundation for everything else.

---

## What This Enables

The current GUI says "chat with an AI." The v2 GUI says "manage a knowledge worker." The operator sees the conversation, the system state, the ongoing work, the documents, and the agent's health — all in one place, without blocking, with keyboard navigation for power users and mobile support for on-the-go check-ins.

For the Guido demo: the current GUI is functional. For a customer: v2 is necessary.
