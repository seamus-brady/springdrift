# Librarian ETS-vs-Disk Reconciliation

**Status**: Planned
**Priority**: Medium — correctness bug, not crash
**Effort**: Small (~100-150 lines)

## Problem

JSONL on disk is the source of truth. The Librarian's ETS tables are a cache
populated by replaying JSONL at startup and by `IndexEntry` notifications from
the Archivist during the session. If a notification is lost (mailbox full,
Librarian restart, race condition), the entry exists on disk but not in ETS.
There is no reconciliation — the cache stays stale until the next full restart.

This was discovered when the web admin Narrative tab showed stale data via the
Librarian while disk had current entries. The web GUI was switched to read from
disk directly as a workaround, but the Librarian's ETS is still used by the
agent's own memory tools (`recall_recent`, `recall_search`, `recall_threads`,
etc.). A missed entry means the agent can't find its own recent work.

## Proposed Fix

Add a periodic reconciliation check to the Librarian's tick loop (or as a new
`send_after` timer):

1. Count entries in ETS per date file
2. Count lines in the corresponding JSONL file on disk
3. If disk has more entries than ETS for any date, replay the missing entries
4. Log the reconciliation result (entries synced, if any)

The check should be lightweight — just line counts vs ETS table size, not full
re-parsing. Only dates with a mismatch trigger a selective replay.

### Frequency

Every 60 seconds is sufficient. The Archivist writes at most one entry per
cycle, and cycles take seconds to minutes. A 60-second reconciliation window
means at most one minute of stale cache.

### Scope

All Librarian-managed stores: narrative entries, CBR cases, facts, artifacts.
Each has the same JSONL-on-disk + ETS-cache pattern and the same potential for
missed notifications.

## Alternative Considered

**Acknowledged writes** — the Archivist waits for an `IndexComplete` reply
from the Librarian before continuing. Rejected because the Archivist is
fire-and-forget by design (failures must never affect the user), and adding
synchronous acknowledgment would change that contract.
