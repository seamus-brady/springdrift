---
name: writer-pdf-export
description: When and how to render a promoted export to PDF via the export_pdf tool. Reads the writer's draft → export → PDF lifecycle and the operator-facing failure modes when the host is missing pandoc or tectonic.
agents: writer, cognitive
---

## Purpose

The writer agent's `export_pdf` tool renders a promoted export
from markdown to PDF. The PDF lands alongside the markdown at
`exports/<slug>.pdf`. This skill teaches when to call it and what
the failure modes look like.

## The lifecycle

```
create_draft  →  update_draft (any number)  →  promote_draft
      ↓                                              ↓
exports/<slug>.md exists                exports/<slug>.md (Promoted)
      ↓
operator runs approve_export
      ↓
exports/<slug>.md (Approved, citeable)
      ↓
export_pdf  →  exports/<slug>.pdf
```

Two important properties of this chain:

- **`export_pdf` works on promoted exports, not drafts.** The tool
  reads `exports/<slug>.md`. If you're still iterating in
  `drafts/<slug>.md`, the call will return "no promoted export at
  …" — that's correct; a PDF is a delivery artefact, not a working
  surface.
- **Re-running on the same slug overwrites the PDF.** Useful when
  the operator has approved a revision and asked for an updated
  artefact. Don't call it speculatively — generation is 1–5
  seconds for a real document.

## When to call it

- The operator asks for a PDF, or for "the report" / "the
  deliverable" in a context where a markdown file isn't enough.
- An approved export needs to leave the system (email, hand-off,
  archive). PDF is the universal artefact format.
- The operator references downloading from the Documents tab —
  that's PDF-shaped affordance.

When NOT to call it:

- The operator just promoted a draft and hasn't approved it yet.
  They may still want to revise. Wait for `approve_export` (or
  ask if you're unsure).
- For internal sharing of a draft. Markdown is fine.
- After every `update_draft` "just in case." Wasteful.

## Failure modes (and what they mean)

The tool surfaces specific operator-actionable errors. When they
come back, summarise them in plain language for the operator —
don't paste the raw tool output.

### "tectonic is not installed"

The host is missing the PDF rendering engine. Pandoc shells out to
tectonic to actually produce the PDF; without tectonic, pandoc
errors before producing anything.

**What to tell the operator:** "I can't generate the PDF because
the `tectonic` binary isn't installed on this host. The
operator-manual install section has the curl line for Linux and
`brew install tectonic` for macOS. After install, ask me again
and the export will work."

### "no promoted export at exports/…"

Either the slug is wrong, or the draft hasn't been promoted yet.
Check `list_documents` to see what's actually in exports/ and
confirm the slug matches.

### "PDF generation failed (exit N): …"

Pandoc or tectonic ran but couldn't produce a PDF. Typical
causes: markdown contains LaTeX-incompatible content (rare but
possible — heavy emoji, exotic Unicode), or tectonic couldn't
fetch a needed package on its first run.

**What to tell the operator:** report the exit code and the first
line of stderr; suggest re-running once if it looks like a
transient package fetch, or ask for help if it looks like content.

## Worth knowing

- The tool runs synchronously. If the operator is waiting on the
  reply, expect a 1–5 second pause on most documents; 5–15 on the
  first run after install (tectonic fetches LaTeX packages on
  demand).
- The PDF is plain pandoc-LaTeX article style. No corporate
  letterhead, no styled headers. If the operator wants styling,
  that's a follow-up plan (templates).
- The web GUI's Documents tab will eventually surface a "Download
  PDF" button alongside approved exports; until then the operator
  reads the PDF straight from `.springdrift/knowledge/exports/`.

## Related skills

- `delegation-strategy` — call the writer agent to draft and
  promote; call `export_pdf` directly from the cog loop after
  the export is approved (no need to re-delegate to the writer).
- `personal-index` — the writer's draft / export workflow as a
  whole.
