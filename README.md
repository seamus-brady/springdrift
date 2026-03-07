# Springdrift

A terminal-UI chatbot written in **Gleam/OTP** that implements the
[12-Factor Agents](https://github.com/humanlayer/12-factor-agents) principles.
It runs a ReAct loop — the model reasons, calls tools, observes results, and
repeats until it can give a final answer — all inside a full alternate-screen
TUI with a three-tab interface (Chat, Log, Narrative).

---

## Features

### Multi-provider LLM support
Anthropic, OpenAI, and OpenRouter are all supported via a thin provider
abstraction (`src/llm/provider.gleam`). On startup the app auto-detects which
API key is available (`ANTHROPIC_API_KEY` → `OPENROUTER_API_KEY` →
`OPENAI_API_KEY`), or you can force a provider with `--provider`. A mock
provider is available for development and tests.

### ReAct agent loop
The core control flow is an explicit `react_loop` that iterates up to
`max_turns` times per user message:

1. Send the conversation (including tool definitions) to the LLM.
2. If the response contains tool calls, execute them, append results, repeat.
3. If the response is a final text answer, return it.

Errors surface as visible `[Error: …]` messages — never as silent empty
responses.

### Built-in tools

| Tool | Description |
|---|---|
| `calculator` | Basic arithmetic (`+`, `-`, `*`, `/`) with division-by-zero guard |
| `get_current_datetime` | Returns the current local date and time as `YYYY-MM-DDTHH:MM:SS` |
| `request_human_input` | Asks the human a question mid-loop and blocks until they reply |
| `read_skill` | Loads a `SKILL.md` file from disk (used with the skills system) |

### Agent skills (agentskills.io)
Springdrift implements the [agentskills.io](https://agentskills.io/) standard for
giving agents reusable, portable capabilities. At startup it scans configured
skill directories for subdirectories containing a `SKILL.md` file with YAML
frontmatter (`name`, `description`). Discovered skills are injected into the
system prompt as an `<available_skills>` XML block. The model can then call the
`read_skill` tool to load full instructions for any skill it decides to use.

Default skill directories (checked in order):
- `~/.config/springdrift/skills`
- `.skills` (project-local)

Override with `--skills-dir <path>` (repeatable) or `"skills_dirs"` in config.

### Model routing by query complexity
Each incoming message is classified as **Simple** or **Complex** before the
main LLM call:

1. A fast call to `task_model` with a one-word-reply classification prompt.
2. If that call fails, a heuristic fallback (message length, keywords, `?` count,
   numbered lists).

Simple queries use `task_model`; Complex queries automatically switch to
`reasoning_model`. The `/model` command lets you toggle between the two models
manually at any time.

### Automatic model fallback with retry
When an LLM call fails with a retryable error (500, 503, 529, 429, network,
timeout), the worker retries up to 3 times with exponential backoff (500ms →
1s → 2s). If all retries exhaust and the failed model isn't the task model, the
cognitive loop automatically falls back to `task_model` and prepends a brief
notice to the response: `[model_x unavailable, used model_y]`. This is
provider-agnostic — it works with Anthropic, OpenAI, and OpenRouter.

### Session persistence and resume
After every completed turn the full conversation (including all tool-use and
tool-result blocks) is saved to `~/.config/springdrift/session.json`. Start with
`--resume` to reload it.

### Cycle logging
Every conversation cycle is assigned a UUID and logged to
`cycle-log/YYYY-MM-DD.jsonl`. Each file is JSON-L (one object per line) and
contains five event types per cycle: `human_input`, `llm_request`,
`llm_response`, `tool_call`, `tool_result`. Classification decisions are also
logged. Events carry `parent_id` to chain cycles in order.

The `--verbose` flag enables logging of full `llm_request` and `llm_response`
payloads (off by default to keep log files small).

### System logging
Springdrift has a system-level logger (`slog`) with three output sinks:

1. **Date-rotated files** — `logs/YYYY-MM-DD.jsonl` (JSON-L, one entry per line).
   Every module instruments key functions with `slog.debug` / `slog.info` /
   `slog.warn` / `slog.log_error` calls.
2. **Stderr** — when `--verbose` is set, formatted log lines are written to
   stderr (not stdout, to avoid corrupting TUI alternate-screen output).
3. **UI log tabs** — both the TUI Log tab and the Web GUI Log tab load and
   display entries from today's log file.

### Log tab (TUI and Web GUI)
Press **Tab** in the TUI to open the Log tab. Each entry shows timestamp,
colored level badge, module::function, message, and optional cycle ID. Use
`↑`/`↓` to scroll. Press **Tab** again for the Narrative tab, which shows
narrative entries with cycle IDs, status badges, thread info, summaries,
and delegation chains. The Web GUI has a separate Log tab with a refresh button.

### Context window management
Set `--max-context <n>` to cap the number of messages passed to the LLM per
call. The full history is always kept in memory and on disk; trimming only
happens at request-build time.

### Agent orchestration

The main LLM acts as a cognitive orchestrator managing three specialist sub-agents:

| Agent | Role | Tools |
|---|---|---|
| `planner` | Break down complex goals into structured plans | None (text only) |
| `researcher` | Gather information from files, web, and built-in tools | files, web, builtin |
| `coder` | Write code, run shell commands in the sandbox | files, shell, builtin |

The cognitive loop only has two kinds of tools: `agent_*` tools (one per
registered agent) and `request_human_input`. All other tools (calculator, file
ops, shell, web) are delegated to agents. This keeps the orchestrator focused
on planning and communication.

The notification channel between the cognitive loop and the TUI is decoupled —
`Notification` is a pure data type with no process references (`Subject`). This
means the same cognitive loop could be driven by a websocket handler or any
other UI without code changes.

### Prime Narrative — agent memory

When enabled (`--narrative`), Springdrift writes a first-person narrative record
after every conversation cycle. The **Archivist** — a single async LLM call
running in `spawn_unlinked` — generates a `NarrativeEntry` covering what happened,
why, and how confident the system was. Entries are appended to immutable JSON-L
files in `prime-narrative/YYYY-MM-DD.jsonl`.

**Threading**: entries are automatically grouped into story arcs by overlap scoring.
Locations (weight 3), domains (weight 2), and keywords (weight 1) are compared
against existing threads. If the overlap exceeds a threshold (4), the entry joins
that thread with a continuity note comparing data points across cycles.

**Summaries**: periodic LLM-generated summaries aggregate entries over weekly or
monthly ranges.

**Narrative tab**: press Tab twice in the TUI to see narrative entries with
cycle IDs, timestamps, status badges, thread info, summaries, and delegation chains.

Zero overhead when disabled — no LLM calls, no files written, no Archivist spawned.

### Profile system

Profiles are self-contained agent team configurations that can be hot-swapped at
runtime. Each profile is a directory containing:

```
profiles/analyst/
├── config.toml          # Name, description, model overrides, agent definitions
├── dprime.json          # Optional dual-gate D' config (tool_gate + output_gate)
├── schedule.toml        # Optional scheduled tasks with delivery config
└── skills/              # Optional profile-specific skills
```

Load at startup with `--profile analyst` or switch at runtime via the web GUI's
profile dropdown. Profile directories are scanned from `~/.config/springdrift/profiles`
and `./profiles`.

### Output gate (dual D')

When a profile includes a `dprime.json` with an `output_gate` section, finished
reports are evaluated for quality before delivery. The output gate checks for
unsourced claims, causal overreach, stale data, and certainty overstatement.
Reports that fail quality checks can be automatically modified (up to 2 iterations)
or rejected.

### BEAM-native task scheduler

Profiles can define recurring scheduled tasks in `schedule.toml`. Tasks are executed
by OTP processes using `process.send_after` for timing. Results are delivered to
configurable destinations (files with timestamps, webhook, or websocket). Scheduler
state is persisted atomically to checkpoint files and reconciled on restart.

### Safety circuit breakers
- **Max turns** (`--max-turns`, default 5): prevents infinite tool loops.
- **Consecutive errors** (`--max-errors`, default 3): aborts if the same tool
  keeps failing without making progress.

### Input boundary protection
- TUI input buffer capped at 100KB — prevents paste-bombing
- `read_file` tool rejects files over 10MB — prevents memory exhaustion
- WebSocket messages capped at 1MB — prevents oversized payloads

### Web GUI authentication

Set `SPRINGDRIFT_WEB_TOKEN` to require authentication on all HTTP and WebSocket
connections. Supports `Authorization: Bearer <token>` header or `?token=<token>`
query parameter. When unset, no auth is required (suitable for localhost use).

### Config file validation

TOML config files are validated on load. Unknown keys produce warnings (logged via
`slog`), helping catch typos like `provder` instead of `provider`. Numeric values
are range-checked (must be positive). Invalid provider or GUI mode values are flagged.

### Session integrity

Sessions are saved with a version number and timestamp. On resume, the system detects
and warns about stale sessions from previous days. Corrupt session files are detected
and logged instead of silently returning empty state. Legacy session formats (pre-versioning)
are loaded transparently.

### Log retention

Daily log files are size-rotated at 10MB (renamed to `.1`). Log files older than
30 days are automatically cleaned up on startup.

### Verbose and diagnostics
- `--verbose`: log full LLM request/response payloads to the cycle log.
- `--print-config`: print the resolved config and exit.
- `--help`: show all flags.
- Token usage displayed in the footer (last turn) and per cycle in the Log tab.

---

## Installation

```sh
# Install Erlang/OTP and Gleam
brew install erlang gleam   # macOS

# Clone and build
git clone https://github.com/seamus-brady/springdrift
cd springdrift
gleam build
```

---

## Usage

```sh
# Start (auto-detects API key)
gleam run

# Resume previous session
gleam run -- --resume

# Force provider and model
gleam run -- --provider anthropic --model claude-opus-4-6

# Use a config file
gleam run -- --config /path/to/my.toml

# Start with an extra skill directory
gleam run -- --skills-dir ~/my-skills

# Print resolved config and exit
gleam run -- --print-config
```

### TUI keyboard shortcuts

| Key | Action |
|---|---|
| Enter | Send message (or answer agent question) |
| Tab | Cycle tabs: Chat → Log → Narrative → Chat |
| PgUp / PgDn | Scroll message history |
| ↑ / ↓ | (Log/Narrative tab) Scroll entries |
| Ctrl-C / Ctrl-D | Exit |

### Slash commands

| Command | Action |
|---|---|
| `/model` | Toggle between task model and reasoning model |
| `/clear` | Clear the conversation history |

---

## Configuration

Three-layer merge (highest priority first):

1. CLI flags
2. `.springdrift.toml` (current directory)
3. `~/.config/springdrift/config.toml`

### All config fields

```toml
provider               = "anthropic"
system_prompt          = "You are a helpful assistant."
max_tokens             = 1024
max_turns              = 5
max_consecutive_errors = 3
max_context_messages   = 50
task_model             = "claude-haiku-4-5-20251001"
reasoning_model        = "claude-opus-4-6"
log_verbose            = false
write_anywhere         = false
skills_dirs            = ["/path/to/skills"]

# D' safety system
dprime_enabled = false
dprime_config  = "dprime-config.json"

# Prime Narrative
[narrative]
enabled          = false
dir              = "prime-narrative"
archivist_model  = "claude-haiku-4-5-20251001"
threading        = true
summaries        = false
summary_schedule = "weekly"

# Profiles
profile      = "analyst"              # Default profile to load at startup
profiles_dirs = ["./profiles"]        # Profile directories to scan
```

### CLI flags

```
--provider <name>         anthropic | openrouter | openai | mistral | local | mock
--system <prompt>         System prompt string
--max-tokens <n>          Max output tokens per LLM call (default: 1024)
--max-turns <n>           Max react-loop turns per message (default: 5)
--max-errors <n>          Max consecutive tool failures before abort (default: 3)
--max-context <n>         Max messages in context window (default: unlimited)
--task-model <name>       Model for simple queries
--reasoning-model <name>  Model for complex queries
--config <path>           Load an additional TOML config file
--verbose                 Log full LLM request/response payloads
--skills-dir <path>       Add a skill directory (repeatable)
--allow-write-anywhere    Allow write_file outside the current working directory
--gui <tui|web>           GUI mode (default: tui)
--resume                  Reload previous session
--print-config            Print resolved config and exit
--dprime                  Enable D' safety evaluation
--no-dprime               Disable D' safety evaluation (default)
--dprime-config <path>    Path to D' config JSON
--narrative               Enable narrative logging after each cycle
--no-narrative            Disable narrative logging (default)
--narrative-dir <path>    Directory for narrative logs (default: prime-narrative)
--profile <name>          Load a profile at startup
--profiles-dir <path>     Add a profile directory (repeatable)
--help, -h                Show help
```

---

## Agent Skills

Create a skill by making a directory with a `SKILL.md` file:

```
.skills/
└── my-skill/
    └── SKILL.md
```

`SKILL.md` format (frontmatter + instructions):

```markdown
---
name: my-skill
description: A one-line summary of what this skill does.
---

# My Skill

Full instructions for the agent here. The model reads this file
when it decides to use the skill.
```

During a session, the model will see `<available_skills>` in its system
prompt and can call `read_skill` with the listed path to load the full
instructions.

---

## Architecture

```
springdrift.gleam         Entry point — config, provider selection, wiring
├── slog.gleam            System logger — date-rotated JSON-L + log retention (10MB/30d)
├── config.gleam          3-layer config with key validation + range checking
├── storage.gleam         Versioned session save/load with staleness detection
├── skills.gleam          Skill discovery, frontmatter parsing, XML-escaped injection
│
├── agent/                Agent substrate
│   ├── types.gleam       Notification, QuestionSource, WaitingContext, CognitiveMessage, etc.
│   ├── cognitive.gleam   Cognitive loop — orchestrates agents, model switching, request_human_input
│   ├── framework.gleam   Gen-server wrapper for agent specs → running agent processes
│   ├── supervisor.gleam  Restart strategies (Permanent/Transient/Temporary)
│   ├── registry.gleam    Pure data structure tracking agent status + task subjects
│   └── worker.gleam      Unlinked think workers with monitor forwarding
│
├── agents/               Specialist agent specs
│   ├── planner.gleam     Planning agent (no tools, max_turns=3)
│   ├── researcher.gleam  Research agent (files+web+builtin, max_turns=8)
│   ├── coder.gleam       Coding agent (files+shell+builtin, max_turns=10)
│   └── writer.gleam      Writer agent (files+builtin, max_turns=6)
│
├── dprime/               D' discrepancy-gated safety system
│   ├── types.gleam       Feature, Forecast, GateDecision, GateResult, DprimeConfig/State
│   ├── engine.gleam      Pure D' computation (importance weighting, scaling, gate decision)
│   ├── scorer.gleam      LLM magnitude scoring with structured prompts + JSON parsing
│   ├── canary.gleam      Hijack + leakage probes (fail-closed, fresh tokens per request)
│   ├── gate.gleam        Three-layer H-CogAff orchestrator (reactive → deliberative → meta)
│   ├── config.gleam      D' config loading, dual-gate support (tool_gate + output_gate)
│   ├── output_gate.gleam Output quality gate — evaluates reports before delivery
│   └── meta.gleam        History ring buffer, stall detection, threshold tightening
│
├── profile/              Profile system — switchable agent team configurations
│   └── types.gleam       Profile, ProfileModels, AgentDef, DeliveryConfig, ScheduleTaskConfig
├── profile.gleam         Profile discovery, parsing, validation, schedule loading
│
├── scheduler/            BEAM-native task scheduler
│   ├── types.gleam       ScheduledJob, JobStatus, SchedulerMessage
│   ├── runner.gleam      OTP scheduler process with send_after tick loop
│   ├── delivery.gleam    Report delivery (file, webhook stub, websocket stub)
│   └── persist.gleam     Atomic checkpoint persistence with reconciliation
│
├── query_complexity.gleam  LLM-based + heuristic query classifier (Simple | Complex)
├── context.gleam           Sliding-window context trim helper
├── cycle_log.gleam         Per-cycle JSON-L logging + log reading + rewind helpers
│
├── narrative/              Prime Narrative — immutable first-person agent memory
│   ├── types.gleam        NarrativeEntry, Intent, Outcome, DelegationStep, Thread, etc.
│   ├── log.gleam          Append-only JSON-L log, full encode/decode, query functions
│   ├── archivist.gleam    Async LLM narrative generation + JSON sanitization
│   ├── threading.gleam    Overlap scoring, thread assignment, continuity notes
│   ├── summary.gleam      Periodic LLM summaries (weekly/monthly)
│   └── cycle_tree.gleam   Hierarchical CycleNode tree from parent_cycle_id links
│
├── tools/
│   ├── builtin.gleam     calculator, get_current_datetime, request_human_input, read_skill
│   ├── files.gleam       read_file (10MB limit), write_file, list_directory + symlink-aware CWD check
│   ├── web.gleam         fetch_url (50KB limit)
│   └── shell.gleam       run_shell (delegates to sandbox)
│
├── tui.gleam             Alternate-screen TUI — Chat + Log + Narrative tabs (100KB input cap)
│
├── web/                  Web chat GUI
│   ├── gui.gleam         Mist HTTP + WebSocket server with bearer token auth (1MB msg cap)
│   ├── html.gleam        Embedded HTML/CSS/JS chat page
│   └── protocol.gleam    WebSocket JSON codec (ClientMessage/ServerMessage)
│
└── llm/
    ├── types.gleam        Shared types: Message, ContentBlock, LlmRequest/Response/Error, Tool
    ├── request.gleam      Pipe-friendly request builder
    ├── response.gleam     Response helpers (text, needs_tool_execution, tool_calls)
    ├── tool.gleam         Tool definition builder
    ├── provider.gleam     Provider abstraction (name + chat function)
    └── adapters/
        ├── anthropic.gleam  Anthropic SDK translation
        ├── openai.gleam     OpenAI / OpenRouter translation
        └── mock.gleam       Test/fallback provider with injectable responses
```

### Concurrency model

| Process | Lifetime | Role |
|---|---|---|
| Main / TUI event loop | App | Render, raw stdin, message dispatch |
| Cognitive loop | App | Orchestrates agents, model switching, handles `request_human_input` |
| Stdin reader | App | Blocking `read_char` loop → `StdinByte` to selector |
| Think worker | Per turn | Blocking LLM call for the cognitive loop |
| Agent processes | App | Each specialist agent runs its own react loop |
| Archivist | Per turn | Async narrative generation after reply (spawn_unlinked) |
| Scheduler | App | BEAM-native task scheduler with `send_after` tick loop |

All cross-process communication uses typed `Subject(T)` channels — no shared
mutable state, no locks. The cognitive loop's notification channel uses pure
data types (`Notification`) with no embedded `Subject` references, enabling
non-OTP consumers (e.g. websocket handlers).

### Message flow

```
User input → TUI
  → cognitive.UserInput(text, reply_to)
  → Cognitive loop classifies query complexity, picks model
  → Spawns think worker (LLM call)
  → Think worker completes:
      → If agent_* tool call: dispatch to agent, wait for AgentComplete
      → If request_human_input: send QuestionForHuman notification, wait for UserAnswer
      → If final text: send CognitiveReply to TUI
          → If narrative_enabled: spawn Archivist (async, fire-and-forget)
              → Archivist generates NarrativeEntry via LLM
              → Threading assigns/creates thread
              → Entry appended to prime-narrative/YYYY-MM-DD.jsonl
  → TUI renders response
```

---

## 12-Factor Agents compliance

| Factor | Status | Implementation |
|---|---|---|
| 1 — Natural language to tool calls | ✓ | ReAct loop with typed `ToolCall` / `ToolResult` |
| 2 — Own your prompts | ✓ | System prompt fully in config; skills injected as XML |
| 3 — Own your context window | ✓ | `context.trim` applied at request-build time |
| 4 — Tools as structured outputs | ✓ | All tools use `gleam_json` decoders on typed input |
| 5 — Unify execution and business state | ✓ | `ChatState.messages` is the only state; saved verbatim |
| 6 — Launch / pause / resume | ✓ | `--resume` reloads from `session.json`; Log tab rewinds |
| 7 — Contact humans via tools | ✓ | `request_human_input` blocks worker via OTP channel |
| 8 — Own your control flow | ✓ | Explicit `max_turns` limit + visible error on exhaustion |
| 9 — Compact errors into context | ✓ | Consecutive-error circuit breaker; errors shown in TUI |
| 10 — Small focused agents | ✓ | Cognitive mode: planner, researcher, coder agents with focused tool sets |
| 11 — Trigger from anywhere | Partial | Decoupled `Notification` channel enables non-TUI consumers |
| 12 — Stateless reducer | ✓ | `react_loop` returns full accumulated message list |

---

## Development

```sh
gleam run             # Run the application
gleam run -- --resume # Resume previous session
gleam test            # Run the test suite
gleam format          # Format all source files
gleam build           # Compile only
```

Tests live in `test/`. The `mock.gleam` adapter is the primary tool for
testing LLM-dependent behaviour without network calls. All tests must pass
and all code must be formatted before a change is complete.
