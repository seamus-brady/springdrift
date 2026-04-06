# SD Budget — Token Cost Management Tool

**Status**: Planned
**Date**: 2026-03-26
**Dependencies**: Multi-provider failover (planned), Multi-tenant (planned)

---

## Table of Contents

- [Overview](#overview)
- [Why a Separate Tool](#why-a-separate-tool)
- [What It Tracks](#what-it-tracks)
- [CLI Commands](#cli-commands)
  - [`sd-budget summary`](#sd-budget-summary)
  - [`sd-budget breakdown`](#sd-budget-breakdown)
  - [`sd-budget dprime`](#sd-budget-dprime)
  - [`sd-budget waste`](#sd-budget-waste)
  - [`sd-budget forecast`](#sd-budget-forecast)
  - [`sd-budget alert`](#sd-budget-alert)
  - [`sd-budget report`](#sd-budget-report)
  - [`sd-budget compare`](#sd-budget-compare)
  - [`sd-budget export`](#sd-budget-export)
- [Cost Model](#cost-model)
- [Budget Alerts](#budget-alerts)
  - [In-Agent Alerts](#in-agent-alerts)
  - [External Alerts](#external-alerts)
- [Reports](#reports)
- [Web GUI Integration](#web-gui-integration)
- [Multi-Tenant Budget Isolation](#multi-tenant-budget-isolation)
- [Architecture](#architecture)
- [Configuration](#configuration)
- [Relationship to Other Specs](#relationship-to-other-specs)
- [Implementation Order](#implementation-order)
- [What This Enables](#what-this-enables)

---

## Overview

A standalone Python CLI tool for tracking, analysing, and managing token costs across Springdrift agents, providers, tenants, and time periods. Part of the Python tooling suite alongside SD Audit, SD Designer, and SD Backup.

SD Budget answers: "How much did this agent cost to run?", "Where did the money go?", and "Are we within budget?"

## Why a Separate Tool

Token cost management is an operator concern, not an agent concern. The agent should focus on doing good work. The operator tracks the bill. Separating this keeps the agent's codebase clean and gives the operator a familiar toolchain.

The running agent tracks raw token counts (it already does — `tokens_in`/`tokens_out` on every cycle). SD Budget reads those counts and applies cost models offline.

## What It Tracks

| Metric | Source | Granularity |
|---|---|---|
| Input tokens | Cycle log `tokens_in` | Per cycle |
| Output tokens | Cycle log `tokens_out` | Per cycle |
| Thinking tokens | Cycle log `thinking_tokens` | Per cycle |
| Model used | Cycle log `model` | Per cycle |
| Provider used | Cycle log `provider` | Per cycle |
| D' overhead | D' audit log (scorer calls) | Per gate evaluation |
| Canary overhead | D' audit log (probe calls) | Per canary evaluation |
| Archivist overhead | Narrative log (archivist cycles) | Per cycle |
| Agent sub-cycles | DAG nodes (agent cycles) | Per delegation |
| Scheduler cycles | DAG nodes (scheduler cycles) | Per job |

### What SD Budget calculates

- **Cost in currency**: tokens × rate per model per provider
- **Cost attribution**: which endeavour/task/agent/tool consumed the most
- **D' tax**: what percentage of total cost is safety evaluation overhead
- **Waste**: tokens spent on retries, failed calls, D' rejections, output gate revisions
- **Trends**: daily/weekly/monthly cost trajectory
- **Forecasts**: projected monthly spend based on recent usage
- **Budget alerts**: threshold-based warnings

## CLI Commands

```
sd-budget [OPTIONS] COMMAND [ARGS]

Options:
  --data-dir PATH      Path to .springdrift/ directory
  --tenant TEXT         Tenant ID
  --from DATE           Start date
  --to DATE             End date
  --provider TEXT       Filter by provider
  --model TEXT          Filter by model

Commands:
  summary              Cost summary for a period
  breakdown            Detailed breakdown by model/provider/agent/task
  dprime               D' safety system cost analysis
  waste                Tokens spent on retries, failures, rejections
  forecast             Cost forecast based on recent usage
  alert                Check budget alerts
  export               Export cost data as CSV/JSON
  compare              Compare costs between periods or providers
  report               Generate formatted cost report (text/html)
```

### `sd-budget summary`

```
$ sd-budget summary --from 2026-03-20 --to 2026-03-26

Token Cost Summary: 2026-03-20 to 2026-03-26
=============================================

Total tokens:     1,245,000 (in: 892K, out: 353K)
Total cost:       $2.47

By provider:
  anthropic:      1,198,000 tokens  $2.39 (97%)
  vertex:         47,000 tokens     $0.08 (3%)

By model:
  claude-opus-4-6:     423,000 tokens  $1.54 (62%)
  claude-haiku-4-5:    822,000 tokens  $0.93 (38%)

By purpose:
  User cycles:         612,000 tokens  $1.38 (56%)
  Agent sub-cycles:    389,000 tokens  $0.72 (29%)
  D' safety overhead:  156,000 tokens  $0.24 (10%)
  Scheduler cycles:    88,000 tokens   $0.13 (5%)

Daily average:   $0.35/day
Monthly forecast: $10.65 (at current rate)
```

### `sd-budget breakdown`

```
$ sd-budget breakdown --by agent

Cost by Agent
==============

Agent            Cycles  Tokens      Cost     Avg/Cycle
─────────────────────────────────────────────────────
cognitive        89      612,000     $1.38    $0.016
researcher       34      245,000     $0.48    $0.014
coder            12      89,000      $0.15    $0.013
planner          8       32,000      $0.04    $0.005
writer           4       23,000      $0.03    $0.008
observer         3       12,000      $0.01    $0.003
scheduler        15      88,000      $0.13    $0.009
D' (all gates)   —       156,000     $0.24    —
─────────────────────────────────────────────────────
Total            165     1,245,000   $2.47
```

Also supports: `--by model`, `--by provider`, `--by endeavour`, `--by tool`.

### `sd-budget dprime`

```
$ sd-budget dprime

D' Safety Cost Analysis
=========================

Total D' cost:        $0.24 (10% of total spend)

By gate:
  Input gate:         $0.08 (89 evaluations, avg 920 tokens)
  Tool gate:          $0.05 (156 evaluations, avg 340 tokens)
  Output gate:        $0.09 (89 evaluations, avg 1100 tokens)
  Canary probes:      $0.02 (178 probes, avg 128 tokens)

Deterministic savings:
  Evaluations skipped by pre-filter: 7
  Estimated savings: $0.01

D' tax rate:          10.0%

Waste from D':
  Tokens on rejected inputs:    12,400
  Tokens on output revisions:   34,800
  Total D' waste:               $0.08 (3.2% of total)
```

### `sd-budget waste`

```
$ sd-budget waste

Token Waste Analysis
=====================

Total waste:     187,000 tokens ($0.31, 12.6% of total)

By category:
  Provider retries:    89,000 tokens  $0.14
  D' output revisions: 34,800 tokens  $0.06
  D' rejections:       12,400 tokens  $0.02
  Failed agent cycles: 28,000 tokens  $0.05
  Model fallback:      22,800 tokens  $0.04

Recommendations:
  → Provider retries are the largest waste category.
    Consider multi-provider failover.
  → Output revisions significant (14 cycles).
    Review D' output gate thresholds.
```

### `sd-budget forecast`

```
$ sd-budget forecast

Cost Forecast
==============

Based on: last 7 days of usage
Current daily rate: $0.35/day

Projected:
  This month:    $10.65
  This quarter:  $31.95

Budget status:
  Monthly budget: $50.00
  Used:           $2.47 (4.9%)
  Projected:      $10.65 (21.3%)
  Status:         Within budget
```

### `sd-budget alert`

```
$ sd-budget alert

Budget Alerts
==============

  Monthly budget: $2.47 / $50.00 (4.9%) — healthy
  Daily rate increasing: $0.28 → $0.42 over last 3 days — warning
  D' tax rate: 10.0% — above 8% threshold — warning
  No provider approaching rate limit — healthy
```

### `sd-budget report`

```sh
sd-budget report --from 2026-03-01 --to 2026-03-31 --format html --output march-2026.html
```

HTML report with: executive summary, provider/model/agent breakdowns, D' overhead, waste analysis, forecast, recommendations. Suitable for management or invoices.

### `sd-budget compare`

```sh
sd-budget compare --period1 2026-02 --period2 2026-03
sd-budget compare --provider anthropic --provider vertex --from 2026-03-20
```

Side-by-side comparison of costs between time periods or providers.

### `sd-budget export`

```sh
sd-budget export --from 2026-03-01 --format csv --output march.csv
```

Flat CSV for import into spreadsheets, accounting systems, or BI tools.

## Cost Model

Per-provider, per-model pricing stored in config:

```toml
[[providers]]
name = "anthropic"

[[providers.models]]
name = "claude-opus-4-6"
input_per_million = 15.00
output_per_million = 75.00

[[providers.models]]
name = "claude-haiku-4-5-20251001"
input_per_million = 0.80
output_per_million = 4.00

[[providers]]
name = "mistral"

[[providers.models]]
name = "mistral-large-latest"
input_per_million = 2.00
output_per_million = 6.00
```

Rates updated manually or fetched from provider pricing pages (future enhancement).

## Budget Alerts

### In-Agent Alerts

The running agent can check budget status via the scheduler:

```toml
[[task]]
name = "budget-check"
kind = "recurring"
interval_ms = 3600000
query = "Check if we're approaching the token budget. Report any concerns."
```

When budget is low, the agent can: prefer task_model, reduce Archivist calls, reduce canary frequency, notify operator.

### External Alerts

SD Budget runs in a cron job or CI pipeline:

```sh
sd-budget alert --format json | check_warnings.sh
```

Alert thresholds configurable:

```toml
[budget.alerts]
monthly_budget_usd = 50.00
warn_at_pct = 80
daily_rate_increase_pct = 50
dprime_tax_pct = 8
```

## Reports

HTML report includes:
- Executive summary (total cost, daily trend, budget status)
- Provider breakdown with chart
- Model breakdown with chart
- Agent breakdown with chart
- D' overhead analysis
- Waste analysis
- Forecast
- Recommendations

## Web GUI Integration

Budget section in admin dashboard (see [Web GUI v2 spec](web-gui-v2.md)):

```
Budget
=======

This Month: $2.47 / $50.00 ████░░░░░░ 4.9%

Today: $0.42 (↑18% vs yesterday)

[Daily cost chart over 7 days]

[Full Report] [Export CSV] [Alerts Config]
```

## Multi-Tenant Budget Isolation

Each tenant has its own budget:

```toml
# In tenants.toml
[[tenants]]
name = "research-team"
monthly_budget_usd = 200.00
```

```sh
sd-budget summary --tenant research-team
sd-budget summary --all-tenants
```

## Architecture

```
sd-budget/
├── pyproject.toml
├── sd_budget/
│   ├── __init__.py
│   ├── cli.py
│   ├── reader.py           # Token extraction from cycle logs
│   ├── cost.py             # Cost model (tokens × rates)
│   ├── analysis/
│   │   ├── summary.py
│   │   ├── breakdown.py
│   │   ├── dprime.py
│   │   ├── waste.py
│   │   ├── forecast.py
│   │   └── alerts.py
│   ├── formatters/
│   │   ├── text.py
│   │   ├── json.py
│   │   ├── csv.py
│   │   └── html.py
│   └── config.py
└── tests/
```

### Dependencies

```toml
[project]
requires-python = ">=3.10"
dependencies = ["click>=8.0"]

[project.optional-dependencies]
charts = ["matplotlib>=3.7"]
full = ["matplotlib>=3.7", "pandas>=2.0"]
```

Installed at `tools/sd-budget/`.

## Configuration

```toml
[budget]
monthly_budget_usd = 50.00
warn_at_pct = 80
daily_rate_increase_pct = 50
dprime_tax_pct = 8
```

## Relationship to Other Specs

| Spec | Relationship |
|---|---|
| [Multi-Provider Failover](multi-provider-failover.md) | Router tracks costs per provider; SD Budget reads them |
| [Multi-Tenant](multi-tenant.md) | Per-tenant budgets and cost isolation |
| [Autonomous Endeavours](autonomous-endeavours.md) | Per-endeavour cost tracking |
| [Comms Agent](comms-agent.md) | Budget alerts via email/WhatsApp |
| [Self-Diagnostic Skill](self-diagnostic-skill.md) | Diagnostic checks budget health |
| [SD Audit](sd-audit.md) | Same source data, different analysis (audit vs cost) |
| [Escalation Criteria](../roadmap/implemented/dprime-enhancements.md) | Budget-aware escalation could prefer task_model when budget is low |
| [Web GUI v2](web-gui-v2.md) | Budget section in admin dashboard |

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | CLI framework + token reader | Small |
| 2 | Cost model (tokens × rates) | Small |
| 3 | Summary + breakdown commands | Medium |
| 4 | D' overhead analysis | Small |
| 5 | Waste analysis | Medium |
| 6 | Forecast + alerts | Medium |
| 7 | HTML report generation | Medium |
| 8 | Web GUI budget section | Medium |
| 9 | Multi-tenant budget isolation | Small |

## What This Enables

The answer to "how much does it cost?" with full traceability: which models, which agents, which tasks, and how much the safety system costs as a percentage. For enterprise deployment, cost transparency is a procurement requirement. For the operator, it's how you manage a budget without guessing.

The Python tooling suite: SD Designer (configure) → Springdrift (run) → SD Audit (examine) → SD Budget (cost) → SD Backup (protect).
