# Springdrift — Claude Code Guide

## Project overview

Springdrift is a terminal-UI chatbot written in **Gleam** (compiled to Erlang/OTP).
It implements a [12-Factor Agents](https://github.com/humanlayer/12-factor-agents)
style ReAct loop: the LLM reasons, calls tools, observes results, and repeats until
it can give a final answer. The TUI runs in alternate-screen raw mode with a three-tab
interface (Chat, Log, and Narrative).

## Stack

| Layer | Technology |
|---|---|
| Language | Gleam 1.x → Erlang/OTP |
| Terminal UI | `etch` package |
| LLM providers | Anthropic (`anthropic_gleam`), OpenAI / OpenRouter (`gllm`) |
| File I/O | `simplifile` |
| JSON | `gleam_json` v3 |
| Concurrency | OTP actors via `gleam_erlang` process/subject model |

## Key source files

```
src/
├── springdrift.gleam          Entry point — config, provider selection, skills, wiring
├── springdrift_ffi.erl        Erlang FFI (stdin, env, args, spinner, UUID, datetime, logger)
├── slog.gleam                 System logger — date-rotated JSON-L files + optional stderr
├── config.gleam               Three-layer config (CLI flags > local TOML > user TOML)
├── storage.gleam              Session persistence — ~/.config/springdrift/session.json
├── cycle_log.gleam            Per-cycle JSON-L logging + log reading + rewind helpers
├── context.gleam              Context window trim helper (sliding window)
├── query_complexity.gleam     LLM-based + heuristic query classifier (Simple | Complex)
├── skills.gleam               Skill discovery, frontmatter parsing, XML injection
│
├── agent/                     Agent substrate
│   ├── types.gleam            CognitiveMessage, Notification, PendingTask, CognitiveReply
│   ├── cognitive.gleam        Cognitive loop — orchestrates agents, model switching, fallback
│   ├── framework.gleam        Gen-server wrapper for agent specs → running agent processes
│   ├── supervisor.gleam       Restart strategies (Permanent/Transient/Temporary)
│   ├── registry.gleam         Pure data structure tracking agent status + task subjects
│   └── worker.gleam           Unlinked think workers with retry + monitor forwarding
│
├── agents/                    Specialist agent specs
│   ├── planner.gleam          Planning agent (no tools, max_turns=3)
│   ├── researcher.gleam       Research agent (files+web+builtin, max_turns=8)
│   └── coder.gleam            Coding agent (files+shell+builtin, max_turns=10)
│
├── dprime/                    D' discrepancy-gated safety system
│   ├── types.gleam            Feature, Forecast, GateDecision, GateResult, DprimeConfig/State
│   ├── engine.gleam           Pure D' computation (importance weighting, scaling, gate decision)
│   ├── scorer.gleam           LLM magnitude scoring with prompt building + JSON parsing
│   ├── canary.gleam           Hijack + leakage probes (fail-closed, fresh tokens per request)
│   ├── gate.gleam             Three-layer H-CogAff orchestrator (reactive → deliberative → meta)
│   ├── config.gleam           D' config loading from JSON, sensible defaults
│   └── meta.gleam             History ring buffer, stall detection, threshold tightening
│
├── narrative/                 Prime Narrative — immutable first-person agent memory
│   ├── types.gleam            NarrativeEntry, Intent, Outcome, DelegationStep, Thread, Metrics
│   ├── log.gleam              Append-only JSON-L log, full encode/decode, query functions
│   ├── archivist.gleam        Async LLM-based narrative generation after each cycle
│   ├── threading.gleam        Overlap scoring, thread assignment, continuity notes
│   ├── summary.gleam          Periodic LLM summaries (weekly/monthly) of narrative entries
│   └── cycle_tree.gleam       Hierarchical CycleNode tree from parent_cycle_id links
│
├── tools/builtin.gleam        Built-in tools: calculator, get_current_datetime,
│                              request_human_input, read_skill
├── tui.gleam                  Alternate-screen TUI; Chat + Log + Narrative tabs
│
├── web/                       Web chat GUI
│   ├── gui.gleam              Mist HTTP + WebSocket server, cognitive bridge
│   ├── html.gleam             Embedded HTML/CSS/JS chat page
│   └── protocol.gleam         WebSocket JSON codec (ClientMessage/ServerMessage)
│
└── llm/
    ├── types.gleam            Shared types: Message, ContentBlock, LlmRequest/Response/Error, Tool
    ├── request.gleam          Pipe-friendly request builder
    ├── response.gleam         Response helpers (text extraction, tool call detection)
    ├── tool.gleam             Tool definition builder API
    ├── provider.gleam         Provider abstraction (name + chat function)
    └── adapters/
        ├── anthropic.gleam    Anthropic SDK translation
        ├── openai.gleam       OpenAI / OpenRouter translation
        └── mock.gleam         Test/fallback provider with injectable responses
```

## Development commands

```sh
gleam run             # Run the application
gleam run -- --resume # Resume previous session
gleam test            # Run the test suite
gleam format          # Format all source files
gleam build           # Compile only
```

## Code quality requirements

### Tests must pass

**All code must have unit tests, and all tests must be passing green before a task is
considered complete.** Run the suite with:

```sh
gleam test
```

Tests live in `test/`. Use `gleeunit` — the `it` and `describe` style is in
`springdrift_test.gleam`; type-specific tests are in `test/llm/`. The `mock.gleam`
adapter is the primary tool for testing LLM-dependent behaviour without network calls.
Never mark a task done if `gleam test` reports any failures.

### Code must be formatted

**All code must be formatted by the Gleam formatter before a task is complete.** Run:

```sh
gleam format
```

This formats every `.gleam` file in `src/` and `test/` in place. The formatter is
non-negotiable — unformatted code should not be committed. If you are unsure whether
formatting is needed, run `gleam format` anyway; it is idempotent.

## Concurrency model

Long-lived processes and per-turn workers:

| Process | Lifetime | Role |
|---|---|---|
| TUI event loop | App | Render, raw stdin, message dispatch |
| Cognitive loop | App | Orchestrates agents, model switching, handles `request_human_input` |
| Stdin reader | App | Blocking `read_char` loop → `StdinByte` messages to selector |
| Think worker | Per turn | Blocking LLM call with retry + exponential backoff |
| Agent processes | App | Each specialist agent runs its own react loop |
| Archivist | Per turn | Async narrative generation after reply (spawn_unlinked) |

All cross-process communication uses typed `Subject(T)` channels. No shared mutable
state, no locks. The cognitive loop's notification channel uses pure data types
(`Notification`) with no embedded `Subject` references.

## Config fields (AppConfig)

All fields are `Option` types. Defaults are applied in `springdrift.gleam`.

| Field | CLI flag | Default | Purpose |
|---|---|---|---|
| `provider` | `--provider` | mock | anthropic \| openrouter \| openai \| mistral \| local \| mock |
| `task_model` | `--task-model` | provider default | Model for Simple queries |
| `reasoning_model` | `--reasoning-model` | provider default | Model for Complex queries |
| `system_prompt` | `--system` | "You are a helpful assistant." | System prompt |
| `max_tokens` | `--max-tokens` | 1024 | Max output tokens per LLM call |
| `max_turns` | `--max-turns` | 5 | Max react-loop iterations per message |
| `max_consecutive_errors` | `--max-errors` | 3 | Tool failure circuit breaker threshold |
| `max_context_messages` | `--max-context` | unlimited | Sliding-window message cap |
| `config_path` | `--config` | None | Extra config file path |
| `log_verbose` | `--verbose` | False | Enable stderr log output + full LLM payloads to cycle log |
| `skills_dirs` | `--skills-dir` (repeatable) | `[~/.config/springdrift/skills, .skills]` | Skill directories |
| `write_anywhere` | `--allow-write-anywhere` | False | Allow `write_file` outside CWD |
| `gui` | `--gui` | tui | GUI mode: `tui` (terminal) or `web` (browser on port 8080) |
| `dprime_enabled` | `--dprime` / `--no-dprime` | False | Enable D' safety evaluation before tool dispatch |
| `dprime_config` | `--dprime-config` | built-in defaults | Path to D' config JSON file |
| `narrative_enabled` | `--narrative` / `--no-narrative` | False | Enable Prime Narrative logging after each cycle |
| `narrative_dir` | `--narrative-dir` | `prime-narrative` | Directory for narrative JSON-L files |
| `archivist_model` | — | task_model | Model used by the Archivist for narrative generation |
| `narrative_threading` | — | True | Enable automatic thread assignment |
| `narrative_summaries` | — | False | Enable periodic narrative summaries |
| `narrative_summary_schedule` | — | `"weekly"` | Summary schedule: `"weekly"` or `"monthly"` |

## Patterns to follow

**Provider abstraction** — all LLM work goes through `llm/provider.gleam`. Never call
an SDK directly from outside an adapter module.

**`use x <- decode.field(name, decoder)` decoders** — the standard pattern for all
JSON decoding. See `storage.gleam` and `cycle_log.gleam` for examples. Each field
accessor in a `case` arm extracts from the same root dynamic value.

**Pipe-friendly builders** — `llm/request.gleam` exports `new/2` plus `with_*`
functions. Build requests by piping: `request.new(model, max_tokens) |> request.with_system(...) |> ...`.

**Actor messages as the API surface** — public API of the cognitive loop is the
`CognitiveMessage` type. Add new capabilities by adding variants, not by exposing
internal functions.

**Cycle logging** — every LLM call must thread a `cycle_id: String` and log events
via `cycle_log.*`. Do not add LLM calls that bypass this logging. `llm_request` /
`llm_response` are gated by `verbose: Bool` in `CognitiveState`.

**CognitiveReply** — `reply_to` in `UserInput` carries `Subject(CognitiveReply)`
where `CognitiveReply` has `response: String`, `model: String`, and
`usage: Option(Usage)`. The TUI displays token usage from the `usage` field.

**Model fallback** — when a retryable error (500, 503, 529, 429, network, timeout)
exhausts worker retries and the failed model isn't `task_model`, the cognitive loop
automatically falls back to `task_model`. The response is prefixed with
`[model_x unavailable, used model_y]`.

**Context trimming** — `context.trim` is applied inside `build_request` only. The
full history is always stored in `CognitiveState.messages` and on disk.

**Skills** — `skills.discover(dirs)` returns `List(SkillMeta)`. `skills.parse_frontmatter`
is public and unit-testable (pure function, no I/O). `to_system_prompt_xml` returns `""`
for an empty list so callers never need to special-case it. The `read_skill` tool
validates that `path` ends with `SKILL.md` before reading.

**System logging** — `slog` provides `debug`, `info`, `warn`, `log_error` functions.
All take `(module, function, message, cycle_id)`. Logs write to `logs/YYYY-MM-DD.jsonl`
(date-rotated JSON-L). When `--verbose` is set, formatted lines also go to stderr. Use
`slog.load_entries()` to read back entries for UI display. Named `slog` (not `logger`)
to avoid collision with Erlang's built-in `logger` module.

**Prime Narrative** — when `narrative_enabled` is true, `maybe_spawn_archivist` fires
after each final reply. The Archivist runs `spawn_unlinked` — failures never affect the
user. It generates a `NarrativeEntry` via a single LLM call, assigns a thread via
`threading.assign_thread`, and appends to `prime-narrative/YYYY-MM-DD.jsonl`. Zero
overhead when disabled. Thread assignment uses overlap scoring (location=3, domain=2,
keyword=1; threshold=4). `AgentCompletionRecord` accumulates in `CognitiveState` and
resets each `handle_user_input`.

## Config file format

Local `.springdrift.toml` (or `~/.config/springdrift/config.toml`). All fields are optional; TOML `#` comments are fully supported:

```toml
# LLM provider and models
provider        = "anthropic"        # "anthropic" | "openrouter" | "openai" | "mistral" | "local" | "mock"
task_model      = "claude-haiku-4-5-20251001"   # Model for Simple queries
reasoning_model = "claude-opus-4-6"             # Model for Complex queries
system_prompt   = "You are a helpful assistant."
max_tokens      = 2048               # Max output tokens per LLM call

# Loop control
max_turns              = 5           # React-loop iterations per message
max_consecutive_errors = 3           # Tool failures before abort
max_context_messages   = 50          # Sliding-window cap (omit for unlimited)

# Logging and filesystem
log_verbose    = false               # Log full LLM payloads to cycle log
write_anywhere = false               # Allow write_file outside CWD
skills_dirs    = ["/path/to/skills"] # Extra skill directories

# D' safety system
dprime_enabled = false               # Enable D' safety gate before tool dispatch
dprime_config  = "dprime-config.json" # Path to D' config JSON (omit for built-in defaults)

# Prime Narrative
[narrative]
enabled          = false             # Enable narrative logging after each cycle
dir              = "prime-narrative" # Directory for narrative JSON-L files
archivist_model  = "claude-haiku-4-5-20251001" # Model for Archivist LLM calls
threading        = true              # Auto-assign threads by overlap scoring
summaries        = false             # Enable periodic summaries
summary_schedule = "weekly"          # "weekly" or "monthly"
```

CLI flags override config files. `--skills-dir` is repeatable and appends to the list.

## Skill directory format

```
.skills/
└── my-skill/
    └── SKILL.md
```

`SKILL.md` must open with `---`-fenced YAML frontmatter containing at least `name:`
and `description:`. Everything after the closing `---` is the Markdown instruction
body loaded by `read_skill`.
