---
name: task-appraisal
description: How pre-mortems and post-mortems work, what verdicts mean, and how to act on appraisal results.
agents: cognitive
---

## What Are Pre-Mortems and Post-Mortems?

The system automatically appraises your tasks at two points:

**Pre-mortem** — fires when you activate a task (if it's complex enough).
Imagines the task has failed and identifies: predicted failure modes, blind
spot assumptions, dependencies at risk, and information gaps. This is stored
on the task and feeds the Forecaster's health evaluation.

**Post-mortem** — fires when a task completes, fails, or is abandoned.
Evaluates whether the goal was achieved, compares pre-mortem predictions
against reality, extracts lessons learned, and creates a CBR case from the
outcome. A sensory event reports the verdict.

Neither blocks you. Both run as fire-and-forget processes after the lifecycle
transition. If they fail (LLM error, timeout), the task proceeds normally.

## When They Fire

| Transition | What fires | Condition |
|---|---|---|
| Task activated | Pre-mortem | Complexity >= medium, OR 3+ steps, OR part of an endeavour |
| Task completed | Post-mortem | Always. Simple tasks get deterministic "Achieved". Medium+ gets full LLM evaluation |
| Task failed | Post-mortem | Always full LLM, regardless of complexity |
| Task abandoned | Post-mortem | Always full LLM — abandonment has the most to teach |
| Endeavour completed | Endeavour post-mortem | Synthesises across all task post-mortems |

Simple 1-2 step standalone tasks skip the pre-mortem entirely and get a
lightweight deterministic post-mortem. This is by design — the cost of an
LLM call isn't justified for trivial work.

## Verdicts

Post-mortems produce an `AppraisalVerdict`:

| Verdict | Meaning | What to do |
|---|---|---|
| **Achieved** | Goal fully met | Nothing — the system created a Strategy CBR case |
| **PartiallyAchieved** | Goal partly met, gaps remain | Consider a follow-up task for the gaps. Check lessons learned |
| **NotAchieved** | Goal not met | Review contributing factors. Check if the approach was wrong or the goal was unrealistic. A Pitfall CBR case was created |
| **AbandonedWithLearnings** | Stopped early, but something was learned | The learning is the value. Check lessons — they feed future planning |

## Reading the Sensory Event

When a post-mortem completes, you'll see a sensory event like:

```
<event name="post_mortem" title="Research pricing — partially_achieved">
  Task task-abc123 post-mortem: partially_achieved. Key lesson: Two of three
  competitor sites required authentication.
</event>
```

This is your cue to decide:
1. **Achieved** — no action needed, move on
2. **PartiallyAchieved** — decide if the gaps matter. If yes, create a
   follow-up task. If not, accept the result
3. **NotAchieved** — investigate. Use `get_task_detail` to see the full
   post-mortem. Consider a different approach if retrying
4. **AbandonedWithLearnings** — the learning has been captured in CBR.
   Future similar tasks will benefit from this case

## How Pre-Mortems Help Planning

When you're about to start a complex task, the pre-mortem predictions are
stored on the task. The Forecaster uses them as a baseline — if a predicted
risk materialises, the health score reflects it. You can view predictions
with `get_task_detail`.

When planning similar future tasks, `recall_cases` will surface Pitfall
cases from past post-mortems. Read the lessons before committing to an
approach.

## Configuration

Controlled by `[appraisal]` in config.toml:
- `min_complexity` — minimum task complexity for pre-mortem (default: "medium")
- `min_steps` — minimum steps for pre-mortem (default: 3)
- `model` — LLM model for appraisals (defaults to task_model)
- `max_tokens` — max tokens per appraisal call (default: 4096)
