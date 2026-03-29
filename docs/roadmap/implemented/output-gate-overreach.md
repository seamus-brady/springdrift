# Output Gate Overreach — Bug Report & Analysis

## Resolution

**The output gate LLM scorer now only runs on autonomous (scheduler-triggered) cycles.**
Interactive sessions use deterministic rules only — the operator is the quality gate.
This eliminates the false-positive-driven self-censoring loop entirely for interactive
use. The full LLM scorer + normative calculus still protects autonomous delivery where
no operator is watching.

## Problem (historical)

The output gate frequently triggers MODIFY on legitimate agent responses,
causing the agent to replace its substantive output with a timid
"I need to revise my response — it may contain inaccurate information."
The user sees the revision (which is content-free), not the original
(which was useful).

## Observed Pattern

```
User asks question
  → Agent generates substantive response (often after agent delegation)
  → Output gate MODIFY fires (LLM scorer flags "unsourced claims" etc.)
  → MODIFY injection: "[SYSTEM: fix only the flagged issues...]"
  → Agent produces timid revision: "I need to revise my response..."
  → Output gate ACCEPT at 0.00 (the revision is too empty to flag)
  → User sees only the timid revision
  → TUI/web shows "D' ACCEPT (score: 0.00)" — misleading, that's pass 2
```

The user never sees that a MODIFY happened. They just see a useless response
and a confusing 0.00 ACCEPT score.

## Root Causes

### 1. Research report standards applied to all output

The output gate features (`unsourced_claim`, `accuracy`, `certainty_overstatement`)
are calibrated for research reports. But most agent responses are:
- Conversational replies
- Self-diagnostic reports (observer agent output)
- Task status updates
- Planning summaries

These contain first-person observations ("I see three cycles with 0 tokens"),
which the scorer interprets as "unsourced factual claims."

### 2. Haiku ignores the MODIFY instruction

The MODIFY prompt says "Fix ONLY the flagged issues. Preserve all other content."
Haiku interprets this as "acknowledge the problem" and produces a one-liner
instead of surgically editing the response. This is a model capability issue —
haiku is too small to follow complex revision instructions reliably.

### 3. The 300-char threshold doesn't catch post-delegation responses

Agent delegation responses (observer, researcher, planner) are typically
500-2000 chars. These go through the full output gate. The 300-char threshold
only helps with short conversational replies.

### 4. The user can't see what happened

The TUI/web only shows the final gate result (ACCEPT 0.00). The first-pass
MODIFY is invisible. The user has no way to know their response was gutted.

### 5. Session poisoning (now fixed)

Gate injection messages persisted to session.json, so resumed sessions
contained MODIFY/REJECT notices that taught the agent to self-censor.
**Fixed:** `filter_gate_injections` now strips these before saving.

### 6. Verbose rejection notices (now fixed)

REJECT notices were 500+ words of feature-by-feature analysis injected into
the agent's context window. This ate tokens and reinforced self-censoring.
**Fixed:** notices are now terse — just decision, score, and feature triggers.

## Fixes Already Applied

| Fix | Status | Effect |
|---|---|---|
| Interactive/autonomous split | Done | Interactive: deterministic only. Autonomous: full scorer. |
| Improved MODIFY prompt | Done | Tells agent to fix only flagged issues (autonomous only) |
| Session filter for gate injections | Done | Gate messages don't persist to session.json |
| Terse rejection notices | Done | Agent sees 1 line, not 500 words |
| Normative calculus with toned-down NPs | Done | Adds axiom reasoning, `ought` not `required` |

## Remaining Issues

### Issue A: Output gate fires on self-diagnostic output

The observer agent reports what it found in the system logs and memory.
These are first-person observations, not research claims. The scorer
flags them as "unsourced."

**Proposed fix:** Add output gate exemption for agent-delegated responses
by type. Observer and planner output should skip the output gate (or use
a different feature set). Research and writer output should use the full
quality check.

### Issue B: Haiku can't do surgical MODIFY

Even with the improved prompt, haiku rewrites the entire response as a
timid acknowledgment instead of editing the specific flagged issue.

**Proposed fixes (pick one):**
- **Use reasoning model for MODIFY revisions** — the MODIFY regen should
  use the reasoning model, not the task model. Opus/Sonnet can follow
  "fix this specific issue" instructions.
- **Include the original response in the MODIFY prompt** — currently the
  agent revises from memory. Injecting the original text as a reference
  would help smaller models do targeted edits.
- **Limit MODIFY to 1 attempt, then deliver with warning** — if the first
  revision attempt produces a shorter response than the original, deliver
  the original with a quality warning appended.

### Issue C: User can't see MODIFY happened

The web UI shows "D' ACCEPT (score: 0.00)" for the revision pass. The user
has no signal that their response was modified.

**Proposed fix:** Show both gate passes in the UI. If the response went
through MODIFY, show "D' MODIFY (0.62) → ACCEPT (0.00)" or similar. The
notification should distinguish first-pass and revision-pass results.

### Issue D: Output gate feature calibration

`unsourced_claim` at HIGH importance with `modify_threshold: 0.40` is too
aggressive for a general-purpose agent. A single magnitude-2 on unsourced_claim
pushes past the threshold.

**Proposed fixes:**
- Lower `unsourced_claim` importance to MEDIUM
- Raise output `modify_threshold` to 0.55
- Add a `self_observation` feature at LOW importance for first-person
  diagnostic claims (distinct from third-party factual claims)

## Recommended Priority

1. **Issue B** — most impactful. Use reasoning model for MODIFY revisions, or
   deliver-with-warning when revision is shorter than original.
2. **Issue A** — skip output gate for observer/planner agent output.
3. **Issue D** — tune feature importance and thresholds.
4. **Issue C** — UI transparency for MODIFY events.
