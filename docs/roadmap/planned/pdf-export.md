# PDF Export — Markdown → PDF via pandoc + tectonic

**Status**: Planned
**Priority**: Medium — operator-facing, completes the document lifecycle (drafts → exports → deliverable artefact)
**Effort**: Small (~150-200 LOC + ops install + tests + skill)

## The Gap

The writer agent can:

- create drafts (`create_draft`)
- read and revise them across sessions (`read_draft`, `update_draft`)
- promote a draft to an export (`promote_draft`) which lands as
  markdown in `.springdrift/knowledge/exports/<slug>.md`

The operator can then approve the export from the Documents tab.
But the *artefact* — the thing the operator hands to whoever
commissioned the work — is still a markdown file. For most
real-world delivery (clients, regulators, archivists) the
deliverable is a PDF.

There's no `export_pdf` tool. There's no PDF anywhere in the
pipeline. The pdftotext binary used for *ingestion* doesn't run in
reverse.

## Approach

**Reuse the pandoc that's already installed for ingestion.** Pandoc
is the markdown↔* converter we use for `.docx`/`.epub`/`.html`
ingestion. Pandoc itself doesn't render PDFs — it shells out to a
separate engine. Adding PDF generation is therefore:

1. Install a PDF engine on the host.
2. Add a writer tool that calls `pandoc input.md -o output.pdf
   --pdf-engine=<chosen>`.
3. Surface the same kinds of operator-actionable errors the cold-
   start fixes just shipped for ingestion.

**Engine choice: tectonic.** Single Rust binary (~50 MB), no Python
dependency, downloads LaTeX packages on demand. Available on Linux
(curl from GitHub releases) and macOS (Homebrew). Operator installs
once; agent invokes via `pandoc --pdf-engine=tectonic`.

Considered alternatives:
- **weasyprint** — Pure HTML/CSS rendering, easier to style, but
  drags Python + Pango. The user's standing rule is "no pip on a
  long-running VPS" — disqualifies it.
- **texlive-xetex** — Standard LaTeX. Installs cleanly on Debian
  but is 300-800 MB. Heavier than tectonic for no functional gain.

## Tool Design

New writer-side tool: **`export_pdf(slug)`**.

```
input: { "slug": "q4-report" }

Behaviour:
  - Reads exports/<slug>.md (must already be promoted; rejects
    drafts to keep the lifecycle clean — a PDF is an artefact, not
    a working surface)
  - Runs: pandoc <md> -o exports/<slug>.pdf --pdf-engine=tectonic
  - On success: returns "Exported '<slug>.pdf' (N KB)"
  - On BinaryMissing(tectonic): returns actionable install hint
  - On ConversionFailed: returns pandoc/tectonic stderr (truncated
    to ~500 chars; full text in slog)
```

Why scoped to promoted exports (not drafts)?
- A PDF is a delivery artefact. Drafts are working surfaces.
- Generating a PDF from every draft revision wastes 1-5s per
  iteration with no operator value.
- The promote→approve→export-pdf chain matches the natural
  lifecycle.
- Operators who want a "preview as PDF" affordance for drafts can
  ask for it as a follow-up; the cost is a `preview_pdf` tool that
  doesn't write the PDF anywhere durable.

## Failure Modes

Reusing the patterns from the cold-start PR:

- **`tectonic` not installed** → `BinaryMissing` → operator chat
  message: "Cannot generate PDF — `tectonic` is not installed on
  the host. See operators-manual §Install."
- **pandoc not installed** (shouldn't happen — used for ingestion,
  but defend against partial installs) → similar message naming
  pandoc.
- **LaTeX compile failure** (typical: bad markdown that produces
  invalid LaTeX, or missing packages tectonic can't auto-fetch) →
  `ConversionFailed` with truncated stderr.
- **Disk full / permission error** → `WriteFailed`.

The operator-actionable message format is the same as
`intake.format_failure` in PR cold-start-onboarding. We may even
share the variant types if it proves clean.

## Surface Updates Required

Per the user's "update everything" instruction:

1. **`docs/operators-manual.md`** — install section gains tectonic
   (`brew install tectonic` macOS, curl-from-releases Linux).
2. **`scripts/setup/macos.sh`** — add `brew install tectonic` (and
   pandoc + poppler if not already there — they should be, but
   currently aren't in the setup script even though the manual
   names them).
3. **`scripts/setup/linux.sh`** — `apt install pandoc poppler-utils`
   and a curl line for tectonic with a SHA check.
4. **New skill** — `writer-pdf-export/SKILL.md` teaching the writer
   when to call `export_pdf` (after operator approval, not before;
   not on drafts; one PDF per slug per export, regenerate after
   re-promote).
5. **`HOW_TO.md`** — short note in the operator-guide section about
   when to ask the writer for a PDF.
6. **`CLAUDE.md`** — tool tables gain `export_pdf`. Writer agent
   row mentions it.
7. **Web GUI Documents tab** — *not in scope for this PR.* Adding a
   "Download PDF" button on an approved export is a small follow-up
   that builds on PR #143's tab. Tracked here so we don't lose it.

## Testing

- Markdown happy path: small fixture → pandoc + tectonic → output
  PDF exists, file size > 0. Skip cleanly if tectonic isn't on
  PATH (same pattern as the existing `pdftotext` skip in PR 6).
- BinaryMissing path: mock the run_cmd to return a "command not
  found" error; verify the agent gets the install hint.
- Slug containment: an attempt to export a slug that traverses out
  of the exports dir is rejected up-front (path normalisation
  before pandoc is invoked).
- Reject drafts: calling `export_pdf` on a draft slug (no
  corresponding export) returns a clear "draft not yet promoted"
  error, not a confusing pandoc failure.

## Where to hold off

- **Not generating PDFs automatically on promote.** The operator
  may want to revise after promoting (the writer-revise flow
  supports this). Auto-generating wastes work.
- **Not adding PDF templates / styling.** The default pandoc-LaTeX
  output is plain article style. Customising means a `.tex`
  template per agent persona, which is a separate plan.
- **Not embedding PDF preview in the chat UI.** The Documents tab
  download is the right surface; chat is text-first.

## Triggers to revisit

- Operators asking for a preview-PDF on drafts (low-friction
  iteration cycle) → add `preview_pdf` that writes to a
  scratch dir and returns the path.
- Style complaints (corporate clients want letterhead, etc.) →
  introduce a templating layer.
- Recurring tectonic compile errors on certain markdown patterns →
  pre-process the markdown (strip emoji, escape characters that
  don't survive LaTeX) before invoking pandoc.

## Suggested Implementation Order

One PR, in this order so each commit leaves the system working:

1. **Tool + dispatch** — `export_pdf` tool + writer executor branch
   + `run_export_pdf` calling pandoc. Reuse `run_cmd`,
   `format_failure` patterns from PR 156.
2. **Setup scripts** — install lines on Linux + macOS. The agent
   side runs but errors actionably until the host has tectonic.
3. **Operator manual** — install instructions.
4. **Skill + HOW_TO + CLAUDE.md** — agent learns the procedure.
5. **Tests** — happy path (skipped without tectonic), BinaryMissing,
   slug containment, draft-rejection.
