# Springdrift

A prototype knowledge worker agent that checks data and generates reports on a
schedule. Built in [Gleam](https://gleam.run) on the Erlang/OTP runtime.

Springdrift is an experiment in building autonomous research agents with
safety gates and persistent memory. It runs scheduled queries, scores each
action against configurable safety dimensions before execution, and maintains
an immutable narrative log that gives the agent continuity across runs -- and
gives you a complete audit trail of what it did and why.

---

## Table of Contents

- [What it does](#what-it-does)
- [Quickstart](#quickstart)
- [Configuring a profile](#configuring-a-profile)
- [Delivery options](#delivery-options)
- [D-prime safety system](#d-prime-safety-system)
- [Prime Narrative -- explainable memory](#prime-narrative----explainable-memory)
- [Why Gleam on the BEAM](#why-gleam-on-the-beam)
- [Architecture](#architecture)
- [Interactive mode](#interactive-mode)
- [Configuration](#configuration)
- [Requirements](#requirements)
- [Development](#development)
- [License](#license)

---

## What it does

Define a profile with one or more scheduled research queries. Springdrift runs
each query on its interval, routes it through the appropriate model (simple
queries get a fast model, complex ones get a reasoning model), evaluates safety
before executing any tools, and delivers the result to a file or webhook.

Between runs, the agent remembers what it found. The narrative threading system
links related research cycles into conversations, so a Monday property market
report knows what Tuesday's report said -- and flags when data points change.

## Quickstart

```bash
# Clone and build
git clone https://github.com/seamus-brady/springdrift
cd springdrift
gleam build

# Set your API key
export ANTHROPIC_API_KEY=sk-ant-...

# Run interactively
gleam run

# Copy the example config to get started
cp -r .springdrift_example .springdrift

# Run with the example profile
gleam run -- --profile market-monitor
```

## Configuring a profile

Profiles are TOML files that define what to research, how often, and where to
deliver results. See `.springdrift_example/profiles/market-monitor/config.toml` for a working example.

A minimal profile:

```toml
[profile]
name = "my-monitor"

[agent]
system_prompt = "You are a research analyst."
model = "claude-sonnet-4-5"

[[jobs]]
name = "daily-check"
query = "Latest news on quantum computing funding rounds."
interval = "24h"

[jobs.delivery]
type = "file"
directory = "./reports"
format = "markdown"
```

## Delivery options

**File** -- writes markdown or JSON to a local directory.

```toml
[jobs.delivery]
type = "file"
directory = "./reports"
format = "markdown"  # or "json"
```

**Webhook** -- POSTs a JSON payload to any HTTP endpoint.

```toml
[jobs.delivery]
type = "webhook"
url = "https://your-endpoint.com/reports"
method = "POST"

[[jobs.delivery.headers]]
name = "Authorization"
value = "Bearer YOUR_TOKEN"
```

---

## D-prime safety system

Every proposed agent action passes through a safety gate before execution.
The system is based on two bodies of academic work:

**The Psychology of Narrative Thought** (Beach, 2010). Lee Roy Beach's theory
of narrative thought models human decision-making as a screening process: new
options are tested for compatibility against existing standards (the "value
image") rather than optimised across all alternatives. An option that violates
any standard is rejected without further analysis. Springdrift adopts this as
the D' (D-prime) discrepancy score -- a weighted sum of how far an action
deviates from the agent's configured standards. Actions below a threshold
pass; those above are modified or rejected.

**H-CogAff architecture** (Sloman, 2001; Sloman & Chrisley, 2003). Aaron
Sloman's H-CogAff framework describes a three-layer cognitive architecture:
reactive (fast, automatic responses), deliberative (slower, model-based
reasoning), and meta-management (self-monitoring and adaptation). Springdrift's
safety gate runs these three layers in sequence:

1. **Reactive** -- canary probes check for prompt injection and data leakage
   using fresh random tokens. Critical features (e.g. user safety) trigger
   immediate rejection.
2. **Deliberative** -- the full D' score is computed across all features with
   importance weighting. The LLM scores each feature's magnitude (0-3) against
   calibration examples.
3. **Meta-management** -- a sliding window tracks recent D' scores. If scores
   stall above the modify threshold, the system tightens thresholds to escalate
   borderline cases.

### Configuration

Copy `.springdrift_example/dprime.example.json` and adjust thresholds to your risk tolerance:

```json
{
  "features": [
    { "name": "accuracy", "importance": "high", "critical": true },
    { "name": "legal_compliance", "importance": "high", "critical": true },
    { "name": "privacy", "importance": "medium", "critical": false }
  ],
  "modify_threshold": 1.2,
  "reject_threshold": 2.0
}
```

Features marked `"critical": true` cause immediate rejection if they trigger,
regardless of the aggregate score. Non-critical features contribute to the
weighted sum compared against `modify_threshold` and `reject_threshold`.

### References

- Beach, L. R. (2010). *The Psychology of Narrative Thought: How the Stories We Tell Ourselves Shape Our Lives*. Xlibris.
- Sloman, A. (2001). Beyond shallow models of emotion. *Cognitive Processing*, 2(1), 177-198.
- Sloman, A., & Chrisley, R. (2003). Virtual machines and consciousness. *Journal of Consciousness Studies*, 10(4-5), 133-172.

---

## Prime Narrative -- explainable memory

The Prime Narrative system gives the agent persistent, structured memory across
research cycles. It draws on ideas from narrative cognition research:

**Narrative as cognition** (Bruner, 1991; Beach, 2010). Jerome Bruner argued
that humans organise experience primarily through narrative -- constructing
stories that link events by causality, intention, and temporal sequence rather
than by logical categorisation. Beach extended this into decision theory with
his "narrative image", where past decisions form a story that constrains future
ones. Springdrift's narrative log makes this explicit: every cycle is recorded
as a structured entry with intent, outcome, entities, data points, and
confidence scores.

**Threading and continuity.** Related research cycles are automatically grouped
into threads using overlap scoring across locations (weight 3), domains
(weight 2), and keywords (weight 1). When a new cycle joins an existing thread,
the system generates a continuity note comparing data points across cycles --
flagging when values have changed. This gives the agent temporal context that
pure chat history cannot provide.

Each entry records:

- Intent classification and domain
- Entities extracted (locations, organisations, data points)
- Outcome status and confidence
- Thread assignment and continuity notes
- Delegation chain (which sub-agents contributed)
- Performance metrics (tokens, duration, model used)

### Explainability

The narrative log serves as a complete audit trail. Every research cycle
produces a human-readable record of what the agent did, what it found, how
confident it was, and which thread of ongoing work it belongs to. Combined
with D-prime's per-feature safety scores and rationales, the system provides
end-to-end explainability from input to output.

### References

- Bruner, J. (1991). The narrative construction of reality. *Critical Inquiry*, 18(1), 1-21.
- Beach, L. R. (2010). *The Psychology of Narrative Thought: How the Stories We Tell Ourselves Shape Our Lives*. Xlibris.
- Schank, R. C., & Abelson, R. P. (1995). Knowledge and memory: The real story. In R. S. Wyer (Ed.), *Advances in Social Cognition*, Vol. 8 (pp. 1-85). Lawrence Erlbaum.

---

## Memory architecture

The agent has five memory stores that work together to give it continuity,
self-awareness, and the ability to learn from experience.

```
Librarian (ETS query layer)
├── Narrative entries    what happened each cycle (append-only JSONL)
│   └── Threads          ongoing topics grouping related entries
├── Facts                explicit key-value working memory (scoped, versioned)
├── CBR cases            problem → solution → outcome patterns
├── Artifacts            large content on disk (web pages, extractions)
└── DAG nodes            operational telemetry (tokens, tools, gates, agent output)
```

**Narrative entries** are the atomic unit -- one per cognitive cycle, recording
intent, outcome, entities, delegation chain, and confidence. **Threads** group
related entries by overlap scoring across locations, domains, and keywords.
**Facts** are things the agent explicitly stores and retrieves (e.g. "Dublin
average rent = €2,340"). **CBR cases** capture reusable patterns so the agent
can learn from past approaches. **Artifacts** store large web content on disk
with compact IDs, keeping agent context windows lean. **DAG nodes** track every
cycle's operational data in a parent-child tree.

The **Librarian** actor owns ETS tables indexing all six stores and serves as
the unified query layer. The **Curator** assembles the system prompt from
identity files and memory counts. The **Archivist** generates narrative entries
and CBR cases after each cycle via fire-and-forget LLM calls.

Fourteen memory tools let the agent query its own memory: `recall_recent`,
`recall_search`, `recall_threads`, `recall_cases`, `memory_write`,
`memory_read`, `memory_clear_key`, `memory_query_facts`,
`memory_trace_fact`, `reflect`, `inspect_cycle`, `list_recent_cycles`,
`query_tool_activity`, and `introspect`. Two additional artifact tools
(`store_result`, `retrieve_result`) let the researcher agent offload large
content to disk and retrieve it by ID.

---

## Agent subsystem

The cognitive loop delegates work to specialist agents, each running as a
supervised OTP process with its own react loop and tool set.

| Agent | Tools | Turns | Purpose |
|---|---|---|---|
| Planner | none | 3 | Break down complex goals into structured plans |
| Researcher | web + artifacts + builtin | 8 | Gather information via search and extraction |
| Coder | builtin | 10 | Write and modify code |
| Writer | builtin | 6 | Draft and edit text |

Agents are managed by a supervisor with restart strategies (Permanent,
Transient, Temporary). Lifecycle events are forwarded to the TUI/web GUI.
When an agent calls `request_human_input`, the question routes through the
cognitive loop to the user.

Profiles configure which agents are available and how they're wired. A profile
is a directory with `config.toml` (agent roster, models), optional `dprime.json`
(safety config), `schedule.toml` (recurring tasks), and a `skills/` directory.

---

## Why Gleam on the BEAM

Gleam is a particularly good fit for building AI agent systems, for reasons
that compound:

**Type safety without ceremony.** Gleam's type system catches entire
categories of agent bugs at compile time -- malformed tool calls, missing
message variants, protocol mismatches between processes. The `Result` type
makes error paths explicit. There are no runtime type errors, no `undefined
is not a function`. For agent systems where a single unhandled error can
derail a multi-step reasoning chain, this matters enormously.

**The BEAM is the best agent runtime.** Erlang's virtual machine was designed
for systems that must run continuously, handle failures gracefully, and manage
thousands of concurrent activities -- which is exactly what an agent
orchestrator does. Each agent is an OTP process. If one crashes, its supervisor
restarts it. The scheduler preemptively time-slices across agents without
cooperative yielding. `process.send_after` gives you cron-like scheduling
with microsecond precision and zero external dependencies. There is no
garbage collection pause that freezes all agents simultaneously. This is not
concurrency bolted onto a language -- it is the runtime.

**LLM compatibility.** Claude is exceptionally good at writing Gleam. The
language is small (the entire syntax fits on one page), consistent (no
special cases or legacy baggage), and well-documented. This means an LLM
can generate correct Gleam code reliably, which matters both for the agent's
own tool use and for the development process. Springdrift itself was largely
built with Claude Code.

**Immutability by default.** All data in Gleam is immutable. There is no
shared mutable state between processes. This eliminates data races by
construction -- agents communicate through typed message channels
(`Subject(T)`) and nothing else. When you are running multiple agents
concurrently making LLM calls, file writes, and web requests, the absence
of shared state is not a nice-to-have. It is a prerequisite for
correctness.

**Small binaries, fast startup.** A compiled Springdrift release is a
self-contained BEAM package. Startup time is measured in milliseconds.
There is no container to build, no interpreter to warm up, no dependency
tree to resolve at runtime.

---

## Architecture

```
cognitive loop
├── query classifier (simple -> task model, complex -> reasoning model)
├── multi-agent supervisor (OTP)
│   └── named agents with typed specs, tool sets, restart strategies
├── tools
│   ├── web_search (DuckDuckGo, no API key required)
│   └── fetch_url (HTTP GET with scheme validation)
├── D-prime safety gate (reactive -> deliberative -> meta-management)
├── narrative memory (.springdrift/memory/narrative/)
└── scheduler
    ├── persistent job state (JSON checkpoint)
    └── delivery (file, webhook)
```

### Concurrency model

| Process | Lifetime | Role |
|---|---|---|
| TUI event loop | App | Render, raw stdin, message dispatch |
| Cognitive loop | App | Orchestrates agents, model switching, fallback |
| Agent processes | App | Specialist agents with own react loops |
| Think worker | Per turn | Blocking LLM call with retry + backoff |
| Archivist | Per turn | Async narrative generation (spawn_unlinked) |
| Scheduler | App | BEAM-native tick loop via `send_after` |

All cross-process communication uses typed `Subject(T)` channels. No shared
mutable state, no locks.

---

## Interactive mode

Springdrift also works as a terminal chatbot with a three-tab TUI (Chat, Log,
Narrative). Use it for ad-hoc research or to interact with running profiles.

```bash
gleam run                      # Start interactive TUI
gleam run -- --resume          # Resume previous session
gleam run -- --gui web         # Start web GUI on port 8080
gleam run -- --dprime          # Enable D' safety evaluation
```

### TUI keyboard shortcuts

| Key | Action |
|---|---|
| Enter | Send message |
| Tab | Cycle tabs: Chat -> Log -> Narrative |
| PgUp / PgDn | Scroll message history |
| Ctrl-C | Exit |

---

## Configuration

All runtime data lives under `.springdrift/` in the project root:

```
.springdrift/
├── config.toml          Project config
├── identity/            Agent identity files
│   ├── persona.md       First-person character text ({{agent_name}} slot)
│   └── session_preamble.md  Dynamic session template ({{slot}} + [OMIT IF])
├── identity.json        Stable agent UUID (auto-generated)
├── session.json         Session persistence (auto-generated)
├── logs/                System logs (date-rotated JSON-L)
├── memory/
│   ├── cycle-log/       Per-cycle request/response logs
│   ├── narrative/       Prime Narrative memory (JSON-L + thread index)
│   ├── cbr/             Case-Based Reasoning cases
│   ├── facts/           Key-value fact store (daily-rotated JSON-L)
│   └── artifacts/       Large content store (daily-rotated JSON-L)
├── skills/              Local skill definitions
└── profiles/            Agent profile directories
```

Copy `.springdrift_example/` to `.springdrift/` to get started. Add `.springdrift/`
to your `.gitignore` — it contains runtime state and logs.

### Agent identity

Every Springdrift instance gets a stable UUID persisted in `.springdrift/identity.json`.
This gives the narrative corpus first-person continuity across sessions.

The `identity/` directory contains two files assembled into the system prompt by the
Curator actor:

- **`persona.md`** — fixed first-person character text. The `{{agent_name}}` slot is
  replaced with the value from `[agent] name` in config.
- **`session_preamble.md`** — dynamic template populated each turn with memory counts,
  thread summaries, performance stats, and agent health. Uses `[OMIT IF ZERO]` /
  `[OMIT IF EMPTY]` rules to hide empty sections.

Identity files are searched in order: `.springdrift/identity/` then
`~/.config/springdrift/identity/`.

### Config file

Config is resolved with a three-layer merge (highest priority first):

1. CLI flags
2. `.springdrift/config.toml` (project directory)
3. `~/.config/springdrift/config.toml` (user directory)

```toml
provider        = "anthropic"
task_model      = "claude-haiku-4-5-20251001"
reasoning_model = "claude-opus-4-6"
max_tokens      = 2048
max_turns       = 5
log_verbose     = false

# Agent identity
[agent]
name    = "Springdrift"
version = ""

# D' safety system
dprime_enabled = false
dprime_config  = "dprime.json"

# Prime Narrative
[narrative]
threading        = true
summaries        = false
summary_schedule = "weekly"
# max_days       = 30          # Days of history replayed into ETS at startup
```

## Requirements

- Erlang/OTP 26+
- Gleam 1.5+
- An Anthropic API key (or configure a different provider via the LLM adapter)

## Development

```sh
gleam build           # Compile
gleam test            # Run the test suite (~800 tests)
gleam format          # Format all source files
gleam run             # Run the application
```

## License

MIT
