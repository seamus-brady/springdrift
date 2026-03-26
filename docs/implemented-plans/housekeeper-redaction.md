# Housekeeper GenServer and Secret Redaction — Implementation Record

**Status**: Implemented
**Date**: 2026-03-18 onwards
**Source**: housekeeper-redaction-spec.md

---

## Table of Contents

- [Overview](#overview)
- [Housekeeper (`narrative/housekeeper.gleam`)](#housekeeper-narrativehousekeepergleam)
  - [Maintenance Tasks](#maintenance-tasks)
  - [Configuration](#configuration)
- [Secret Redaction (`narrative/redactor.gleam`)](#secret-redaction-narrativeredactorgleam)
  - [Pattern Categories](#pattern-categories)
  - [Key Fixes](#key-fixes)


## Overview

Long-running maintenance actor for ETS/memory hygiene, plus a secret redaction module applied at all log-write boundaries.

## Housekeeper (`narrative/housekeeper.gleam`)

Supervised GenServer with three tick intervals:

| Tick | Default | Tasks |
|---|---|---|
| Short (6h) | 21,600,000ms | Narrative window trimming |
| Medium (12h) | 43,200,000ms | Fact conflict resolution, thread pruning |
| Long (24h) | 86,400,000ms | CBR dedup/pruning, DAG/artifact trim |

### Maintenance Tasks

- **CBR dedup**: Symmetric weighted field similarity (configurable threshold, default 0.92)
- **CBR pruning**: Old low-confidence failures without pitfalls; cases with harmful_count > helpful_count * 2 and retrieval_count > 5
- **Fact conflict resolution**: Same-key different-value, keeps higher confidence
- **Thread pruning**: Single-cycle threads with no signal after N days (default 7)
- **ETS memory management**: Configurable retention windows per store (narrative 90d, CBR 180d, DAG 30d, artifacts 60d)
- **Budget-triggered dedup**: Immediate CBR dedup when Curator's preamble budget causes truncation (30-minute debounce)

### Configuration

```toml
[housekeeper]
# short_tick_ms = 21600000
# medium_tick_ms = 43200000
# long_tick_ms = 86400000
# narrative_days = 90
# cbr_days = 180
# dag_days = 30
# artifact_days = 60
# budget_dedup_debounce_ms = 1800000

[housekeeping]
# dedup_similarity = 0.92
# pruning_confidence = 0.3
# fact_confidence = 0.7
# cbr_pruning_days = 60
# thread_pruning_days = 7
# fact_decay_half_life_days = 30
# cbr_decay_half_life_days = 60
```

## Secret Redaction (`narrative/redactor.gleam`)

Pure module applied at log-write boundaries. Idempotent — already-redacted text passes through unchanged.

### Pattern Categories

| Category | Example | Replacement |
|---|---|---|
| Private keys | `-----BEGIN RSA PRIVATE KEY-----` | `[REDACTED:private_key]` |
| JWTs | `eyJhbG...` | `[REDACTED:jwt]` |
| API keys | `sk-ant-...`, `ghp_...`, `xoxb-...`, `AIza...` | `[REDACTED:api_key]` |
| JSON secret fields | `"api_key": "long_value"` | `[REDACTED:api_key]` |
| Bearer tokens | `Bearer eyJ...` | `Bearer [REDACTED:bearer_token]` |
| URL credentials | `://user:pass@host` | `://[REDACTED:url_credential]@host` |
| Password fields | `"password": "..."` | `[REDACTED:password]` |
| Env secrets | `API_KEY=value` | `[REDACTED:env_secret]` |

### Key Fixes
- Word boundary `\b` on `sk-` pattern to prevent matching inside words like `task-fde57327...`
- JSON field regex tightened from generic `"key"/"token"` to secret-specific names only (`api_key`, `access_token`, `client_secret`, etc.)
- `redact_secrets` configurable per agent and globally (default: true)
