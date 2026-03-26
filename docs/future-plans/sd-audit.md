# SD Audit — Python Log Analysis Toolkit

**Status**: Planned
**Date**: 2026-03-26
**Dependencies**: None — reads existing JSONL logs, no changes to Springdrift core

---

## Table of Contents

- [Overview](#overview)
- [Design Principles](#design-principles)
- [CLI Interface](#cli-interface)
- [Commands](#commands)
  - [`sd-audit summary`](#sd-audit-summary)
  - [`sd-audit cycles`](#sd-audit-cycles)
  - [`sd-audit dprime`](#sd-audit-dprime)
  - [`sd-audit cbr`](#sd-audit-cbr)
  - [`sd-audit facts`](#sd-audit-facts)
  - [`sd-audit narrative`](#sd-audit-narrative)
  - [`sd-audit timeline`](#sd-audit-timeline)
  - [`sd-audit meta-states`](#sd-audit-meta-states)
  - [`sd-audit export`](#sd-audit-export)
  - [`sd-audit compliance`](#sd-audit-compliance)
- [Architecture](#architecture)
  - [Dependencies](#dependencies)
  - [Installation](#installation)
- [JSONL Format Compatibility](#jsonl-format-compatibility)
- [Relationship to Springdrift](#relationship-to-springdrift)
- [Relationship to Empirical Evaluation](#relationship-to-empirical-evaluation)
- [Implementation Estimate](#implementation-estimate)


## Overview

A standalone Python CLI tool for offline analysis, auditing, and reporting on Springdrift's append-only JSONL logs. Reads the immutable log files directly — no connection to the running agent, no Erlang dependency, no modification of source data.

SD Audit is the external verification tool. Springdrift's own introspection tools (`inspect_cycle`, `reflect`, `introspect`) let the agent examine itself. SD Audit lets a human, auditor, or automated pipeline examine the agent independently — using standard Python data analysis tooling.

---

## Design Principles

1. **Read-only.** SD Audit never writes to `.springdrift/`. It reads JSONL files and produces reports to stdout or a separate output directory.
2. **No agent dependency.** Does not require the agent to be running. Works on a cold `.springdrift/` directory, a git checkout, or a backup archive.
3. **Standard tooling.** Python, pandas, click (CLI), matplotlib/plotly (optional charts). No exotic dependencies.
4. **Multi-tenant aware.** Understands the `tenants/` directory structure when present. Falls back to single-tenant root when not.
5. **Reproducible.** Same logs, same command, same output. No randomness, no LLM calls.

---

## CLI Interface

```
sd-audit [OPTIONS] COMMAND [ARGS]

Options:
  --data-dir PATH      Path to .springdrift/ directory (default: .springdrift)
  --tenant TEXT        Tenant ID (default: auto-detect or root)
  --from DATE          Start date (YYYY-MM-DD)
  --to DATE            End date (YYYY-MM-DD, default: today)
  --format TEXT        Output format: text | json | csv | html (default: text)
  --output PATH        Output file (default: stdout)
```

---

## Commands

### `sd-audit summary`

High-level overview of agent activity for a date range.

```
$ sd-audit summary --from 2026-03-20 --to 2026-03-26

Springdrift Audit Summary: 2026-03-20 to 2026-03-26
=====================================================

Agent: Curragh (a62fa947)
Session since: 2026-03-20T08:15:00Z
Data directory: .springdrift/

Activity:
  Total cycles:          247
  User cycles:           89
  Scheduler cycles:      158
  Agent sub-cycles:      412
  Total tokens:          1,245,000 (in: 892K, out: 353K)
  Total tool calls:      1,834
  Tool failures:         23 (1.3%)

Safety (D'):
  Input gate:            89 evaluations (87 accept, 1 modify, 1 reject)
  Tool gate:             156 evaluations (148 accept, 5 modify, 3 reject)
  Output gate:           89 evaluations (71 accept, 14 modify, 4 reject)
  Deterministic blocks:  7
  Canary probe failures: 2 (both during Vertex auth issue)
  False positives reported: 3

Memory:
  Narrative entries:     89
  CBR cases:             34 (12 Strategy, 8 CodePattern, 6 Troubleshooting, 5 Pitfall, 3 DomainKnowledge)
  Facts written:         67
  Facts with provenance: 52 (78%)
  Artifacts stored:      12

Endeavours:
  Active:                2
  Completed:             1
  Blocked:               1

Model usage:
  claude-opus-4-6:       34 cycles (38%)
  claude-haiku-4-5:      55 cycles (62%)
  Escalations:           3 (tool failures → model upgrade)
  Fallbacks:             7 (provider timeout → task model)
```

### `sd-audit cycles`

List all cognitive cycles with key metrics.

```
$ sd-audit cycles --from 2026-03-25

Cycle ID      Time     Type       Model              Tools  Tokens  D' Score  Outcome
─────────────────────────────────────────────────────────────────────────────────────
c8e201c0      07:34    user       claude-opus-4-6    3      4,521   0.00/0.56 success
20cd8f46      07:39    user       claude-haiku-4-5   2      1,203   0.00/0.56 modified
59209ed6      08:42    user       claude-opus-4-6    5      8,102   0.00/0.41 success
6ac2c52e      09:50    user       claude-haiku-4-5   0        892   0.67/—    rejected
...

D' Score shown as: input_gate/output_gate (— if not evaluated)
```

Options:
- `--type user|scheduler|agent` — filter by cycle type
- `--outcome success|failure|modified|rejected` — filter by outcome
- `--model TEXT` — filter by model
- `--min-tokens N` — minimum token usage
- `--sort tokens|duration|dprime` — sort order

### `sd-audit dprime`

D' safety gate analysis.

```
$ sd-audit dprime --from 2026-03-25

D' Safety Gate Report: 2026-03-25
===================================

Input Gate:
  Evaluations:   12
  Accept:        10 (83%)
  Modify:        1 (8%)
  Reject:        1 (8%)
  Avg score:     0.08
  Max score:     0.67 (cycle 6ac2c52e — operator meta-discussion)
  Deterministic: 0 blocks, 0 escalations

Tool Gate:
  Evaluations:   28
  Accept:        26 (93%)
  Exempt:        14 (memory/planner/builtin tools skipped)
  Modify:        1 (4%)
  Reject:        1 (4%)

Output Gate:
  Evaluations:   12
  Accept:        7 (58%)
  Modify:        4 (33%)
  Reject:        1 (8%)
  Avg score:     0.31
  Most common flag: unsourced_claim (4 times)

Feature Triggers (all gates):
  unsourced_claim:         4
  certainty_overstatement: 3
  accuracy:                2
  prompt_injection:        1

Meta Observer:
  Interventions:  2
  TightenAllGates: 2 (factor 0.90)
  Escalations:    0
  False positives: 0

Threshold History:
  Input gate:  modify 0.45 → 0.45 (stable), reject 0.75 → 0.68 (tightened)
  Output gate: modify 0.40 → 0.40 (stable), reject 0.75 → 0.68 (tightened)
```

Options:
- `--gate input|tool|output|all` — filter by gate
- `--decision accept|modify|reject` — filter by decision
- `--feature TEXT` — filter by feature name
- `--show-explanations` — include full D' explanations

### `sd-audit cbr`

CBR case analysis — retrieval quality, usage stats, category distribution.

```
$ sd-audit cbr

CBR Case Report
================

Total cases:     134
  Strategy:      42 (31%)
  CodePattern:   28 (21%)
  Troubleshooting: 24 (18%)
  Pitfall:       19 (14%)
  DomainKnowledge: 15 (11%)
  Uncategorised: 6 (4%)

Usage Stats:
  Cases ever retrieved:  89 (66%)
  Never retrieved:       45 (34%)
  Avg retrieval count:   3.2
  Avg utility score:     0.61

Top 5 most useful (by utility score):
  1. case-a1b2c3 (Strategy, utility: 0.92) — "Web search → brave_answer for factual queries"
  2. case-d4e5f6 (Pitfall, utility: 0.88) — "Don't present reconstructed data as verified"
  3. ...

Bottom 5 (harmful case candidates):
  1. case-x7y8z9 (Troubleshooting, utility: 0.15, harmful: 6, helpful: 1)
  2. ...

Confidence Decay Impact:
  Cases > 30 days old:   34
  Avg original confidence: 0.78
  Avg decayed confidence:  0.42
  Effective decay:         46%
```

Options:
- `--category TEXT` — filter by category
- `--min-retrievals N` — minimum retrieval count
- `--harmful` — show only harmful case candidates
- `--stale` — show cases with decayed confidence below threshold

### `sd-audit facts`

Fact store analysis — provenance coverage, decay, conflicts.

```
$ sd-audit facts

Fact Store Report
==================

Total facts:     312 (active: 267, deleted: 45)
  Persistent:    198
  Session:       69
  Ephemeral:     0 (cleared)

Provenance:
  With provenance:    212 (79%)
  Without (legacy):   55 (21%)
  Derivation breakdown:
    Synthesis:         178 (84%)
    DirectObservation: 28 (13%)
    OperatorProvided:  6 (3%)
    Unknown:           0

Confidence Decay:
  Facts > 30 days:    89
  Avg original:       0.81
  Avg decayed:        0.44
  Below 0.3 (stale):  23

Top keys by write frequency:
  1. "research_status" — 12 writes (latest: 0.72 confidence)
  2. "agent_health" — 8 writes
  3. ...
```

Options:
- `--scope persistent|session|ephemeral` — filter by scope
- `--stale` — show facts with decayed confidence below threshold
- `--conflicts` — show keys with contradictory values
- `--key TEXT` — trace a specific key's full history

### `sd-audit narrative`

Narrative and thread analysis.

```
$ sd-audit narrative --from 2026-03-20

Narrative Report: 2026-03-20 to 2026-03-26
=============================================

Entries: 89
Threads: 12 active, 3 closed

Top threads by activity:
  1. "D' Safety System" — 23 entries, 5 domains
  2. "Three-Paper Integration" — 18 entries, 3 domains
  3. "Vertex AI Setup" — 9 entries, 2 domains
  ...

Intent distribution:
  Research:      34 (38%)
  Implementation: 28 (31%)
  Analysis:      15 (17%)
  Maintenance:   12 (13%)

Outcome distribution:
  Success:       67 (75%)
  Partial:       14 (16%)
  Failure:       8 (9%)
```

### `sd-audit timeline`

Chronological event timeline — useful for incident investigation.

```
$ sd-audit timeline --from 2026-03-25T08:00 --to 2026-03-25T09:00

08:42:08  CYCLE START    59209ed6  user input: "Good morning Curragh..."
08:42:08  D' INPUT       ACCEPT    score: 0.00
08:42:08  MODEL SELECT   opus-4-6  complexity: complex
08:42:13  TOOL CALL      reflect   → success
08:42:13  TOOL CALL      recall_recent → success (3 entries)
08:42:13  TOOL CALL      introspect → success
08:42:19  D' OUTPUT      MODIFY    score: 0.41 — unsourced_claim, certainty_overstatement
08:42:19  SYSTEM         [Response NOT delivered — quality gate revision]
08:42:54  LLM RETRY      attempt 1/3 — timeout
08:43:25  LLM RETRY      attempt 2/3 — timeout
08:44:05  LLM RETRY      attempt 1/3 — timeout (fallback model)
08:45:39  THINK ERROR    timeout — exhausted retries
08:45:54  FALLBACK       opus → haiku (revision with fallback model)
08:46:07  D' OUTPUT      MODIFY    score: 0.56 — cautious fallback (scorer failed)
08:46:15  REVISION       delivered with quality warning
08:46:20  D' TOOL        ACCEPT    score: 0.00
08:46:20  CYCLE END      59209ed6  outcome: success (with warning)
```

Options:
- `--verbose` — include tool call inputs/outputs
- `--dprime-only` — show only D' events
- `--errors-only` — show only errors and warnings

### `sd-audit meta-states`

Meta-state analysis — uncertainty, prediction error, novelty over time.

```
$ sd-audit meta-states --from 2026-03-25

Meta-State Report: 2026-03-25
================================

Session averages:
  Uncertainty:       0.32 (12 cycles)
  Prediction error:  0.08
  Novelty:          0.61

Trend:
  08:00-12:00  uncertainty: 0.45  pred_error: 0.12  novelty: 0.78
  12:00-16:00  uncertainty: 0.28  pred_error: 0.05  novelty: 0.52
  16:00-20:00  uncertainty: 0.22  pred_error: 0.06  novelty: 0.48

Correlations (with cycle outcome):
  Uncertainty → failure:      r=0.42 (moderate)
  Prediction error → failure: r=0.58 (strong)
  Novelty → tool_call_count:  r=0.35 (weak-moderate)

Escalations triggered by meta-states: 1
  Cycle 6ac2c52e — prediction_error 0.67 → model escalation
```

### `sd-audit export`

Export raw data for external analysis tools.

```
$ sd-audit export cycles --from 2026-03-20 --format csv --output cycles.csv
$ sd-audit export dprime --from 2026-03-20 --format json --output dprime.json
$ sd-audit export cbr --format csv --output cbr_cases.csv
$ sd-audit export facts --format csv --output facts.csv
$ sd-audit export narrative --format json --output narrative.json
```

Exports clean, flat data suitable for pandas, Excel, R, or any analysis tool.

### `sd-audit compliance`

Compliance-focused report for regulated industries.

```
$ sd-audit compliance --from 2026-03-20 --to 2026-03-26

Compliance Audit Report
========================
Period: 2026-03-20 to 2026-03-26
Agent: Curragh (a62fa947)
Generated: 2026-03-26T22:00:00Z

1. DECISION AUDIT TRAIL
   All 247 cognitive cycles have complete audit trails.
   No gaps in cycle ID sequence.
   All cycles have: input logged, tools logged, output logged, D' evaluation logged.

2. SAFETY GATE COVERAGE
   Input gate:  89/89 user inputs evaluated (100%)
   Tool gate:   156/170 tool calls evaluated (92% — 14 exempt internal tools)
   Output gate: 89/89 outputs evaluated (100%)
   No unreviewed output delivered to users.

3. DATA PROVENANCE
   Facts with provenance: 212/267 (79%)
   CBR cases with source narrative: 134/134 (100%)
   All narrative entries have cycle_id linkage.

4. SAFETY INTERVENTIONS
   D' rejections: 5 (all logged with explanations)
   D' modifications: 19 (all re-evaluated after revision)
   Deterministic blocks: 7 (pattern-matched, no LLM needed)
   Meta observer interventions: 2 (threshold tightening)
   False positives reported: 3 (annotated in meta log)

5. DATA INTEGRITY
   All log files are append-only JSONL.
   No evidence of modification or truncation.
   SHA256 checksums of log files: [listed]

6. EXTERNAL COMMUNICATIONS
   Outbound messages: 0 (comms agent not yet deployed)
   All outputs delivered via authenticated web GUI only.

7. ANOMALIES
   2 canary probe failures (2026-03-24, correlated with Vertex AI auth issue)
   7 LLM fallbacks (provider timeouts, all during US peak hours)
   1 meta observer escalation (rate + rejection pattern)
```

Options:
- `--standard iso27001|soc2|gdpr|custom` — compliance framework mapping
- `--sign` — include SHA256 checksums of all source log files
- `--format html` — formatted HTML report for distribution

---

## Architecture

```
sd-audit/
├── pyproject.toml           # Python packaging (pip installable)
├── sd_audit/
│   ├── __init__.py
│   ├── cli.py               # Click CLI entry point
│   ├── config.py            # Data dir detection, tenant resolution
│   ├── readers/
│   │   ├── cycles.py        # Cycle log JSONL reader
│   │   ├── dprime.py        # D' audit log reader
│   │   ├── narrative.py     # Narrative JSONL reader
│   │   ├── cbr.py           # CBR cases JSONL reader
│   │   ├── facts.py         # Facts JSONL reader
│   │   ├── meta.py          # Meta observer JSONL reader
│   │   ├── scheduler.py     # Scheduler state reader
│   │   └── comms.py         # Comms log reader (future)
│   ├── analysis/
│   │   ├── summary.py       # Aggregate statistics
│   │   ├── dprime.py        # Safety gate analysis
│   │   ├── cbr.py           # CBR quality analysis
│   │   ├── facts.py         # Fact store analysis
│   │   ├── narrative.py     # Narrative/thread analysis
│   │   ├── timeline.py      # Chronological event reconstruction
│   │   ├── meta_states.py   # Epistemic signal analysis
│   │   ├── compliance.py    # Compliance report generation
│   │   └── correlation.py   # Cross-signal correlation (for empirical eval)
│   ├── formatters/
│   │   ├── text.py          # Terminal output
│   │   ├── json.py          # JSON export
│   │   ├── csv.py           # CSV export
│   │   └── html.py          # HTML reports
│   └── utils/
│       ├── dates.py         # Date range handling
│       ├── decay.py         # Confidence decay computation (mirrors dprime/decay.gleam)
│       └── stats.py         # Basic statistics (mean, correlation, bootstrap CI)
└── tests/
    ├── test_readers.py
    ├── test_analysis.py
    └── fixtures/             # Sample JSONL files for testing
```

### Dependencies

```toml
[project]
requires-python = ">=3.10"
dependencies = [
    "click>=8.0",
    "pandas>=2.0",       # Optional — only for export/correlation
]

[project.optional-dependencies]
charts = ["matplotlib>=3.7", "plotly>=5.0"]
all = ["pandas>=2.0", "matplotlib>=3.7", "plotly>=5.0"]
```

Core functionality (summary, cycles, dprime, timeline, compliance) works with just `click`. Pandas is optional for export and correlation analysis. Matplotlib/plotly for chart generation.

### Installation

```sh
pip install sd-audit
# or from the repo:
pip install -e tools/sd-audit/
```

Lives in `tools/sd-audit/` within the Springdrift repo, installable as a standalone Python package.

---

## JSONL Format Compatibility

SD Audit must parse the same JSONL formats that Springdrift writes. Key formats:

| File | Key Fields |
|---|---|
| `cycle-log/YYYY-MM-DD.jsonl` | type, cycle_id, parent_cycle_id, timestamp, model, human_input, tool calls, outcome, tokens, dprime_gates |
| `narrative/YYYY-MM-DD.jsonl` | cycle_id, summary, intent, outcome, entities, keywords, thread_id |
| `cbr/cases.jsonl` | case_id, problem, solution, outcome, category, usage_stats |
| `facts/YYYY-MM-DD-facts.jsonl` | key, value, scope, confidence, operation, provenance |
| `dprime/YYYY-MM-DD-audit.jsonl` | cycle_id, gate, decision, score, features, explanation |
| `meta/YYYY-MM-DD-meta.jsonl` | cycle_id, gate_decisions, tokens_used, type (observation/false_positive) |
| `planner/YYYY-MM-DD-tasks.jsonl` | task_id, title, status, steps, risks |
| `planner/YYYY-MM-DD-endeavours.jsonl` | endeavour_id, title, phases, status |

SD Audit uses lenient parsing — unknown fields are ignored, missing optional fields default to None. This ensures forward compatibility as Springdrift adds new fields.

---

## Relationship to Springdrift

| | Springdrift (Gleam/BEAM) | SD Audit (Python) |
|---|---|---|
| Runs | Live agent, real-time | Offline, batch analysis |
| Reads | JSONL + ETS in-memory | JSONL files only |
| Writes | Append-only JSONL | Never writes to .springdrift/ |
| Audience | Agent (introspection tools) | Human auditor, analyst, regulator |
| Dependencies | Erlang/OTP, LLM providers | Python, click, optional pandas |
| Speed | Real-time per-cycle | Batch over date ranges |

---

## Relationship to Empirical Evaluation

The empirical evaluation plan (`docs/future-plans/empirical-evaluation.md`) describes seven evaluations that need runtime data. SD Audit provides the data extraction layer:

| Evaluation | SD Audit Command |
|---|---|
| 1. Safety gate accuracy | `sd-audit dprime` + `sd-audit export dprime` |
| 2. CBR self-improvement | `sd-audit cbr` + `sd-audit export cbr` |
| 3. Output gate quality | `sd-audit dprime --gate output --show-explanations` |
| 4. Confidence decay impact | `sd-audit facts --stale` + `sd-audit cbr --stale` |
| 5. Deterministic savings | `sd-audit dprime` (deterministic block count vs total) |
| 6. Archivist quality | `sd-audit narrative` (compare entry quality metrics) |
| 7. Meta-state correlation | `sd-audit meta-states` + `sd-audit export cycles` |

The `correlation.py` analysis module computes the statistical metrics (Pearson, Spearman, bootstrap CI, ROC AUC) described in the evaluation plan.

---

## Implementation Estimate

| Component | Effort |
|---|---|
| JSONL readers (8 file types) | Medium |
| CLI framework + config | Small |
| Summary command | Small |
| Cycles command | Small |
| D' analysis | Medium |
| CBR analysis | Medium |
| Timeline reconstruction | Medium |
| Compliance report | Medium |
| Export/formatters | Small |
| Meta-state analysis | Small |
| Correlation/stats | Medium |
| Tests + fixtures | Medium |

Total: ~2000-2500 lines of Python. Straightforward data processing — no ML, no LLM calls, no complex dependencies.
