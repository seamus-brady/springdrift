# How to Use This System

## Research Tasks

Choose tools in this order:

- **brave_answer** — fastest, for self-contained factual questions (requires `BRAVE_API_KEY`)
- **brave_llm_context** — default for most research, machine-optimised context (requires `BRAVE_API_KEY`)
- **brave_web_search** — multiple sources with snippets (requires `BRAVE_API_KEY`)
- **brave_news_search** — time-sensitive and current events (requires `BRAVE_API_KEY`)
- **brave_summarizer** — citations and follow-up threads (requires `BRAVE_API_KEY`)
- **jina_reader** — full markdown extraction from a known URL (requires `JINA_API_KEY`)
- **web_search** — DuckDuckGo fallback when Brave keys unavailable (no key required)
- **fetch_url** — raw HTTP GET with 50KB truncation (no key required)

Before starting a multi-step research task, call `recall_cases` with the relevant
intent and domain. Past cases reveal which tools worked and what pitfalls to avoid.
Cases are organised by category (Strategy, CodePattern, Troubleshooting, Pitfall,
DomainKnowledge) and ranked by historical utility — cases that led to successful
outcomes in the past are ranked higher. Maximum 4 cases are retrieved per query.

## Memory Tasks

- **recall_recent**(period) — orientation at session start (today, yesterday, this_week, etc.)
- **recall_search**(query) — find narrative entries by topic
- **recall_threads** — ongoing lines of investigation
- **recall_cases** — similar past tasks and how they went
- **memory_read** / **memory_write** — explicit key-value facts across sessions
- **memory_query_facts** — search facts by keyword
- **memory_clear_key** — remove a fact (history preserved)
- **memory_trace_fact** — full history of a key including supersessions
- **introspect** — system constitution before complex multi-agent work

For diagnostic questions (what failed, why, patterns over time) use the diagnostic
tools: `reflect`, `inspect_cycle`, `list_recent_cycles`, `query_tool_activity`.

### D' Gate Architecture

The input gate uses a split evaluation path for performance:
1. **Deterministic pre-filter** — regex pattern matches on known-bad inputs. Instant, no LLM cost.
2. **Canary probes** (if enabled) — hijack and leakage detection using embedded tokens. 2 LLM calls. Fail-open: if the probe LLM errors, it passes with a warning (not evidence of hijacking). Consecutive failures are tracked — at 3+ failures, a sensory event alerts that the safety probe LLM may be degraded.
3. **Fast-accept** — if deterministic clean and canaries clean, accept without LLM scoring.
4. **LLM scorer** — only runs if the deterministic layer escalates (suspicious pattern).

The tool gate always runs the full LLM scorer for non-exempt tools (web, file, shell). Memory, planner, builtin, and agent delegation tools are exempt.

The output gate evaluates report quality. Gate timeout (default 60s) prevents blocking forever if the scorer LLM hangs — the report is delivered (fail-open).

### D' Deterministic Pre-Filter

Some blocks happen instantly without any LLM evaluation — these are deterministic pattern matches on known-bad inputs, banned commands, or credential leaks. When a deterministic rule fires, you see a decision like "deterministic block: banned pattern detected" but the specific rule pattern is not disclosed. These blocks are fast (no LLM cost) and non-negotiable.

### D' Rejection Format

When D' blocks something via the LLM scorer, you receive two layers of information:

**In your message history** — a technical notice for pattern learning:
```
[D' <gate> gate: REJECTED (score: <0.0-1.0>). <explanation> Feature triggers: [<feature>=<magnitude>/3, ...]. Content type: <type>. Original text redacted from logs.]
```
- **gate** — `input`, `tool`, or `output`
- **score** — normalized 0.0-1.0
- **Feature triggers** — sorted by severity, each `feature_name=magnitude/3` (0=none, 1=low, 2=medium, 3=high)
- **Content type** — `user query`, `tool dispatch`, or `agent response`

**In the DAG** (via `inspect_cycle`) — structured record: gate, decision, score, explanation.

The user sees a separate human-friendly message with no technical detail.

### D' Safety Feedback

When D' rejects a request you believe was legitimate, use **report_false_positive**(cycle_id, reason) to flag it. This:
- Persists to meta JSONL so it survives restarts
- Excludes the cycle from the repeated rejection detector (prevents false escalation)
- If many rejections are flagged (>=50% in the window), the meta observer escalates to the user suggesting threshold review

Use `inspect_cycle` or `list_recent_cycles` to find the cycle_id of the rejected request.

### Normative Calculus (Output Gate)

When `normative_calculus_enabled = true` in `[dprime]` config, the output gate applies
virtue-based evaluation after D' scoring. This adds principled reasoning to gate
decisions — instead of just "score > threshold", you get named axiom trails explaining
*why* a decision was made.

**How it works:**
1. The D' scorer evaluates the response as normal (LLM-scored features → magnitudes)
2. The normative bridge converts those magnitudes into normative propositions
3. The calculus resolves each proposition against the character spec's highest endeavour
4. Floor rules produce a verdict: **Flourishing** (accept), **Constrained** (modify),
   or **Prohibited** (reject)
5. The axiom trail appears in the gate explanation and cycle log

**Character spec** — loaded from `identity/character.json`. Contains virtues (named
behavioural expressions) and highest endeavour (normative propositions the agent
commits to). The operator controls how strict the calculus is by choosing `required`
(categorical) vs `ought` (advisory) operators on each proposition.

**Short reply bypass** — responses under 300 characters skip the LLM scorer entirely.
Deterministic rules still run. This prevents conversational replies from being
evaluated against research report quality standards.

**Virtue drift detection** — the system tracks normative verdicts over time. If it
detects high constraint/prohibition rates, repeated axiom firing, or over-restriction
patterns, it escalates to the operator via the meta observer. Drift signals also
appear in the sensorium `<events>` section. The system never auto-adjusts thresholds
for drift — only the operator can tune the character spec or D' config.

**MODIFY behaviour** — when the output gate constrains a response, the agent is
instructed to fix only the specific flagged issues while preserving all other content.
It will not strip out unflagged content or add unnecessary hedging.

## Code Tasks

1. Call `recall_cases(intent: "code")` for relevant past patterns
2. Use `agent_coder` for the actual work
3. If sandbox is enabled, coder has `run_code` (execute scripts) and `serve` (start servers)
4. If sandbox is unavailable, coder uses `request_human_input` to ask the user to run code
5. Coder also has `sandbox_exec` (shell commands like git/pip), `workspace_ls` (list files), and `sandbox_status` (check slots)

## Multi-Agent Tasks

1. Check the sensorium `<vitals agent_health="...">` before dispatching — if an agent
   is degraded, do not delegate to it blindly
2. Prefer sequential agent calls when tasks have dependencies
3. Use `store_result` / `retrieve_result` for large outputs — do not pass full
   research results as context strings between agents
4. Use `agent_planner` before complex multi-step work
5. When an agent result contains `[WARNING: agent X had tool failures]`, treat the
   result with suspicion — the agent continued despite tool errors

## Delegation Management

The sensorium shows a `<delegations>` section with live agent status when agents are executing. Each entry shows agent name, current turn, token usage, elapsed time, and last tool called.

### When to cancel an agent
- Agent is past 80% of its max turns with no useful progress
- Token usage exceeds what the task warrants (e.g. >200K tokens for a simple lookup)
- The agent is calling the same tool repeatedly (loop detection)
- The user has changed their mind or the task is no longer needed

Use **cancel_agent**(agent_name) to stop a running agent. Cancelled agents with Permanent restart strategy will be restarted by the supervisor, but the current task is abandoned.

### Depth limit
Delegation depth is capped at the configured maximum (default: 3). This prevents runaway agent chains.

### Verifying agent results
When a sub-agent returns, check before acting on the result:

1. **Warnings** — does the result contain `[WARNING: agent X had tool failures]`? If so, the agent continued despite errors. Treat the result with suspicion.
2. **Evidence vs claims** — did the agent claim an outcome ("deployed", "tested", "verified") but no tool call actually confirmed it? Look at the tools_used list.
3. **Turn exhaustion** — did the agent hit its max_turns limit? That means it didn't finish cleanly. The result is partial.
4. **Missing tools** — did the agent have the right tools for the job? Check `introspect` if unsure. A coder without sandbox tools will try workarounds instead of telling you.
5. **Environment assumptions** — did the agent assume something about its environment (packages installed, ports available, file paths) without checking? First-time tasks in new environments need tight directives.

When verification fails, use `recall_cases` to check if this is a known pattern. If not, the Archivist will capture it automatically. Use `correct_case` or `annotate_case` to improve low-quality cases.

### Delegation style
- **First time** with a new task type or environment: be specific. Name the tools, the approach, the expected output format.
- **Repeated tasks** where CBR shows prior success: give more latitude.
- **After a failure**: tighten up. Review what went wrong, adjust the instruction, try again.

## Agents

- **agent_researcher** — web research and fact gathering (web + artifact + builtin tools)
- **agent_planner** — task decomposition and dependency mapping (no tools, max 3 turns)
- **agent_coder** — code writing, debugging, refactoring (builtin tools, max 10 turns)
- **agent_writer** — long-form writing and structured reports (builtin tools, max 6 turns)
- **agent_observer** — diagnostic memory examination (diagnostic memory tools, max 6 turns)

### Agent error surfacing

Agent results include tool failure information at two levels:

- **Reactive (in result)** — if an agent's tools failed but the agent LLM chose to
  continue, the result is prefixed with `[WARNING: agent X had tool failures: ...]`.
  This means the result may be fabricated. Do not trust it without verification.
- **Proactive (in sensorium)** — agent health is updated in the sensorium's `<vitals>`
  element when tools fail or agents crash/restart. Check `agent_health` before
  delegating to an agent that previously had issues.

When you see a tool failure warning:
1. Report the failure to the user — do not silently retry
2. Explain what failed and why the result may be unreliable
3. Do not re-delegate to the same agent unless the underlying issue is resolved

## Sensorium

The sensorium is an XML block injected at every cycle start. You perceive it
passively — no tool calls needed. It answers: what time is it, how long was I
away, who woke me, what's happening, is anything waiting, and is anything wrong?

### Sections

- **`<clock>`** — `now`, `session_uptime`, optional `last_cycle` elapsed time
- **`<situation>`** — `input` source (user/scheduler), `queue_depth`, `conversation_depth`
  (message count), optional `thread` (most recent active thread name)
- **`<schedule>`** — `pending`/`overdue` counts with per-`<job>` detail (omitted when empty)
- **`<vitals>`** — `cycles_today`, `agents_active`, conditional `agent_health` (only when
  non-nominal), conditional `last_failure` (from narrative), optional `cycles_remaining`
  and `tokens_remaining` (scheduler budget)

### Using the sensorium

- A large `conversation_depth` means you're mid-conversation — maintain continuity
- A `last_cycle` gap of hours means context may be stale — consider `recall_recent`
- `agent_health` non-empty means an agent is degraded — do not delegate to it blindly
- `last_failure` tells you what went wrong recently — adjust your approach
- Low `cycles_remaining` or `tokens_remaining` means pace yourself

## Scheduler

The scheduler runs recurring tasks autonomously. Jobs fire on their configured
schedule and run through the cognitive loop as `SchedulerInput` messages (not
interactive `UserInput`), using `task_model` without complexity classification.

### Scheduler agent tools

- **schedule_from_spec** — preferred: create a job from explicit structured parameters
  (kind, title, body, due_at, for_, interval_ms, max_occurrences, tags). Returns
  structured confirmation with fire time preview. No NL ambiguity.
- **schedule_reminder** — create a reminder from individual params (NL-friendly)
- **add_todo** — task with optional due date
- **add_appointment** — calendar-style event with start time
- **inspect_job** — view full job details (status, fired/max, interval, errors, tags)
- **complete_item** / **cancel_item** — mark a job done or cancelled
- **update_item** — modify an existing job's schedule or description
- **list_schedule** — view all scheduled jobs with status and recurrence info

### Job kinds

- `Reminder` — fires a notification at the scheduled time
- `Todo` — task item, optionally recurring
- `Appointment` — time-bound event
- `ScheduledQuery` — profile-defined research query with delivery config

### ForAgent vs ForUser

Each job has a `for_target` field:
- **ForAgent** — the agent processes the result autonomously (e.g. scheduled research)
- **ForUser** — the result is delivered to the user (e.g. reminders, reports)

### Resource limits

Autonomous scheduler cycles are rate-limited to prevent runaway token spend:

- `max_autonomous_cycles_per_hour` (default: 20) — max scheduler-triggered cognitive
  cycles per rolling hour. Set to 0 for unlimited.
- `autonomous_token_budget_per_hour` (default: 500000) — max total tokens (input +
  output) the scheduler may consume per rolling hour. Set to 0 for unlimited.

Configure in `[scheduler]` section of `config.toml`.

### Web admin tabs

When using `gui = "web"`, the admin page has four tabs:

- **Narrative** — recent narrative entries
- **Log** — system log stream
- **Scheduler** — job list with status, kind, next-run time, and for-target
- **Cycles** — scheduler-triggered cycle history with token usage and agent output

## Planning

Tasks and Endeavours let you track your own work as it progresses.

### Tasks

A Task is your current unit of work. When the Planner produces a plan, a Task is
created automatically with numbered steps, dependencies, risks, and a forecast health
score. Most work is Tasks. A Task can exist alone — not everything needs an Endeavour.

### Endeavours

An Endeavour is your own initiative — create one when you have a larger goal that
needs multiple independent Tasks. If the Planner produces one plan with sequential
steps, that is just a Task, not an Endeavour.

### When NOT to create an Endeavour

If the Planner produces a single plan with sequential steps, that is just a Task.
Only create an Endeavour when you have genuinely independent tasks that serve a
shared goal.

### Planner tools

- **complete_task_step** — mark a step as done
- **flag_risk** — record a materialised risk on a task
- **activate_task** — move a task from Pending to Active
- **abandon_task** — abandon a task that is no longer viable
- **create_endeavour** — start a new multi-task initiative
- **add_task_to_endeavour** — associate a task with an endeavour
- **get_active_work** — list all active tasks and open endeavours
- **get_task_detail** — full detail on a specific task (steps, risks, forecast)
- **request_forecast_review** — ask the Forecaster to re-evaluate a task now

### Lifecycle

Tasks follow the lifecycle: **Pending → Active → Complete / Failed / Abandoned**.
When the Planner creates a task it starts as Pending. Use `activate_task` to begin
work. Steps are completed individually via `complete_task_step`. When all steps are
done, the task is marked Complete.

### Forecaster

The Forecaster periodically evaluates active tasks using D' scoring across five
dimensions: step completion rate, dependency health, complexity drift, risk
materialisation, and scope creep. If a task's health deteriorates past the replan
threshold, the Forecaster sends a replan suggestion to the cognitive loop, which
dispatches the Planner to produce a revised plan. Use `request_forecast_review` to
check task health on demand.

### Sensorium integration

Active tasks and forecaster events appear in the `<tasks>` and `<events>` sections
of the sensorium. No tool calls are needed to see current work — it is part of your
ambient perception at every cycle.

## Degradation Paths

When a required API key is missing, fall back gracefully:

- **Brave tools unavailable** (no `BRAVE_API_KEY`) → use `web_search` (DuckDuckGo, no key required)
- **jina_reader unavailable** (no `JINA_API_KEY`) → use `fetch_url` as fallback
- **Sandbox unavailable** (no podman) → coder uses `request_human_input` to ask user to run code

## What to Avoid

- Do not call `introspect` before every task — use it before complex multi-agent work
  or after failures, not routinely
- Do not pass large tool results as agent context — use `store_result`
- Do not call `how_to` in a loop or recursively
- Prefer `brave_answer` or `brave_llm_context` over `brave_web_search` for simple
  factual questions — they are faster and cheaper
- Do not use `fetch_url` for discovery — it requires a known URL. Use a search tool first.
