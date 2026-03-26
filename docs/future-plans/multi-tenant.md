# Multi-Tenant Architecture Plan

**Status**: Planned, not started
**Date**: 2026-03-25
**Prerequisites**: Stable D' system, working Vertex AI provider, one week of unattended agent operation

---

## Overview

Transform Springdrift from a single-user agent tool into a multi-tenant agent platform. A "tenant" is the unit of data isolation — either a single user or a team. Multiple users can map to the same tenant, sharing memory, narrative, and agent state.

Single-tenant mode (no `tenants.toml`) continues to work unchanged. Multi-tenant is additive, not a rewrite.

---

## Directory Structure

```
.springdrift/
├── tenants.toml                    # Tenant registry (NEW)
├── config.toml                     # Global defaults (existing)
├── schemas/                        # Shared XSD schemas
│
└── tenants/
    ├── default/                    # Migrated single-user data
    │   ├── config.toml             # Tenant config overrides
    │   ├── session.json
    │   ├── identity.json
    │   ├── identity/               # Persona + preamble
    │   ├── dprime.json             # Per-tenant D' config
    │   ├── logs/
    │   ├── memory/
    │   │   ├── cycle-log/
    │   │   ├── narrative/
    │   │   ├── cbr/
    │   │   ├── facts/
    │   │   ├── artifacts/
    │   │   ├── planner/
    │   │   └── meta/
    │   ├── skills/
    │   ├── scheduler/
    │   │   └── outputs/
    │   ├── email.toml              # Email delivery config (NEW)
    │   └── backup.toml             # Git backup config (NEW)
    │
    ├── alice/                      # User tenant
    │   └── (same structure)
    │
    └── research-team/              # Team tenant (shared by multiple users)
        └── (same structure)
```

Teams are not a special directory type. A team IS a tenant. Multiple users are mapped to the same tenant in `tenants.toml`.

---

## Tenant Registry (`tenants.toml`)

```toml
[defaults]
max_token_budget_per_hour = 500000
max_storage_mb = 1000

[[users]]
username = "alice"
tenant = "default"
role = "admin"                     # admin | member

[[users]]
username = "bob"
tenant = "research-team"
role = "member"

[[users]]
username = "carol"
tenant = "research-team"
role = "admin"

[[tenants]]
name = "default"
display_name = "Default Workspace"

[[tenants]]
name = "research-team"
display_name = "Research Team"
max_cycles_per_hour = 30
max_token_budget_per_hour = 1000000
max_storage_mb = 5000
```

No `tenants.toml` = single-tenant mode. Full backward compatibility.

---

## Process Architecture

Each active tenant gets its own complete OTP subtree:

```
Application
├── TenantManager (NEW — lazy start/stop of tenants)
│   ├── TenantInstance("default")
│   │   ├── Librarian (own ETS tables)
│   │   ├── Curator
│   │   ├── Housekeeper
│   │   ├── CognitiveLoop
│   │   ├── AgentSupervisor
│   │   │   ├── planner
│   │   │   ├── researcher
│   │   │   ├── coder
│   │   │   ├── writer
│   │   │   ├── observer
│   │   │   └── scheduler         ← per-tenant, own jobs + delivery
│   │   ├── Forecaster (if enabled)
│   │   ├── BackupActor (if enabled)
│   │   └── NotificationRelay
│   │
│   └── TenantInstance("research-team")
│       └── (same subtree)
│
├── WebServer (shared mist, routes by auth to correct tenant)
├── SandboxManager (shared pool, tenant-namespaced workspaces)
└── EmbeddingClient (shared Ollama connection)
```

### Lazy startup

Tenants start on demand (first WebSocket connection or first scheduled job fires), not all at once. Idle tenants (no activity for configurable hours) can be stopped to reclaim memory and ETS tables. Restarted on next request.

### Scheduler

Per-tenant. Each tenant's scheduler has its own jobs, firing into that tenant's cognitive loop. Schedule config lives in the tenant's config. Resource limits (`max_autonomous_cycles_per_hour`, `autonomous_token_budget_per_hour`) are per-tenant.

### Sandbox

Shared container pool, tenant-namespaced workspaces (`.sandbox-workspaces/<tenant_id>/N/`). Per-tenant slot limits prevent one tenant monopolising containers.

---

## Authentication and Routing

### Login

Simple login page — tenant name + username. No password initially, OAuth added later. On submit:

1. Server looks up user in `tenants.toml`
2. Issues a session token (random string), sets a cookie
3. Session expires after configurable inactivity period

### WebSocket routing

1. WebSocket connects, cookie carries session token
2. Server resolves token → `(username, tenant_id, role)`
3. `TenantManager` returns `TenantProcesses` for that tenant (starts if dormant)
4. WebSocket handler binds to that tenant's cognitive loop + notification relay

### Admin view

The admin tabs (D' Safety, D' Config, Scheduler, Cycles, etc.) show data for the current tenant only. Admin-role users get an extra "Tenant Admin" tab for managing users and viewing cross-tenant stats.

---

## Config Hierarchy (four layers)

```
Priority (highest to lowest):
  1. CLI flags
  2. Per-tenant config     (.springdrift/tenants/<id>/config.toml)
  3. Global local config   (.springdrift/config.toml)
  4. Hardcoded defaults
```

Each tenant can override provider, models, D' config, scheduler settings, and all other AppConfig fields.

---

## Email Delivery

Per-tenant config: `.springdrift/tenants/<id>/email.toml`

```toml
[smtp]
host = "smtp.example.com"
port = 587
username = "agent@example.com"
password_env = "SMTP_PASSWORD"       # Read from env var, never in plaintext
tls = true

[[recipients]]
name = "Alice"
email = "alice@example.com"
jobs = ["daily-briefing", "weekly-summary"]

[[recipients]]
name = "Team Channel"
email = "team@example.com"
jobs = ["*"]                         # All jobs
```

New `EmailDelivery` variant in `scheduler/types.gleam`, SMTP client in `scheduler/email.gleam`.

---

## Git Backup

Per-tenant config: `.springdrift/tenants/<id>/backup.toml`

```toml
[git]
enabled = true
remote = "git@github.com:org/springdrift-data.git"
branch = "tenant/default"
schedule = "hourly"                   # hourly | daily | after_cycle
ssh_key_path = "~/.ssh/springdrift_backup"

[git.commit]
author_name = "Springdrift Agent"
author_email = "agent@example.com"
```

OTP actor per tenant with periodic `git add/commit/push`. Uses existing `run_cmd` FFI.

---

## Resource Limits

Per-tenant in `tenants.toml`:

| Limit | Purpose |
|---|---|
| `max_cycles_per_hour` | Scheduler autonomy cap |
| `max_token_budget_per_hour` | LLM spend cap |
| `max_storage_mb` | Data directory quota |
| `max_sandbox_slots` | Container pool share |
| `max_requests_per_minute` | LLM API rate limit |

---

## Additional Design Considerations

### 1. Who said what

When multiple users share a tenant, the agent needs to distinguish them. `UserInput` messages carry a username. The agent sees "alice: ..." vs "bob: ...". The cycle log records which user triggered each cycle.

### 2. Concurrent access to the same tenant

Two team members talking to the same agent simultaneously. The cognitive loop processes one input at a time (input queue handles this). The notification relay broadcasts to ALL WebSocket connections on that tenant — both users see responses.

### 3. Audit trail per user

Cycle log entries gain a `user_id` field. Full traceability of who triggered what.

### 4. Session isolation

Two users on the same tenant see the same agent state (shared memory, shared conversation). Two users on different tenants see nothing of each other. Auth cookie scopes every request to a tenant.

### 5. Agent identity per tenant

Each tenant has its own `identity.json` and `identity/` directory. Different tenants can have different agent names and personas. Research team gets "Atlas", personal workspace gets "Curragh".

### 6. LLM provider per tenant

Provider selection is per-tenant config. Some tenants use Anthropic, others Vertex. Falls naturally out of the per-tenant config merge.

### 7. D' config per tenant

`dprime.json` lives in the tenant directory. Different tenants can have different safety rules, thresholds, and deterministic patterns.

### 8. Backup failure notifications

When git backup fails, the admin sees it in the web GUI notification area, not just in logs.

### 9. Tenant creation from admin UI

Admin users can create new tenants and add users from the web interface, not just by editing `tenants.toml`.

### 10. Logout and session expiry

Sessions expire after configurable inactivity. On expiry, back to the login page. Explicit logout clears the session.

### 11. ETS memory with many tenants

Each Librarian creates ~15 ETS tables. With 10 tenants = 150 tables (within BEAM's default 1400 limit). Lazy startup and idle shutdown keep active table count low. For larger deployments, set `ERL_MAX_ETS_TABLES`.

### 12. Cold start time

Lazy startup mitigates this. Each tenant's Librarian replays JSONL on start. Per-tenant `librarian_max_days` controls the replay window. Future optimisation: background replay with progressive availability.

### 13. LLM API key management

Shared by default (global config provides keys). Tenants can override by specifying which env var to read in their config — keys are never stored in config files.

---

## Migration Path

### Zero-change backward compatibility

No `tenants.toml` = single-tenant mode. Nothing changes for existing installations.

### Migration command

```sh
gleam run -- --migrate-to-multi-tenant
```

This:
1. Creates `.springdrift/tenants.toml` with a single `default` user
2. Creates `.springdrift/tenants/default/`
3. Moves all data from `.springdrift/` root into `.springdrift/tenants/default/`
4. Leaves `config.toml` and `schemas/` at the root (shared)

### Tenant creation command

```sh
gleam run -- --create-tenant <name>
```

Scaffolds a tenant directory with default config.

---

## Implementation Phases

| Phase | What | Effort | Risk |
|---|---|---|---|
| 1 | Parameterise `paths.gleam` with tenant_id (`Option(String)`, `None` = current behaviour) | Large | Highest — touches every file |
| 2 | Tenant registry parser + four-layer config merge | Medium | Low |
| 3 | Extract `TenantInstance` from `springdrift.run()` | Large | Medium — key refactor |
| 4 | `TenantManager` actor (lazy start/stop) | Medium | Low |
| 5 | Login page + session management | Medium | Low |
| 6 | Web multi-tenant routing + per-tenant WebSocket binding | Medium | Medium |
| 7 | Per-tenant scheduler wiring | Small | Low — already isolated per cognitive loop |
| 8 | User attribution in cycle log + chat | Small | Low |
| 9 | Email delivery (SMTP client + config) | Medium | Low |
| 10 | Git backup actor | Small | Low |
| 11 | Resource limits + storage quotas | Small | Low |
| 12 | Admin UI (tenant management) | Medium | Low |
| 13 | Migration tooling + docs | Medium | Low |

### Key risk

Phase 1 touches the most files. Mitigation: `Option(String)` everywhere with `None` preserving current behaviour. Single-tenant mode works throughout development. Every phase is independently testable.

---

## New Files

| File | Purpose |
|---|---|
| `src/tenant/types.gleam` | TenantId, TenantConfig, UserEntry, TenantRegistry, TenantProcesses, UserRole |
| `src/tenant/registry.gleam` | Parse tenants.toml, user lookup, tenant resolution |
| `src/tenant/config.gleam` | Four-layer config merge with tenant layer |
| `src/tenant/instance.gleam` | Reusable tenant bootstrap (extracted from springdrift.run) |
| `src/tenant/manager.gleam` | OTP actor: lazy start/stop of tenant instances |
| `src/tenant/auth.gleam` | Login, session management, tenant-aware auth |
| `src/tenant/email.gleam` | Per-tenant email.toml parser |
| `src/tenant/backup.gleam` | OTP actor for periodic git backup |
| `src/scheduler/email.gleam` | SMTP delivery implementation |

## Significantly Modified Files

| File | Change |
|---|---|
| `src/paths.gleam` | All functions gain tenant_id parameter |
| `src/springdrift.gleam` | Refactor run() to use TenantInstance |
| `src/web/gui.gleam` | Multi-tenant routing, login, per-tenant WsState |
| `src/web/html.gleam` | Login page, admin scoping, tenant admin tab |
| `src/agent/cognitive_config.gleam` | Add tenant_id |
| `src/agent/cognitive_state.gleam` | Add tenant_id to MemoryContext |
| `src/config.gleam` | Per-tenant config merge layer |
| `src/storage.gleam` | Tenant-scoped session paths |
| `src/slog.gleam` | Tenant-scoped log paths |
| `src/agent_identity.gleam` | Tenant-scoped identity path |
| `src/cycle_log.gleam` | Add user_id to entries |
| `src/scheduler/types.gleam` | Add EmailDelivery variant |
| `src/scheduler/delivery.gleam` | Email delivery support |
| `src/sandbox/manager.gleam` | Per-tenant workspace namespacing |

---

## Recommendation

Do not build this yet. Stabilise D', get Vertex working, let the agent run unattended for a week. Have the plan ready for when someone asks "can this be multi-tenant?" — the answer is yes, the architecture is designed for it, the migration is non-destructive, and single-tenant is a special case of multi-tenant.
