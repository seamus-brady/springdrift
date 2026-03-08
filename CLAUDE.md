# Springdrift — Claude Code Guide

## Project overview

Springdrift is a knowledge worker agent framework written in **Gleam** (compiled to
Erlang/OTP). It runs research queries on a schedule, remembers what it found last
time, and delivers structured reports. It implements a
[12-Factor Agents](https://github.com/humanlayer/12-factor-agents) style ReAct loop
and includes an interactive TUI with a three-tab interface (Chat, Log, and Narrative).

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
├── springdrift_ffi.erl        Erlang FFI (stdin, env, args, spinner, UUID, datetime, logger,
│                              file_size, resolve_symlinks, sanitize_json, days_ago_date,
│                              uri_encode, extract_ddg_results)
├── paths.gleam                Centralised path definitions for .springdrift/ directory
├── slog.gleam                 System logger — date-rotated JSON-L + stderr + log retention
├── config.gleam               Three-layer config with key validation + range checking
├── storage.gleam              Versioned session persistence with staleness detection
├── cycle_log.gleam            Per-cycle JSON-L logging + log reading + rewind helpers
├── context.gleam              Context window trim helper (sliding window)
├── query_complexity.gleam     LLM-based + heuristic query classifier (Simple | Complex)
├── skills.gleam               Skill discovery, frontmatter parsing, XML-escaped injection
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
│   ├── researcher.gleam       Research agent (web+builtin, max_turns=8)
│   ├── coder.gleam            Coding agent (builtin, max_turns=10)
│   └── writer.gleam           Writer agent (builtin, max_turns=6)
│
├── dprime/                    D' discrepancy-gated safety system
│   ├── types.gleam            Feature, Forecast, GateDecision, GateResult, DprimeConfig/State
│   ├── engine.gleam           Pure D' computation (importance weighting, scaling, gate decision)
│   ├── scorer.gleam           LLM magnitude scoring with prompt building + JSON parsing
│   ├── canary.gleam           Hijack + leakage probes (fail-closed, fresh tokens per request)
│   ├── gate.gleam             Three-layer H-CogAff orchestrator (reactive → deliberative → meta)
│   ├── config.gleam           D' config loading from JSON, dual-gate support (tool + output)
│   ├── output_gate.gleam      Output quality gate — evaluates finished reports before delivery
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
├── profile/                   Profile system — switchable agent team configurations
│   └── types.gleam            Profile, ProfileModels, AgentDef, DeliveryConfig, ScheduleTaskConfig
├── profile.gleam              Profile discovery, parsing, validation, schedule loading
│
├── scheduler/                 BEAM-native task scheduler
│   ├── types.gleam            ScheduledJob, JobStatus, SchedulerMessage
│   ├── runner.gleam           OTP scheduler process with send_after tick loop
│   ├── delivery.gleam         Report delivery (file, webhook via gleam_httpc)
│   └── persist.gleam          Atomic checkpoint persistence with reconciliation
│
├── tools/builtin.gleam        Built-in tools: calculator, get_current_datetime,
│                              request_human_input, read_skill
├── tools/web.gleam            Web tools: fetch_url (50KB limit), web_search (DuckDuckGo)
├── tui.gleam                  Alternate-screen TUI; Chat + Log + Narrative tabs
│
├── web/                       Web chat GUI
│   ├── gui.gleam              Mist HTTP + WebSocket server with bearer token auth
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
| Scheduler | App | BEAM-native task scheduler with `send_after` tick loop |

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
| `skills_dirs` | `--skills-dir` (repeatable) | `[~/.config/springdrift/skills, .springdrift/skills]` | Skill directories |
| `write_anywhere` | `--allow-write-anywhere` | False | Allow `write_file` outside CWD |
| `gui` | `--gui` | tui | GUI mode: `tui` (terminal) or `web` (browser on port 8080) |
| `dprime_enabled` | `--dprime` / `--no-dprime` | False | Enable D' safety evaluation before tool dispatch |
| `dprime_config` | `--dprime-config` | built-in defaults | Path to D' config JSON file |
| `narrative_enabled` | `--narrative` / `--no-narrative` | False | Enable Prime Narrative logging after each cycle |
| `narrative_dir` | `--narrative-dir` | `.springdrift/memory/narrative` | Directory for narrative JSON-L files |
| `archivist_model` | — | task_model | Model used by the Archivist for narrative generation |
| `narrative_threading` | — | True | Enable automatic thread assignment |
| `narrative_summaries` | — | False | Enable periodic narrative summaries |
| `narrative_summary_schedule` | — | `"weekly"` | Summary schedule: `"weekly"` or `"monthly"` |
| `profiles_dirs` | `--profiles-dir` (repeatable) | `[~/.config/springdrift/profiles, .springdrift/profiles]` | Profile directories |
| `default_profile` | `--profile` | None | Profile to load at startup |

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
for an empty list so callers never need to special-case it. Skill names, descriptions, and
paths are XML-escaped (`&<>"'`) before injection via `xml_escape`. The `read_skill` tool
validates that `path` ends with `SKILL.md` before reading.

**System logging** — `slog` provides `debug`, `info`, `warn`, `log_error` functions.
All take `(module, function, message, cycle_id)`. Logs write to `.springdrift/logs/YYYY-MM-DD.jsonl`
(date-rotated JSON-L). Per-file size limit of 10MB with rotation (renames to `.1`).
Old logs (>30 days) are cleaned up on startup via `cleanup_old_logs`. When `--verbose`
is set, formatted lines also go to stderr. Named `slog` (not `logger`) to avoid
collision with Erlang's built-in `logger` module.

**Prime Narrative** — when `narrative_enabled` is true, `maybe_spawn_archivist` fires
after each final reply. The Archivist runs `spawn_unlinked` — failures never affect the
user. It generates a `NarrativeEntry` via a single LLM call, assigns a thread via
`threading.assign_thread`, and appends to `.springdrift/memory/narrative/YYYY-MM-DD.jsonl`. Zero
overhead when disabled. Thread assignment uses overlap scoring (location=3, domain=2,
keyword=1; threshold=4). `AgentCompletionRecord` accumulates in `CognitiveState` and
resets each `handle_user_input`.

**Profiles** — switchable agent team configurations loaded from TOML directories.
`profile.discover(dirs)` scans for directories with `config.toml`. `profile.load(name, dirs)`
returns a `Profile` with models, agents, D' path, schedule path, and skills dir.
The cognitive loop handles `LoadProfile` messages to hot-swap configuration. Per-profile
D' uses dual-gate format: `tool_gate` + `output_gate` sections in `dprime.json`.

**Output gate** — second D' evaluation point in `dprime/output_gate.gleam`. Evaluates
finished reports for quality (unsourced claims, causal overreach, stale data) before
delivery. Uses the same scoring infrastructure but with output-focused prompts. Bounded
modification loop (max 2 iterations).

**Scheduler** — BEAM-native task scheduling in `scheduler/runner.gleam`. Uses OTP
`process.send_after` for recurring tick-based execution. `scheduler/delivery.gleam`
handles report delivery (file with timestamps, webhook/websocket stubs).
`scheduler/persist.gleam` provides atomic checkpoint persistence (tmp + rename) with
`reconcile` to align checkpoint state with current config.

**Config validation** — `parse_config_toml` validates unknown TOML keys and warns via
`slog`. Numeric values are range-checked (must be positive). Provider and GUI mode
values are validated against known options. Parse failures are logged instead of silent.

**Session versioning** — `storage.save` writes a JSON envelope with `version` (int),
`saved_at` (ISO timestamp), and `messages`. `storage.load` checks for staleness and
logs a warning when resuming sessions from a different day. Backward-compatible with
legacy plain-array format. Corruption is detected and logged.

**Input size limits** — TUI input buffer capped at 100KB. `read_file` checks file size
(10MB max) before reading via `file_size` FFI. WebSocket messages capped at 1MB.

**Symlink resolution** — `is_within_cwd` in `tools/files.gleam` resolves symlinks via
`resolve_symlinks` FFI (walks path components, follows links) before CWD boundary check.

**Web GUI auth** — when `SPRINGDRIFT_WEB_TOKEN` is set, all HTTP and WebSocket requests
require authentication via `Authorization: Bearer <token>` header or `?token=` query
parameter. No auth required when the env var is unset.

## Config file format

`.springdrift/config.toml` (or `~/.config/springdrift/config.toml`). All fields are optional; TOML `#` comments are fully supported:

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
dprime_config  = "dprime.json" # Path to D' config JSON (omit for built-in defaults)

# Prime Narrative
[narrative]
enabled          = false             # Enable narrative logging after each cycle
dir              = ".springdrift/memory/narrative" # Default location
archivist_model  = "claude-haiku-4-5-20251001" # Model for Archivist LLM calls
threading        = true              # Auto-assign threads by overlap scoring
summaries        = false             # Enable periodic summaries
summary_schedule = "weekly"          # "weekly" or "monthly"
```

### Profile directory format

```
profiles/
└── analyst/
    ├── config.toml          # Required — name, description, models, agents
    ├── dprime.json          # Optional — dual-gate D' config (tool_gate + output_gate)
    ├── schedule.toml        # Optional — recurring tasks with delivery config
    └── skills/              # Optional — profile-specific skills
        └── summarize/
            └── SKILL.md
```

CLI flags override config files. `--skills-dir` is repeatable and appends to the list.

## Skill directory format

```
.springdrift/skills/
└── my-skill/
    └── SKILL.md
```

`SKILL.md` must open with `---`-fenced YAML frontmatter containing at least `name:`
and `description:`. Everything after the closing `---` is the Markdown instruction
body loaded by `read_skill`.
