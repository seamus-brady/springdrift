# Springdrift

A cognitive agent that learns from experience, explains its reasoning, and
improves over time. It keeps a complete audit trail you can back up to git
and restore at any point.

Built in [Gleam](https://gleam.run) on the Erlang/OTP runtime.

**Status:** Beta. In active development. Running in daily use. ~43,000 lines of Gleam
across 120 source files, 1,414 tests passing. Core systems (cognitive loop,
multi-agent delegation, D' safety gates, normative calculus, CBR memory,
narrative threading, sensorium, scheduler, web GUI) are implemented and
relatively stable. There are probably bugs though!

See [docs/future-plans/](docs/future-plans/) for planned work
including federation, learner ingestion, and metacognition reporting.

---

## Table of Contents

- [What it is](#what-it-is)
- [Why CBR and not RAG](#why-cbr-and-not-rag)
- [The learning loop](#the-learning-loop)
- [Cognitive architecture](#cognitive-architecture)
- [Safety -- D' and normative calculus](#safety----d-and-normative-calculus)
- [Introspection](#introspection)
- [Sensorium](#sensorium)
- [Memory](#memory)
- [Agents](#agents)
- [Interfaces](#interfaces)
- [Cost management](#cost-management)
- [Persistence and recovery](#persistence-and-recovery)
- [Architecture](#architecture)
- [Why Gleam on the BEAM](#why-gleam-on-the-beam)
- [Getting started](#getting-started)
- [Configuration](#configuration)
- [Requirements](#requirements)
- [Development](#development)
- [Evaluation results](#evaluation-results)
- [Background reading](#background-reading)


[Back to top](#springdrift)

---

## What it is

Springdrift is a cognitive agent platform. It retains what it learns, reasons
about safety using virtue ethics, and gets measurably better at its job over
weeks and months of operation. It runs interactively with an operator or
autonomously on a schedule.

It is not a framework. It is the agent. You give it a character, point it at a
domain, and let it work. It learns from its own experience as it operates.
Sub-agents (researcher, planner, coder, writer, observer) are its hands, not
independent minds. One identity, one memory, one cognitive loop.

The system draws on classical cognitive science, Stoic philosophy, and
contemporary agent research. The full theoretical lineage and paper-by-paper
mapping is in [docs/background/references.md](docs/background/references.md).

### Design philosophy

The TallMountain project that preceded Springdrift proposed a model for
what it called a *synthetic individual* -- an autonomous, bounded, auditable
entity with a stable character. Not a chatbot. Not a human substitute. A
useful analogy is the assistance animal: it may refuse a dangerous command,
it has autonomy in service of safety, it is excellent in a specific domain,
and every decision it makes is reviewable.

Springdrift implements this. A running instance has:

- **An identity** -- a persona, a name, a stable UUID that persists across
  sessions. The agent knows who it is.
- **A character** -- normative commitments expressed as propositions in the
  character spec. The agent knows what it values.
- **Bounded autonomy** -- it acts independently within constraints (turn
  limits, delegation depth, token budgets, safety gates). It can refuse
  unsafe requests and explain why, citing the specific axiom.
- **Auditability** -- every decision, every safety evaluation, every memory
  operation is logged in append-only JSONL. The operator can reconstruct
  exactly what the agent did and why.
- **Self-governance** -- virtue drift detection monitors whether the agent's
  conduct remains consistent with its character. When it drifts, it
  escalates to the operator rather than silently adjusting.

The design principle is that trustworthy autonomy comes from character, not
from rules. Rules tell you what you must not do. Character tells you who
you are. An agent with character can navigate situations its rules never
anticipated -- and explain its reasoning after the fact.


[Back to top](#springdrift)

---

## What it's like

The best way to explain Springdrift is to show what it does when things go
wrong -- because that's where most agent systems fall apart, and where this
one starts to get interesting.

The following examples are real, pulled from the narrative memory of an
instance named Curragh running on Springdrift over two weeks in March 2026.

### It diagnosed its own infrastructure bugs

On March 15, Curragh noticed that its cycle-level telemetry was inconsistent.
It used `reflect` and `list_recent_cycles` to compare aggregate stats against
per-cycle records, found the mismatch, and wrote a structured bug report into
its own fact store:

> *"Yesterday's cycle-level data completely missing -- list_recent_cycles
> returns empty, inspect_cycle fails. BUT narrative log entries survived
> (20 entries) and reflect has aggregate stats (10 cycles, 36K tokens).
> Likely root causes: cycle records not persisted to durable storage --
> living in ETS or in-memory, lost on restart. Cycle finalization not
> happening -- status stays pending, token counts never written back."*

That bug report -- written by the agent about itself -- led directly to the
cycle log persistence fixes.

### It classified its own sub-agent failure modes

When the coder agent kept failing, Curragh didn't just retry. It analysed the
pattern across multiple delegations and identified three distinct failure modes:

> *"PROBLEM 1 -- 'Talking but not coding' (Most Common): The coder agent
> responds with text like 'I'll create and execute...' but never actually
> calls run_code. Of the 5 coder delegations, 4 returned 'succeeded' but
> only produced TEXT RESPONSES, not code execution.*
>
> *PROBLEM 2 -- run_code tool failures: When the coder DID finally call
> run_code, it hit 'too many consecutive tool errors'.*
>
> *PROBLEM 3 -- Script too large for single execution."*

### It found an architectural vulnerability in itself

On March 21, Curragh identified that the coder agent's `request_human_input`
tool was injecting prompts into its own cognitive loop input channel --
creating a control inversion where a sub-agent appeared to hijack the
conversation:

> *"The injection was invisible to my telemetry because responses routed
> back through the main loop as normal user inputs. This represents a
> significant architectural vulnerability."*

It then assessed whether the problem was structural or a skill issue:

> *"I concluded the gap is a skill deficiency in my own judgment and
> verification practices, not a structural layer problem. Adding another
> agent layer would not address these fundamental verification failures."*

### It learned from its mistakes

After the delegation failures, Curragh reflected on what it needed to change:

> *"I learned to critically evaluate sub-agent outputs rather than accepting
> success classifications at face value, and to examine failure evidence in
> error logs. My previous attempts lacked specificity, behavioral
> constraints, and critical evaluation, whereas my second attempt succeeded
> because I was precise about requirements."*

That reflection became a CBR case. The next time Curragh delegated to the
coder agent, it retrieved the case and applied the lesson -- tighter
instructions, explicit constraints, verification steps.

### What this means

None of this was programmed. Curragh wasn't told to diagnose its own bugs or
classify failure modes. The introspection tools (`reflect`, `inspect_cycle`,
`list_recent_cycles`, `query_tool_activity`, the observer agent), the narrative
memory, the CBR learning loop, and the [sensorium's](#sensorium) ambient self-awareness
created the conditions for the agent to notice problems, reason about them,
and learn from them.

This is what it feels like to operate a system like this: you come back after
the weekend and the agent has filed bug reports against itself, classified its
own failure modes, and started applying the lessons it learned. You don't
debug the agent. You review its self-assessments.


[Back to top](#springdrift)

---

## Why CBR and not RAG

Most agent memory systems use Retrieval-Augmented Generation -- embed documents,
search by vector similarity, inject results as context. RAG retrieves by
similarity. It does not learn from outcomes.

Springdrift uses Case-Based Reasoning (Aamodt & Plaza, 1994). Each case records
the problem, the solution the agent tried, and the outcome -- did it work? Cases
that led to successful outcomes are retrieved more often (utility scoring,
following the Memento paper's learned retrieval policy). Cases that failed are
gradually deprioritised. The agent builds institutional knowledge through use.

The retrieval engine fuses six signals: weighted field matching, inverted index
overlap, recency, domain relevance, semantic embedding (via Ollama),
and utility score from outcome tracking. The retrieval cap is K=4 cases per
query (per the Memento finding that more causes context pollution).

This is not similarity search. It is experience-weighted pattern matching with
a closed learning loop.


[Back to top](#springdrift)

---

## The learning loop

Every cognitive cycle produces structured output that feeds back into the
agent's memory:

```
User/scheduler input
  --> Cognitive loop (classify, delegate, tool use, respond)
  --> Archivist (fire-and-forget, post-cycle)
      --> Phase 1: Reflector (plain-text honest assessment of what happened)
      --> Phase 2: Curator (structured NarrativeEntry + CbrCase via XStructor)
  --> Narrative entry appended (intent, outcome, entities, delegation chain)
  --> CBR case generated (problem, solution, outcome, utility stats)
  --> Thread assignment (overlap scoring: location, domain, keywords)
  --> Librarian indexes in ETS (available next cycle)
```

The two-phase Archivist pipeline (inspired by the ACE paper, arXiv 2510.04618)
separates honest reflection from structured curation. Phase 1 can't hide behind
formatting. Phase 2 can't invent what Phase 1 didn't say.

Over time, the agent accumulates domain knowledge: which approaches worked for
which problems, which tools failed in which contexts, which sources were
reliable. CBR utility scoring (Laplace-smoothed: `(successes + 1) /
(retrievals + 2)`) reinforces what works and lets failures fade.


[Back to top](#springdrift)

---

## Cognitive architecture

Springdrift's architecture follows Aaron Sloman's H-CogAff model -- a
three-layer cognitive architecture originally designed to describe human-like
minds, adapted here for an autonomous agent (Sloman, 2001; Sloman & Chrisley,
2003).

### Layer 1: Reactive

Fast, automatic responses that don't require deliberation.

In Springdrift: deterministic pre-filters (regex pattern matching on
known-bad inputs -- injection attempts, dangerous commands, credential
patterns), canary probes (prompt hijack and data leakage detection using
fresh random tokens embedded in the context -- if the token appears in the
output, the LLM has been compromised), and critical-feature immediate
rejection. These fire in milliseconds with no LLM cost. The canary probe
system tests whether the LLM can be trusted *before* asking it to evaluate
safety -- a defence against the fundamental bootstrap problem in LLM-based
safety systems.

### Layer 2: Deliberative

Slower, model-based reasoning that evaluates options against standards.

In Springdrift: the D' scorer (LLM-scored features with importance
weighting), the normative calculus (Stoic axiom resolution against the
character spec), query complexity classification (routing simple vs complex
queries to different models), and the cognitive loop's agent delegation
decisions. This is where the agent thinks about what to do.

### Layer 3: Meta-management

Self-monitoring and adaptation -- the system reasoning about its own
performance and adjusting its behaviour.

In Springdrift this splits into three sub-layers:

**3a -- Intra-gate meta.** Within a single D' gate evaluation: sliding
window of recent scores, stall detection, threshold tightening when the
agent is stuck in a borderline loop.

**3b -- Cross-cycle meta observer.** After each cycle completes: pattern
detection across gate decisions (rate limits, cumulative risk drift,
repeated rejections, high false positive rates, virtue drift). Produces
interventions: inject caution, tighten gates, force cooldown, or escalate
to operator.

**3c -- Ambient self-perception (sensorium).** Continuous: three epistemic
meta-states -- uncertainty (proportion of cycles without CBR hits),
prediction error (tool failure + safety modification rate), and novelty
(keyword dissimilarity to recent work). These are injected into the
[sensorium](#sensorium) every cycle so the agent perceives its own
cognitive state without making tool calls. Derived from the System M paper
(Dupoux, LeCun, Malik; arXiv 2603.15381).

### The CBR learning lifecycle

The three layers create a closed loop that improves over the agent's
lifetime:

```
Cycle N:
  Layer 2 retrieves CBR cases for context (K=4, utility-weighted)
  Agent acts, using cases to inform its approach
  Archivist records outcome as NarrativeEntry + new CbrCase

Cycle N+1:
  Layer 2 retrieves cases -- including N's outcome
  Utility scoring adjusts: N's case weighted by success/failure
  Agent benefits from (or avoids repeating) N's experience

Over weeks:
  Layer 3b detects patterns (repeated failures, drift, stagnation)
  Cases that helped accumulate retrieval success counts
  Cases that didn't are deprioritised by utility scoring
  Confidence on old facts decays via half-life formula
  Housekeeping deduplicates similar cases, prunes low-value failures
```

The utility scoring uses Laplace-smoothed estimates: `(successes + 1) /
(retrievals + 2)` -- following the Memento paper's learned retrieval policy
(Zhou et al., arXiv 2508.16153). Fresh cases start with a neutral prior
(0.5) and converge toward their true utility as they're retrieved and
evaluated. This is not a static knowledge base. It is a system that gets
measurably better with use.

### Character drift detection

The normative calculus tracks every verdict (Flourishing, Constrained,
Prohibited) in a ring buffer. Four drift detectors run after each output
gate evaluation:

- **High prohibition rate** (>15%) -- the agent is refusing too much
- **High constraint rate** (>40%) -- the agent is hedging too much
- **Repeated axiom** (>60% of non-flourishing verdicts fire the same rule)
  -- a single normative proposition is dominating, probably miscalibrated
- **Over-restriction** (prohibitions present but harm scores low) -- the
  character spec is stricter than the actual risk

When drift is detected, two things happen: a sensory event is emitted (the
agent sees it in the [sensorium](#sensorium) next cycle), and the Layer 3b
meta observer escalates to the operator. The system never auto-adjusts its
own ethical commitments -- only the operator can tune the character spec.

This is eudaimonic self-governance: the agent monitors whether its own
conduct is consistent with its character, and flags when it isn't. The
concept is from Becker's *A New Stoicism* (1998) -- virtue as rational
agency that follows the facts, including facts about its own behaviour.


[Back to top](#springdrift)

---

## Safety -- D' and normative calculus

The safety system has two layers: D' (quantitative scoring) and the normative
calculus (qualitative reasoning). Both produce audit trails.

### D' (D-prime)

Based on Beach's Image Theory (2010) and Sloman's H-CogAff architecture (2001).
Every tool dispatch passes through a safety gate with four layers:

1. **Deterministic pre-filter** -- regex pattern matches on known-bad inputs.
   Instant, no LLM cost. Credential leaks, injection patterns, dangerous
   commands. Configurable rules in `dprime.json`.
2. **Canary probes** -- hijack and leakage detection using fresh random tokens
   per request. Tests whether the LLM has been compromised *before* trusting it
   to evaluate safety. Fail-open on probe errors (not evidence of hijacking).
3. **LLM scorer** -- D' score computed across weighted features. Each feature
   scored 0-3 by the LLM. Importance weighting (Low/Medium/High) with optional
   multi-tier hierarchies. Score normalised to [0,1] for threshold comparison.
4. **Meta-management** -- sliding window of recent scores. Stall detection
   tightens thresholds. Cross-cycle pattern analysis (Layer 3b meta observer)
   detects rate limits, cumulative risk drift, repeated rejections, and high
   false positive rates.

Three gates: **input** (screens user/scheduler input, fast-accept path for
benign input), **tool** (evaluates every non-exempt tool dispatch), and
**output** (evaluates autonomous deliveries only -- interactive sessions use
deterministic rules only because the operator is the quality gate).

D' configuration is a unified JSON format with five sections: `gates` (named
gate configs), `agent_overrides` (per-agent tool gate features), `meta`
(Layer 3b observer settings), `shared` (common settings), and `deterministic`
(regex pre-filter rules and allowlists).

### Normative calculus

Based on Becker's *A New Stoicism* (1998), ported from the TallMountain project.
A deterministic calculus that resolves conflicts between normative propositions
using level ordinals, operator strength, and six named axioms (Futility,
Indifference, Absolute Prohibition, Moral Priority, Moral Rank, Normative
Openness -- Becker's axioms 6.2-6.7).

The agent's character specification (`identity/character.json`) defines its
highest endeavour -- normative commitments expressed as propositions with a
level (14-tier hierarchy from EthicalMoral down to Operational), an operator
(Required, Ought, Indifferent), and a modality (Possible, Impossible).

When the output gate evaluates an autonomous delivery, the normative bridge
converts D' forecasts into normative propositions and resolves them against
the character spec. Eight floor rules in priority order produce a verdict:
**Flourishing** (accept), **Constrained** (modify), or **Prohibited** (reject).
Every verdict carries a named axiom trail.

Virtue drift detection tracks verdicts over time using a ring buffer. If
constraint or prohibition rates climb, or the same axiom fires repeatedly, the
meta observer escalates to the operator. The system never auto-adjusts its own
ethical commitments.


[Back to top](#springdrift)

---

## Introspection

The agent has 28 tools for querying its own state and history:

**Memory tools** (14): `recall_recent`, `recall_search`, `recall_threads`,
`recall_cases`, `memory_write`, `memory_read`, `memory_clear_key`,
`memory_query_facts`, `memory_trace_fact`, `store_result`, `retrieve_result`,
`how_to`, `introspect`, `cancel_agent`

**Diagnostic tools** (8): `reflect` (day-level stats: cycles, tokens, models,
gate decisions), `inspect_cycle` (drill into a specific cycle tree with tool
calls and agent output), `list_recent_cycles` (discover cycle IDs for a date),
`query_tool_activity` (per-tool usage stats), `report_false_positive` (flag
incorrect D' rejections), `complete_task_step`, `flag_risk`, `activate_task`

**Planner tools** (6): `get_active_work`, `get_task_detail`, `abandon_task`,
`create_endeavour`, `add_task_to_endeavour`, and task/step management

See also: [Sensorium](#sensorium) -- the agent's ambient self-awareness system.


[Back to top](#springdrift)

---

## Sensorium

Most agent systems are blind between tool calls. They process input, generate
output, and have no awareness of their own state unless they explicitly query
for it. Springdrift's agent perceives itself continuously.

The **sensorium** is a self-describing XML block injected into the system
prompt at the start of every cognitive cycle. The agent doesn't request it --
it's always there, like peripheral vision. It contains:

- **Clock** -- current time, session uptime, elapsed time since last cycle.
  The agent knows how long it's been running and how long since it last acted.
- **Situation** -- input source (user or scheduler), queue depth, conversation
  depth, most recent active thread. The agent knows what triggered this cycle
  and what it was working on.
- **Schedule** -- pending and overdue jobs with names and due times. The agent
  knows what's coming next.
- **Vitals** -- cycles today, active agents, agent health status, last failure
  description, remaining budget (cycles and tokens). The agent knows if
  something is degraded.
- **Delegations** -- live agent status: name, turn N/M, tokens consumed,
  elapsed time, instruction summary. The agent can see its sub-agents working.
- **Tasks** -- active planned work with steps and progress. The agent knows
  what it committed to.
- **Events** -- sensory events accumulated since last cycle (forecaster
  replan suggestions, virtue drift signals, probe degradation warnings).

Three canonical **meta-states** are computed from session counters and
injected as vitals attributes (following the System M paper, arXiv 2603.15381):

- **Uncertainty** -- proportion of cycles without CBR hits. High uncertainty
  means the agent is operating in unfamiliar territory.
- **Prediction error** -- tool failure rate combined with D'
  modification/rejection rate. High prediction error means the agent's actions
  are not going as expected.
- **Novelty** -- keyword dissimilarity between the current input and recent
  narrative entries. High novelty means this is a new kind of request.

These three signals give the agent a continuous sense of how well it
understands its current situation -- without making a single tool call or
LLM query. The meta-states are derived from counters the system already
maintains.

No other agent framework provides this. Most agents operate in a perceptual
vacuum between turns, aware only of the conversation history. Springdrift's
agent knows what time it is, what it's working on, how well things are going,
what's scheduled next, and whether its own subsystems are healthy -- every
single cycle.


[Back to top](#springdrift)

---

## Memory

Seven memory stores, all backed by append-only JSONL and indexed in ETS by
the Librarian actor:

```
Librarian (ETS query layer)
├── Narrative entries    what happened each cycle (intent, outcome, delegation chain)
│   └── Threads          ongoing topics grouping related entries
├── Facts                key-value working memory (scoped, versioned, confidence-decayed)
├── CBR cases            problem -> solution -> outcome (utility-scored, outcome-weighted)
├── Artifacts            large content on disk (web pages, extractions, 50KB truncation)
├── Tasks + Endeavours   planned work with steps, risks, forecast scores
└── DAG nodes            operational telemetry (tokens, tools, gates, agent output)
```

**Facts** have scoped lifetimes (Session, Persistent, Global), provenance
tracking (which tool/agent/cycle produced them, following the CCA paper's
Parameter Provenance Placeholders), and confidence that decays over time via
a half-life formula (inspired by SOFAI-LM's episodic memory confidence decay).

The **Curator** manages a virtual context window -- the hardest problem in
agent engineering that most frameworks leave entirely to the user. Every cycle,
the Curator assembles the system prompt from named, prioritised slots: identity
(persona + character), [sensorium](#sensorium) (clock, situation, vitals, delegations, tasks),
active threads, persistent facts, retrieved CBR cases, and working memory. Each
slot has a priority level (1=identity through 10=background). When the total
exceeds a configurable character budget, lower-priority slots are automatically
truncated or omitted -- `[OMIT IF EMPTY]` and `[OMIT IF ZERO]` rules handle
this gracefully so the agent never sees jagged formatting.

The result: the agent always has its most important context in the window, the
budget is enforced without manual intervention, and you never hit the failure
mode where stale context from 40 turns ago displaces the facts the agent needs
right now. This is not prompt engineering. It is memory management.

The **Archivist** generates narrative entries and CBR cases after each cycle
via a fire-and-forget two-phase pipeline (Reflector then Curator, per the ACE
paper).

**XStructor** makes the entire memory and safety pipeline reliable rather than
probabilistic. Every structured LLM output -- D' safety scores, narrative
entries, CBR cases, narrative summaries -- is validated against XSD schemas
with automatic retry. There is no JSON parsing from LLM responses. No regex
extraction. No repair heuristics. When the LLM produces malformed output,
XStructor retries with the validation error as feedback until it gets valid
XML or exhausts its retry budget. Five call sites, all schema-validated. This
is why the safety scores and memory entries are trustworthy -- they are
structurally guaranteed to be well-formed.


[Back to top](#springdrift)

---

## Agents

The cognitive loop delegates work to specialist agents, each a supervised OTP
process with its own react loop, tool set, and context window.

| Agent | Tools | Turns | Purpose |
|---|---|---|---|
| Planner | none | 3 | Break down complex goals into structured plans |
| Researcher | web + artifacts + builtin | 8 | Gather information via search and extraction |
| Coder | sandbox + builtin | 10 | Write and execute code in isolated Podman containers |
| Writer | builtin | 6 | Draft and edit text |
| Observer | diagnostic memory (10 tools) | 6 | Examine past activity, explain failures, identify patterns |

Agents are supervised with configurable restart strategies (Permanent, Transient,
Temporary). When an agent completes, it returns structured findings (sources,
dead ends, files touched) that feed into the DAG and narrative. Tool errors are
surfaced both in the result and in the [sensorium's](#sensorium) agent health vitals.

The **sandbox** provides isolated Podman containers for code execution with two
modes: `run_code` (scripts) and `serve` (long-lived processes with port
forwarding). Deterministic port allocation, health checks, workspace isolation.

Web tools: `web_search` (DuckDuckGo, no API key), `fetch_url` (HTTP GET).
DuckDuckGo requires no API key. Optional Brave Search integration requires
a `BRAVE_API_KEY`.

Skills follow the [agentskills.io](https://agentskills.io) open standard --
YAML frontmatter with name/description/agents, Markdown instruction body.
Skills are scoped to specific agents via the `agents:` field — the researcher
gets web-research, the coder gets code-review, the observer gets
self-diagnostic. Seven built-in skills cover delegation strategy, memory
management, planning patterns, web research, code execution, sandbox usage,
and self-diagnosis.


[Back to top](#springdrift)

---

## Interfaces

**Terminal TUI** -- three-tab interface (Chat, Log, Narrative) with
alternate-screen rendering. `gleam run` or `gleam run -- --gui tui`.

**Web GUI** -- browser-based chat with an admin dashboard (Narrative, Log,
Scheduler, Cycles tabs). D' Config panel shows gate configurations, normative
calculus status, and character spec. `gleam run -- --gui web` (default port
8080). Supports bearer token authentication via `SPRINGDRIFT_WEB_TOKEN`.

**Autonomous scheduler** -- BEAM-native task scheduling with
`process.send_after`. Profiles define recurring tasks with delivery to file or
webhook. Rate-limited (configurable cycles/hour, token budget/hour). Full output
gate evaluation (LLM scorer + normative calculus) on autonomous deliveries.


[Back to top](#springdrift)

---

## Cost management

Springdrift uses LLM tokens at multiple points: the cognitive loop, agent
delegations, query complexity classification, D' safety scoring (canary probes
+ LLM scorer), Archivist narrative generation, and XStructor validation retries.
A busy session with multiple agent delegations and safety evaluations will
consume more tokens than a simple chat. This is the cost of having memory,
safety, and learning — but every component is configurable.

**What you control:**

- **Task model vs reasoning model** -- simple queries route to a cheaper model
  (e.g. Haiku), complex queries to a reasoning model (e.g. Opus). The query
  classifier makes this automatic.
- **Max tokens per call** -- `max_tokens` caps output tokens per LLM call.
- **Max turns per cycle** -- `max_turns` limits how many react-loop iterations
  the agent takes per message (default 5).
- **Agent turn limits** -- each agent spec has its own `max_turns` (researcher 8,
  coder 10, writer 6, planner 3, observer 6). All configurable in `[agents.*]`.
- **Archivist model** -- narrative generation can use the cheaper task model
  (`archivist_model` in config).
- **D' scorer** -- the safety scorer uses the task model. Interactive sessions
  skip the LLM scorer entirely for output (deterministic rules only), saving
  those tokens. Input gate uses fast-accept for benign input (2 canary calls
  instead of 5+).
- **Scheduler rate limits** -- `max_autonomous_cycles_per_hour` (default 20) and
  `autonomous_token_budget_per_hour` (default 500,000) cap autonomous spending.
  Set either to 0 for unlimited.
- **CBR retrieval cap** -- K=4 cases maximum injected as context, preventing
  token bloat from over-retrieval.
- **Preamble budget** -- `preamble_budget_chars` (default 8000) caps the system
  prompt size. Lower-priority memory slots are truncated under budget.

The DAG tracks token usage per cycle (input + output). `reflect` shows daily
totals. The sensorium displays remaining budget in `<vitals>`. The agent can
see its own token consumption.


[Back to top](#springdrift)

---

## Persistence and recovery

Everything lives in `.springdrift/`:

```
.springdrift/
├── config.toml              Project config
├── dprime.json              D' safety gate configuration
├── identity/                Agent identity
│   ├── persona.md           First-person character text
│   ├── session_preamble.md  Dynamic session template
│   └── character.json       Normative calculus character spec
├── identity.json            Stable agent UUID
├── session.json             Conversation state
├── logs/                    System logs (date-rotated JSONL)
├── memory/
│   ├── cycle-log/           Per-cycle JSONL (requests, responses, gates, tools)
│   ├── narrative/           Narrative entries + thread index
│   ├── cbr/                 Case-Based Reasoning cases
│   ├── facts/               Key-value facts (daily-rotated)
│   ├── artifacts/           Large content (daily-rotated, 50KB truncation)
│   └── planner/             Tasks and endeavours
├── schemas/                 XStructor XSD schemas (compiled at runtime)
├── skills/                  Skill definitions + HOW_TO.md operator guide
└── scheduler/outputs/       Delivered reports
```

This directory is designed to be git-backed. All files are append-only JSONL or
plain text -- no binary formats, no database, no external state. `git commit`
after each session and you have a versioned history of every decision, every
safety evaluation, every narrative entry. `git diff` shows what the agent
learned. `git log --oneline` is a session timeline. Roll back to any commit
and the agent restarts with that state.

Cycle log rewind restores the conversation to any previous cycle. The Librarian
replays JSONL on startup to rebuild ETS indexes. Session files include version
and staleness metadata.

### Automated git backup

Enabled by default. An OTP backup actor initialises a git repo inside
`.springdrift/` and commits all state changes on a periodic timer (default
every 5 minutes). Each commit captures the delta since the last — `git log`
becomes a human-readable activity timeline.

```toml
[backup]
# enabled = true                      # On by default
# mode = "periodic"                   # "periodic" | "after_cycle" | "manual"
# interval_ms = 300000                # 5 minutes
remote_url = "git@github.com:org/springdrift-data.git"   # Recommended
# branch = "main"
```

Without a remote, the actor logs a warning on every commit — a backup that
only exists on the same disk as the data isn't a backup. Configure
`remote_url` to push to GitHub, GitLab, or any git remote for offsite safety.


[Back to top](#springdrift)

---

## Architecture

```
cognitive loop (OTP process)
├── query classifier (simple -> task model, complex -> reasoning model)
├── multi-agent supervisor (OTP supervision tree)
│   ├── planner, researcher, coder, writer, observer
│   └── restart strategies: Permanent, Transient, Temporary
├── D' safety gates
│   ├── input gate (deterministic + canary + fast-accept)
│   ├── tool gate (deterministic + LLM scorer, per-agent overrides)
│   ├── output gate (deterministic-only interactive, full scorer autonomous)
│   └── normative calculus (character spec, axiom resolution, drift detection)
├── meta observer (Layer 3b cross-cycle pattern detection)
├── memory subsystem
│   ├── Librarian (ETS query layer over all stores)
│   ├── Curator (system prompt assembly, sensorium, virtual context window)
│   └── Archivist (post-cycle narrative + CBR generation)
├── tools (~30 tools: memory, web, files, sandbox, planner, diagnostics)
├── scheduler (BEAM-native send_after tick loop, rate-limited)
└── XStructor (XML schema validation for all structured LLM output)
```

### Concurrency model

| Process | Lifetime | Role |
|---|---|---|
| Cognitive loop | App | Orchestrates agents, model switching, fallback |
| Agent processes | App | Specialist agents with own react loops |
| Think worker | Per turn | Blocking LLM call with retry + exponential backoff |
| Archivist | Per turn | Async narrative generation (spawn_unlinked) |
| Librarian | App | ETS owner, unified query layer over all memory stores |
| Curator | App | System prompt assembly from identity + memory |
| Scheduler | App | BEAM-native tick loop via `send_after` |
| Forecaster | App | Self-ticking plan health evaluator (optional) |
| Sandbox manager | App | Podman container pool with health checks |
| TUI / Web server | App | Render, input, notification dispatch |

All cross-process communication uses typed `Subject(T)` channels. No shared
mutable state, no locks. Following the
[12-Factor Agents](https://github.com/humanlayer/12-factor-agents) design
principles.


[Back to top](#springdrift)

---

## Why Gleam on the BEAM

**Type safety without ceremony.** Gleam's type system catches malformed tool
calls, missing message variants, and protocol mismatches at compile time. The
`Result` type makes error paths explicit. For agent systems where a single
unhandled error can derail a multi-step reasoning chain, this matters.

**The BEAM is the best agent runtime.** Designed for systems that run
continuously, handle failures gracefully, and manage thousands of concurrent
activities. Each agent is an OTP process with supervision and preemptive
scheduling. No garbage collection pauses. No external scheduler dependencies.
This is not concurrency bolted onto a language.

**Immutability by default.** No shared mutable state between processes. Agents
communicate through typed `Subject(T)` channels. When running multiple agents
concurrently making LLM calls, file writes, and web requests, the absence of
shared state is a prerequisite for correctness.

**LLM compatibility.** Claude writes correct Gleam reliably. The language is
small, consistent, and well-documented. Springdrift itself was largely built
with Claude Code.


[Back to top](#springdrift)

---

## Getting started

```bash
git clone https://github.com/seamus-brady/springdrift
cd springdrift
gleam build

# Set your API key (at least one provider required)
export ANTHROPIC_API_KEY=sk-ant-...

# Copy example config
cp -r .springdrift_example .springdrift

# Edit config with your provider and models
# vim .springdrift/config.toml

# Run (terminal TUI)
gleam run

# Run (web GUI on port 8080)
gleam run -- --gui web

# Resume previous session
gleam run -- --resume
```

### API keys

| Provider | Environment variable | Required for |
|---|---|---|
| Anthropic | `ANTHROPIC_API_KEY` | Default LLM provider |
| OpenAI / OpenRouter | `OPENAI_API_KEY` | Alternative LLM provider |
| Mistral | `MISTRAL_API_KEY` | Alternative LLM provider |
| Google Vertex AI | GCP service account JSON | EU data residency |
| Brave Search | `BRAVE_API_KEY` | Optional enhanced web search |
| Ollama | (local, no key) | CBR semantic embeddings (recommended) |

DuckDuckGo web search requires no API key.


[Back to top](#springdrift)

---

## Configuration

Config resolves with a three-layer merge (highest priority first):

1. CLI flags
2. `.springdrift/config.toml` (project)
3. `~/.config/springdrift/config.toml` (user)

```toml
provider        = "anthropic"
task_model      = "claude-haiku-4-5-20251001"
reasoning_model = "claude-opus-4-6"
max_tokens      = 2048
max_turns       = 5

[agent]
name = "Springdrift"

[dprime]
# normative_calculus_enabled = true  # Enabled by default

[narrative]
threading = true
```

LLM providers: `anthropic`, `openai`, `openrouter`, `mistral`, `vertex`,
`local` (Ollama), `mock` (testing).

See `.springdrift_example/config.toml` for the complete reference with every
section and default value documented.


[Back to top](#springdrift)

---

## Requirements

- Erlang/OTP 27+
- Gleam 1.9+
- An API key for at least one LLM provider
- Podman (recommended -- code execution sandbox; coder agent falls back to
  asking the operator to run code manually without it)
- Ollama (recommended -- semantic embeddings for CBR retrieval; the system
  works without it but retrieval quality is significantly reduced)

## Development

```sh
gleam build           # Compile (must be warning-free)
gleam test            # Run the test suite (1414 tests)
gleam format          # Format all source files
gleam run             # Run the application
```


[Back to top](#springdrift)

---

## Evaluation results

Empirical evaluations in [evals/](evals/). All results reproducible from
the repository.

### CBR retrieval vs RAG baseline

800 synthetic cases across 4 domains × 5 subdomains. 200 queries at three
difficulty levels (easy: core keywords, medium: mixed vocabulary, hard:
mostly shared terms). RAG baseline uses Ollama nomic-embed-text (768-dim)
with cosine similarity. K=4 following Zhou et al. (2025). Bootstrap 95% CIs
(2000 resamples).

| System | P@4 | 95% CI | MRR |
|---|---|---|---|
| Random | 0.028 | [0.018, 0.040] | 0.063 |
| CBR deterministic only | 0.620 | [0.575, 0.665] | 0.852 |
| RAG cosine similarity | 0.920 | [0.895, 0.943] | 0.978 |
| **CBR index + embedding** | **0.956** | **[0.936, 0.974]** | **0.993** |

CBR with hybrid index+embedding retrieval outperforms pure RAG (P@4 = 0.956
vs 0.920, non-overlapping 95% CIs). The inverted index provides perfect
precision on unambiguous queries (P@4 = 1.000 on easy) while embeddings
handle cross-vocabulary similarity on hard queries (P@4 = 0.883 vs RAG's
0.796).

**By difficulty:**

| System | Easy | Medium | Hard |
|---|---|---|---|
| CBR deterministic only | 0.872 | 0.588 | 0.317 |
| RAG cosine | 0.988 | 0.954 | 0.796 |
| CBR index + embedding | 1.000 | 0.971 | 0.883 |

Default retrieval weights were tuned from these results: embedding raised
from 0.10 to 0.40, recency reduced from 0.15 to 0.05. The full ablation
is in [evals/experiment-3/REPORT.md](evals/experiment-3/REPORT.md).

### Normative calculus completeness

Exhaustive verification over the full input space: 14 levels × 3 operators
× 2 modalities = 84 normative propositions, all 7,056 ordered pairs tested.

| Property | Result |
|---|---|
| Coverage | 100% (7,056/7,056 pairs) |
| Totality | Verified (every pair produces a result) |
| Determinism violations | 0 |
| Monotonicity violations | 0 |
| Rules fired | 8/8 |
| Floor rules correct | 8/8, priority ordering 2/2 |

The calculus is total, deterministic, and complete — a mathematical proof,
not a statistical sample.

Full methodology and per-query results in [evals/](evals/).

[Back to top](#springdrift)

---

## Background reading

The full theoretical lineage, prototype history, and paper-by-paper mapping
is documented in [docs/background/references.md](docs/background/references.md).

Key references:

- Beach, L. R. (2010). *The Psychology of Narrative Thought*. Xlibris.
- Sloman, A. (2001). Beyond shallow models of emotion. *Cognitive Processing*, 2(1), 177-198.
- Becker, L. C. (1998). *A New Stoicism*. Princeton University Press.
- Aamodt, A., & Plaza, E. (1994). Case-based reasoning: Foundational issues. *AI Communications*, 7(1), 39-59.
- Bruner, J. (1991). The narrative construction of reality. *Critical Inquiry*, 18(1), 1-21.
- Schank, R. C. (1982). *Dynamic Memory*. Cambridge University Press.
- Zhou, H. et al. (2025). Memento. [arXiv:2508.16153](https://arxiv.org/abs/2508.16153)
- Zhang, Z. et al. (2025). ACE. [arXiv:2510.04618](https://arxiv.org/abs/2510.04618)
- Dupoux, E., LeCun, Y., & Malik, J. (2026). System M. [arXiv:2603.15381](https://arxiv.org/abs/2603.15381)
- HumanLayer. [12-Factor Agents](https://github.com/humanlayer/12-factor-agents).
