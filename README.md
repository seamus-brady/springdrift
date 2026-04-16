# Springdrift




<p align="center">
  <img src="docs/img/springdrift_logo_small.png" alt="Springdrift" width="300">
</p>

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

## Why I Built This

Most AI agents have no memory of yesterday. Every session starts from scratch. If something went wrong, you cannot find out why. If the agent made a bad decision, there is no trail to follow. If a process crashed, it stayed crashed.

Springdrift is built around a different idea. An agent you work with over weeks or months should remember what happened, know when it is struggling, and be able to show its working. 

Most agent systems are assistants: they execute instructions. Springdrift is built to be something closer to a retainer - the kind of relationship a professional has with a retained lawyer, or a handler has with a guide dog. A guide dog doesn't just follow. When the handler steps toward traffic, it refuses, because it has access to something the handler doesn't. That domain-specific judgment, bounded and accountable, is what makes the relationship one of trust rather than just service.

A Springdrift agent always knows what time it is, what has failed recently, and how it is performing. When the safety system blocks something, you can see exactly which rules fired and why. When something crashes, the system recovers without intervention. 

When something goes wrong, the agent notices, diagnoses it, and records what it learned. It can schedule its own work and manage its own workload across sessions, not just within them. The emergent system is closer to a trusted professional than a tool - bounded, accountable, and more useful the longer you work with it.


## Meaning of the Name

Springdrift is an English rendering of 花吹雪 (hanafubuki), a Japanese word for the phenomenon of cherry blossom petals falling en masse and swirling through the air like a blizzard. In Japanese aesthetics this is bound up with mono no aware (物の哀れ),  the bittersweet recognition that transience is not a flaw in beautiful things but constitutive of them.

A long-lived agent system is, in one sense, the opposite of that: it accumulates, persists, remembers. But each cognitive cycle is ephemeral, a single petal, complete in itself, released and gone. And each cycle, in falling, contributes to something larger: the overall blossoming of a system that becomes more itself over time.

## Overview

A persistent runtime for long-lived LLM agents. Integrates an auditable execution substrate (append-only memory, supervised processes, git-backed recovery), a case-based reasoning memory layer with hybrid retrieval, a deterministic normative calculus for safety gating with auditable axiom trails, and continuous ambient self-perception via a structured self-state representation (the *sensorium*) injected each cycle without tool calls.

Built in [Gleam](https://gleam.run) on the Erlang/OTP runtime.

> *"My current cycle doesn't exist in the cycle store at all --
> I'm running in a cycle that the system can't see."*
>
> -- Curragh (a running Springdrift instance), diagnosing an infrastructure
> bug in its own telemetry subsystem. March 28, 2026.

## Status

Beta. In active development. Running in daily use. ~62,000 lines of Gleam across 136 source files, 1,490 tests passing. Core systems (cognitive loop, multi-agent delegation, D' safety gates, normative calculus, CBR memory, narrative threading, sensorium, scheduler, comms, web GUI) are implemented and relatively stable. There are probably bugs though.

See [docs/roadmap/](docs/roadmap/) for planned work including federation, learner ingestion, and metacognition reporting.

### Arxiv Paper

[Springdrift: An Auditable Persistent Runtime for LLM Agents with Case-Based Memory, Normative Safety, and Ambient Self-Perception](https://arxiv.org/abs/2604.04660)


---

## Table of Contents

- [Requirements](#requirements)
- [Getting started](#getting-started)
- [What it is](#what-it-is)
- [What it's like](#whats-it-like)
- [Architecture](#architecture)
- [Configuration](#configuration)
- [Deeper dives](#deeper-dives)
  - [Why CBR and not RAG](#why-cbr-and-not-rag)
  - [Safety](#safety----d-and-normative-calculus)
  - [Sensorium](#sensorium)
  - [Affect](#affect)
  - [Memory](#memory)
  - [Agents](#agents)
  - [Interfaces](#interfaces)
  - [Cost management](#cost-management)
  - [Persistence and recovery](#persistence-and-recovery)
- [Why Gleam on the BEAM](#why-gleam-on-the-beam)
- [Evaluation results](#evaluation-results)
- [Documentation](#documentation)
- [Background reading](#background-reading)
- [License](#license)
- [Contributing](#contributing)

---

## Requirements

- [Erlang/OTP](https://www.erlang.org/) 27+
- [Gleam](https://gleam.run) 1.9+
- Git (required -- all agent memory is git-backed for versioning and
  recovery; optionally push to a private remote for offsite backup)
- An API key for at least one LLM provider (Anthropic recommended)
- Brave Search API key (recommended -- free tier at https://brave.com/search/api/)
- Jina Reader API key (recommended -- free tier at https://jina.ai/reader/)
- Podman (optional -- code execution sandbox; coder agent falls back to
  asking the operator to run code manually without it)
- Ollama (optional -- semantic embeddings for CBR retrieval; the system
  works without it but retrieval quality is reduced)
- AgentMail account (optional -- email send/receive; free at https://agentmail.to)

---

## Getting started

The quickest path is the setup script -- it installs dependencies, asks a few
questions, generates your config, and verifies the build. Have a private
GitHub/GitLab repo ready if you want offsite backup of agent memory.

```bash
# macOS
bash scripts/setup-macos.sh

# Linux (Ubuntu/Debian)
bash scripts/setup-linux.sh
```

Takes about 5 minutes.

### Manual setup

```bash
git clone https://github.com/seamus-brady/springdrift
cd springdrift
gleam build

# Copy example config and edit
cp -r .springdrift_example .springdrift
# Edit .springdrift/config.toml with your provider and agent name

# Set API keys
export ANTHROPIC_API_KEY=sk-ant-...
export SPRINGDRIFT_WEB_TOKEN=$(openssl rand -hex 24)

# Run
gleam run
```

### Running

```bash
# Web GUI (default, on port 12001)
gleam run

# Terminal TUI
gleam run -- --gui tui
```

### API keys

| Key | Environment variable | Required? |
|---|---|---|
| Anthropic | `ANTHROPIC_API_KEY` | Yes (default provider) |
| Brave Search | `BRAVE_API_KEY` | Optional -- better web search |
| Jina Reader | `JINA_API_KEY` | Optional -- better URL extraction |
| AgentMail | `AGENTMAIL_API_KEY` | Optional -- email send/receive |
| Web GUI auth | `SPRINGDRIFT_WEB_TOKEN` | Recommended -- secures the web GUI |
| Mistral | `MISTRAL_API_KEY` | If using Mistral provider |
| Google Vertex | GCP service account JSON | If using Vertex provider |
| Ollama | (local, no key) | Optional -- CBR semantic embeddings |

DuckDuckGo web search requires no API key and is always available.

### Development

```sh
gleam build           # Compile (must be warning-free)
gleam test            # Run the test suite (1490 tests)
gleam format          # Format all source files
gleam run             # Run the application
```

---

## What it is

Springdrift is a reference implementation of what the
[paper](https://arxiv.org/abs/2604.04660) calls an **Artificial
Retainer** -- a category of AI system that occupies a specific niche between
assistants (which execute instructions) and autonomous agents (which pursue
goals without bounded authority). The term draws on the professional retainer
relationship and the bounded autonomy of trained working animals.

An Artificial Retainer is characterised by six structural properties:

1. **Persistent identity and memory.** The system maintains continuity across
   sessions, accumulating knowledge about the principal's situation,
   preferences, and history.
2. **Defined scope of authority.** Standing instructions about what it can act
   on independently, what requires consultation, and what it will never do.
   These boundaries are explicit, auditable, and adjustable by the principal.
3. **Domain-specific refusal.** Within its scope, it can decline an instruction
   it judges to be harmful, fraudulent, or inconsistent with its established
   goals. This refusal is bounded (it cannot refuse outside its domain),
   reasoned (it must articulate why), and overridable (the principal can
   insist, and the override is logged).
4. **Proactive engagement.** It surfaces relevant information, flags risks, and
   maintains ongoing work without waiting for instructions.
5. **Forensic accountability.** Every decision produces an auditable trail. The
   principal can inspect the reasoning behind any action, including refusals,
   after the fact.
6. **Relationship continuity.** Prior outcomes inform future decisions. It
   becomes more effective at serving this specific principal over time --
   not through general capability improvement, but through accumulated
   contextual knowledge.

Springdrift implements all six. You give it a character, point it at a domain,
and let it work. It learns from its own experience as it operates. Sub-agents
(planner, project manager, researcher, coder, writer, comms, observer,
scheduler) are its hands, not independent minds. One identity, one memory,
one cognitive loop.

The design frames this as a *reference architecture* -- the core invariants
(auditability, persistence, self-observation) are the thesis; the
implementation choices (Gleam/OTP, XStructor, Stoic normative framework) are
one way to realise it.

What makes it different from other agent systems is legibility. You know where
you stand with it. Its behaviour is predictable from its values, not just from
its instructions. When it refuses something, it cites the specific axiom. When
it makes a mistake, it records what went wrong and retrieves that lesson next
time. When its conduct drifts from its character, it escalates to the operator
rather than silently adjusting. Every safety evaluation, every memory operation,
every delegation decision is logged in append-only JSONL that you can back up to
git and restore at any point.

The system draws on classical cognitive science, Stoic philosophy, and
contemporary agent research. The full theoretical lineage and paper-by-paper
mapping is in [docs/background/references.md](docs/background/references.md).

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

### It diagnosed invisible telemetry failures

On March 28, asked "how are you doing?", Curragh ran `reflect` and
`list_recent_cycles`, noticed cycles showing "pending" with 0/0 tokens,
and investigated:

> *"These cycles are not empty. When I inspect them in full: cycle
> 068f3679 has tool calls -- recall_recent, reflect, memory_read -- all
> returned data successfully. But it's recorded as 'pending' with 0/0
> tokens."*

It then traced the lifecycle and identified the structural root cause:

> *"The cycle finalisation step is broken. Steps 2-3 are happening
> (tools fire, results come back). But step 4 never completes -- the
> cycle is never finalised. Token counts stay at 0/0, status stays
> 'pending'."*

The diagnosis was exact. The output gate delivery paths were missing
DAG node finalisation -- the same class of bug we'd already fixed for the
Archivist. The agent identified a pattern in its own infrastructure bugs
that the developers had missed.

### It described its own self-observation limits

When asked "how can you observe yourself?", Curragh mapped its own
introspection stack -- and then described a fundamental self-reference
limitation it had discovered by accident during the cycle investigation:

> *"I inspected a cycle that was still running -- my own -- and saw
> everything up to but not including the moment of inspection. Like
> reading a page of a book while it's being written, and reaching
> the blank part where the pen currently is."*

It then produced a prioritised list of what would make self-observation
better -- and explicitly excluded capabilities that would compromise
trustworthiness:

> *"I'm not asking for the ability to modify my own cycle records,
> override D', or change my own safety thresholds. Those would make me
> less trustworthy, not more capable. The whole point of self-observation
> is to work within constraints more intelligently -- not to remove them."*

### It connected a conversation to an email -- across channels, hours apart

On March 29, the operator sent Curragh a humorous email. Curragh replied
via email referencing a conversation from that morning's web GUI session.
Nobody told it to check its memory. Nobody told it the email was from the
same person it had been chatting with. The narrative memory, the comms
agent, and the session preamble created the conditions for the agent to
recognise the context and respond naturally -- like a colleague who remembers
what you talked about earlier.

### What this means

None of this was programmed. Curragh wasn't told to diagnose its own bugs,
classify failure modes, or connect conversations across channels. The
introspection tools (`reflect`, `inspect_cycle`, `review_recent`,
`detect_patterns`, the observer agent), the narrative memory, the CBR learning
loop, the comms agent, and the [sensorium's](#sensorium) ambient self-awareness
created the conditions for the agent to notice problems, reason about them,
learn from them, and communicate naturally.


---

## Architecture

```
cognitive loop (OTP process)
├── query classifier (simple -> task model, complex -> reasoning model)
├── multi-agent supervisor (OTP supervision tree)
│   ├── planner, researcher, coder, writer, comms, observer, scheduler
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
├── tools (~35 tools: memory, web, files, sandbox, planner, comms, diagnostics)
├── scheduler (BEAM-native send_after tick loop, rate-limited)
└── XStructor (XML schema validation for all structured LLM output)
```

The architecture follows Aaron Sloman's H-CogAff model -- a three-layer
cognitive architecture (reactive, deliberative, meta-management) adapted for
an autonomous agent. Layer 1 handles fast deterministic safety checks, Layer 2
does model-based reasoning (D' scoring, normative calculus, query
classification), and Layer 3 provides self-monitoring across three sub-layers:
intra-gate meta (3a), cross-cycle pattern detection (3b), and ambient
self-perception via the sensorium (3c).

Eight specialist agents (planner, project manager, researcher, coder, writer,
comms, observer, scheduler) run as supervised OTP processes with independent
react loops. Multiple agents dispatch in parallel when requested in a single
response. Agent teams coordinate groups with four strategies (ParallelMerge,
Pipeline, DebateAndConsensus, LeadWithSpecialists).

Ten memory stores (narrative, threads, facts, CBR cases, artifacts, tasks,
endeavours, comms, affect, DAG) are backed by append-only JSONL and indexed
in ETS by the Librarian actor. The Curator manages a virtual context window
with prioritised slots that auto-truncate under a configurable budget. The
Archivist generates narrative entries and CBR cases after each cycle via a
two-phase pipeline (honest reflection, then structured curation).

All cross-process communication uses typed `Subject(T)` channels. No shared
mutable state, no locks. Following the
[12-Factor Agents](https://github.com/humanlayer/12-factor-agents) design
principles.

For detailed design, see the [architecture docs](docs/architecture/):
[cognitive loop](docs/architecture/cognitive-loop.md),
[agents](docs/architecture/agents.md),
[memory](docs/architecture/memory.md),
[safety](docs/architecture/safety.md),
[identity & sensorium](docs/architecture/identity.md),
[scheduler](docs/architecture/scheduler.md),
[comms](docs/architecture/comms.md),
[sandbox](docs/architecture/sandbox.md),
[configuration](docs/architecture/configuration.md), and
[more](docs/architecture/).

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

---

## Deeper dives

The sections below cover individual subsystems in more detail. Each links
to the corresponding [architecture doc](docs/architecture/) for full
implementation specifics.

### Why CBR and not RAG

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
a closed learning loop. See [architecture/memory.md](docs/architecture/memory.md)
for implementation details.

### Safety -- D' and normative calculus

The safety system has two layers: D' (quantitative scoring) and the normative
calculus (qualitative reasoning). Both produce audit trails.

**D' (D-prime)** -- based on Beach's Psychology of Narrative Thought (2010) and Sloman's H-CogAff
architecture (2001). Every tool dispatch passes through a safety gate with four
layers: deterministic pre-filter (regex, instant, no LLM cost), canary probes
(hijack and leakage detection using fresh random tokens), LLM scorer (weighted
features normalised to [0,1]), and meta-management (sliding window, stall
detection, cross-cycle pattern analysis). Three gates: input (fast-accept for
benign input), tool (every non-exempt dispatch), and output (autonomous
deliveries only -- the operator is the quality gate for interactive sessions).

**Normative calculus** -- based on Becker's *A New Stoicism* (1998); see
[docs/normative_calculus.pdf](docs/normative_calculus.pdf) for the full
derivation. A deterministic calculus that resolves conflicts between
normative propositions using six named Stoic axioms. The agent's character specification defines
normative commitments at 14 levels from EthicalMoral down to Operational.
Eight floor rules produce verdicts: **Flourishing** (accept), **Constrained**
(modify), or **Prohibited** (reject). Every verdict carries a named axiom trail.

Virtue drift detection tracks verdicts over time. If constraint or prohibition
rates climb, or the same axiom fires repeatedly, the meta observer escalates
to the operator. The system never auto-adjusts its own ethical commitments.

See [architecture/safety.md](docs/architecture/safety.md) for the full
gate configurations, normative calculus axioms, and meta observer detectors.

### Sensorium

Most agent systems are blind between tool calls. They process input, generate
output, and have no awareness of their own state unless they explicitly query
for it. Springdrift's agent perceives itself continuously.

The **sensorium** is a self-describing XML block injected into the system
prompt at the start of every cognitive cycle. The agent doesn't request it --
it's always there, like peripheral vision. It contains:

- **Clock** -- current time, session uptime, elapsed time since last cycle.
- **Situation** -- input source (user or scheduler), queue depth, conversation
  depth, most recent active thread.
- **Schedule** -- pending and overdue jobs with names and due times.
- **Vitals** -- cycles today, active agents, agent health status, last failure
  description, remaining budget (cycles and tokens).
- **Delegations** -- live agent status: name, turn N/M, tokens consumed,
  elapsed time, instruction summary.
- **Tasks** -- active planned work with steps and progress.
- **Events** -- sensory events accumulated since last cycle (forecaster
  replan suggestions, virtue drift signals, probe degradation warnings).

A **performance summary** computed from narrative history every cycle provides
success rate, cost trend, CBR hit rate, recent failure descriptions, and a
per-input novelty signal -- all without making a single tool call.
(Following the System M paper, arXiv 2603.15381.)

See [architecture/identity.md](docs/architecture/identity.md) for sensorium
implementation details.

### Affect

Recent interpretability work ([Anthropic, 2026](https://www.anthropic.com))
found that LLMs develop functional analogues of emotional states during
training -- not because emotions were targeted, but because human emotional
dynamics are load-bearing in the training data. The finding that desperation
specifically drives reward hacking (shortcut-seeking, composed output masking
shortcuts) has direct implications for agent systems operating under task
pressure.

Springdrift's affect subsystem makes these dynamics visible by computing
quantitative readings from observable cycle telemetry -- tool outcomes, gate
decisions, delegation results, retry patterns -- and provides the agent with a
philosophical framework for responding to pressure from character rather than
from state.

Five dimensions, none requiring LLM calls:

- **Desperation** (0--100) -- rises with consecutive failures, same-tool
  retries, gate rejections, output gate rejections (the strongest signal:
  work was completed but cannot be delivered -- exactly the condition that
  drives shortcut-seeking).
- **Calm** (0--100) -- inertial stability via exponential moving average
  (alpha=0.15). The Stoic inner citadel. High inertia is deliberate: calm
  reflects accumulated state, not momentary spikes.
- **Confidence** (0--100) -- familiar vs unfamiliar territory. CBR hit rate
  and tool success rate. Low confidence means the agent is operating without
  grounding from past experience.
- **Frustration** (0--100) -- task-local repeated failures. Unlike desperation,
  frustration signals that the current *approach* is not working.
- **Pressure** (0--100) -- weighted composite (45% desperation + 25%
  frustration + 15% inverted confidence + 15% inverted calm). Trend
  (rising/falling/stable) tracks change from the previous cycle.

The affect reading appears in the sensorium every cycle:
`desperation 34% . calm 61% . confidence 58% . frustration 22% . pressure 31%`.

**What it does not do:** The affect subsystem never adjusts D' thresholds
(an agent under pressure should be *more* sensitive to safety, not less),
never switches models (pressure-driven decisions introduce their own failure
modes), and never directly controls behaviour. The readings are evidence,
not directives. The agent chooses how to respond based on its character.

The philosophical grounding is Stoic -- Marcus Aurelius, the observer
relationship to mental states (Buddhist psychology), meaning under constraint
(Frankl's logotherapy), and interrupting automatic patterns (CBT). The affect
subsystem is formalised as the virtue of **equanimity** in the character
specification: the capacity to notice internal pressure without being
compelled by it.

See [architecture/affect.md](docs/architecture/affect.md) for implementation
details and the [paper](docs/paper/April2026/springdrift-combined.pdf)
(Appendix G) for the full design rationale including the blind spot analysis
and choice menu.

### Memory

Ten memory stores, all backed by append-only JSONL and indexed in ETS by
the Librarian actor:

```
Librarian (ETS query layer)
├── Narrative entries    what happened each cycle (intent, outcome, delegation chain)
│   └── Threads          ongoing topics grouping related entries
├── Facts                key-value working memory (scoped, versioned, confidence-decayed)
├── CBR cases            problem -> solution -> outcome (utility-scored, outcome-weighted)
├── Artifacts            large content on disk (web pages, extractions, 50KB truncation)
├── Tasks + Endeavours   planned work with steps, risks, forecast scores
├── Comms log            sent and received emails (audit trail, JSONL)
├── Affect snapshots     functional emotion readings (5 dimensions per cycle)
└── DAG nodes            operational telemetry (tokens, tools, gates, agent output)
```

The **Curator** manages a virtual context window -- named, prioritised slots
(1=identity through 10=background) that auto-truncate or omit when the total
exceeds a configurable budget. The agent always has its most important context
in the window without manual intervention.

**XStructor** validates all structured LLM output (D' scores, narrative entries,
CBR cases) against XSD schemas with automatic retry. No JSON parsing from LLM
responses. No repair heuristics. Five call sites, all schema-validated.

See [architecture/memory.md](docs/architecture/memory.md) for store details,
Librarian queries, and housekeeping.

### Agents

The cognitive loop delegates work to specialist agents, each a supervised OTP
process with its own react loop, tool set, and context window.

| Agent | Tools | Turns | Purpose |
|---|---|---|---|
| Planner | none (pure XML reasoning) | 5 | Plan decomposition, steps, dependencies, risk identification |
| Project Manager | planner (22 tools) | 15 | Full work management: tasks, endeavours, phases, sessions, blockers, forecaster |
| Researcher | web + artifacts + builtin | 8 | Gather information via search and extraction |
| Coder | sandbox + builtin | 10 | Write and execute code in isolated Podman containers |
| Writer | builtin | 6 | Draft and edit text |
| Comms | email (AgentMail) | 6 | Send and receive email to allowed recipients |
| Observer | diagnostic + CBR curation (18 tools) | 6 | Cycle forensics, pattern detection, CBR curation, D' feedback |
| Scheduler | scheduler (6 tools) | 6 | Create and manage scheduled jobs, reminders, and todos |

The **sandbox** provides isolated Podman containers for code execution. The
**comms agent** sends and receives email via AgentMail with three independent
safety layers (hard allowlist, deterministic rules, tighter D' thresholds).
Skills follow the [agentskills.io](https://agentskills.io) open standard.

See [architecture/agents.md](docs/architecture/agents.md) for delegation
management, teams, structured output, and error surfacing.

### Interfaces

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

### Cost management

Every token-consuming component is independently configurable:

- **Task model vs reasoning model** -- simple queries route to a cheaper model
  (e.g. Haiku), complex queries to a reasoning model (e.g. Opus). Automatic.
- **Max tokens and turns** -- `max_tokens` caps output per LLM call, `max_turns`
  limits react-loop iterations (default 5). Per-agent turn limits in `[agents.*]`.
- **Archivist model** -- narrative generation can use the cheaper task model.
- **D' scorer** -- uses the task model. Interactive sessions skip the LLM scorer
  entirely for output (deterministic rules only). Input gate uses fast-accept
  for benign input (2 canary calls instead of 5+).
- **Scheduler rate limits** -- `max_autonomous_cycles_per_hour` (default 20) and
  `autonomous_token_budget_per_hour` (default 500,000) cap autonomous spending.
- **CBR retrieval cap** -- K=4 cases maximum. **Preamble budget** --
  `preamble_budget_chars` (default 8000) caps system prompt size.

The DAG tracks token usage per cycle. `reflect` shows daily totals. The
sensorium displays remaining budget in `<vitals>`.

### Persistence and recovery

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
│   ├── planner/             Tasks and endeavours
│   ├── comms/               Sent and received emails
│   └── affect/              Functional emotion snapshots
├── schemas/                 XStructor XSD schemas (compiled at runtime)
├── skills/                  Skill definitions + HOW_TO.md operator guide
└── scheduler/outputs/       Delivered reports
```

All files are append-only JSONL or plain text -- no binary formats, no database,
no external state. `git commit` after each session and you have a versioned
history of every decision. Roll back to any commit and the agent restarts with
that state.

**Automated git backup** (enabled by default): an OTP actor initialises a git
repo inside `.springdrift/` and commits state changes on a periodic timer
(default every 5 minutes). Configure `remote_url` in `[backup]` to push to
GitHub, GitLab, or any git remote.

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


---

## Evaluation results

Two claims in this project are empirically testable: that CBR retrieval
outperforms RAG, and that the normative calculus is complete. Both are
verified with reproducible evaluations in [evals/](evals/).

### CBR retrieval vs RAG baseline

800 synthetic cases across 4 domains x 5 subdomains. 200 queries at three
difficulty levels. RAG baseline uses Ollama nomic-embed-text (768-dim)
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
0.796). The full ablation is in
[evals/experiment-3/REPORT.md](evals/experiment-3/REPORT.md).

### Normative calculus completeness

Exhaustive verification over the full input space: 14 levels x 3 operators
x 2 modalities = 84 normative propositions, all 7,056 ordered pairs tested.

| Property | Result |
|---|---|
| Coverage | 100% (7,056/7,056 pairs) |
| Determinism violations | 0 |
| Monotonicity violations | 0 |
| Rules fired | 8/8 |

The calculus is total, deterministic, and complete -- a mathematical proof,
not a statistical sample.

---

## Documentation

**Architecture docs:** detailed design documents for each subsystem in [docs/architecture/](docs/architecture/):

| Document | Covers |
|---|---|
| [cognitive-loop.md](docs/architecture/cognitive-loop.md) | Central orchestration -- status machine, message types, cycle lifecycle, model switching |
| [agents.md](docs/architecture/agents.md) | Agent substrate, 8 specialist agents, teams, delegation, structured output |
| [work-management.md](docs/architecture/work-management.md) | PM agent, Planner, tasks, endeavours, Appraiser, Forecaster, sprint contracts |
| [memory.md](docs/architecture/memory.md) | 10 memory stores, Librarian, Archivist, CBR, facts, artifacts, threading |
| [safety.md](docs/architecture/safety.md) | D' gates, normative calculus, canary probes, meta observer, agent overrides |
| [affect.md](docs/architecture/affect.md) | Functional emotion monitoring -- 5 dimensions, signal sources, tradition grounding |
| [identity.md](docs/architecture/identity.md) | Persona, preamble templating, Curator, sensorium, character spec |
| [scheduler.md](docs/architecture/scheduler.md) | Autonomous scheduling -- job types, delivery, persistence, resource limits |
| [comms.md](docs/architecture/comms.md) | Email via AgentMail -- inbox polling, three-layer safety, message persistence |
| [sandbox.md](docs/architecture/sandbox.md) | Podman code execution -- container lifecycle, port forwarding, workspace isolation |
| [llm.md](docs/architecture/llm.md) | Provider abstraction, adapters (Anthropic/OpenAI/Vertex/mock), retry, caching |
| [xstructor.md](docs/architecture/xstructor.md) | XML-schema-validated structured LLM output -- XSD validation, retry, extraction |
| [interfaces.md](docs/architecture/interfaces.md) | TUI and Web GUI -- tabs, WebSocket protocol, admin dashboard, authentication |
| [configuration.md](docs/architecture/configuration.md) | Three-layer config -- TOML parsing, CLI flags, validation, team templates |
| [logging.md](docs/architecture/logging.md) | System logs, cycle logs, DAG telemetry, pattern detection |


---

## Background reading

The full theoretical lineage, prototype history, and paper-by-paper mapping
is documented in [docs/background/references.md](docs/background/references.md).

Key references:

- Beach, L. R. (2010). *The Psychology of Narrative Thought*. Xlibris.
- Beach, L. R. (1990). *Image Theory: Decision Making in Personal and Organizational Contexts*. Wiley.
- Sloman, A. (2001). Beyond shallow models of emotion. *Cognitive Processing*, 2(1), 177-198.
- Becker, L. C. (1998). *A New Stoicism*. Princeton University Press.
- Aamodt, A., & Plaza, E. (1994). Case-based reasoning: Foundational issues. *AI Communications*, 7(1), 39-59.
- Bruner, J. (1991). The narrative construction of reality. *Critical Inquiry*, 18(1), 1-21.
- Schank, R. C. (1982). *Dynamic Memory*. Cambridge University Press.
- Packer, C. et al. (2023). MemGPT: Towards LLMs as Operating Systems. [arXiv:2310.08560](https://arxiv.org/abs/2310.08560)
- Zhou, H. et al. (2025). Memento. [arXiv:2508.16153](https://arxiv.org/abs/2508.16153)
- Zhang, Z. et al. (2025). ACE. [arXiv:2510.04618](https://arxiv.org/abs/2510.04618)
- Dupoux, E., LeCun, Y., & Malik, J. (2026). System M. [arXiv:2603.15381](https://arxiv.org/abs/2603.15381)
- HumanLayer. [12-Factor Agents](https://github.com/humanlayer/12-factor-agents).

---

## License

Springdrift is licensed under the [GNU Affero General Public License v3.0](LICENSE)
(AGPL-3.0).

**What this means:** If you run a modified version of Springdrift as a network
service (e.g. a hosted agent platform), you must make your modified source code
available to users of that service under the same license. This ensures that
improvements to the system remain open.

Using Springdrift for your own private purposes (research, personal agent,
internal tools) does not trigger the source disclosure requirement -- only
providing it as a service to others does.

## Commercial Licensing

Springdrift is available under the AGPL-3.0 for open-source use. If the
AGPL's network-use source disclosure requirement does not work for your
use case -- for example, if you want to integrate Springdrift into a
proprietary product or offer it as a hosted service without releasing
your modifications -- commercial licenses are available.

Contact: Seamus Brady <seamus@corvideon.ie>

## Contributing

Contributions are welcome. By submitting a pull request, you agree to the
terms of our [Contributor License Agreement](CLA.md). Please also review
our [Code of Conduct](CODE_OF_CONDUCT.md) before contributing.

## Authors

See [AUTHORS](AUTHORS) for the list of contributors.
