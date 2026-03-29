# Git Backup, Restore, and Time Travel — Specification

**Status**: Planned
**Date**: 2026-03-26
**Dependencies**: Multi-tenant (planned), SD Audit (planned)

---

## Table of Contents

- [Overview](#overview)
- [Why Git](#why-git)
- [What Gets Backed Up](#what-gets-backed-up)
- [What Does NOT Get Backed Up](#what-does-not-get-backed-up)
- [Backup Architecture](#backup-architecture)
  - [The Backup Actor](#the-backup-actor)
  - [Trigger Modes](#trigger-modes)
  - [Commit Strategy](#commit-strategy)
  - [Branch Strategy](#branch-strategy)
  - [Remote Push](#remote-push)
- [Restore](#restore)
  - [Full Restore](#full-restore)
  - [Point-in-Time Restore](#point-in-time-restore)
  - [Selective Restore](#selective-restore)
  - [Restore Validation](#restore-validation)
- [Time Travel](#time-travel)
  - [Concept](#concept)
  - [CLI Commands](#cli-commands)
  - [Web GUI Integration](#web-gui-integration)
  - [Read-Only Inspection](#read-only-inspection)
- [SD Backup CLI Tool](#sd-backup-cli-tool)
  - [Commands](#commands)
  - [Architecture](#architecture)
  - [Dependencies](#dependencies)
- [Integrity Verification](#integrity-verification)
  - [Checksums](#checksums)
  - [Consistency Checks](#consistency-checks)
  - [Tamper Detection](#tamper-detection)
- [Disaster Recovery](#disaster-recovery)
  - [Scenarios](#scenarios)
  - [Recovery Time Objectives](#recovery-time-objectives)
  - [Runbook](#runbook)
- [Multi-Tenant](#multi-tenant)
  - [Per-Tenant Backup Config](#per-tenant-backup-config)
  - [Isolation](#isolation)
  - [Shared vs Separate Repos](#shared-vs-separate-repos)
- [D' Integration](#d-integration)
- [Sensorium Integration](#sensorium-integration)
- [Configuration](#configuration)
  - [Per-Tenant backup.toml](#per-tenant-backuptoml)
  - [Global config.toml](#global-configtoml)
- [Relationship to Other Specs](#relationship-to-other-specs)
- [Implementation Order](#implementation-order)
- [What This Enables](#what-this-enables)

---

## Overview

Springdrift's entire state is append-only JSONL files in a single directory. This is an architectural property, not an accident — the system was designed to be backed up to git from the start.

This spec formalises what was previously informal: automated git backup, validated restore, point-in-time recovery, and a CLI tool for managing agent state across time. It turns "you can back this up to git" into "the system backs itself up, you can restore to any point, and you can prove the data hasn't been tampered with."

---

## Why Git

Not because it's a version control system. Because it's a content-addressable, cryptographically verified, distributed, append-only data store with built-in integrity checking and universal tooling support.

| Property | Why It Matters |
|---|---|
| Content-addressable | Every commit has a SHA hash. The data proves its own identity. |
| Cryptographic verification | `git fsck` detects corruption. `git log --show-signature` proves authorship. |
| Distributed | Clone to multiple locations. No single point of failure. |
| Append-only (with reflog) | Even force-pushes leave traces. The reflog is the audit trail of the audit trail. |
| Universal tooling | Every developer, every CI system, every cloud platform understands git. |
| Diff-friendly | JSONL is line-oriented. Git diffs show exactly what was appended. |
| Efficient | Git compresses well. JSONL is highly compressible. A year of agent memory might be 100MB compressed. |

Other backup targets (S3, database, tape) are supported as git remotes. Git is the abstraction layer, not the storage layer.

---

## What Gets Backed Up

Everything under `.springdrift/` (or `.springdrift/tenants/{id}/` in multi-tenant):

| Directory | Contents | Changes Frequently |
|---|---|---|
| `memory/narrative/` | Per-cycle narrative entries | Every cycle |
| `memory/cbr/` | CBR cases with usage stats | Every cycle (Archivist) |
| `memory/facts/` | Key-value facts | On memory_write |
| `memory/artifacts/` | Artifact metadata + content | On store_result |
| `memory/planner/` | Tasks and endeavours | On plan creation/update |
| `memory/cycle-log/` | Full cycle telemetry | Every cycle |
| `memory/meta/` | Meta observer history | Every cycle |
| `memory/comms/` | Communications log | On send/receive |
| `memory/skills/` | Skill usage JSONL | On skill use |
| `memory/consolidation/` | Remembrancer output | Weekly |
| `knowledge/` | Sources, consolidation, exports | On upload/generate |
| `scheduler/` | Scheduler state + outputs | On job fire |
| `logs/` | System logs | Continuously |
| `identity/` | Persona, preamble | Rarely |
| `config.toml` | Configuration | On edit |
| `dprime.json` | D' safety config | On edit |
| `session.json` | Current session state | On save |
| `identity.json` | Agent UUID | Once |

---

## What Does NOT Get Backed Up

| Item | Why |
|---|---|
| `schemas/` | Compiled XSD schemas — regenerated at startup |
| `.sandbox-workspaces/` | Ephemeral container workspaces — outside .springdrift/ |
| ETS tables | In-memory only — reconstructed from JSONL at startup |
| LLM provider credentials | Env vars, never in files |

---

## Backup Architecture

### The Backup Actor

An OTP process per tenant that manages the git repository:

```gleam
pub type BackupMessage {
  RunBackup                              // Manual or scheduled trigger
  RunBackupAfterCycle(cycle_id: String)  // Post-cycle auto-backup
  GetStatus(reply_to: Subject(BackupStatus))
  Verify                                 // Run integrity check
  Shutdown
}

pub type BackupStatus {
  BackupStatus(
    enabled: Bool,
    last_backup: Option(String),         // ISO timestamp
    last_commit: Option(String),         // Git commit hash
    last_push: Option(String),           // ISO timestamp of last successful push
    commits_since_push: Int,
    repo_size_bytes: Int,
    errors: List(String),                // Recent backup errors
  )
}
```

### Trigger Modes

```toml
[backup.schedule]
# When to create commits
mode = "after_cycle"    # "after_cycle" | "periodic" | "manual"

# For periodic mode: interval in ms (default: 3600000 = 1 hour)
# interval_ms = 3600000

# For after_cycle mode: commit after every N cycles (default: 1)
# cycle_interval = 1

# When to push to remote
push_mode = "periodic"  # "after_commit" | "periodic" | "manual"

# For periodic push: interval in ms (default: 3600000 = 1 hour)
# push_interval_ms = 3600000
```

**after_cycle** (recommended): commit after every cycle (or every N cycles). Maximum granularity for point-in-time recovery. Push periodically to avoid hammering the remote.

**periodic**: commit on a timer. Lower overhead, coarser recovery granularity.

**manual**: operator triggers backup explicitly. For development use.

### Commit Strategy

Each commit captures the delta since the last commit:

```
commit abc123def
Author: Springdrift Agent <agent@springdrift>
Date:   2026-03-26T22:15:00Z

    Cycle 59209ed6: research query (3 tools, 4521 tokens)

    Narrative: 1 entry added
    CBR: 1 case added (Strategy)
    Facts: 2 written (dublin_rent, research_status)
    D': input ACCEPT (0.00), output ACCEPT (0.12)
```

The commit message is auto-generated from the cycle telemetry. This makes `git log` a human-readable activity log:

```
$ git log --oneline
abc123d Cycle 59209ed6: research query (3 tools, 4521 tokens)
def456a Cycle 20cd8f46: follow-up analysis (5 tools, 8102 tokens)
789abcd Scheduler: daily-briefing completed (2341 tokens)
bcd1234 Config: dprime.json thresholds updated
```

### Branch Strategy

| Mode | Branch | Purpose |
|---|---|---|
| Single-tenant | `main` | Single timeline |
| Multi-tenant | `tenant/{tenant_id}` | Per-tenant branch |
| Pre-restore snapshot | `snapshot/{timestamp}` | Auto-created before any restore operation |

### Remote Push

```toml
[backup.remote]
url = "git@github.com:org/springdrift-data.git"
ssh_key_path = "~/.ssh/springdrift_backup"
# Or for HTTPS:
# url = "https://github.com/org/springdrift-data.git"
# token_env = "GIT_BACKUP_TOKEN"
```

Push failures are logged and retried. The backup actor tracks `commits_since_push` — the operator sees how far behind the remote is.

---

## Restore

### Full Restore

Restore the entire agent state from a git commit:

```sh
sd-backup restore --commit abc123def
```

1. Stop the running agent (or refuse if agent is running)
2. Create a snapshot branch of the current state
3. `git checkout` the target commit
4. Run integrity verification
5. Start the agent — Librarian replays JSONL into ETS as normal

The agent picks up exactly where it was at that commit. Session, memory, config, identity — everything.

### Point-in-Time Restore

Restore to the state at a specific timestamp:

```sh
sd-backup restore --timestamp "2026-03-25T14:00:00Z"
```

Finds the commit closest to (but not after) the target timestamp using `git log --before`.

### Selective Restore

Restore specific memory stores without affecting others:

```sh
sd-backup restore --commit abc123def --only memory/cbr/
sd-backup restore --commit abc123def --only memory/facts/ --only dprime.json
```

Use case: "the CBR cases got corrupted by a bad Archivist run, but the rest of the state is fine."

### Restore Validation

After every restore, automatic verification:

1. Parse all JSONL files — no corruption
2. Count entries — match expected counts from commit metadata
3. Verify cross-references (narrative → CBR source IDs exist)
4. Check config files parse correctly
5. Report any anomalies before starting the agent

```
Restore Validation
===================
Commit: abc123def (2026-03-25T14:00:00Z)

Narrative entries: 312 ✓
CBR cases: 98 ✓
Facts: 201 ✓
Cycle log entries: 847 ✓
Config: valid ✓
D' config: valid ✓
Identity: present ✓
Cross-references: 3 orphaned CBR source IDs (narrative entries pruned) ⚠

Ready to start? [Y/n]
```

---

## Time Travel

### Concept

Browse the agent's state at any point in history without restoring. Read-only inspection using `git show` and `git checkout` to a detached HEAD in a temporary worktree.

### CLI Commands

```sh
# Show what the agent knew at a specific time
sd-backup show facts --at "2026-03-20T10:00:00Z" --key "dublin_rent"

# Compare CBR cases between two points
sd-backup diff cbr --from "2026-03-20" --to "2026-03-25"

# Show what changed in a specific commit
sd-backup show commit abc123def

# List all commits for a date
sd-backup log --date 2026-03-25

# Show the agent's config at a point in time
sd-backup show config --at "2026-03-22T09:00:00Z"

# Show narrative entries that existed at a point but have since been pruned
sd-backup show pruned --since "2026-03-15"
```

### Web GUI Integration

The Documents panel (see [Web GUI v2 spec](web-gui-v2.md)) gains a timeline slider:

```
┌──────────────────────────────────────────────────────┐
│ Time Travel                                           │
│                                                       │
│ ◄ 2026-03-15 ═══════●════════════ 2026-03-26 ►     │
│                   2026-03-22                          │
│                                                       │
│ Viewing state at: 2026-03-22T14:00:00Z               │
│ Commit: def456a "D' threshold adjustment"            │
│                                                       │
│ Facts: 189 (current: 267)                            │
│ CBR: 76 (current: 134)                               │
│ Narrative: 45 entries (current: 89)                  │
│                                                       │
│ [View Details]  [Compare to Current]  [Restore]      │
└──────────────────────────────────────────────────────┘
```

### Read-Only Inspection

Time travel uses `git worktree add --detach` to create a temporary read-only checkout. The running agent is unaffected. Multiple time-travel sessions can be active simultaneously.

```gleam
pub type TimeTravelSession {
  TimeTravelSession(
    session_id: String,
    target_commit: String,
    target_timestamp: String,
    worktree_path: String,
    created_at: String,
  )
}
```

Sessions are cleaned up automatically after a timeout or on explicit close.

---

## SD Backup CLI Tool

A standalone tool (like SD Audit and SD Designer) for managing backups outside the running agent.

### Commands

```
sd-backup [OPTIONS] COMMAND [ARGS]

Options:
  --data-dir PATH      Path to .springdrift/ directory (default: .springdrift)
  --tenant TEXT         Tenant ID (multi-tenant mode)

Commands:
  init                 Initialise git repo in the data directory
  status               Show backup status (last commit, push status, repo size)
  run                  Trigger a manual backup (commit + optional push)
  push                 Push local commits to remote
  log                  Show commit history (filterable by date, type)
  show                 Inspect state at a commit (facts, cbr, config, etc.)
  diff                 Compare state between two commits
  restore              Restore to a commit (full, point-in-time, or selective)
  verify               Run integrity checks on the current state
  prune                Remove old log files that are safely committed (optional)
  export               Export a commit's state as a tarball (for migration)
  travel               Open a time-travel session (read-only worktree)
```

### Architecture

```
sd-backup/
├── pyproject.toml
├── sd_backup/
│   ├── __init__.py
│   ├── cli.py              # Click CLI
│   ├── git.py              # Git operations (commit, push, checkout, worktree)
│   ├── commit.py           # Commit message generation from JSONL deltas
│   ├── restore.py          # Full, point-in-time, selective restore
│   ├── verify.py           # Integrity verification
│   ├── travel.py           # Time-travel worktree management
│   ├── diff.py             # State comparison between commits
│   └── config.py           # backup.toml parsing
└── tests/
```

### Dependencies

```toml
[project]
requires-python = ">=3.10"
dependencies = [
    "click>=8.0",
    "gitpython>=3.1",       # Git operations
]
```

Installed alongside SD Audit and SD Designer in `tools/sd-backup/`.

---

## Integrity Verification

### Checksums

Every backup commit includes a `.springdrift/checksums.sha256` file:

```
sha256:abc123... memory/narrative/2026-03-25.jsonl
sha256:def456... memory/cbr/cases.jsonl
sha256:789abc... memory/facts/2026-03-25-facts.jsonl
sha256:bcd123... config.toml
sha256:ef0123... dprime.json
...
```

`sd-backup verify` recomputes checksums and compares against the committed values. Any mismatch indicates corruption or tampering.

### Consistency Checks

Beyond checksums, verify structural consistency:

| Check | What It Verifies |
|---|---|
| JSONL parseable | Every line in every JSONL file is valid JSON |
| Cycle ID uniqueness | No duplicate cycle IDs in cycle log |
| Narrative → CBR links | source_narrative_id in CBR cases points to existing entries |
| Fact key consistency | No key appears in both active and deleted state |
| Config validity | TOML and JSON configs parse without error |
| Date continuity | No gaps in daily-rotated log files |

### Tamper Detection

For regulated environments, commits can be GPG-signed:

```toml
[backup.signing]
enabled = true
gpg_key = "agent@springdrift"
```

`git log --show-signature` proves every commit was made by the agent. An external party cannot insert or modify commits without breaking the signature chain.

For maximum assurance: push to an immutable remote (e.g. a git repo with branch protection, or a dedicated audit repository where only the agent has push access).

---

## Disaster Recovery

### Scenarios

| Scenario | Recovery Method | RTO |
|---|---|---|
| Agent crash | Restart — ETS rebuilt from JSONL | Seconds (startup replay) |
| Disk corruption (partial) | Selective restore from git | Minutes |
| Disk loss (total) | Full restore from remote | Minutes (clone + startup) |
| Bad Archivist run (corrupted cases) | Selective restore of CBR | Minutes |
| Config mistake (D' too aggressive) | Restore dprime.json from commit | Seconds |
| Operator error (deleted facts) | Restore facts from commit | Minutes |
| Hardware migration | Clone repo to new machine, start agent | Minutes |
| Ransomware | Clone from remote to clean machine | Minutes (if remote is clean) |

### Recovery Time Objectives

| Metric | Target |
|---|---|
| Agent restart (no data loss) | <30 seconds |
| Selective restore (one store) | <2 minutes |
| Full restore from remote | <5 minutes (depends on repo size + network) |
| Point-in-time restore | <5 minutes |

### Runbook

```
DISASTER RECOVERY RUNBOOK

1. ASSESS
   - Is the agent running? Stop it: gleam run -- --stop (or kill process)
   - Is .springdrift/ accessible? Check disk health.
   - Is the git remote reachable? git ls-remote <url>

2. RESTORE
   If .springdrift/ is intact:
     sd-backup restore --commit <last_known_good>

   If .springdrift/ is destroyed:
     git clone <remote_url> .springdrift
     sd-backup restore --commit <last_known_good>

   If selective corruption:
     sd-backup restore --commit <last_known_good> --only memory/<store>/

3. VERIFY
   sd-backup verify
   Review output. Address any warnings before starting.

4. RESTART
   gleam run
   Agent rebuilds ETS from restored JSONL.
   Verify in web GUI: check narrative, CBR, facts, scheduler.

5. POST-MORTEM
   sd-audit timeline --from <incident_time>
   Review what happened. Update backup schedule if needed.
```

---

## Multi-Tenant

### Per-Tenant Backup Config

Each tenant has its own `backup.toml`:

```
.springdrift/tenants/{tenant_id}/backup.toml
```

See: [Multi-Tenant spec](multi-tenant.md)

### Isolation

Each tenant's data is committed on its own branch: `tenant/{tenant_id}`. No cross-tenant data in any commit.

### Shared vs Separate Repos

| Approach | Pros | Cons |
|---|---|---|
| One repo, per-tenant branches | Simpler management, single remote | All tenants in one repo (size, access control) |
| Separate repo per tenant | Full isolation, independent access control | More repos to manage |

Recommendation: separate repos for production (isolation), shared repo for development (simplicity). Configurable per tenant.

---

## D' Integration

The backup actor is an internal system process — not subject to D' gating. However:

- Backup **failures** are surfaced as sensory events (the agent knows its safety net is broken)
- Backup **status** appears in the sensorium vitals
- Restore operations require operator authentication (not triggerable by the agent)
- The agent cannot delete or modify git history (it can only commit new data)

---

## Sensorium Integration

```xml
<backup last_commit="5m ago" commits_since_push="3"
        repo_size="42MB" status="healthy"/>
```

When backup is failing:
```xml
<backup last_commit="2h ago" commits_since_push="15"
        status="degraded" error="push failed: remote unreachable"/>
```

---

## Configuration

### Per-Tenant backup.toml

```toml
[git]
enabled = true
remote = "git@github.com:org/springdrift-data.git"
branch = "tenant/default"
ssh_key_path = "~/.ssh/springdrift_backup"

[git.commit]
author_name = "Springdrift Agent"
author_email = "agent@springdrift"

[git.signing]
# enabled = false
# gpg_key = "agent@springdrift"

[schedule]
mode = "after_cycle"         # after_cycle | periodic | manual
# cycle_interval = 1         # Commit every N cycles (after_cycle mode)
# interval_ms = 3600000      # Commit interval (periodic mode)
push_mode = "periodic"       # after_commit | periodic | manual
# push_interval_ms = 3600000 # Push interval (periodic mode)
```

### Global config.toml

```toml
[backup]
# Enable git backup (default: false)
# enabled = false

# Max repo size before warning in MB (default: 1000)
# max_repo_size_mb = 1000

# Include checksums in every commit (default: true)
# checksums = true
```

---

## Relationship to Other Specs

| Spec | Relationship |
|---|---|
| [Multi-Tenant](multi-tenant.md) | Per-tenant backup config, branch strategy, repo isolation |
| [SD Audit](sd-audit.md) | Audit reads the same JSONL files; backup ensures they're preserved and verifiable |
| [SD Designer](sd-designer.md) | Initial setup includes backup config in the wizard |
| [Knowledge Management](knowledge-management.md) | Knowledge sources, consolidation, exports all backed up |
| [Remembrancer](remembrancer.md) | Reads raw JSONL — backup ensures historical files are always available on disk |
| [Comms Agent](comms-agent.md) | Comms logs backed up; delivery receipts preserved |
| [Autonomous Endeavours](autonomous-endeavours.md) | Endeavour state backed up; work survives hardware failure |
| [Self-Diagnostic Skill](self-diagnostic-skill.md) | Diagnostic can check backup health (last commit age, push status) |
| [Empirical Evaluation](empirical-evaluation.md) | Evaluation data preserved in git; experiments are reproducible |

---

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | Backup actor (OTP process, git init, commit, push) | Medium |
| 2 | Commit message generation from JSONL deltas | Medium |
| 3 | Trigger modes (after_cycle, periodic, manual) | Small |
| 4 | SD Backup CLI: init, status, run, push, log | Medium |
| 5 | Restore: full and point-in-time | Medium |
| 6 | Restore: selective (per-store) | Small |
| 7 | Integrity verification (checksums + consistency) | Medium |
| 8 | Time travel (worktree-based read-only inspection) | Medium |
| 9 | Sensorium integration (backup status in vitals) | Small |
| 10 | Web GUI: backup status + time travel slider | Medium |
| 11 | GPG signing | Small |
| 12 | Multi-tenant: per-tenant branches + separate repos | Medium |

Phase 1-4 delivers automated backup with a CLI. Phase 5-7 delivers restore with verification. Phase 8-10 delivers the time-travel experience.

---

## What This Enables

The agent's memory is indestructible. Not "backed up" — indestructible. Every fact, every case, every narrative entry, every D' decision exists in a cryptographically verified, distributed, append-only store. You can recover from any failure, inspect any historical state, prove the data hasn't been tampered with, and migrate to new hardware by cloning a repository.

For regulated industries: this is the answer to "what happens if the system crashes?" and "can you prove this data hasn't been modified?" and "can we audit what the agent knew six months ago?"

The answer to all three is: `git log`.
