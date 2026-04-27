# Springdrift Operators Manual

A practical guide for running a Springdrift agent in anger. The
[architecture docs](architecture/) explain *how* each subsystem works;
this manual covers *what to do* — the daily rhythm, the diagnostic
recipes, the recovery procedures, and how to deploy the thing.

If you've never touched Springdrift before, read the [README](../README.md)
first. This manual assumes you already have an agent running locally
or on a VPS.

## Table of contents

1. [What Springdrift is](#1-what-springdrift-is)
2. [Daily and weekly rhythm](#2-daily-and-weekly-rhythm)
3. [Web UI tour](#3-web-ui-tour)
4. [Working with the agents](#4-working-with-the-agents)
5. [Diagnostic recipes](#5-diagnostic-recipes)
6. [Recovery procedures](#6-recovery-procedures)
7. [Auditing](#7-auditing)
8. [Config — the knobs you actually reach for](#8-config--the-knobs-you-actually-reach-for)
9. [VPS setup and deployment](#9-vps-setup-and-deployment)
10. [Extending with Claude Code](#10-extending-with-claude-code)

---

## 1. What Springdrift is

Springdrift is a **knowledge-worker agent framework** — a long-running
process that thinks on a schedule, remembers what it saw last time,
and produces structured output. It is written in Gleam and runs on
the Erlang/OTP runtime.

Concretely, an instance can:

- **Hold a conversation** through a terminal UI or a browser
- **Run scheduled research** on its own (daily, weekly, or one-off
  reminders) and deliver reports to file or webhook
- **Send and receive email** through the comms agent
- **Delegate to specialist agents** — a planner, a project manager,
  a researcher, a coder (with Podman sandbox), a writer, an observer,
  a comms agent, and a remembrancer
- **Remember everything** in nine append-only memory stores —
  narrative, threads, facts, CBR cases, artifacts, tasks,
  endeavours, comms, consolidation runs
- **Evaluate its own outputs** through a D' safety gate with optional
  Stoic normative calculus
- **Improve over time** — propose new skills from CBR clusters, track
  affect-vs-outcome correlations, manage a Strategy Registry of
  named approaches

It is **not** a chatbot, an IDE assistant, or a one-shot CLI tool.
The point is the persistence: the same agent running for weeks or
months, accumulating memory, refining its own playbook.

### When you'd run an instance

- You want a research assistant that wakes up at 8am and pings you
  with a market summary at 9
- You want an email autoresponder that triages inbound mail according
  to rules you can audit
- You want a long-horizon planner that can hold a multi-week project
  in memory and resume work after restarts
- You're researching agent architectures and want a substrate to
  experiment on

For a quick tour of the architecture, see
[architecture/cognitive-loop.md](architecture/cognitive-loop.md). For
the full feature list, see [`CLAUDE.md`](../CLAUDE.md).

---

## 2. Daily and weekly rhythm

The agent runs continuously. You don't need to babysit it, but a
short check each morning catches problems before they decay into
long silences.

### Morning skim (2 minutes)

1. **Web admin** (`/admin`) → **Narrative tab.** Read the previous
   day's last 3–5 entries. Look for `outcome=failure` or `partial`.
2. **Scheduler tab.** Any job with `Last Result: error` or sitting
   `Pending` past its due time deserves a click.
3. **Cycles tab.** Token usage trend. Spikes are usually one of:
   a runaway agent (look at `agents_active`), a verbose research
   query, or the model picker escalating to the reasoning model.

### Weekly review (15 minutes)

1. **Comms tab.** Skim the week's inbox/outbox. Anything the agent
   sent that you wouldn't have? That's a feedback loop signal —
   tighten the comms agent's D' overrides or revise the email skill.
2. **Skills tab.** Look at recently proposed skills. Promoted ones
   live under `.springdrift/skills/`; archived ones stay in the
   lifecycle log.
3. **Affect tab.** Are any dimensions stuck high or trending the
   wrong way? See [Diagnostic recipes](#5-diagnostic-recipes).
4. **Trigger consolidation** by asking the agent to delegate to the
   Remembrancer (only when `remembrancer_enabled = true`):
   > "Please run a memory consolidation for the past week."
   The report lands in `.springdrift/knowledge/consolidation/`.

### What "normal" looks like

- Cycles per day in the low double digits (10–40 for a chatty
  instance; 1–5 for a quiet one)
- Daily token usage well under `autonomous_token_budget_per_hour × 24`
- D' rejection rate under 5%; if it climbs above 20%, thresholds are
  too tight or the agent's outputs are genuinely degrading
- Forecaster scores varying per task (if every task scores
  identically, the heuristic is broken — see recipe in section 5)
- Narrative entries with non-empty `summary`, `intent`, and `outcome`
  fields

---

## 3. Web UI tour

Default port: **12001**. Set `SPRINGDRIFT_WEB_TOKEN` in the
environment to require auth on every request (highly recommended for
anything not on `localhost`).

Three pages:

- `/chat` — the conversational UI. Two tabs: **Chat** and
  **Activity** (live tool-use feed). Designed for desktop.
- `/m` — mobile-first chat. Strip-down of `/chat` for phone screens:
  full-width messages, big tap targets, no sidebar, no admin tabs,
  no activity feed. Same WebSocket protocol, same conversation
  history. Use this from your phone instead of `/chat`.
- `/admin` — 11 read-only tabs for inspecting agent state. Below

Authenticate by appending `?token=YOUR_TOKEN` to the URL or sending
`Authorization: Bearer YOUR_TOKEN`.

### Admin tabs

| Tab | What it shows | When to look |
|---|---|---|
| **Narrative** | Daily timeline of cycle summaries — intent, outcome, entities, threads. The single most useful tab. | Every morning. After any failure. |
| **Log** | System logger output. Filter by level (debug/info/warn/error) and search. | Triage. When something is silently failing. |
| **Scheduler** | All scheduled jobs (recurring, reminders, todos, appointments) with status, last result, error count. | Daily. After scheduler messages in the chat. |
| **Cycles** | Per-cycle DAG: token usage, tools called, model, duration, agent output. | Cost spikes. Debugging a specific cycle. |
| **Planner** | Active tasks and endeavours with progress, forecast scores, breakdowns. | When work isn't progressing as expected. |
| **D' Safety** | Recent gate decisions (input, tool, output) with scores and trigger features. | After a `[modified by safety gate]` notice. Tuning thresholds. |
| **D' Config** | Loaded gates, agent overrides, deterministic rules, normative axioms. | After editing `dprime.json` to confirm reload. |
| **Comms** | Email inbox/outbox with delivery status. | Daily if comms is enabled. |
| **Affect** | Five-dimensional affect snapshots over time. | Investigating a behaviour change. |
| **Skills** | Active and archived skills with metadata, decay candidates. | Weekly during skills review. |
| **Memory** | Counts and recent entries from facts, CBR cases, artifacts. | Sanity-checking that memory is actually growing. |

### Accessing the agent from your phone

The dense admin UI is desktop-only — `/m` is the page for phone
chat. Open `http://your-host:12001/m?token=...` from your phone
(via Tailscale or SSH tunnel as below). The agent itself can answer
"what's on my schedule today?" or "any failures since yesterday?",
which is usually faster than scrolling through admin tabs on a
phone screen anyway.

### Accessing the admin from your phone or laptop

If the agent runs on a VPS, **don't** open port 12001 to the public
internet. Two good options:

- **SSH tunnel** (one-shot):
  ```bash
  ssh -L 8080:localhost:12001 you@your-vps
  ```
  Then `http://localhost:8080` in your browser.
- **Tailscale** (always-on private network): see
  [section 9](#9-vps-setup-and-deployment).

---

## 4. Working with the agents

You never speak directly to a specialist agent. You talk to the
**cognitive loop** — the conversational front-end — and it decides
when to delegate. The 8 specialists are:

| Agent | Role | Tools | When the cognitive loop reaches for it |
|---|---|---|---|
| **Planner** | Pure XML reasoning, no tools | none | "Help me think through how to do X." Decomposes work into steps, dependencies, risks. |
| **Project Manager** | Work management | 22 planner tools (tasks, endeavours, phases, sessions, blockers) | "Manage my project X." Auto-creates tasks from planner output. |
| **Researcher** | Web search + extraction | 10 web tools (Kagi, Brave, Jina, DDG) + artifacts + builtins | "Find me information on X." Stores large content as artifacts. |
| **Coder** | Code in a Podman sandbox | run_code, serve, sandbox_exec, etc. | "Write/modify code X." Sandbox is isolated, ephemeral. |
| **Writer** | Drafts and reports | knowledge tools + artifacts | "Draft a report on X." Output goes through the D' output gate. |
| **Observer** | Cycle forensics + CBR curation | 19 diagnostic tools | "Why did cycle X fail?" "What's our overall hit rate today?" |
| **Comms** | Send/receive email | 4 comms tools (allowlisted) | "Reply to that email" or scheduled inbox triage. |
| **Remembrancer** | Deep-memory consolidation | 14 tools (search, trace, mine, propose) | Weekly/monthly consolidation. Skill proposal. |

Plus a **Scheduler agent** for managing scheduled jobs at runtime
(`schedule_from_spec`, `cancel_item`, `inspect_job`, etc.).

Phrasing matters less than you'd think. The cognitive loop is good
at routing — "find out X", "build X", "summarise X", "schedule X
weekly" all land at the right specialist. If a specialist isn't
firing when you'd expect, check that the agent is enabled in config
(some default to off — see [section 8](#8-config--the-knobs-you-actually-reach-for)).

### Captures — the commitment tracker (MVP)

A small post-cycle scanner reads the agent's responses for commitments
and promises. "I'll check the scheduler logs later," "remind me about
X tomorrow," and similar phrases get caught and written to
`.springdrift/memory/captures/YYYY-MM-DD-captures.jsonl`. The
sensorium shows a count (`<captures pending="N"/>`) every cycle; the
agent can act on a capture by:

- `clarify_capture(id, due_at, description)` — schedules a cycle at
  `due_at` via the existing scheduler; the agent will see the
  description as its input when the cycle fires
- `dismiss_capture(id, reason)` — drops the capture (already done,
  irrelevant, false detection)

`list_captures()` shows pending; auto-expiry is 14 days. Enable via
`[captures] scanner_enabled = true` (default true; opt out with false
to skip the per-cycle Haiku call). Full design:
[architecture/captures.md](../docs/roadmap/implemented/commitment-tracker.md).

### Deputies — delegated attention (MVP)

When the cognitive loop delegates to a specialist, a **deputy** spawns
alongside — an ephemeral read-only cog-loop variant that briefs the
specialist on relevant CBR cases, facts, and known pitfalls before its
react loop starts. The deputy stays alive for the root delegation's
lifetime, can answer `ask_deputy(question)` calls from the specialist
mid-task, and dies when the hierarchy completes.

Deputies are read-only by construction: they can't write memory,
delegate, or produce output. They exist to close the gap between the
cog loop (which has full CBR retrieval, facts, sensorium) and
specialist agents (which historically got just an instruction string).

Operator surface:

- Sensorium shows `<deputies active="N" completed_recent="M"/>` with
  signal tags (routine / high_novelty / anomaly / unanswered) when
  deputies are running or recently ran
- `kill_deputy(deputy_id, reason)` — terminate a stuck deputy;
  hierarchy continues without briefing
- `recall_deputy(deputy_id)` — non-destructive snapshot of deputy state

Enabled by default. Disable via `[deputies] enabled = false` if you
want to avoid the per-delegation Haiku call. Full design:
[architecture/deputies.md](architecture/deputies.md).

### Setting up the Comms agent (email)

Email is the most common operator-facing setup. Springdrift uses
[AgentMail](https://agentmail.to) for inbound and outbound delivery.

1. **Get an AgentMail account** and create an inbox. Note the inbox
   ID and your API key.
2. **Set the API key** in the agent's environment:
   ```bash
   export AGENTMAIL_API_KEY="am_live_..."
   ```
   Or put it in `/etc/springdrift/.env` if you're using systemd
   ([section 9](#9-vps-setup-and-deployment)).
3. **Configure** in `.springdrift/config.toml`:
   ```toml
   [comms]
   enabled = true
   inbox_id = "your-inbox-id"
   from_address = "agent@agentmail.to"
   from_name = "Springdrift"
   allowed_recipients = ["you@example.com"]
   max_outbound_per_hour = 20
   ```
   The `allowed_recipients` list is a **hard allowlist** — the agent
   physically cannot send to addresses not on it, regardless of what
   the LLM decides.
4. **Restart the agent.** The comms agent appears in the agent
   roster and the Comms tab in the admin UI starts populating.
5. **Test** by asking the agent to send you an email. Watch the
   Comms tab and your inbox.

Three layers of safety apply to outbound mail: hard allowlist
(operator config), deterministic rules (regex blocking credentials,
localhost URLs, env-var refs), and a tightened D' gate (0.30 modify
/ 0.50 reject vs. the default 0.45/0.65). See
[architecture/comms.md](architecture/comms.md) for detail.

### Triggering the Remembrancer

The Remembrancer is the deep-memory specialist. It reads raw JSONL
across months of archive (the Librarian only caches recent days).
Enable it in config:

```toml
[remembrancer]
enabled = true
consolidation_schedule = "weekly"   # or "monthly"
```

Then either let the metacognitive scheduler trigger it
(`meta_scheduler_enabled = true`) or ask the agent directly:

> "Run a memory consolidation for the last 30 days."

Reports land in `.springdrift/knowledge/consolidation/YYYY-MM-DD-*.md`.
The latest run's age surfaces in the sensorium so the agent itself
knows when its archive last got consolidated.

---

## 5. Diagnostic recipes

Symptom-driven. Find the row that matches what you're seeing, follow
the trail.

### "Tasks aren't progressing"

| Step | Where | What to look for |
|---|---|---|
| 1 | Planner tab | Does each task have non-zero `progress`? |
| 2 | Planner tab → forecast scores | Are they all identical? If yes, the forecaster heuristic is broken (see [v0.9.3 changelog](../CHANGELOG.md)). |
| 3 | Cycles tab → most recent | Is the agent actually thinking about the task, or stuck on something else? |
| 4 | Narrative tab → search task title | What did the agent last try? What was the outcome? |
| 5 | `.springdrift/memory/planner/YYYY-MM-DD-tasks.jsonl` | Inspect raw task ops if you suspect data corruption. |

### "Recurring scheduled job stopped firing"

As of v0.9.4 this is mostly self-healing — startup recovery re-arms
recurring jobs that were accidentally marked Completed. But if you
see it live:

| Step | Where | What to look for |
|---|---|---|
| 1 | Scheduler tab → filter by Recurring | `Last Run` time. If too long ago, job is stale. |
| 2 | Sensorium (any cycle's system prompt in cycle-log) | `<schedule>` element with `stale="overdue"` or `stale="never_fired"` flags. |
| 3 | Restart the agent | Recovery logic re-arms accidentally-killed recurrences. |
| 4 | If still dead | Check `.springdrift/memory/scheduler/*.jsonl` for the job's op history. Look for `Complete` ops the agent shouldn't have written. |

### "D' is rejecting too much"

| Step | Where | What to look for |
|---|---|---|
| 1 | D' Safety tab | Recent decisions. What features are scoring high? |
| 2 | D' Config tab | Current `reject_threshold` for the offending gate. Default 0.65. |
| 3 | Cognitive loop | Use the `report_false_positive` tool. The meta observer factors annotations into rate-limit detectors. |
| 4 | If chronic | Edit `dprime.json` (raise `reject_threshold` slightly, or move a feature from `Critical` to `High`). Restart. |

### "The agent's tone has changed"

| Step | Where | What to look for |
|---|---|---|
| 1 | Affect tab | Has any dimension drifted? Pressure rising? |
| 2 | Skills tab | Recently promoted skills — did one change response patterns? |
| 3 | Identity files | `.springdrift/identity/persona.md` — has anything been edited? |
| 4 | Output gate | Is MODIFY firing more often (autonomous cycles only)? |

### "Memory queries return stale data"

| Step | Where | What to look for |
|---|---|---|
| 1 | Memory tab | Total counts. Are they growing daily as expected? |
| 2 | Logs (warn+) | Librarian errors — `librarian_max_days` may have truncated reach. |
| 3 | Bypass the Librarian | Ask the agent to delegate to the Remembrancer for archive depth. |

### "Sandbox slot is wedged"

| Step | Where | What to look for |
|---|---|---|
| 1 | Logs | "sandbox" entries; "container exit" or "permission denied". |
| 2 | Shell | `podman ps -a \| grep springdrift-sandbox` — find the slot. |
| 3 | Restart agent | Startup sweeps stale `springdrift-sandbox-*` containers. |
| 4 | If chronic | Check `sandbox_workspaces/<slot>/` for root-owned files. v0.8.2 fixed this but a migration from older versions could leave residue. |

### "Scheduler-driven cycles are silently dropping"

Likely the rate limit kicked in. Check
`max_autonomous_cycles_per_hour` (default 20) and
`autonomous_token_budget_per_hour` (default 500000). Both are rolling
hour windows. The scheduler skips jobs (logs a warning) when either
is exhausted.

---

## 6. Recovery procedures

Always read before you act. These are last-resort steps when normal
operation has broken down.

### General principle

Springdrift's persistence model is **append-only JSONL files** plus
ETS caches built by replay. **Don't edit the JSONL files directly
unless you understand the resolve logic** (see
[architecture/memory.md](architecture/memory.md)). Operations that
look "obviously wrong" may be intentional (e.g. supersession ops
preserving audit trail).

The safest recovery is usually:

1. Stop the agent
2. Back up `.springdrift/` (`tar -czf backup.tar.gz .springdrift/`)
3. Make the smallest possible change
4. Restart and check logs

### Wedged scheduler

Symptoms: jobs stuck in `Running` forever, no `Tick` messages in
logs, restart doesn't help.

```bash
# 1. Stop the agent
systemctl stop springdrift     # or Ctrl-C

# 2. Inspect today's scheduler log
ls -lt .springdrift/memory/scheduler/

# 3. Check for half-written lines (incomplete JSON)
tail -5 .springdrift/memory/scheduler/$(date +%Y-%m-%d)-schedule.jsonl

# 4. If the last line is truncated, remove it
sed -i.bak '$d' .springdrift/memory/scheduler/$(date +%Y-%m-%d)-schedule.jsonl

# 5. Restart
systemctl start springdrift
```

### Corrupted JSONL day-file

Symptoms: agent panics on startup, log shows JSON decode errors.

```bash
# 1. Identify the bad file from the panic message
# 2. Validate each line individually
while read -r line; do
  echo "$line" | python3 -m json.tool > /dev/null 2>&1 || echo "BAD: $line"
done < .springdrift/memory/<store>/<date>.jsonl

# 3. Move the bad file aside (don't delete — investigate later)
mv .springdrift/memory/<store>/<date>.jsonl /tmp/

# 4. Restart. The day will be missing from history but the agent
#    will continue.
```

### Lost identity (different "personality" wakes up)

Symptom: the agent introduces itself differently, doesn't remember
its name, forgets project context.

| File | What it controls | If missing |
|---|---|---|
| `.springdrift/identity/persona.md` | Personality, voice | Falls back to generic `{{agent_name}}` template |
| `.springdrift/identity/session_preamble.md` | Per-cycle preamble template with slots | Falls back to plain system prompt |
| `.springdrift/identity/character.json` | Stoic virtues + commitments for normative calculus | Falls back to default character |
| `.springdrift/identity.json` | Stable agent UUID | New UUID generated — agent loses identity continuity |

If you've moved hosts and these files weren't transferred, you have
a different agent. See [section 9](#9-vps-setup-and-deployment) for
the migration checklist.

### Runaway agent delegation

Symptom: Cycles tab shows an agent burning tokens for many turns
without making progress.

```
> cancel_agent <agent-name>
```

The cognitive loop has the `cancel_agent` tool. The supervisor will
restart Permanent agents automatically. If the runaway is in a
recursive delegation chain, lower `max_delegation_depth` in config
(default 3) and restart.

### Restart from a previous session

```bash
gleam run -- --resume
```

Reads `.springdrift/session.json` (versioned envelope). The session
file is filtered to remove gate-injection messages so the agent
doesn't relearn self-censorship on resume. Stale by more than a day
triggers a warning in the log but loads anyway.

### Selective rollback via forward-write

**There is no "undo" primitive.** Springdrift's append-only JSONL
stores do not support deleting or editing a past entry — that's a
feature, not a gap, because it preserves an audit trail that survives
the same mistake being made twice. What you have instead are
**forward-write primitives** that change the agent's current view of
memory without erasing history. Most operator requests for "undo
the last X" map to one of these.

| You want to undo... | Use this, because... | Tool / ask the agent to call |
|---|---|---|
| A fact the agent wrote with the wrong value | Supersede it. The replay logic uses the most recent write, so the bad value disappears from retrieval. The old write stays in the log for audit. | `memory_write` with the corrected value (same key) |
| A fact you want gone entirely | Clear the key. Reads return nothing; history preserved. | `memory_clear_key` |
| A CBR case the agent shouldn't retrieve anymore (e.g. wrong lesson drawn) | Suppress it. The case is filtered out of future retrievals but stays on disk. Reversible via `unsuppress_case`. | Observer agent: `suppress_case` |
| A CBR case that's technically correct but misleading without caveats | Annotate it. Adds a pitfall note that's shown alongside the case whenever it's retrieved. | Observer agent: `annotate_case` |
| A CBR case with factually wrong content (wrong domain, wrong outcome) | Correct it. Writes a correction entry; retrieval applies the correction at read time. | Observer agent: `correct_case` |
| A CBR case whose retrieval weight is too high or low | Boost it. Explicitly raises or lowers confidence; influences retrieval ordering. | Observer agent: `boost_case` |
| A planner task that shouldn't be active anymore | Abandon it. Task stops accruing forecast-score evaluations; history preserved. | Planner agent: `abandon_task` |
| An endeavour that should be shelved | Cancel it via the Project Manager. Phases and work sessions stay on record. | `update_endeavour` with status change |
| A bad D' rejection the safety system made | Report it as a false positive. The meta observer factors this into threshold tuning. | Observer agent: `report_false_positive` |
| A scheduled job that shouldn't fire again | Cancel it via the scheduler agent. The schedule file keeps the record. | Scheduler: `cancel_item` |

Mental model: you are **adding a correcting entry**, not removing a
wrong one. The agent's current behaviour is controlled by the replay
result; the replay respects ordering and supersession rules; so the
newest correct entry wins without requiring you to delete anything.

When operator intervention is needed (you're in the chat, not asking
the agent), the simplest pattern is to tell the agent what you want
and let it pick the tool:

> "The fact `project_deadline` is wrong — should be 2026-05-15."
> "Suppress the CBR case about the Dublin rent analysis; the outcome
> classification was wrong."
> "Abandon the `cleanup-legacy-auth` task, superseded by the new
> auth endeavour."

If something needs to happen without the agent in the loop (agent
down, unsafe to chat), the JSONL files can be hand-edited with care —
but see the "General principle" at the top of this section before
doing that.

### When forward-write isn't enough

If the corruption spans many entries or the replay logic itself is
misbehaving, the appropriate move is still the full-state git rollback:

```bash
cd .springdrift/
git log --oneline -20               # pick a known-good commit
git diff HEAD~1 --stat              # sanity-check what changed
git checkout <sha>                  # roll back everything
# or, to review first:
git checkout <sha> -- memory/cbr/cases.jsonl
```

This nukes everything back to a point in time, including audit
history. It's the right answer for "the fact store has been
corrupted by a bad test run," not for "the agent learned the wrong
lesson from one cycle."

---

## 7. Auditing

`.springdrift/` contains everything the agent has ever done. Three
ways to audit:

### sd-audit (Flask dashboard + CLI)

Lives in `tools/sd-audit/`. Reads JSONL directly, no agent
dependency.

```bash
cd tools/sd-audit
uv sync
uv run sd-audit serve --port 5001
# Open http://localhost:5001
```

CLI commands for scripting:

| Command | What it does |
|---|---|
| `sd-audit serve` | Flask dashboard with charts (daily activity, tokens, D' decisions, outcomes) |
| `sd-audit summary --from YYYY-MM-DD --to YYYY-MM-DD` | Aggregate summary for a date range |
| `sd-audit skills list [--status active\|archived]` | List skills with metadata |
| `sd-audit skills decay-candidates --top 10` | Skills least useful by recent metrics |
| `sd-audit skills tokens` | Per-skill token cost estimates |

Add `--data-dir /path/to/.springdrift` to point at a non-default
directory. `--json-output` produces machine-readable output for
piping into `jq`.

### Raw JSONL grep recipes

When you need something sd-audit doesn't show:

```bash
# All failures yesterday
jq -c 'select(.outcome.success == false)' \
  .springdrift/memory/narrative/$(date -v-1d +%Y-%m-%d).jsonl

# All emails sent to a specific address
jq -c 'select(.direction == "outbound" and (.to[]? == "x@y.com"))' \
  .springdrift/memory/comms/*.jsonl

# All D' rejections in the past week
for d in $(seq 0 6); do
  date_str=$(date -v-${d}d +%Y-%m-%d)
  jq -c 'select(.event == "gate_decision" and .decision == "Reject")' \
    .springdrift/logs/${date_str}.jsonl 2>/dev/null
done

# Cycles that escalated to the reasoning model
jq -c 'select(.event == "model_escalation")' \
  .springdrift/logs/*.jsonl

# All skill promotion events
jq -c 'select(.event_type == "promoted")' \
  .springdrift/memory/skills/*.jsonl
```

### The narrative is the source of truth

When in doubt about what the agent actually did:
`.springdrift/memory/narrative/YYYY-MM-DD.jsonl`. Every cycle
produces one entry containing summary, intent, outcome, entities,
delegation chain, source references. Cycle-log files in
`.springdrift/memory/cycle-log/` carry the full LLM exchange (gated
by `--verbose`).

---

## 8. Config — the knobs you actually reach for

Springdrift has 80+ config fields (full table in
[`CLAUDE.md`](../CLAUDE.md)). In practice, you'll touch the same
dozen most of the time. Set in `.springdrift/config.toml`.

### LLM provider and models

```toml
provider        = "anthropic"
task_model      = "claude-haiku-4-5-20251001"
reasoning_model = "claude-opus-4-6"
```

Other providers: `openrouter`, `openai`, `mistral`, `vertex`, `local`,
`mock`. Set the corresponding API key env var
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.).

### Token limits and turn caps

```toml
max_tokens      = 2048    # output per LLM call
max_turns       = 5       # react-loop iterations per user message
```

Per-agent overrides in `[agents.researcher]` etc. Researcher
typically wants more turns (it's chasing leads); coder wants more
turns and a bigger context.

### Autonomous cycle budgets

```toml
[scheduler]
max_autonomous_cycles_per_hour     = 20      # 0 = unlimited
autonomous_token_budget_per_hour   = 500000  # 0 = unlimited
```

These bound runaway costs. Hit either and the scheduler skips jobs
until the rolling hour window rolls over. Set to 0 only if you have
external cost controls.

### Agent and subsystem enables

| Config | Default | Notes |
|---|---|---|
| `[comms] enabled` | `true` | Disable to stop loading the comms agent entirely |
| `[remembrancer] enabled` | `false` | Enable for weekly consolidation reports |
| `[forecaster] enabled` | `false` | Enable for autonomous plan-health monitoring |
| `[meta_learning] scheduler_enabled` | `false` | Adds 5 recurring meta-learning jobs |
| `[sandbox] enabled` | `true` | Disable if Podman isn't available |
| `[captures] scanner_enabled` | `true` | Post-cycle commitment scanner (see §4) |
| `[deputies] enabled` | `true` | Delegated-attention briefings per root delegation (see §4) |

### D' tightness

```toml
dprime_enabled = true            # set false only for debugging
gate_timeout_ms = 60000          # fail-open after this delay
normative_calculus_enabled = true
max_output_modifications = 2
```

Per-gate thresholds live in `dprime.json`. Lower
`reject_threshold` for tighter, higher for looser. Per-agent
overrides apply to specialist agent tool calls.

### Memory retention

```toml
[narrative]
threading = true
librarian_max_days = 180        # bounds startup ETS replay

fact_decay_half_life_days = 30  # confidence decay at read time
```

Older data isn't deleted; it just isn't auto-loaded into the ETS
cache. The Remembrancer can reach beyond.

### Web GUI

```toml
gui = "web"                  # or "tui" for terminal UI
[web]
port = 12001

[limits]
max_upload_bytes = 26214400  # POST /upload cap (default 25 MB)
```

**Auth is required by default.** Set `SPRINGDRIFT_WEB_TOKEN` to a
non-empty token before starting the GUI in `web` mode. If the token
isn't set, Springdrift refuses to start the GUI with a clear error
rather than silently shipping an unauthenticated surface — the
default before this change was a footgun on VPS deploys, where a
missing env var meant fully open chat / upload / admin panels.

For localhost-only dev where auth is genuinely unwanted, pass
`--web-no-auth` (or set `[web] no_auth = true`). This bypasses the
token check AND force-binds mist to `127.0.0.1` so the no-auth
surface can't be reached over a network. This combination is
explicitly opt-in and reported in the startup banner.

**Uploading documents from the chat tab.** The paperclip button
next to the chat input opens a file picker. The file is sent
directly to `POST /upload` as raw bytes (no multipart, no base64),
auth via the same bearer token the WebSocket uses. The byte cap is
`max_upload_bytes` (default 25 MB). Filenames are sanitised at the
intake boundary (path components stripped, `..` rejected). After
the upload lands the agent's intake processor runs synchronously,
so a markdown / PDF / docx / epub / HTML document becomes citeable
immediately. Unsupported file types stay in
`.springdrift/knowledge/intray/` for the operator to remove.

### Sandbox

```toml
[sandbox]
enabled = true
pool_size = 2          # max 3
memory_mb = 512
cpus = "1"
image = "python:3.12-slim"
```

Workspace dirs live at `.sandbox-workspaces/` in the project root
(sibling of `.springdrift/`, not inside it — ephemeral container state
vs persistent agent memory).

### Coder (OpenCode-backed)

The coder side of Springdrift is built around two pieces:

- **`dispatch_coder`** — a cog-loop / PM tool. One call spawns one
  OpenCode session inside a sandbox slot, blocks until the session
  returns (asynchronously, via an OTP worker — the cog stays
  responsive), and returns a summary plus the CBR case. Use this when
  you want a single self-contained coding task delegated.
- **`agent_coder`** — a specialist agent that wraps the above. It
  frames the work via `project_status`/`project_read`/`project_grep`,
  delegates each edit via `dispatch_coder` (potentially multiple
  times), verifies on disk, and integrates with the Planner via
  `complete_task_step`/`flag_risk`/`report_blocker`. Use this when the
  PM should hand off a multi-step work item.

Both share the same OpenCode container pool, the same per-task budget
caps, and the same CBR ingest (sessions land as `CodePattern` cases
keyed by the tools the in-container model used).

#### Activation

Both `dispatch_coder` (on the cog/PM) and the specialist `agent_coder`
require ALL of these:

- `[coder] image` — your built coder image tag
- `[coder] project_root` — the host directory the coder operates against
- `[coder] model_id` — a model identifier OpenCode and your API key both accept
- `ANTHROPIC_API_KEY` env var — typically loaded from `.env`

If any of those is missing, neither path is wired. Startup logs say
which gate failed (`real-coder mode disabled: [coder] image not set`).
The cog still runs; coder work just isn't available until you set the
missing field.

#### One-time setup

```sh
# 1. Build the coder image (pinned OpenCode version)
scripts/build-coder-image.sh

# 2. Verify the pinned version actually works headless
scripts/smoke-coder-image.sh

# 3. (Optional) Run the full e2e smoke against a real LLM call
#    Costs a couple of cents per run, proves end-to-end wiring
#    (manager + ACP + ingest, including CBR + session archive)
scripts/e2e-coder.sh
```

The smoke is the contract — if it fails, the pinned OpenCode version
isn't usable on your host. Don't proceed until smoke is green.

#### Configuration

```toml
[coder]
image = "springdrift-coder:latest"      # Built by scripts/build-coder-image.sh
project_root = "/Users/you/Repos/foo"   # Must NOT contain .springdrift/
provider_id = "anthropic"
model_id = "claude-sonnet-4-20250514"   # See "Model selection" below
# session_timeout_ms = 600000           # 10 min wall-clock cap per session
# max_cost_per_hour_usd = 20.0          # Aggregate cap across all dispatches in a rolling hour

[coder.budget]
# Per-task budget defaults the dispatch_coder tool clamps against. The
# agent can request more than the default via the tool params; the
# manager enforces the ceilings.
# default_max_tokens_per_task   = 200000
# default_max_cost_per_task_usd = 5.0
# default_max_minutes_per_task  = 10
# default_max_turns_per_task    = 50
# ceiling_max_tokens_per_task   = 1000000
# ceiling_max_cost_per_task_usd = 25.0
# ceiling_max_minutes_per_task  = 60
# ceiling_max_turns_per_task    = 200
```

`project_root` must be a directory you own. `/tmp` itself does NOT
work on macOS — podman bind-mounts it as `nobody:nogroup` and
OpenCode's provider init silently fails. Use
`/Users/you/Repos/<project>` or similar.

**Self-edit safety guard (v0.10.1).** Springdrift refuses any
`project_root` that:

- is empty or `"."` (would resolve to cwd)
- contains a `.springdrift/` subdirectory anywhere inside
- is itself a `.springdrift/` data directory

These checks fire at startup before the OpenCode container is
spawned. Their purpose is preventing the obvious footgun of pointing
the coder agent at the running agent's own data dir or source
checkout — the coder would happily edit Springdrift's memory,
identity, cycle log, or source code. Refused paths produce a clear
startup message naming the exact reason; the coder layer is disabled
until you fix the config.

If you don't set `[coder] project_root` explicitly, Springdrift
defaults to `${TMPDIR:-/tmp}/springdrift-coder-workspace` —
auto-created on first boot, structurally disjoint from cwd by
construction, persistent across restarts of the same instance so the
coder remembers prior commits inside the workspace. The default is
fine for "just kicking the tyres"; for real projects of yours,
override.

The actual security boundary is the rootless-podman container
itself (kept-id userns + no-new-privileges + memory / CPU / pid
caps); the path check is just don't-shoot-yourself.

#### Model selection

The pinned OpenCode version (1.14.25) ships with a current model
catalog including all Claude 4.x models — Sonnet 4.6, Opus 4.7,
Haiku 4.5. List the available IDs with `scripts/discover-coder-endpoints.sh`
or by running `opencode models` inside the container.

Set `[coder] model_id` to a model your Anthropic API key has access
to. Reasonable defaults:
- `claude-haiku-4-5-20251001` — cheapest, fast iteration
- `claude-sonnet-4-6` — balance, default for most coding tasks
- `claude-opus-4-7` — heavy reasoning, expensive

Note: the OpenCode catalog drifts when new Anthropic models ship —
periodically bump the pinned OpenCode version (procedure below) to
pick up new model IDs.

#### Bump procedure

```sh
# 1. Edit Containerfile.coder, change ARG OPENCODE_VERSION=...
# 2. Rebuild
scripts/build-coder-image.sh

# 3. Verify smoke still passes against the new pin
scripts/smoke-coder-image.sh

# 4. (Optional) Run e2e with a real LLM call
scripts/e2e-coder.sh

# 5. Commit Containerfile.coder. The image's :latest tag now points
#    at the new version; existing slots running the old image keep
#    running until restart.
```

Smoke is the gate. Don't ship to production unless it passes against
the new pin.

#### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `real-coder mode disabled: ...` at startup | `[coder]` not fully set or no API key | Check the startup log line — it names the missing field. The cog/PM still has `dispatch_coder` and the project_* tools, but the specialist `agent_coder` is not registered until [coder] is complete. |
| `ProviderModelNotFoundError` from `dispatch_coder` | `model_id` not in OpenCode's catalog | Use a model that's in `/config/providers` (run `scripts/discover-coder-endpoints.sh` to see the list) |
| `not_found_error` from Anthropic | Model is in OpenCode's catalog but Anthropic deprecated it | Bump to a newer model (4.x family) |
| OpenCode silently shuts down on serve | Probably `project_root` permission/idmap issue | Confirm `project_root` is user-owned, not `/tmp` |
| Stranded `springdrift-coder-*` containers | A dispatch crashed before manager teardown could run | `podman ps -a \| grep springdrift-coder-` then `podman rm -f <name>`; the manager will spin up fresh containers on the next dispatch |
| `dispatch_coder failed: cost budget exceeded` | Per-task cost cap fired mid-session | Raise `coder_default_max_cost_per_task_usd` (and the matching ceiling) in `[coder.budget]`, or set `max_cost_usd` per-call when invoking `dispatch_coder` |
| Cog loop appears unresponsive during a long coder run | (R5b regression check) — should NOT happen; dispatch_coder spawns a worker so the cog stays free | If you see this, file a bug. The cog should still process sensory events, AgentProgress, and `cancel_coder_session` while a dispatch is in flight |

See `docs/roadmap/planned/real-coder-opencode-phase2-notes.md` for the
full set of findings from the build.

### Where to look for everything else

- All fields with defaults: [`.springdrift_example/config.toml`](../.springdrift_example/config.toml)
- D' gate config: [`.springdrift_example/dprime.json`](../.springdrift_example/dprime.json)
- Forecaster weights: [`.springdrift_example/planner_features.json`](../.springdrift_example/planner_features.json)
- Profile templates: `.springdrift/profiles/<name>/`

---

## 9. VPS setup and deployment

For a long-running agent, a small Linux VPS beats running on your
laptop. The agent is designed to survive restarts — memory persists,
scheduled jobs reload, identity is stable across sessions — but
those guarantees only matter if the host is up.

### Provider

[Hetzner Cloud](https://www.hetzner.com/cloud) is our default
recommendation. Sign up at
[accounts.hetzner.com/signUp](https://accounts.hetzner.com/signUp)
(credit card and ID verification).

Other providers (DigitalOcean, Linode, Scaleway) work fine — the
setup below is provider-agnostic apart from the firewall config.

### Server spec

- **Plan:** CX23 (2 vCPU / 4 GB RAM / 80 GB NVMe) — ~€8/month
- **Location:** Finland or Germany (EU), or whichever is closest to
  your LLM provider's region
- **OS:** Ubuntu 24.04 LTS
- **IPv4:** Yes (IPv6-only causes issues with some APIs and SSH
  clients)
- **Volumes:** Not needed initially — 80 GB is plenty
- **Firewall:** Yes — allow only port 22 (SSH) inbound, block
  everything else
- **Backups:** Not needed at the provider level — Springdrift's own
  persistence model is the system of record. (You may still want
  off-host backups; see "Backups" below.)
- **Delete protection:** Enable

If you outgrow CX23, the CPX32 (4 vCPU / 8 GB) at ~€16/month handles
Podman-heavy workloads comfortably.

### SSH setup

Generate a key locally if you don't already have one:

```bash
ssh-keygen -t ed25519
```

Default location `~/.ssh/id_ed25519` works. Paste the public key
contents into the Hetzner setup form:

```bash
cat ~/.ssh/id_ed25519.pub
```

Connect:

```bash
ssh root@your-server-ip
```

Set the hostname:

```bash
hostnamectl set-hostname springdrift
```

Create a non-root user and copy your SSH key over:

```bash
adduser springdrift
usermod -aG sudo springdrift
mkdir -p /home/springdrift/.ssh
cp ~/.ssh/authorized_keys /home/springdrift/.ssh/
chown -R springdrift:springdrift /home/springdrift/.ssh
chmod 700 /home/springdrift/.ssh
chmod 600 /home/springdrift/.ssh/authorized_keys
```

**Test login as the non-root user in a separate terminal before
closing the root session.** Then disable password and root login by
editing `/etc/ssh/sshd_config`:

```
PasswordAuthentication no
PermitRootLogin no
```

Restart SSH:

```bash
sudo systemctl restart sshd
```

### Provisioning

System update:

```bash
apt update && apt upgrade -y
```

Install Podman (for the coder sandbox):

```bash
apt install -y podman
```

Install the document-library converters (for ingesting PDFs and
Office documents into `.springdrift/knowledge/intray/`, and for
generating PDFs from approved exports):

```bash
# pandoc handles HTML / docx / epub on ingest, and markdown → PDF on export
apt install -y pandoc

# unpdf handles PDF → structured markdown on ingest. Single Rust
# binary downloaded from GitHub Releases; no Rust toolchain needed.
curl -L \
  https://github.com/iyulab/unpdf/releases/latest/download/unpdf-linux-x86_64-v0.4.5.tar.gz \
  | tar xz -C /usr/local/bin unpdf
chmod +x /usr/local/bin/unpdf
```

`unpdf` extracts PDFs into structured markdown — real `#` / `##`
headings detected from PDF font sizes — which the document-library
indexer needs to build a navigable section tree. (The previous
backend, `pdftotext`, emitted flat text with no headings, so the
indexer couldn't tell chapters from paragraphs.) `pandoc` handles
HTML, docx, and epub on the way in, and markdown → PDF on the way
out. Both are optional — if absent, the relevant operations skip
with a specific error message — but PDF is the dominant real-world
document format so you'll want `unpdf` at minimum.

For PDF *generation* (the writer's `export_pdf` tool), install
`tectonic` as well — pandoc by itself doesn't render PDFs, it
shells out to a separate engine. Tectonic is a single Rust
binary, so the install is a curl + chmod rather than `apt`:

```bash
curl -L \
  https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%400.15.0/tectonic-0.15.0-x86_64-unknown-linux-musl.tar.gz \
  | tar xz -C /usr/local/bin tectonic
chmod +x /usr/local/bin/tectonic
```

Adjust the version + arch for your host. Tectonic downloads LaTeX
packages on demand on first run, so the first export takes a few
extra seconds; subsequent runs are fast.

Install asdf and the Erlang/Gleam toolchain:

```bash
apt install -y curl git build-essential autoconf m4 \
  libncurses-dev libssl-dev libwxgtk3.2-dev
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.1
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
source ~/.bashrc

asdf plugin add erlang
asdf install erlang 28.4.2     # ~10–20 minutes; compiles from source
asdf global erlang 28.4.2

asdf plugin add gleam
asdf install gleam 1.15.4
asdf global gleam 1.15.4
```

Match the versions on your local machine:

```bash
gleam --version
erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().'
```

### Secrets management

API keys and other secrets live outside the application directory:

```bash
sudo mkdir -p /etc/springdrift
sudo touch /etc/springdrift/.env
sudo chown springdrift:springdrift /etc/springdrift/.env
sudo chmod 600 /etc/springdrift/.env
```

Edit with your keys (e.g. `ANTHROPIC_API_KEY=...`,
`AGENTMAIL_API_KEY=...`, `SPRINGDRIFT_WEB_TOKEN=...`). Never commit
this file.

Keep separate `.env.local` and `.env.production` files locally.
Before deploying, check for missing keys:

```bash
comm -23 \
  <(grep -oE '^[A-Z_]+' .env.local | sort) \
  <(grep -oE '^[A-Z_]+' .env.production | sort)
```

### Build and deploy

Use a release shipment in production — `gleam run` recompiles every
start, which is wasteful and error-prone:

```bash
cd ~/springdrift
git pull
gleam export erlang-shipment
```

This produces a self-contained BEAM shipment under
`build/erlang-shipment/` that runs without Gleam installed — only
Erlang at runtime.

### Migrating an existing agent

**This is the bit that matters if you're moving an existing
Curragh-style instance to a new host.** Without these files, a
**different agent wakes up** — same code, different identity, no
memory.

| What to copy | From | To | Why |
|---|---|---|---|
| `.springdrift/` (entire directory) | source host | `~/springdrift/.springdrift/` | All memory, identity, schedules, skills, config |
| `.springdrift/identity/` | source host | (nested in above) | Persona, preamble, character spec — lose these and the agent forgets who it is |
| `.springdrift/identity.json` | source host | (nested in above) | Stable agent UUID — lose this and continuity breaks even if persona transfers |
| `/etc/springdrift/.env` | source host | new host | API keys including `SPRINGDRIFT_WEB_TOKEN` |

Quick recipe:

```bash
# On source host, with agent stopped
sudo systemctl stop springdrift
tar -czf springdrift-backup.tar.gz \
  ~/springdrift/.springdrift \
  /etc/springdrift/.env

# Transfer
scp springdrift-backup.tar.gz user@new-host:~/

# On new host
cd ~/
tar -xzf springdrift-backup.tar.gz -C ~/
sudo cp etc/springdrift/.env /etc/springdrift/.env
sudo chown springdrift:springdrift /etc/springdrift/.env
sudo chmod 600 /etc/springdrift/.env

# Verify identity
cat ~/springdrift/.springdrift/identity.json
# UUID should match the source host's

# Start
sudo systemctl start springdrift
sudo journalctl -u springdrift -f
```

First-boot checks: open the admin UI, confirm the agent introduces
itself with the right name, confirm Memory tab shows expected
counts, confirm Scheduler tab shows your existing jobs.

### systemd service

Create `/etc/systemd/system/springdrift.service`:

```
[Unit]
Description=Springdrift Agent
After=network.target

[Service]
Type=simple
User=springdrift
WorkingDirectory=/home/springdrift/springdrift
EnvironmentFile=/etc/springdrift/.env
ExecStart=/home/springdrift/springdrift/build/erlang-shipment/entrypoint.sh run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now springdrift
```

Day-to-day:

```bash
sudo systemctl status springdrift     # check status
sudo journalctl -u springdrift -f     # tail logs
sudo systemctl restart springdrift    # after deploy
```

### Upgrades

```bash
cd ~/springdrift
git pull
gleam export erlang-shipment
sudo systemctl restart springdrift
```

The `.env` file is untouched. `.springdrift/` is untouched. Run the
config diff snippet (above) before deploying to catch any new env
keys the new release needs.

### Network and security

The server exposes only port 22 (SSH). The Hetzner firewall blocks
everything else. **Do not open port 12001 to the internet** —
anyone could read the agent's memory.

**SSH tunnel** for occasional admin access:

```bash
ssh -L 8080:localhost:12001 springdrift@your-server-ip
# Open http://localhost:8080
```

Add to `~/.ssh/config` for convenience:

```
Host springdrift
    HostName your-server-ip
    User springdrift
    LocalForward 8080 localhost:12001
```

Then `ssh springdrift` opens the tunnel automatically.

**Tailscale** for always-on mobile access — creates a private
WireGuard network between your devices, no ports to open. Free
Personal plan covers 3 users and 100 devices.

```bash
# On the server
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
# Follow the login URL

# On your phone
# Install Tailscale from App Store / Play Store, sign in with the
# same account.

# Find the server's Tailscale IP
tailscale ip
```

Then `http://100.x.x.x:12001` from your phone (with `?token=...`).
Add to home screen for PWA-style access. Auto-reconnects, no
firewall changes.

### Outbound connections

Always work regardless of inbound firewall rules. The agent can
freely call LLM APIs, fetch web content, send email, and push to
webhooks even with all inbound ports blocked.

### fail2ban (SSH brute-force protection)

```bash
apt install -y fail2ban
systemctl enable --now fail2ban
```

Works out of the box for SSH. Tighten with `/etc/fail2ban/jail.local`:

```
[sshd]
enabled = true
maxretry = 3
bantime = 1h
```

Check banned IPs: `fail2ban-client status sshd`.

### Backups

Springdrift handles its own persistence inside `.springdrift/`. For
off-host backup of that one directory, the simplest option is a
nightly tarball to S3-compatible storage:

```bash
# /etc/cron.daily/springdrift-backup
#!/bin/sh
tar -czf /tmp/sd-$(date +%Y%m%d).tar.gz -C /home/springdrift springdrift/.springdrift
# upload to your storage of choice
```

Restore is `tar -xzf` into the new home. The agent doesn't care if
its `.springdrift/` was restored from a snapshot — it'll replay
JSONL on startup as usual.

---

## 10. Extending with Claude Code

Springdrift is designed for [Claude Code](https://claude.ai/code) to
work on. The repo's [`CLAUDE.md`](../CLAUDE.md) is a 700-line guide
for Claude that covers architecture, patterns, config fields, and
conventions. CC will read it automatically and is well-grounded in
the codebase from the first prompt.

A few things to watch for.

### Always run `gleam test` before *and* after

Tests must pass before any task is considered complete (it's in
CLAUDE.md, but it bears repeating). 1700+ tests run in well under a
minute. Don't merge if anything is red.

```bash
gleam test
```

### Don't let Claude Code commit blind

The bash tool can run `git commit`. The CLAUDE.md guidelines say it
must only commit when explicitly asked, but treat that as a default
to override carefully. Workflow that works:

1. Have CC implement and run tests
2. Review the diff yourself (`git diff`)
3. Then ask CC to commit (or commit yourself)

Spurious "AI slop" commits — over-cleanup, unprompted refactors, doc
files you didn't ask for — are easier to catch in review than to
revert later.

### CHANGELOG and versioning

The project uses semver (`0.x.y`) starting at 0.8.0. Patch bumps
(0.9.4 → 0.9.5) are bug-fix-only. Minor bumps add features. CC will
draft CHANGELOG entries — verify they describe what *actually*
changed, not what was planned.

### Watch the output gate

When you ask CC to draft user-facing text (READMEs, error messages,
help strings), the same rules that apply to Springdrift's own
outputs apply: no jargon nobody outside the project understands, no
internal phase names ("Phase A/B/C/D"), no marketing-style hedging.
The output gate logs in the agent's own runs catch this; in CC there
is no automatic gate, so the human must do that work.

### Useful CC entry points

| Goal | Prompt |
|---|---|
| Investigate a bug | "There's a bug where X happens. Find the code path that produces it and propose a fix." |
| Add a config knob | "I want a new config field `[scheduler] purge_retention_days`. Add it to AppConfig with default 30, surface in both config.toml files, and apply at the usage site in `runner.gleam`." |
| Audit a subsystem | "Audit `src/dprime/` and report any gaps between the architecture doc and the actual code." |
| Write a test | "Write tests for `extract_list` covering single-element, indexed-takes-precedence, and round-trip-with-XML cases." |

### Caveats

- CC's bash tool can't run a long-lived agent process to test
  changes interactively. Use `gleam test` and the mock LLM provider
  for fast feedback; reach for a full agent run only at the end.
- The Podman sandbox needs `podman` on the host. CC running in
  CI-style environments (no Podman) can still write code that uses
  it but can't exercise it end-to-end.
- The web GUI is a single-page Gleam-templated HTML string in
  `src/web/html.gleam`. Changes there require restarting the agent
  to see — don't expect hot reload.
- Don't ask CC to bypass the output gate, the D' system, or the
  comms allowlist. Those are intentional safety boundaries; if you
  want them off, configure them off rather than routing around them
  in code.

---

## Index of related docs

- [Architecture overview](architecture/) — 16 subsystem docs
- [`CLAUDE.md`](../CLAUDE.md) — the AI-collaboration guide; also the
  most complete config reference
- [`CHANGELOG.md`](../CHANGELOG.md) — what changed in each release
- [`.springdrift_example/`](../.springdrift_example/) — annotated
  reference config and skills
- [`docs/engineering-log.md`](engineering-log.md) — implementation
  history beyond what's user-visible
