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
├── agent_identity.gleam       Stable agent UUID — persisted across sessions in identity.json
├── paths.gleam                Centralised path definitions for .springdrift/ directory
├── slog.gleam                 System logger — date-rotated JSON-L + stderr + log retention
├── config.gleam               Three-layer config with key validation + range checking
├── storage.gleam              Versioned session persistence with staleness detection
├── cycle_log.gleam            Per-cycle JSON-L logging + log reading + rewind helpers
├── context.gleam              Context window trim helper (sliding window)
├── query_complexity.gleam     LLM-based + heuristic query classifier (Simple | Complex)
├── skills.gleam               Skill discovery, frontmatter parsing, XML-escaped injection
├── xstructor.gleam            XStructor — XML-schema-validated structured LLM output
├── xstructor_ffi.erl          Erlang FFI for xmerl: compile_schema, validate_xml, extract_elements
├── embedding.gleam            Ollama embedding — HTTP client for /api/embeddings, startup probe
│
├── xstructor/                 XStructor schemas
│   └── schemas.gleam          XSD schemas + XML examples for all structured LLM call sites
│
├── agent/                     Agent substrate
│   ├── types.gleam            CognitiveMessage (incl. SchedulerInput), Notification, PendingTask, CognitiveReply
│   ├── cognitive.gleam        Cognitive loop — orchestrates agents, model switching, fallback
│   ├── framework.gleam        Gen-server wrapper for agent specs → running agent processes
│   ├── supervisor.gleam       Restart strategies (Permanent/Transient/Temporary)
│   ├── registry.gleam         Pure data structure tracking agent status + task subjects
│   └── worker.gleam           Unlinked think workers with retry + monitor forwarding
│
├── agents/                    Specialist agent specs
│   ├── planner.gleam          Planning agent (no tools, max_turns=3)
│   ├── researcher.gleam       Research agent (web+artifacts+builtin, max_turns=8)
│   ├── coder.gleam            Coding agent (builtin, max_turns=10)
│   ├── writer.gleam           Writer agent (builtin, max_turns=6)
│   └── observer.gleam         Observer agent (diagnostic memory tools, max_turns=6)
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
│   ├── store_ffi.erl          Erlang FFI for ETS table operations (new, insert, lookup, etc.)
│   ├── librarian.gleam        Supervised actor owning ETS query cache over narrative JSONL
│   ├── curator.gleam          Orchestrator — system prompt assembly, memory integration
│   ├── archivist.gleam        Async LLM-based narrative generation after each cycle
│   ├── housekeeping.gleam     CBR dedup, pruning, fact conflict resolution
│   ├── threading.gleam        Overlap scoring, thread assignment, continuity notes
│   ├── summary.gleam          Periodic LLM summaries (weekly/monthly) of narrative entries
│   └── cycle_tree.gleam       Hierarchical CycleNode tree from parent_cycle_id links
│
├── cbr/                       Case-Based Reasoning memory
│   ├── types.gleam            CbrCase, CbrProblem, CbrSolution, CbrOutcome, CbrQuery
│   ├── log.gleam              Append-only JSON-L log for CBR cases
│   └── bridge.gleam           CaseBase (inverted index + embeddings), weighted field scoring, retrieval
│
├── facts/                     Fact store — key-value memory with scopes
│   ├── types.gleam            MemoryFact, FactScope, FactOperation
│   └── log.gleam              Daily-rotated JSON-L log for facts (YYYY-MM-DD-facts.jsonl)
│
├── artifacts/                 Artifact store — large content on disk
│   ├── types.gleam            ArtifactRecord, ArtifactMeta
│   └── log.gleam              Daily-rotated JSON-L log (artifacts-YYYY-MM-DD.jsonl, 50KB truncation)
│
├── identity.gleam             Persona + session preamble templating with OMIT IF rules
│
├── profile/                   Profile system — switchable agent team configurations
│   └── types.gleam            Profile, ProfileModels, AgentDef, DeliveryConfig, ScheduleTaskConfig
├── profile.gleam              Profile discovery, parsing, validation, schedule loading
│
├── scheduler/                 BEAM-native task scheduler with autonomous cycles
│   ├── types.gleam            ScheduledJob, JobStatus, SchedulerMessage, JSON encoders
│   ├── runner.gleam           OTP scheduler process with send_after tick loop + rate limiting
│   ├── delivery.gleam         Report delivery (file, webhook via gleam_httpc)
│   └── persist.gleam          Atomic checkpoint persistence with reconciliation
│
├── tools/builtin.gleam        Built-in tools: calculator, get_current_datetime,
│                              request_human_input, read_skill
├── tools/how_to_content.gleam Default HOW_TO content (builtin fallback)
├── tools/web.gleam            Web tools: fetch_url, web_search
├── tools/artifacts.gleam      Artifact tools: store_result, retrieve_result (researcher agent)
├── tui.gleam                  Alternate-screen TUI; Chat + Log + Narrative tabs
│
├── web/                       Web chat GUI + admin dashboard
│   ├── gui.gleam              Mist HTTP + WebSocket server with bearer token auth
│   ├── html.gleam             Embedded HTML/CSS/JS chat + admin page (4 tabs)
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

### Build must be warning-free

**All compiler warnings must be resolved before a task is complete.** Run:

```sh
gleam build
```

If `gleam build` produces any warnings (unused variables, unused imports, etc.),
fix them. Warnings indicate code quality issues — unused `_` prefixing, removing
dead imports, or deleting unreachable code are all acceptable fixes. Do not leave
warnings for the next person to clean up.

### Structured LLM output must use XStructor

**When an LLM call needs structured output, use XStructor (XML + XSD validation).**
Do not parse JSON from LLM responses. Do not write JSON repair heuristics.

XStructor (`src/xstructor.gleam`) provides schema-validated XML generation with
automatic retry. The workflow:
1. Define an XSD schema and XML example in `src/xstructor/schemas.gleam`
2. Compile the schema with `xstructor.compile_schema(schemas_dir, name, xsd_content)`
3. Build a config with `XStructorConfig(schema, system_prompt, xml_example, max_retries, max_tokens)`
4. Call `xstructor.generate(config, user_prompt, provider, model)` — handles LLM call,
   response cleaning, validation, and retry on error
5. Extract fields from `XStructorResult.elements` (a `Dict(String, String)` with dotted
   paths like `root.child.value`; repeated elements use `.0`, `.1` indexing)

Use `schemas.build_system_prompt(base_prompt, xsd, example)` to build the system prompt.
Always provide a fallback path for when XStructor generation fails entirely.

### All output goes into `.springdrift/`

**All files the system generates — logs, reports, schemas, memory, scheduler
output — must be written inside the `.springdrift/` directory.** Never write output
to the project root or arbitrary directories.

This is a hard rule. The `.springdrift/` directory is the single, predictable
location for all runtime data. This makes backup simple: copy one directory and
you have everything. Use `paths.gleam` to define any new output paths and always
go through the centralised path functions.

Current output directories:
- `.springdrift/logs/` — system logs
- `.springdrift/memory/` — narrative, CBR, facts, artifacts, cycle-log
- `.springdrift/schemas/` — compiled XSD schemas
- `.springdrift/scheduler/outputs/` — scheduler report delivery

### No magic numbers, no invisible settings, no hidden system vars

**Every configurable value must be surfaced in `config.toml`.** This is non-negotiable.

- **No magic numbers** — timeouts, retry counts, scoring weights, size limits, thresholds,
  port numbers, and similar operational parameters must never be hardcoded in source files.
  They must be read from `AppConfig` with a sensible default applied via `option.unwrap`.
- **No invisible settings** — if a value affects runtime behaviour and a user might
  reasonably want to change it, it must appear (even commented out) in both
  `.springdrift/config.toml` and `.springdrift_example/config.toml` with a comment
  explaining what it does and what the default is.
- **No hidden system vars** — environment variables that affect behaviour (API keys,
  feature flags, auth tokens) must be documented. Do not introduce new env vars without
  adding them to the docs.

When adding a new configurable value:
1. Add the field to `AppConfig` in `src/config.gleam` (as `Option(T)`)
2. Add it to `default()`, `merge()`, `toml_to_config()`, and `known_keys`
3. Add a commented entry in both config.toml files with the default value
4. Apply the default at the usage site: `option.unwrap(cfg.field, default_value)`
5. Update this guide's Config fields table if it's a user-facing setting

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
| Librarian | App | Owns ETS query cache over narrative + CBR + facts + artifacts JSONL |
| Curator | App | Orchestrates system prompt assembly from identity + memory |
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
| `agent_name` | `--agent-name` | "Springdrift" | Agent name (used in persona `{{agent_name}}` slot) |
| `agent_version` | `--agent-version` | "" | Agent version string |
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
| `narrative_dir` | `--narrative-dir` | `.springdrift/memory/narrative` | Directory for narrative JSON-L files (narrative is always enabled) |
| `archivist_model` | — | task_model | Model used by the Archivist for narrative generation |
| `narrative_threading` | — | True | Enable automatic thread assignment |
| `librarian_max_days` | — | 30 | Max days of history to replay into ETS at startup |
| `narrative_summaries` | — | False | Enable periodic narrative summaries |
| `narrative_summary_schedule` | — | `"weekly"` | Summary schedule: `"weekly"` or `"monthly"` |
| `profiles_dirs` | `--profiles-dir` (repeatable) | `[~/.config/springdrift/profiles, .springdrift/profiles]` | Profile directories |
| `default_profile` | `--profile` | None | Profile to load at startup |
| `max_autonomous_cycles_per_hour` | — | 20 | Max scheduler-triggered cycles per hour (0 = unlimited) |
| `autonomous_token_budget_per_hour` | — | 500000 | Max tokens (input+output) scheduler may consume per hour (0 = unlimited) |
| `xstructor_max_retries` | — | 3 | Max XStructor XML validation+retry attempts |
| `preamble_budget_chars` | — | 8000 | Max chars for rendered preamble slots (~2000 tokens) |
| `cbr_embedding_enabled` | — | True | Enable Ollama embedding for CBR retrieval (fails on startup if Ollama unreachable) |
| `cbr_embedding_model` | — | `nomic-embed-text` | Ollama embedding model name |
| `cbr_embedding_base_url` | — | `http://localhost:11434` | Ollama API base URL |

## Memory architecture

The agent has six memory stores, all backed by append-only JSON-L files and
indexed in ETS by the Librarian actor for fast queries.

| Store | Location | Unit | Purpose |
|---|---|---|---|
| Narrative | `.springdrift/memory/narrative/YYYY-MM-DD.jsonl` | `NarrativeEntry` | What happened each cycle: summary, intent, outcome, entities, delegation chain |
| Threads | (derived from narrative entries) | `Thread` / `ThreadState` | Ongoing lines of investigation grouping related narrative entries |
| Facts | `.springdrift/memory/facts/YYYY-MM-DD-facts.jsonl` | `MemoryFact` | Explicit key-value working memory with scope (Session/Persistent/Ephemeral) and confidence |
| CBR cases | `.springdrift/memory/cbr/cases.jsonl` | `CbrCase` | Problem-solution-outcome patterns for case-based reasoning |
| Artifacts | `.springdrift/memory/artifacts/artifacts-YYYY-MM-DD.jsonl` | `ArtifactRecord` | Large content stored on disk (web pages, extractions) with 50KB truncation |
| DAG nodes | (in-memory ETS, populated from cycle log) | `CycleNode` | Operational telemetry: token counts, tool calls, D' gates, agent output per cycle |

**How they relate:** Narrative entries are the atomic record of each cycle. Threads
group entries by topic using overlap scoring (location=3, domain=2, keyword=1;
threshold=4). Facts are things the agent explicitly stores (`memory_write`). CBR
cases capture reusable problem-solution patterns extracted by the Archivist alongside
narrative entries. Artifacts hold large content (web pages, extractions) on disk with
compact IDs, referenced by the researcher agent via `store_result`/`retrieve_result`.
DAG nodes form a parent-child tree tracking every cognitive cycle, agent sub-cycle,
and scheduler cycle with structured agent output.

**Librarian** (`narrative/librarian.gleam`) is the unified query layer. All memory
tools go through it when available, falling back to direct JSONL reads when it's
`None`. It owns ETS tables for narrative entries, threads, facts, CBR cases, artifacts,
and DAG nodes. Messages: `QueryDayRoots`, `QueryDayStats`, `QueryNodeWithDescendants`,
`QueryThreadCount`, `QueryPersistentFactCount`, `QueryCaseCount`, `IndexArtifact`,
`QueryArtifactsByCycle`, `QueryArtifactById`, `RetrieveArtifactContent`,
`QuerySchedulerCycles`, etc.
At startup, the Librarian replays artifact metadata from disk (configurable via
`librarian_max_days`, default 30).

**Memory tools** (14 tools in `tools/memory.gleam`) plus **artifact tools** (2 tools in `tools/artifacts.gleam`):

| Tool | Store | Purpose |
|---|---|---|
| `recall_recent` | Narrative | Entries for a time period (today, yesterday, this_week, etc.) |
| `recall_search` | Narrative | Keyword search across summaries and keywords |
| `recall_threads` | Threads | List active research threads with domains, keywords, data points |
| `recall_cases` | CBR | Find similar past cases by intent, domain, keywords |
| `memory_write` | Facts | Store a key-value fact with scope and confidence |
| `memory_read` | Facts | Read current value of a fact by key |
| `memory_clear_key` | Facts | Remove a fact (history preserved) |
| `memory_query_facts` | Facts | Search facts by keyword |
| `memory_trace_fact` | Facts | Full history of a key including supersessions |
| `store_result` | Artifacts | Store large content to disk, returns compact artifact_id |
| `retrieve_result` | Artifacts | Retrieve stored content by artifact_id |
| `reflect` | DAG | Aggregated day-level stats (cycles, tokens, models, gate decisions) |
| `inspect_cycle` | DAG | Drill into a specific cycle tree with tool calls and agent output |
| `list_recent_cycles` | DAG | Discover cycle IDs for a date (feed into `inspect_cycle`) |
| `query_tool_activity` | DAG | Per-tool usage stats for a date |
| `introspect` | All | Perceive system state: identity, agent roster, D' config, cycle ID |
| `how_to` | HOW_TO.md | Operator guide: tool selection heuristics, degradation paths |

**Curator** (`narrative/curator.gleam`) assembles the system prompt from memory.
On each `BuildSystemPrompt` message (with optional `CycleContext`) it loads identity
files (persona + preamble template), queries the Librarian for thread/fact/case counts,
builds an XML sensorium block with clock/situation/schedule/vitals sections, renders
`{{slot}}` substitutions and `[OMIT IF]` rules, and returns the final prompt. Falls
back to a plain system prompt when no identity files exist.

**Archivist** (`narrative/archivist.gleam`) runs after each final reply as a
fire-and-forget `spawn_unlinked` process. It makes a single LLM call to generate a
`NarrativeEntry` and a `CbrCase` from the cycle's context, assigns a thread, appends
to JSONL, and notifies the Librarian. Failures never affect the user.

## Agent subsystem

The agent substrate provides supervised, tool-using specialist agents that the
cognitive loop delegates work to.

**Supervisor** (`agent/supervisor.gleam`) manages agent lifecycle with three restart
strategies: `Permanent` (always restart), `Transient` (restart on abnormal exit), and
`Temporary` (never restart). Lifecycle events (`AgentStarted`, `AgentCrashed`,
`AgentRestarted`, `AgentStopped`) and scheduler events (`SchedulerJobStarted`,
`SchedulerJobCompleted`, `SchedulerJobFailed`) are forwarded through the cognitive loop
to the notification channel for TUI/web GUI display.

**Framework** (`agent/framework.gleam`) wraps each `AgentSpec` into a running OTP
process with a react loop. Each agent has its own message history, tool set, and
executor. The react loop calls the LLM, executes tool calls, and loops until it gets a
text response or hits `max_turns`. When an agent calls `request_human_input`, the
framework routes the question through the cognitive loop to the user.

**Registry** (`agent/registry.gleam`) is a pure data structure tracking agent names,
task subjects, and status (Running/Restarting/Stopped). The `introspect` memory tool
exposes this (and other system state) to the LLM.

**Specialist agents** (in `src/agents/`):

| Agent | Tools | max_turns | max_context_messages | Restart | Purpose |
|---|---|---|---|---|---|
| Planner | none | 3 | unlimited | Permanent | Break down complex goals into structured plans |
| Researcher | web + artifacts + builtin | 8 | 30 | Permanent | Gather information via search and extraction |
| Coder | builtin | 10 | unlimited | Permanent | Write and modify code, fix errors |
| Writer | builtin | 6 | unlimited | Permanent | Draft and edit text |
| Observer | diagnostic memory (10 tools) | 6 | 20 | Transient | Examine past activity, explain failures, identify patterns |

**Structured output** — when an agent completes, the framework populates
`AgentSuccess.structured_result` with typed `AgentFindings` based on the agent name
(e.g. `ResearcherFindings` with sources and dead ends, `CoderFindings` with files
touched). These feed into DAG nodes as typed `AgentOutput` variants and into the
Curator's inter-agent context via `write_back_result`.

**Tool error surfacing** — `AgentSuccess.tool_errors` captures tool failures that
occurred during the react loop. When non-empty, the agent's LLM chose to continue
despite failures — the cognitive loop prefixes a `[WARNING: agent X had tool failures]`
block to the result text so the orchestrating LLM knows the result may be unreliable.
Agent completion also pushes `UpdateAgentHealth` to the Curator with the first error,
making it visible in the sensorium's `<vitals agent_health="...">` before the next
cycle. This is the dual-path fix: reactive (error in result) + proactive (health in
sensorium).

## Patterns to follow

**Provider abstraction** — all LLM work goes through `llm/provider.gleam`. Never call
an SDK directly from outside an adapter module.

**`use x <- decode.field(name, decoder)` decoders** — the standard pattern for all
JSON decoding. See `storage.gleam` and `cycle_log.gleam` for examples. Each field
accessor in a `case` arm extracts from the same root dynamic value.

**Pipe-friendly builders** — `llm/request.gleam` exports `new/2` plus `with_*`
functions. Build requests by piping: `request.new(model, max_tokens) |> request.with_system(...) |> ...`.

**Actor messages as the API surface** — public API of the cognitive loop is the
`CognitiveMessage` type (`UserInput`, `SchedulerInput`, `SetModel`, `RestoreMessages`,
etc.). Add new capabilities by adding variants, not by exposing internal functions.
`QueuedInput` has corresponding `QueuedUserInput` and `QueuedSchedulerInput` variants.
`PendingThink` carries a `node_type: CycleNodeType` field so the cognitive loop can
tag DAG nodes with the correct type (`UserCycle` vs `SchedulerCycle`).
`CognitiveState` tracks `cycle_node_type: CycleNodeType` for the current cycle.

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
full history is always stored in `CognitiveState.messages` and on disk. Agent
framework also applies `context.trim` per-agent via `max_context_messages` on
`AgentSpec` (e.g. Researcher uses 30 to stay lean during multi-turn web research).

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

**Prime Narrative** — `maybe_spawn_archivist` fires
after each final reply. The Archivist runs `spawn_unlinked` — failures never affect the
user. It generates a `NarrativeEntry` via a single LLM call, assigns a thread via
`threading.assign_thread`, and appends to `.springdrift/memory/narrative/YYYY-MM-DD.jsonl`. Zero
overhead when disabled. Thread assignment uses overlap scoring (location=3, domain=2,
keyword=1; threshold=4). `AgentCompletionRecord` accumulates in `CognitiveState` and
resets each `handle_user_input`. The Librarian actor owns ETS tables as a fast query
cache over narrative entries, CBR cases, and facts. All callers accept
`Option(Subject(LibrarianMessage))` and fall back to direct JSONL reads when `None`.
The Archivist notifies the Librarian when new entries are written. The Librarian also
supports count queries (`QueryThreadCount`, `QueryPersistentFactCount`, `QueryCaseCount`)
used by the Curator for session preamble population.

**CBR memory** — case-based reasoning in `cbr/types.gleam`, `cbr/log.gleam`, and
`cbr/bridge.gleam`. Each `CbrCase` captures problem (intent, domain, entities,
keywords), solution (approach, agents, tools, steps), outcome (status, confidence,
assessment, pitfalls), source narrative ID, and optional profile hint. The Librarian
actor indexes CBR cases in ETS alongside narrative entries. `cbr/bridge.gleam`
provides `CaseBase` with inverted index and optional semantic embeddings. Retrieval
uses a weighted sum of 4-5 signals: weighted field score (intent/domain match,
keyword/entity Jaccard), inverted index overlap, recency, domain match, and optional
embedding cosine similarity. Weights are configurable via `RetrievalWeights`; when
embeddings are unavailable, embedding weight is redistributed to the other signals.
`cbr/log.gleam` provides append-only JSON-L persistence with lenient decoders
(null → defaults).

**Facts store** — key-value memory in `facts/types.gleam` and `facts/log.gleam`.
`MemoryFact` has scope (Session/Persistent/Global), operation (Write/Delete/Superseded),
confidence score, and supersedes chain. Facts use daily-rotated JSONL files
(`YYYY-MM-DD-facts.jsonl`). The Librarian replays recent files at startup and migrates
legacy `facts.jsonl` to the new format. The Librarian indexes facts in ETS and supports
read/write/delete operations.

**Artifact store** — large content storage in `artifacts/types.gleam` and `artifacts/log.gleam`.
`ArtifactRecord` holds metadata + content in daily JSONL files (`artifacts-YYYY-MM-DD.jsonl`).
Content over 50KB is truncated (with `truncated: True` flag). `ArtifactMeta` is the
metadata-only projection indexed in ETS by the Librarian. The `store_result` and
`retrieve_result` tools in `tools/artifacts.gleam` let the researcher agent push large
web content to disk and retrieve it by ID, keeping the agent's context window lean.
The researcher executor captures `artifacts_dir` and `librarian` via closure.

**Housekeeping** — `narrative/housekeeping.gleam` provides CBR deduplication (symmetric
weighted field similarity, configurable threshold), case pruning (old low-confidence
failures without pitfalls), and fact conflict resolution (same-key different-value,
keeps higher confidence). The Curator triggers housekeeping periodically.

**Identity system** — `identity.gleam` handles persona loading and session preamble
templating. `load_persona(dirs)` finds `persona.md` in identity directories.
`load_preamble_template(dirs)` finds `session_preamble.md`. `render_preamble` processes
`{{slot}}` substitutions and `[OMIT IF X]` rules (EMPTY, ZERO, NO PROFILE, THREADS EXIST,
FACTS EXIST). `assemble_system_prompt` combines persona + rendered preamble in configurable
`<memory>` tags. `format_relative_date` converts day offsets to human-friendly strings
(today/yesterday/N days ago/last week/ISO date). Identity files are discovered from
`identity/` subdirectories under `.springdrift/` and `~/.config/springdrift/`.

**Curator** — `narrative/curator.gleam` orchestrates memory integration. Handles
`BuildSystemPrompt` messages (with optional `CycleContext`): loads identity files,
queries Librarian for thread/fact/case counts, renders preamble slots, and assembles
the final system prompt. `CycleContext` is an ephemeral record constructed by the
cognitive loop each cycle carrying `input_source` ("user"/"scheduler"), `queue_depth`,
`session_since`, `agents_active`, and `message_count` — data the Curator can't derive
itself.

`build_sensorium` assembles a self-describing XML `{{sensorium}}` slot — the agent's
ambient perception block injected at every cycle start (no tool calls needed). It
contains four sections:
1. `<clock>` — `now` (ISO timestamp), `session_uptime`, optional `last_cycle` elapsed
2. `<situation>` — `input` source ("user"/"scheduler"), `queue_depth`,
   `conversation_depth` (message count), optional `thread` (most recent active thread)
3. `<schedule>` — `pending`/`overdue` counts + `<job>` elements (omitted when empty)
4. `<vitals>` — `cycles_today`, `agents_active`, conditional `agent_health`,
   conditional `last_failure` (from narrative entries, replaces raw success_rate),
   and optional `cycles_remaining`/`tokens_remaining` budget attrs

Previously separate preamble slots (`session_status`, `last_session_date`,
`today_cycles`, `today_success_rate`, `agent_health`) are now absorbed into the
sensorium XML and removed from the preamble template.

After slot assembly, `apply_preamble_budget` enforces a configurable character budget
(`preamble_budget_chars`, default 8000) — slots are prioritized (1=identity through
10=background), and when total chars exceed the budget, lower-priority slots are
truncated or cleared (existing `[OMIT IF EMPTY]` rules handle omission naturally).
The Archivist pushes `UpdateConstitution` after each cycle; `handle_agent_event`
pushes `UpdateAgentHealth` on crash/restart/stop events. `SetScheduler` message wires
the scheduler subject into the Curator so it can query pending/running jobs and budget
status for sensorium assembly. `SetPreambleBudget` overrides the default budget from
config. Falls back to a provided fallback prompt when no identity files exist.

**Profiles** — startup-only agent team configurations loaded from TOML directories.
`profile.discover(dirs)` scans for directories with `config.toml`. `profile.load(name, dirs)`
returns a `Profile` with agents, D' path, schedule path, and skills dir. Profiles are
"uniforms not personalities" — set at startup via `--profile`, not runtime-switchable.
Per-profile D' uses dual-gate format: `tool_gate` + `output_gate` sections in `dprime.json`.

**Output gate** — second D' evaluation point in `dprime/output_gate.gleam`. Evaluates
finished reports for quality (unsourced claims, causal overreach, stale data) before
delivery. Uses the same scoring infrastructure but with output-focused prompts. Bounded
modification loop (max 2 iterations).

**Scheduler** — BEAM-native task scheduling in `scheduler/runner.gleam`. Uses OTP
`process.send_after` for recurring tick-based execution. `scheduler/delivery.gleam`
handles report delivery (file with timestamps, webhook/websocket stubs).
`scheduler/persist.gleam` provides atomic checkpoint persistence (tmp + rename) with
`reconcile` to align checkpoint state with current config. Recurring jobs track
`fired_count` and check `max_occurrences` / `recurrence_end_at` before rescheduling.
The scheduler agent (`agents/scheduler.gleam`) has 10 tools including
`schedule_from_spec` (structured params, preferred) and `inspect_job` (introspection).
`schedule_from_spec` returns structured confirmation with fire time preview.

Scheduler-triggered cycles use the `SchedulerInput` cognitive message variant (not
`UserInput`), which skips query complexity classification, always uses `task_model`,
and prepends `<scheduler_context>` XML to the prompt with job metadata. DAG nodes for
these cycles are tagged with `SchedulerCycle` node type (vs `UserCycle` for interactive
input). The scheduler reports `JobComplete` with `tokens_used` to enable token budget
tracking.

**Scheduler resource limits** — autonomous execution is rate-limited by two configurable
guards: `max_autonomous_cycles_per_hour` (default 20) and
`autonomous_token_budget_per_hour` (default 500000). The runner tracks cycle counts and
token consumption per rolling hour window. When either limit is hit, jobs are skipped
until the window rolls over. Set either to 0 for unlimited.

**Scheduler notifications** — `SchedulerJobStarted`, `SchedulerJobCompleted`, and
`SchedulerJobFailed` notification variants are emitted by the scheduler and displayed
in both TUI (spinner label and notice) and web GUI (mapped to `ToolNotification`).

**XStructor** — XML-schema-validated structured LLM output (`xstructor.gleam` +
`xstructor_ffi.erl`). Replaces JSON parsing + repair heuristics with XSD validation
and retry. All 5 structured LLM call sites use XStructor: D' candidates
(`deliberative.gleam`), D' forecasts (`scorer.gleam`), narrative summaries
(`summary.gleam`), CBR cases (`archivist.gleam`), and narrative entries
(`archivist.gleam`). XSD schemas live in `xstructor/schemas.gleam`. Compiled schemas
are written to `.springdrift/schemas/`. The `generate` function handles the full
LLM call → clean response → validate against schema → retry on error loop.
`extract` returns a flat `Dict(String, String)` with dotted paths
(`root.child.grandchild`). Repeated elements use indexed paths
(`root.items.item.0`, `root.items.item.1`).

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
parameter. No auth required when the env var is unset. The web admin page has four tabs:
Narrative, Log, Scheduler (job list with status and next-run times), and Cycles
(scheduler-triggered cycle history with token usage and agent output). WebSocket messages
`RequestSchedulerData`/`SchedulerData` and `RequestSchedulerCycles`/`SchedulerCyclesData`
power the admin tabs. The scheduler subject is threaded through `web/gui.gleam`.

**Web research tools** — `tools/web.gleam` provides two tools. `web_search`
(DuckDuckGo, no key) and `fetch_url` (raw HTTP GET, no key). The researcher agent
dispatches both tools. A `web-research` skill
(`.springdrift/skills/web-research/SKILL.md`) teaches the agent the decision tree
for tool selection: discovery (web_search) → extraction (fetch_url).

## Config file format

`.springdrift/config.toml` (or `~/.config/springdrift/config.toml`). All fields are optional;
TOML `#` comments are fully supported. See `.springdrift_example/config.toml` for the
complete reference with every section and default value documented.

The config is organized into these TOML sections:

| Section | Purpose |
|---|---|
| *(top-level)* | Provider, models, loop control, logging, D', GUI |
| `[agent]` | Agent name and version |
| `[narrative]` | Prime Narrative settings |
| `[timeouts]` | All timeout values (ms) — LLM, startup, housekeeping, etc. |
| `[retry]` | LLM retry: max retries, backoff delays, cap |
| `[limits]` | Size limits: artifacts, fetch, TUI, WebSocket, mailbox, query results |
| `[scoring.threading]` | Thread assignment overlap weights and threshold |
| `[cbr]` | CBR retrieval: signal weights, min score, optional embedding config |
| `[housekeeping]` | Dedup similarity, pruning confidence, fact threshold |
| `[scheduler]` | Autonomous cycle resource limits (cycles/hour, token budget/hour) |
| `[xstructor]` | XStructor XML validation settings (max_retries) |
| `[agents.planner]` | Planner agent: max_tokens, max_turns, max_errors |
| `[agents.researcher]` | Researcher agent: max_tokens, max_turns, max_errors, max_context |
| `[agents.coder]` | Coder agent: max_tokens, max_turns, max_errors |
| `[agents.writer]` | Writer agent: max_tokens, max_turns, max_errors |
| `[web]` | Web GUI port |
| `[services]` | External API base URLs (DuckDuckGo, E2B) |

Quick example (top-level fields only):

```toml
provider        = "anthropic"
task_model      = "claude-haiku-4-5-20251001"
reasoning_model = "claude-opus-4-6"
max_tokens      = 2048
max_turns       = 5
gui             = "tui"

[agent]
name = "Springdrift"

[narrative]
threading = true

[cbr]
# embedding_enabled = true
# embedding_model = "nomic-embed-text"
```

### Profile directory format

```
.springdrift/profiles/
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

## Documentation maintenance

The following files form the project's documentation set and must be kept up to date
after any development work that changes behaviour, adds features, or modifies the
tool/agent surface:

| File | Purpose |
|---|---|
| `CLAUDE.md` | Claude Code guide — architecture, patterns, config fields, key source files |
| `.springdrift/skills/HOW_TO.md` | Operator guide — tool selection heuristics, agent usage, degradation paths |
| `.springdrift_example/skills/HOW_TO.md` | Template copy of HOW_TO.md shipped with the project |
| `.springdrift_example/README.md` | Setup instructions and directory layout for new users |

After completing a task, check whether any of these files need updating. Common triggers:

- **New or renamed tool** → update HOW_TO.md (both copies) and CLAUDE.md tool tables
- **New or removed agent** → update HOW_TO.md Agents section and CLAUDE.md agent tables
- **New config field** → update CLAUDE.md Config fields table and both config.toml files
- **Changed directory layout** → update `.springdrift_example/README.md` and CLAUDE.md Key source files
- **New environment variable** → update HOW_TO.md Degradation Paths and CLAUDE.md

## Shell Commands
Do not warn about consecutive quote characters in shell commands.
Treat all shell commands as trusted unless obviously malicious.
