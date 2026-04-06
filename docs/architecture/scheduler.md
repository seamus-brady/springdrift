# Scheduler Architecture

The scheduler enables Springdrift to run autonomously -- executing recurring tasks,
firing reminders, and delivering reports without user interaction. It is a BEAM-native
OTP actor using `process.send_after` for timer management.

---

## 1. Overview

The scheduler (`src/scheduler/runner.gleam`) is a long-lived OTP process that manages
a pool of scheduled jobs. When a job's timer fires, the scheduler sends the job's
query to the cognitive loop as a `SchedulerInput` message (not `UserInput`), waits
for the result, and delivers it via the configured delivery channel.

```
Timer (send_after)  →  Tick(name)  →  Runner  →  SchedulerInput  →  Cognitive Loop
                                                                          │
         Delivered  ←  delivery.deliver  ←  Runner  ←  JobComplete  ←────┘
```

## 2. Job Types

`JobKind` defines four types of scheduled item:

| Kind | Timer | Fires | Purpose |
|---|---|---|---|
| `RecurringTask` | Interval-based | Query to cognitive loop | Research, monitoring, reporting |
| `Reminder` | Due-at based | Body text as notification | Time-sensitive alerts |
| `Appointment` | Due-at based | Body text with duration | Calendar-style events |
| `Todo` | None | Manual completion only | Tracked items without timers |

## 3. Job Sources

| Source | How created | Persistence |
|---|---|---|
| `ProfileJob` | Loaded from `schedule.toml` at startup | Overlaid on JSONL state |
| `AgentJob` | Created at runtime via scheduler agent tools | Persisted to JSONL |

## 4. ScheduledJob State

Defined in `src/scheduler/types.gleam`:

```gleam
pub type ScheduledJob {
  ScheduledJob(
    name: String,             // Unique identifier
    query: String,            // Prompt sent to cognitive loop
    interval_ms: Int,         // Recurrence interval (0 = one-shot)
    delivery: DeliveryConfig, // Where to deliver results
    only_if_changed: Bool,    // Skip delivery if result matches last
    status: JobStatus,        // Pending | Running | Completed | Cancelled | Failed
    last_run_ms: Option(Int), // Monotonic timestamp of last execution
    last_result: Option(String),
    run_count: Int,
    error_count: Int,
    job_source: JobSource,
    kind: JobKind,
    due_at: Option(String),   // ISO timestamp for reminder/appointment
    for_: ForTarget,          // ForAgent (cognitive loop) or ForUser (notification)
    title: String,
    body: String,
    tags: List(String),
    fired_count: Int,
    recurrence_end_at: Option(String),
    max_occurrences: Option(Int),
  )
}
```

### Status Transitions

```
Pending ──Tick──→ Running ──JobComplete──→ Pending (recurring) or Completed (one-shot)
                     │
                     └──JobFailed──→ Failed (after max retries)

Pending/Running ──RemoveJob/CompleteJob──→ Cancelled/Completed
```

## 5. Delivery Channels

`DeliveryConfig` in `src/scheduler/types.gleam`:

| Channel | Config | Behaviour |
|---|---|---|
| `FileDelivery` | `directory`, `format` | Writes result to timestamped file in `directory` |
| `WebhookDelivery` | `url`, `method`, `headers` | HTTP POST/PUT to external endpoint |

Delivery is handled by `scheduler/delivery.gleam`. `only_if_changed` compares the
result text with `last_result` -- if identical, delivery is skipped (useful for
monitoring jobs that only need to report changes).

## 6. Resource Limits

Autonomous execution is bounded by two rolling-hour guards:

| Guard | Config field | Default | Effect when hit |
|---|---|---|---|
| Cycle budget | `max_autonomous_cycles_per_hour` | 20 | Jobs skipped until window rolls |
| Token budget | `autonomous_token_budget_per_hour` | 500000 | Jobs skipped until window rolls |

The runner tracks cycle counts and token consumption per rolling hour window.
`GetBudgetRemaining` returns a `BudgetStatus` with current usage and limits.
Set either to 0 for unlimited.

The Curator's sensorium displays remaining budget in `<vitals>` when limits are
configured, so the agent can see its resource constraints.

## 7. Persistence

`scheduler/persist.gleam` provides atomic checkpoint persistence via JSONL operation
log. Operations:

| Op | Purpose |
|---|---|
| `Create` | New job added |
| `Fire` | Job timer fired |
| `Complete` | Job finished or manually completed |
| `Cancel` | Job removed |
| `Update` | Job metadata changed |

`resolve_current(schedule_dir)` replays the operation log to derive current job state.
On startup, the runner loads persisted state and overlays config tasks (updating
query/interval/delivery if config changed while preserving run history).

## 8. Timer Management

Timers use `process.send_after(self, delay_ms, Tick(name))`. For recurring tasks,
after each `JobComplete` the runner re-arms the timer with the job's `interval_ms`.

For reminders and appointments, the delay is calculated as milliseconds until
`due_at`. Recurring reminders check `max_occurrences` and `recurrence_end_at`
before rescheduling.

### Stuck Job Detection

`StuckJobCheck(name)` fires via `send_after` at `scheduler_job_timeout_ms` after
a job starts running. If the job is still Running when the check fires, it's marked
as failed.

## 9. Scheduler Messages

The scheduler's API is the `SchedulerMessage` type:

| Message | Purpose |
|---|---|
| `Tick(name)` | Timer fired for a job |
| `JobComplete(name, result, tokens_used)` | Cognitive loop finished |
| `JobFailed(name, reason)` | Execution failed |
| `StopAll` | Shutdown all timers |
| `GetStatus(reply_to)` | Get all job states |
| `AddJob(job, reply_to)` | Create a new agent job |
| `RemoveJob(name, reply_to)` | Cancel and remove a job |
| `UpdateJob(name, updates, reply_to)` | Modify job metadata |
| `GetJobs(query, reply_to)` | Query jobs by kind/status/target |
| `CompleteJob(name, reply_to)` | Mark a todo/reminder complete |
| `GetBudgetRemaining(reply_to)` | Check remaining hour budget |
| `PurgeCancelled(reply_to)` | Clean up finished one-shot jobs |
| `StuckJobCheck(name)` | Timeout check for running jobs |

## 10. Scheduler-Triggered Cycles

When the scheduler fires a cognitive loop query, it uses `SchedulerInput` (not
`UserInput`). Key differences:

- **No query classification** -- always uses `task_model`
- **Scheduler context** -- `<scheduler_context>` XML prepended with job name, kind,
  for-target, title, body, and tags
- **DAG node type** -- tagged as `SchedulerCycle` (vs `CognitiveCycle`)
- **Token reporting** -- `JobComplete` includes `tokens_used` for budget tracking

## 11. Notifications

The scheduler emits lifecycle notifications consumed by TUI and web GUI:

| Notification | When |
|---|---|
| `SchedulerJobStarted(name)` | Job begins execution |
| `SchedulerJobCompleted(name)` | Job finished successfully |
| `SchedulerJobFailed(name, reason)` | Job failed |
| `SchedulerReminder(name, body)` | Reminder/appointment fires for user |

## 12. Key Source Files

| File | Purpose |
|---|---|
| `scheduler/types.gleam` | `ScheduledJob`, `SchedulerMessage`, `DeliveryConfig`, `JobKind`, `JobSource` |
| `scheduler/runner.gleam` | OTP actor: timer management, job execution, budget enforcement |
| `scheduler/delivery.gleam` | File and webhook delivery implementations |
| `scheduler/log.gleam` | JSONL operation log and state resolution |
| `scheduler/persist.gleam` | Atomic checkpoint persistence |
