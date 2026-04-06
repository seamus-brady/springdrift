# Extended Housekeeper Window — Beyond 30 Days

**Status**: Planned
**Priority**: Low — becomes important as instances run longer
**Effort**: Small (~100-200 lines)

## Problem

The Librarian replays at most `librarian_max_days` (default 30) days of
JSONL history into ETS at startup. Housekeeping (CBR dedup, pruning, fact
conflict resolution) only operates within this window. As an instance
accumulates months of operation, older data is invisible to maintenance:

- CBR cases older than 30 days are never deduplicated against newer cases
- Fact conflicts across the 30-day boundary are never resolved
- Stale cases with low confidence that should be pruned persist indefinitely
- The agent's total case count grows without bound

The 30-day default exists for startup performance — replaying a year of
JSONL would be slow. But the housekeeping window should be independent of
the query replay window.

## Proposed Solution

### 1. Separate Housekeeping Window

Add `housekeeping_max_days` config field (default: 90, or configurable up
to unlimited). Housekeeping operations scan this wider window while the
Librarian's ETS query cache still uses `librarian_max_days` for startup
performance.

### 2. Background Housekeeping Pass

Run a periodic background scan (e.g. daily or weekly) that:

- Reads older JSONL files beyond the Librarian's replay window
- Applies CBR dedup against the current case base
- Prunes cases matching pruning criteria (old, low confidence, no pitfalls)
- Resolves fact conflicts across the full history
- Reports results via sensory event

This avoids the startup cost of replaying everything into ETS — the
background pass reads files sequentially without indexing.

### 3. Compaction (Optional)

For very long-running instances, offer a compaction step:

- Rewrite older JSONL files with deduplicated/pruned entries removed
- Preserve a compaction log for auditability
- Run only on explicit operator request (not automatic — append-only
  is a safety property)

## Open Questions

- Should compaction be automatic or operator-triggered only?
- Should the background pass run during active conversation or only
  during idle periods?
- Impact on git backup — compacting old files changes git history
