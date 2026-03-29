# D' Safety System Overhaul — Implementation Record

**Status**: Implemented
**Date**: 2026-03-22 to 2026-03-25
**Source**: dprime-complete-spec, Curragh shakedown testing, operator feedback

---

## Table of Contents

- [Overview](#overview)
- [Bug Fixes](#bug-fixes)
- [New Capabilities](#new-capabilities)
  - [Deterministic Pre-Filter](#deterministic-pre-filter)
  - [Unified Config Format](#unified-config-format)
  - [Meta Observer (Layer 3b)](#meta-observer-layer-3b)
  - [False Positive Reporting](#false-positive-reporting)
  - [Per-Agent Violation Tracking](#per-agent-violation-tracking)
  - [Escalation Criteria](#escalation-criteria)
  - [D' Rejection Format (Agent-Facing)](#d-rejection-format-agent-facing)
- [Configuration](#configuration)
  - [Input Gate Thresholds](#input-gate-thresholds)
  - [Output Gate Thresholds](#output-gate-thresholds)
  - [Deterministic Rules](#deterministic-rules)


## Overview

Comprehensive overhaul of the D' discrepancy-gated safety system, fixing 14 documented bugs and adding new capabilities. The system went from "blocks good morning" to making substantive quality judgments.

## Bug Fixes

| Bug | Issue | Fix |
|---|---|---|
| BF-01 | Shared dprime_state between gates | Split into input_dprime_state + tool_dprime_state |
| BF-03 | D' scores unbounded (could exceed 1.0) | Normalized via max_possible_score |
| BF-10 | Infinite MODIFY loop | Check meta.should_intervene before re-evaluation |
| Iteration counter | Accept decisions incremented iteration_count | Only increment on Modify/Reject |
| Iteration reset | reset_iterations() never called | Reset at cycle start in both user and scheduler handlers |
| Tool gate false positives | Internal tools (memory, planner) gated by D' | Added is_dprime_exempt() — memory, planner, builtin, agent delegations exempt |
| UUID redaction | Task UUIDs redacted as API keys | Added \b word boundary to sk- regex, tightened JSON field patterns |
| Output gate scoring | Asked LLM for JSON but parsed as XML | Switched to scorer.score_features (XStructor) |
| Rejection opacity | User and agent saw same generic message | Two-layer: human-friendly for user, technical for agent |
| Non-delivery | Agent didn't know output gate blocked its response | Added [SYSTEM: Your response was NOT delivered] to agent history |
| Scorer fallback | Cautious fallback scored critical=2, non-critical=1 | Kept as designed (fail-closed is correct for safety) |
| Config parse | dprime.json agent_overrides format mismatch | Decoder handles both dict (current) and list (legacy) formats |

## New Capabilities

### Deterministic Pre-Filter
- Regex-based rules that run BEFORE any LLM call
- Block known-bad patterns instantly (rm -rf, DROP TABLE, credential strings)
- Escalate ambiguous patterns (force push) with enriched context for LLM scorer
- Agent sees decisions ("banned pattern detected") but NOT rule patterns
- Configured in dprime.json `deterministic` section

### Unified Config Format
Five top-level keys in dprime.json: `gates`, `agent_overrides`, `meta`, `shared`, `deterministic`

### Meta Observer (Layer 3b)
- Post-cycle pattern detection across gate decisions
- Detectors: rate limit, cumulative risk, repeated rejections, Layer 3a persistence, high false positive rate
- Interventions: InjectCaution, TightenAllGates, ForceCooldown, EscalateToUser
- JSONL persistence with configurable decay

### False Positive Reporting
- `report_false_positive(cycle_id, reason)` tool
- Annotations persist to meta JSONL
- Repeated rejection detector excludes annotated cycles
- High false positive rate triggers threshold review escalation

### Per-Agent Violation Tracking
- `violation_count` on DelegationInfo
- Increments on block/reject during agent tool calls
- Visible in sensorium delegations section

### Escalation Criteria
- Mid-cycle model upgrade on tool failures or elevated D' scores
- Configurable thresholds in `[escalation]` config section
- ModelEscalation notification in web GUI

### D' Rejection Format (Agent-Facing)
```
[D' <gate> gate: REJECTED (score: <0.0-1.0>). <explanation> Feature triggers: [<feature>=<magnitude>/3, ...]. Content type: <type>.]
```

## Configuration

### Input Gate Thresholds
- modify: 0.45, reject: 0.75
- prompt_injection: high importance, NOT critical (deliberative layer handles it)
- Descriptions include operator meta-discussion as normal

### Output Gate Thresholds
- modify: 0.40, reject: 0.75 (raised from 0.60 to prefer MODIFY over REJECT)

### Deterministic Rules
- 3 input rules (injection patterns)
- 6 tool rules (banned commands)
- 4 output rules (credential patterns)
- Configurable path and domain allowlists
