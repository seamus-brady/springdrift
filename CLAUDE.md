# Springdrift — Claude Code Guide

## Architecture Documentation

Detailed architecture docs live in `docs/architecture/`:

| Document | Covers |
|---|---|
| [cognitive-loop.md](docs/architecture/cognitive-loop.md) | Central orchestration — status machine, message types, cycle lifecycle, model switching, input queue |
| [agents.md](docs/architecture/agents.md) | Agent substrate, 7 specialist agents, teams, delegation, structured output |
| [work-management.md](docs/architecture/work-management.md) | PM agent, Planner, tasks, endeavours, Appraiser (pre/post-mortems), Forecaster, sprint contracts |
| [memory.md](docs/architecture/memory.md) | 9 memory stores, Librarian, Archivist, CBR, facts, artifacts, threading |
| [safety.md](docs/architecture/safety.md) | D' gates, normative calculus, canary probes, meta observer, agent overrides |
| [affect.md](docs/architecture/affect.md) | Functional emotion monitoring — 5 dimensions, signal sources, tradition grounding |
| [identity.md](docs/architecture/identity.md) | Persona, preamble templating, Curator, sensorium, character spec |
| [scheduler.md](docs/architecture/scheduler.md) | Autonomous scheduling — job types, delivery, persistence, resource limits |
| [comms.md](docs/architecture/comms.md) | Email via AgentMail — inbox polling, three-layer safety, message persistence |
| [sandbox.md](docs/architecture/sandbox.md) | Podman code execution — container lifecycle, port forwarding, workspace isolation |
| [llm.md](docs/architecture/llm.md) | Provider abstraction, adapters (Anthropic/OpenAI/Vertex/mock), retry, caching, thinking |
| [xstructor.md](docs/architecture/xstructor.md) | XML-schema-validated structured LLM output — XSD validation, retry, extraction |
| [interfaces.md](docs/architecture/interfaces.md) | TUI and Web GUI — tabs, WebSocket protocol, admin dashboard, authentication |
| [configuration.md](docs/architecture/configuration.md) | Three-layer config — TOML parsing, CLI flags, validation, team templates |
| [logging.md](docs/architecture/logging.md) | System logs, cycle logs, DAG telemetry, pattern detection |

The Anthropic adapter supports **prompt caching** (system + tools cached via `cache_control: ephemeral`) and **extended thinking** (for reasoning model, configurable via `thinking_budget_tokens`). Both bypass the anthropic_gleam SDK using raw HTTP for full API feature access.

This file contains the quick-reference guide. The architecture docs contain the full detail.

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
├── session_handoff.gleam      Structured session summary (written on save, read on resume)
├── cycle_log.gleam            Per-cycle JSON-L logging + log reading + rewind helpers
├── context.gleam              Context window trim helper (sliding window)
├── query_complexity.gleam     LLM-based + heuristic query classifier (Simple | Complex)
├── skills.gleam               Skill discovery, frontmatter parsing, XML-escaped injection
├── xstructor.gleam            XStructor — XML-schema-validated structured LLM output
├── xstructor_ffi.erl          Erlang FFI for xmerl: compile_schema, validate_xml, extract_elements
├── embedding.gleam            Ollama embedding — HTTP client for /api/embeddings, startup probe
├── session_handoff.gleam      Structured session summary (written on save, read on resume)
│
├── affect/                    Functional emotion monitoring
│   ├── types.gleam            AffectSnapshot (5 dimensions + pressure + trend), encode/decode
│   ├── compute.gleam          Pure signal→dimension computation (no LLM calls)
│   ├── store.gleam            Append-only JSONL persistence
│   └── monitor.gleam          After-cycle hook: gather signals, compute, store, return reading
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
│   ├── worker.gleam           Unlinked think workers with retry + monitor forwarding
│   └── team.gleam             Agent teams — coordinated multi-agent dispatch with strategies
│
├── agents/                    Specialist agent specs
│   ├── planner.gleam          Planning agent (pure XML reasoning, no tools, max_turns=5)
│   ├── project_manager.gleam  Project Manager agent (24 planner tools incl. complete_task_step, max_turns=8)
│   ├── researcher.gleam       Research agent (web+artifacts+builtin, max_turns=8)
│   ├── coder.gleam            Coding agent (builtin, max_turns=10)
│   ├── writer.gleam           Writer agent (knowledge drafts + artifacts + builtin, max_turns=5)
│   ├── observer.gleam         Observer agent (17 diagnostic + CBR curation tools, max_turns=6)
│   ├── comms.gleam            Communications agent (comms tools, max_turns=6, max_context=20)
│   └── remembrancer.gleam     Remembrancer — deep memory consolidation + skill proposals (9 tools, max_turns=8)
│
├── remembrancer/              Deep memory operations (bypasses Librarian ETS window)
│   ├── reader.gleam           Direct JSONL readers for narrative/CBR/facts
│   ├── query.gleam            Pure filter/aggregate: search, trace, cluster, dormant, xref
│   └── consolidation.gleam    ConsolidationRun JSONL log + markdown report writer
│
├── skills/                    Agent-led skill evolution (proposal → gate → Active)
│   ├── metrics.gleam          Per-skill JSONL of read/inject/outcome events
│   ├── versioning.gleam       Snapshot, history/ retention, archive.jsonl compaction, rollback
│   ├── pattern.gleam          Pure CBR-cluster qualification (structured-field Jaccard)
│   ├── proposal.gleam         SkillProposal + ConflictClassification + SkillLogEntry types
│   ├── proposal_log.gleam     Per-day skills lifecycle JSONL (.springdrift/memory/skills/)
│   ├── body_gen.gleam         LLM-written markdown body (XStructor, template fallback)
│   ├── conflict.gleam         LLM classifier: Complementary/Redundant/Supersedes/Contradictory
│   └── safety_gate.gleam      Four-layer gate: deterministic + rate limit + conflict + D'
│
├── strategy/                  Strategy Registry — meta-learning Phase A
│   ├── types.gleam            Strategy + StrategyEvent (Created/Used/Outcome/Archived) + StrategySource
│   └── log.gleam              Per-day JSONL log + resolve_from_events + active_ranked + Laplace success_rate
│
├── affect/correlation.gleam   Affect-Performance Engine — meta-learning Phase D. Pure Pearson math + (snapshot, entry) join + fact key encoding
│
├── comms/                     Communications — email via AgentMail
│   ├── types.gleam            CommsMessage, CommsChannel (Email), Direction, DeliveryStatus, CommsConfig
│   ├── email.gleam            AgentMail HTTP client: send_message, list_messages, get_message
│   └── log.gleam              JSONL persistence (YYYY-MM-DD-comms.jsonl) in .springdrift/memory/comms/
│
├── dprime/                    D' discrepancy-gated safety system
│   ├── types.gleam            Feature, Forecast, GateDecision, GateResult, DprimeConfig/State
│   ├── engine.gleam           Pure D' computation (importance weighting, scaling, gate decision)
│   ├── scorer.gleam           LLM magnitude scoring with prompt building + XStructor XML output
│   ├── canary.gleam           Hijack + leakage probes (fail-open, fresh tokens per request)
│   ├── gate.gleam             Three-layer H-CogAff orchestrator (reactive → deliberative → meta)
│   ├── config.gleam           D' config loading from JSON, unified format (gates + agent overrides + meta + shared + deterministic)
│   ├── deterministic.gleam    Deterministic pre-filter — regex rules, path/domain allowlists (no LLM calls)
│   ├── decay.gleam            Confidence decay — half-life time-based degradation for facts and CBR
│   ├── output_gate.gleam      Output quality gate — evaluates reports before delivery (+ normative calculus)
│   └── meta.gleam             History ring buffer, stall detection, threshold tightening
│
├── normative/                 Normative calculus — Stoic virtue-based safety reasoning
│   ├── types.gleam            NormativeLevel, NormativeOperator, Modality, NormativeProposition, etc.
│   ├── axioms.gleam           Six Stoic axioms as pure predicates (Futility, Indifference, etc.)
│   ├── calculus.gleam         Deterministic conflict resolution (5 rules + pre-processors)
│   ├── judgement.gleam        8 floor rules → FlourishingVerdict (Flourishing/Constrained/Prohibited)
│   ├── character.gleam        CharacterSpec loading from character.json + JSON decoder
│   ├── bridge.gleam           D' forecasts → NormativePropositions translation layer
│   └── drift.gleam            Virtue drift detector — ring buffer + 4 drift signal types
│
├── meta/                      Layer 3b meta observer — post-cycle safety evaluation
│   ├── types.gleam            MetaSignal, MetaIntervention, MetaObservation, MetaState
│   ├── detectors.gleam        Rate limit, cumulative risk, rejection patterns, Layer 3a persistence
│   └── observer.gleam         Post-cycle evaluation, intervention determination
│
├── narrative/                 Prime Narrative — immutable first-person agent memory
│   ├── types.gleam            NarrativeEntry, Intent, Outcome, DelegationStep, Thread, Metrics
│   ├── log.gleam              Append-only JSON-L log, full encode/decode, query functions
│   ├── store_ffi.erl          Erlang FFI for ETS table operations (new, insert, lookup, etc.)
│   ├── librarian.gleam        Supervised actor owning ETS query cache over narrative JSONL
│   ├── curator.gleam          Orchestrator — system prompt assembly, memory integration
│   ├── archivist.gleam        Async LLM-based narrative generation after each cycle
│   ├── appraiser.gleam        Async pre-mortem/post-mortem generation on task lifecycle
│   ├── appraisal_types.gleam  PreMortem, PostMortem, EndeavourPostMortem, AppraisalVerdict
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
├── planner/                   Goal tracking — Tasks, Endeavours, Forecaster
│   ├── types.gleam            PlannerTask, PlanStep, Endeavour, TaskOp, EndeavourOp
│   ├── log.gleam              Daily-rotated JSON-L (YYYY-MM-DD-tasks.jsonl, -endeavours.jsonl)
│   ├── features.gleam         Plan-health feature definitions for D' scoring
│   └── forecaster.gleam       OTP actor: self-ticking plan health evaluator
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
├── tools/planner.gleam        Planner tools: task/endeavour CRUD, get_active_work, get_task_detail
├── tools/how_to_content.gleam Default HOW_TO content (builtin fallback)
├── tools/web.gleam            Web tools: fetch_url, web_search (DuckDuckGo)
├── tools/kagi.gleam           Kagi tools: kagi_search, kagi_summarize (requires KAGI_API_KEY)
├── tools/artifacts.gleam      Artifact tools: store_result, retrieve_result (researcher agent)
├── tools/comms.gleam          Comms tools: send_email, list_contacts, check_inbox, read_message + hard allowlist
├── tools/sandbox.gleam        Sandbox tools: run_code, serve, stop_serve, sandbox_status, workspace_ls, sandbox_exec
│
├── sandbox/                   Local Podman sandbox
│   ├── types.gleam            SandboxConfig, SandboxSlot, SandboxMessage, SandboxManager
│   ├── manager.gleam          OTP actor managing container pool with port forwarding
│   ├── podman_ffi.gleam       FFI declarations for subprocess execution (run_cmd, which)
│   └── diagnostics.gleam      Startup checks: podman version, machine status, image pull
│
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
        ├── vertex.gleam       Google Vertex AI (Anthropic models via rawPredict)
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
- `.springdrift/memory/` — narrative, CBR, facts, artifacts, planner, comms, cycle-log
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

### Plans must be audited against implementation

**When implementing a multi-phase plan, every item must be verified against the
actual code before the work is considered complete.** Plans drift during implementation
— items get skipped, stubs get left in, wiring gets forgotten. After completing a
plan (or at user request), systematically check each planned item:

- Does the file exist? Does it contain the specified types/functions?
- Are all call sites updated? (new parameters, new imports)
- Is the new code actually *reachable* from the running system? (tools registered,
  actors started, handlers wired, UI connected)
- Are sensory/notification channels connected end-to-end? (producer → queue → consumer → render)
- Do tests cover the new behaviour, not just the new types?

The most common failure mode is building the internals correctly but forgetting to
wire them into the running system — tools that exist but are never offered to the LLM,
actors that compile but are never started, UI sections that render but are never called.

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
| Forecaster | App | Self-ticking plan health evaluator (when enabled) |

All cross-process communication uses typed `Subject(T)` channels. No shared mutable
state, no locks. The cognitive loop's notification channel uses pure data types
(`Notification`) with no embedded `Subject` references.

## Config fields (AppConfig)

All fields are `Option` types. Defaults are applied in `springdrift.gleam`.

| Field | CLI flag | Default | Purpose |
|---|---|---|---|
| `provider` | `--provider` | mock | anthropic \| openrouter \| openai \| mistral \| vertex \| local \| mock |
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
| `gui` | `--gui` | tui | GUI mode: `tui` (terminal) or `web` (browser on port 12001) |
| `dprime_enabled` | `--dprime` / `--no-dprime` | True | Enable D' safety evaluation before tool dispatch |
| `dprime_config` | `--dprime-config` | built-in defaults | Path to D' config JSON file |
| `gate_timeout_ms` | — | 60000 | Gate evaluation timeout (ms) — fail-open after this delay |
| `normative_calculus_enabled` | — | True | Stoic normative calculus in output gate (requires character.json) |
| `max_output_modifications` | — | 2 | Max iterations for output gate MODIFY loop |
| `narrative_dir` | `--narrative-dir` | `.springdrift/memory/narrative` | Directory for narrative JSON-L files (narrative is always enabled) |
| `archivist_model` | — | task_model | Model used by the Archivist for narrative generation |
| `narrative_threading` | — | True | Enable automatic thread assignment |
| `librarian_max_days` | — | 180 | Max days of history to replay into ETS at startup; also bounds housekeeping reach |
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
| `forecaster_enabled` | — | False | Enable plan-health Forecaster actor |
| `forecaster_tick_ms` | — | 300000 | Forecaster evaluation interval (ms) |
| `forecaster_replan_threshold` | — | 0.55 | D' score above which replan is suggested |
| `forecaster_min_cycles` | — | 2 | Min cycles on a task before forecaster evaluates |
| `max_delegation_depth` | — | 3 | Max depth for agent delegation chains |
| `sandbox_enabled` | — | True | Enable local Podman sandbox for coder agent |
| `sandbox_pool_size` | — | 2 | Max containers in the pool (max: 3) |
| `sandbox_memory_mb` | — | 512 | Memory limit per container in MB |
| `sandbox_cpus` | — | "1" | CPU limit per container |
| `sandbox_image` | — | "python:3.12-slim" | Container image |
| `sandbox_exec_timeout_ms` | — | 60000 | Per-execution timeout (ms) |
| `sandbox_port_base` | — | 10000 | Host port base for serve mode |
| `sandbox_port_stride` | — | 100 | Host port stride per slot |
| `sandbox_ports_per_slot` | — | 5 | Ports forwarded per slot |
| `sandbox_auto_machine` | — | True | Auto-start podman machine on macOS |
| `vertex_project_id` | — | None | GCP project ID (required for vertex provider) |
| `vertex_location` | — | "europe-west1" | GCP location / region |
| `vertex_endpoint` | — | derived from location | Vertex AI endpoint hostname (e.g. `europe-west1-aiplatform.googleapis.com`) |
| `comms_enabled` | — | False | Enable communications agent (email via AgentMail) |
| `comms_inbox_id` | — | None | AgentMail inbox ID (required when comms enabled) |
| `comms_api_key_env` | — | "AGENTMAIL_API_KEY" | Env var name for AgentMail API key |
| `comms_allowed_recipients` | — | [] | Hard allowlist of permitted email recipients |
| `comms_from_name` | — | agent_name | Display name on outbound emails |
| `comms_max_outbound_per_hour` | — | 20 | Max outbound emails per rolling hour |
| `remembrancer_enabled` | — | False | Enable Remembrancer agent (deep-memory consolidation) |
| `remembrancer_model` | — | reasoning_model | Model for consolidation synthesis |
| `remembrancer_max_turns` | — | 8 | Max react-loop iterations per invocation |
| `remembrancer_consolidation_schedule` | — | "weekly" | Consolidation cadence: "weekly" \| "monthly" |
| `remembrancer_review_confidence_threshold` | — | 0.3 | Decayed confidence floor for fact review |
| `remembrancer_dormant_thread_days` | — | 7 | Min days idle before a thread is dormant |
| `remembrancer_min_pattern_cases` | — | 3 | Min cases to form a mined pattern |
| `strategy_registry_enabled` | — | True | Meta-Learning Phase A. Future config gate; field parses today, no-op without seeded strategies |

## Memory architecture

The agent has nine memory stores, all backed by append-only JSON-L files and
indexed in ETS by the Librarian actor for fast queries.

| Store | Location | Unit | Purpose |
|---|---|---|---|
| Narrative | `.springdrift/memory/narrative/YYYY-MM-DD.jsonl` | `NarrativeEntry` | What happened each cycle: summary, intent, outcome, entities, delegation chain |
| Threads | (derived from narrative entries) | `Thread` / `ThreadState` | Ongoing lines of investigation grouping related narrative entries |
| Facts | `.springdrift/memory/facts/YYYY-MM-DD-facts.jsonl` | `MemoryFact` | Explicit key-value working memory with scope (Session/Persistent/Ephemeral) and confidence |
| CBR cases | `.springdrift/memory/cbr/cases.jsonl` | `CbrCase` | Problem-solution-outcome patterns for case-based reasoning |
| Artifacts | `.springdrift/memory/artifacts/artifacts-YYYY-MM-DD.jsonl` | `ArtifactRecord` | Large content stored on disk (web pages, extractions) with 50KB truncation |
| Tasks | `.springdrift/memory/planner/YYYY-MM-DD-tasks.jsonl` | `PlannerTask` | Planned work with steps, dependencies, risks, forecast scores |
| Endeavours | `.springdrift/memory/planner/YYYY-MM-DD-endeavours.jsonl` | `Endeavour` | Self-directed initiatives grouping multiple independent tasks |
| DAG nodes | (in-memory ETS, populated from cycle log) | `CycleNode` | Operational telemetry: token counts, tool calls, D' gates, agent output per cycle |
| Comms | `.springdrift/memory/comms/YYYY-MM-DD-comms.jsonl` | `CommsMessage` | Sent and received email messages with delivery status |
| Consolidation | `.springdrift/memory/consolidation/YYYY-MM-DD-consolidation.jsonl` | `ConsolidationRun` | Remembrancer run records: period, counts, report path |
| Strategies | `.springdrift/memory/strategies/YYYY-MM-DD-strategies.jsonl` | `StrategyEvent` | Meta-learning Phase A. Append-only Created/Used/Outcome/Archived events; `Strategy` derived by replay |

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
`librarian_max_days`, default 180). The Remembrancer agent reads beyond this
window directly from JSONL when deeper reach is needed.

**Cognitive loop tools** (12 memory + 4 planner + 4 builtin = 20 tools on the
cognitive loop). Diagnostic/forensic tools and CBR curation moved to the Observer
agent. Heavy planner operations moved to the Planner agent.

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
| `reflect` | DAG | Aggregated day-level stats (cycles, tokens, models, gate decisions) |
| `introspect` | All | Perceive system state: identity, agent roster, D' config, cycle ID |
| `how_to` | HOW_TO.md | Operator guide: tool selection heuristics, degradation paths |
| `cancel_agent` | Registry | Stop a running agent delegation by name |
| `complete_task_step` | Tasks | Mark a step complete on a task |
| `activate_task` | Tasks | Set a pending task as current focus |
| `get_active_work` | Tasks+Endeavours | List active tasks and endeavours with progress |
| `get_task_detail` | Tasks | Full task detail: steps, risks, forecast score, cycles |

**Observer agent tools** (18 tools — diagnostic, forensic, CBR curation):

| Tool | Store | Purpose |
|---|---|---|
| `inspect_cycle` | DAG | Drill into a specific cycle tree with tool calls and agent output |
| `list_recent_cycles` | DAG | Discover cycle IDs for a date (feed into `inspect_cycle`) |
| `query_tool_activity` | DAG | Per-tool usage stats for a date |
| `review_recent` | DAG + Narrative | Structured self-review across N recent cycles with filtering |
| `detect_patterns` | DAG + Narrative | Automated pattern detection: repeated failures, tool clusters, cost outliers |
| `memory_trace_fact` | Facts | Full history of a key including supersessions |
| `correct_case` | CBR | Fix misclassified case data |
| `annotate_case` | CBR | Add pitfall annotation to a case |
| `suppress_case` | CBR | Remove a case from retrieval |
| `unsuppress_case` | CBR | Restore a previously suppressed case to retrieval |
| `boost_case` | CBR | Adjust a case's confidence score |
| `report_false_positive` | Meta | Flag a D' rejection as a false positive (cycle_id + reason) |
| `recall_recent` | Narrative | (shared — Observer can also search memory) |
| `recall_search` | Narrative | (shared) |
| `recall_threads` | Threads | (shared) |
| `recall_cases` | CBR | (shared) |
| `reflect` | DAG | (shared) |
| `introspect` | All | (shared) |

**Planner agent tools** (22 tools — full work management + forecaster introspection):

| Tool | Store | Purpose |
|---|---|---|
| `create_endeavour` | Endeavours | Create a self-directed initiative grouping tasks |
| `add_task_to_endeavour` | Endeavours | Associate a task with an endeavour |
| `flag_risk` | Tasks | Record that a predicted risk has materialised |
| `abandon_task` | Tasks | Stop tracking a task |
| `request_forecast_review` | Tasks | Request plan health evaluation |
| `add_phase` | Endeavours | Add a phase to an endeavour |
| `advance_phase` | Endeavours | Mark phase complete, advance to next (approval-gated) |
| `schedule_work_session` | Endeavours | Schedule next autonomous work session |
| `report_blocker` | Endeavours | Report a blocker, optionally requiring human |
| `resolve_blocker` | Endeavours | Mark a blocker as resolved |
| `get_endeavour_detail` | Endeavours | Full detail: phases, blockers, sessions, metrics |
| `get_forecaster_config` | Config | View features, weights, thresholds (global + per-endeavour) |
| `update_forecaster_config` | Config | Adjust per-endeavour feature weights/threshold |
| `update_endeavour` | Endeavours | Modify goal, deadline, update cadence |
| `cancel_work_session` | Endeavours | Cancel a scheduled work session |
| `list_work_sessions` | Endeavours | View session history with filtering |
| `update_task` | Tasks | Edit task title or description |
| `add_task_step` | Tasks | Add a new step to an existing task |
| `remove_task_step` | Tasks | Remove a step by index |
| `get_forecast_breakdown` | Tasks+Endeavours | Per-feature health breakdown for a task or endeavour |
| `delete_task` | Tasks | Permanently delete a task |
| `delete_endeavour` | Endeavours | Permanently delete an endeavour |
| `add_phase` | Endeavours | Add a phase to an endeavour |
| `advance_phase` | Endeavours | Mark phase complete, advance to next (approval-gated) |
| `schedule_work_session` | Endeavours | Schedule next autonomous work session |
| `report_blocker` | Endeavours | Report a blocker, optionally requiring human intervention |
| `resolve_blocker` | Endeavours | Mark a blocker as resolved |
| `get_endeavour_detail` | Endeavours | Full detail: phases, blockers, sessions, metrics |

**Artifact tools** (2 tools in `tools/artifacts.gleam`, on researcher agent):

| Tool | Store | Purpose |
|---|---|---|
| `store_result` | Artifacts | Store large content to disk, returns compact artifact_id |
| `retrieve_result` | Artifacts | Retrieve stored content by artifact_id |

**Comms agent tools** (4 tools in `tools/comms.gleam`):

| Tool | Store | Purpose |
|---|---|---|
| `send_email` | Comms | Send email via AgentMail (hard allowlist + D' gate) |
| `list_contacts` | Comms | List allowed recipients from config |
| `check_inbox` | Comms | List recent messages in inbox |
| `read_message` | Comms | Read full message content by ID |

**Remembrancer tools** (10 tools in `tools/remembrancer.gleam`, on Remembrancer agent):

| Tool | Store(s) | Purpose |
|---|---|---|
| `deep_search` | Narrative | Search full narrative archive across date range (bypasses Librarian ETS window) |
| `fact_archaeology` | Facts | Trace a fact key through every write/supersede/clear + find related keys |
| `mine_patterns` | CBR | Cluster cases by domain + shared keywords, return patterns above min_cases |
| `resurrect_thread` | Narrative | Find dormant threads (no activity >N days), optionally filtered by topic |
| `consolidate_memory` | Narrative+CBR+Facts | Gather statistics + excerpts for a period for in-agent synthesis |
| `restore_confidence` | Facts | Write a verified fact with restored confidence (supersedes previous) |
| `find_connections` | Narrative+CBR+Facts | Cross-reference a topic across all memory stores with hit counts |
| `write_consolidation_report` | Knowledge + Consolidation | Persist markdown report + append ConsolidationRun log entry |
| `propose_skills_from_patterns` | CBR + Skills | Mine CBR clusters, generate skill proposals (LLM body + template fallback), run through the Promotion Safety Gate, promote accepted ones to Active skills on disk |
| `analyze_affect_performance` | Affect + Narrative + Facts | Phase D. Compute Pearson r between each affect dimension and outcome success per task domain; persist significant correlations as facts under `affect_corr_<dim>_<domain>`; sensorium reads them as `<affect_warning>` |

**Remembrancer** (`agents/remembrancer.gleam`) is a deep-memory specialist. Unlike
Observer (recent-cycle diagnostics via Librarian), the Remembrancer reads raw JSONL
directly from disk, so it works across months/years of archive — beyond the
Librarian's ETS window. Enabled via `remembrancer_enabled = true` (default: False).
Model defaults to `reasoning_model` since synthesis is the main capability.
Consolidation reports land in `.springdrift/knowledge/consolidation/YYYY-MM-DD-*.md`
and a JSONL run log at `.springdrift/memory/consolidation/`. The latest run's
timestamp surfaces in the sensorium as `<memory last_consolidation="..."
consolidation_age="..."/>`. Scheduled consolidation is created at runtime via the
scheduler agent's `schedule_from_spec` tool — ask the scheduler agent to create a
weekly recurring job that delegates to the Remembrancer. Skills proposal
(`propose_skills_from_patterns`) mines CBR clusters, generates `SkillProposal`s
via `src/skills/body_gen.gleam`, runs them through the Promotion Safety Gate
(`src/skills/safety_gate.gleam`), and promotes accepted ones to Active skills on
disk — agent-led evolution, operator-audited via the skills lifecycle log at
`.springdrift/memory/skills/YYYY-MM-DD-skills.jsonl`.

**Curator** (`narrative/curator.gleam`) assembles the system prompt from memory.
On each `BuildSystemPrompt` message (with optional `CycleContext`) it loads identity
files (persona + preamble template), queries the Librarian for thread/fact/case counts,
builds an XML sensorium block with clock/situation/schedule/vitals sections, renders
`{{slot}}` substitutions and `[OMIT IF]` rules, and returns the final prompt. Falls
back to a plain system prompt when no identity files exist.

**Archivist** (`narrative/archivist.gleam`) runs after each final reply as a
fire-and-forget `spawn_unlinked` process. Uses a two-phase Reflector/Curator pipeline
(per ACE paper 2510.04618): Phase 1 (Reflection) makes a plain-text LLM call focused
on honest assessment of what worked/failed. Phase 2 (Curation) takes the reflection
and generates structured `NarrativeEntry` + `CbrCase` via XStructor. If Phase 1 fails,
falls back to the original single-call approach. If Phase 2 fails after Phase 1
succeeds, the reflection is preserved in logs. Assigns thread, category, provenance,
and usage stats. Appends to JSONL and notifies the Librarian. Also updates CBR usage
stats for any cases retrieved during the cycle. Failures never affect the user.

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
| Planner | none (XML output) | 5 | unlimited | Permanent | Pure reasoning: plan decomposition, steps, dependencies, risk identification |
| Project Manager | planner (22 tools) | 8 | unlimited | Permanent | Full work management: tasks, endeavours, phases, sessions, blockers, forecaster |
| Researcher | web + artifacts + builtin | 8 | 30 | Permanent | Gather information via search and extraction |
| Coder | builtin | 10 | unlimited | Permanent | Write and modify code, fix errors |
| Writer | knowledge (drafts) + artifacts + builtin | 5 | unlimited | Permanent | Draft structured reports; create/update/promote drafts via document library |
| Observer | diagnostic + CBR curation (18 tools) | 6 | 20 | Transient | Cycle forensics, pattern detection, CBR curation, fact tracing, D' feedback |
| Comms | comms (4 tools) | 6 | 20 | Permanent | Send and receive email via AgentMail |
| Remembrancer | remembrancer (10 tools) | 8 | 30 | Transient | Deep-memory consolidation + skills proposals + affect-performance correlation. Search, trace, cluster, resurrect dormant threads, restore verified confidence, cross-reference, persist reports |

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
validates that `path` ends with `SKILL.md` before reading. Discovery automatically reads
an optional `skill.toml` sidecar in the same directory and merges it over the frontmatter
(see Skill directory format below for the sidecar schema).

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
assessment, pitfalls), source narrative ID, optional category, and optional usage
stats. The Librarian actor indexes CBR cases in ETS alongside narrative entries.
`cbr/bridge.gleam` provides `CaseBase` with inverted index and optional semantic
embeddings. Retrieval uses a weighted sum of 6 signals: weighted field score
(intent/domain match, keyword/entity Jaccard), inverted index overlap, recency,
domain match, optional embedding cosine similarity, and utility score (from usage
tracking). Default retrieval cap is K=4 cases (per Memento paper finding that more
causes context pollution). Weights are configurable via `RetrievalWeights`; when
embeddings are unavailable, embedding weight is redistributed to the other signals.
`cbr/log.gleam` provides append-only JSON-L persistence with lenient decoders
(null → defaults).

**CBR self-improvement** — cases track their own utility via `CbrUsageStats`
(retrieval_count, retrieval_success_count, helpful_count, harmful_count). When
`recall_cases` returns cases, their IDs are recorded. The Archivist updates usage
stats post-cycle based on outcome success/failure. Retrieval scoring blends a
Laplace-smoothed utility score: `(successes + 1) / (retrievals + 2)`. Cases are
typed by `CbrCategory` (Strategy, CodePattern, Troubleshooting, Pitfall,
DomainKnowledge) — assigned deterministically by the Archivist based on outcome.
The Curator organises injected cases by category in the system prompt.

**Facts store** — key-value memory in `facts/types.gleam` and `facts/log.gleam`.
`MemoryFact` has scope (Session/Persistent/Global), operation (Write/Delete/Superseded),
confidence score, supersedes chain, and optional `FactProvenance` (source_cycle_id,
source_tool, source_agent, derivation: DirectObservation/Synthesis/OperatorProvided/
Unknown). Facts use daily-rotated JSONL files (`YYYY-MM-DD-facts.jsonl`). The Librarian
replays recent files at startup and migrates legacy `facts.jsonl` to the new format.
The Librarian indexes facts in ETS and supports read/write/delete operations.
Fact confidence decays at read time via half-life formula:
`confidence_t = confidence_0 * 2^(-age_days / half_life_days)` (configurable,
default 30 days). Stored confidence is never mutated — decay is applied at query time.
`dprime/decay.gleam` provides the pure decay functions.

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
`session_since`, `agents_active`, `message_count`, and `novelty` (Float, per-input
keyword dissimilarity) — data the Curator can't derive itself.

`build_sensorium` assembles a self-describing XML `{{sensorium}}` slot — the agent's
ambient perception block injected at every cycle start (no tool calls needed). It
also gains a `<strategies>` section once the Strategy Registry has any active
strategies — top 3 by Laplace-smoothed success rate (omitted when registry empty) —
an `<affect_warnings>` block surfacing strong negative
correlations (r ≤ -0.4) between affect dimensions and outcome success per
domain (Phase D; sourced from facts written by `analyze_affect_performance`),
and a `<skill_procedures>` block mapping action classes (delegate, create_task,
send_email, etc.) to the skill the agent should consult before acting — the
structured nudge for Curragh's "skills as passive reference, not active
procedure" gap (omitted when no matching skills are loaded).
Sections:
1. `<clock>` — `now` (ISO timestamp), `session_uptime`, optional `last_cycle` elapsed
2. `<situation>` — `input` source ("user"/"scheduler"), `queue_depth`,
   `conversation_depth` (message count), optional `thread` (most recent active thread)
3. `<schedule>` — `pending`/`overdue` counts + `<job>` elements (omitted when empty)
4. `<vitals>` — `cycles_today`, `agents_active`, conditional `agent_health`,
   conditional `last_failure` (from narrative entries, replaces raw success_rate),
   optional `cycles_remaining`/`tokens_remaining` budget attrs, performance summary
   attributes (`success_rate` 0.0-1.0, `recent_failures` semicolon-separated last 3
   failure descriptions omitted when empty, `cost_trend` stable/increasing/decreasing,
   `cbr_hit_rate` proportion of entries with source references), and a `novelty`
   signal (keyword dissimilarity to recent narrative entries, computed per-input from
   Jaccard similarity). Performance summary (`PerformanceSummary`) is computed by
   `compute_performance_summary` in `narrative/curator.gleam` from recent narrative
   entries — these are history-backed signals that span sessions (not reset on restart).
   `novelty` is the only remaining per-cycle meta-state signal, passed directly as a
   `Float` parameter to `render_sensorium_vitals`. No LLM calls needed. Based on
   Sloman's H-CogAff meta-management layer and the Dupoux/LeCun/Malik System M paper
   (2603.15381).

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
Per-profile D' uses the unified config format in `dprime.json` (see below).

**D' unified config** — `dprime/config.gleam` loads a unified JSON format from
`dprime.json` (see `.springdrift_example/dprime.json` for a full example). The unified
format has five top-level keys:

- `gates` — named gate configs: `input` (pre-cycle input screening), `tool` (before
  tool dispatch), `output` (finished report quality, optional), `post_exec` (after tool
  execution, optional). Each gate defines `features`, `modify_threshold`,
  `reject_threshold`, and optional `canary_enabled`.
- `agent_overrides` — per-agent tool gate configs keyed by agent name (e.g. `coder`,
  `researcher`). When a specialist agent dispatches tool calls, `get_agent_tool_config`
  returns the agent-specific features and thresholds instead of the default `tool` gate.
- `meta` — Layer 3b observer settings: `enabled`, `rate_limit_max_cycles`,
  `elevated_score_threshold`, `rejection_count_threshold`, `tighten_factor`, etc.
- `shared` — common settings applied to all gates that don't explicitly override them
  (`tiers`, `max_history`, `stall_window`, `max_iterations`).
- `deterministic` — regex-based pre-filter rules that run BEFORE any LLM calls.
  Contains `input_rules`, `tool_rules`, `output_rules` (each a list of `{id, pattern,
  action}` where action is `"block"` or `"escalate"`), plus `path_allowlist` and
  `domain_allowlist`. Deterministic blocks short-circuit the gate with no LLM cost.
  Escalations enrich context for the LLM scorer. The agent sees decisions ("banned
  pattern detected") but NOT the rule patterns — patterns are operator-only config.

Backward compatible with the old `tool_gate`/`output_gate` dual-gate format and
single-gate format — `load_unified` auto-detects and converts.

**Input gate fast-accept** — the input gate uses a split evaluation path for
performance. Since the operator is the user, the primary threat on user input is
indirect injection (not the operator themselves). The flow differs by source:

**Interactive cycles (operator input):**
1. Deterministic regex pre-filter → Block, Escalate, or Pass
2. Block is **demoted to Escalate** (operator-typed content is trusted; canaries
   decide). Only the rule_id is logged, no hard reject.
3. Canary probes (hijack + leakage, 2 LLM calls) → if detected, reject
4. If canaries clean → fast-accept (no LLM scorer). Done.

This lets the operator discuss adversarial patterns, jailbreak research, and
meta-conversation about safety systems without being blocked by substring
matches. `\bDAN\b` still matches legitimate uses of the term; it just takes
the canary-probe path instead of hard-rejecting.

**Autonomous cycles (scheduler input):**
1. Full deterministic check (regex + structural + payload signatures)
2. Block → hard reject immediately, no LLM calls
3. Escalate → full LLM scorer evaluation (reactive + deliberative layers)
4. Pass → canary probes → fast-accept if clean

Scheduler input can carry indirect injection from email bodies, fetched web
content, or other untrusted sources. Hard-block semantics are retained there.

The tool gate does NOT get fast-accept — it always runs the full LLM scorer
for non-exempt tools, because the threat there is a compromised agent acting
on indirect injection via web content.

**Canary probes** — `dprime/canary.gleam` runs hijack and leakage probes using
fresh random tokens per request. Fail-open: LLM errors during probes are treated
as inconclusive (not evidence of hijacking). Consecutive probe failures are tracked
on `CognitiveState.consecutive_probe_failures` — at 3 consecutive failures, a
`canary_probe_degraded` sensory event is emitted so the agent and operator know the
safety probe LLM may be degraded. Counter resets on successful probe.

**Output gate** — second D' evaluation point in `dprime/output_gate.gleam`. Evaluates
finished reports for quality (unsourced claims, causal overreach, stale data) before
delivery. Uses `scorer.score_with_custom_prompt` with an output-specific prompt (not
the generic input/tool scoring wrapper). Report text is truncated to 6000 chars for
scoring to prevent exceeding the scorer's context window. Bounded modification loop
(max `max_output_modifications` iterations, default 2). The tool gate and output gate
maintain separate `DprimeState` instances (gate state isolation) to prevent
cross-contamination of history and thresholds.

**Output gate split strategy** — the output gate uses different evaluation paths
depending on whether the cycle is interactive or autonomous:
- **Interactive cycles** (user input): deterministic rules only (credential patterns,
  private keys, PII). The LLM scorer is skipped entirely. The operator is present
  and is the quality gate — pre-delivery LLM scoring destroys good output via false
  positives and teaches the agent to self-censor.
- **Autonomous cycles** (scheduler-triggered): full LLM scorer + normative calculus.
  Nobody is watching, so quality evaluation before delivery matters.
The split is based on `cycle_node_type` (`SchedulerCycle` vs `CognitiveCycle`).
Deterministic rules always run on all output regardless of cycle type.

**Output gate MODIFY prompt** — when the output gate returns MODIFY (autonomous
cycles only), the cognitive loop injects a correction message telling the agent to
fix ONLY the flagged issues while preserving all other content, structure, and tone.
The prompt explicitly forbids removing unflagged information or adding unnecessary
hedging.

**Output gate session hygiene** — gate injection messages (MODIFY corrections, REJECT
notices) are filtered from `session.json` before saving. These are transient control
signals that, if persisted, create a feedback loop where the agent learns to
self-censor on session resume. The filter is applied in `cognitive/memory.gleam`'s
`request_save`. Rejection notices in the agent's live message history are kept terse
(decision + score + triggers only) — full explanations go to the cycle log.

**Gate timeout (BF-12)** — all gate evaluations have a configurable timeout
(`gate_timeout_ms`, default 60000). If the scorer LLM hangs, a `GateTimeout`
message fires via `send_after`. The output gate timeout delivers the report
(fail-open) using `pending_output_reply` stored on `CognitiveState`. Late gate
completions are ignored (status has already moved to Idle).

**D' normalization** — BF-03 fix ensures all D' scores are normalized to [0,1] via
min-max scaling before gate decisions. Raw importance-weighted sums are no longer
compared directly against thresholds.

**Normative calculus** — Stoic-inspired deterministic safety reasoning in
`src/normative/`. Based on Becker's *A New Stoicism* (ported from the TallMountain
Python implementation). When `normative_calculus_enabled = true`, the output gate
applies virtue-based evaluation *after* D' scoring — no new LLM calls.

The calculus operates on the existing D' scorer output:
1. `bridge.forecasts_to_propositions` maps D' forecasts to user-side
   `NormativeProposition`s (level from feature name, operator from magnitude)
2. `calculus.resolve_all` resolves each user NP against the character spec's
   `highest_endeavour` system NPs using 5 deterministic rules + 3 pre-processors
3. `judgement.judge` applies 8 floor rules in priority order to produce a
   `FlourishingVerdict` (Flourishing→Accept, Constrained→Modify, Prohibited→Reject)

Core types in `normative/types.gleam`:
- `NormativeLevel` — 14-tier enum (EthicalMoral=6000 through Operational=100)
- `NormativeOperator` — Required(3), Ought(2), Indifferent(1)
- `Modality` — Possible, Impossible
- `ConflictSeverity` — NoConflict, Coordinate, Superordinate, Absolute
- `FlourishingVerdict` — Flourishing, Constrained, Prohibited
- `CharacterSpec` — virtues + highest_endeavour NPs (loaded from `character.json`)

Six Stoic axioms (`normative/axioms.gleam`):
- 6.6 Futility: IMPOSSIBLE modality is normatively inert
- 6.7 Indifference: INDIFFERENT operator carries no weight
- 6.2 Absolute prohibition: ETHICAL_MORAL + REQUIRED is categorical
- 6.3 Moral priority: system level > user level → system wins
- 6.4 Moral rank: same level, stronger operator → system wins
- 6.5 Normative openness: no conflicts → compatible

Eight floor rules (`normative/judgement.gleam`):
1. PROHIBITED: any Absolute severity
2. PROHIBITED: Superordinate at Legal or higher
3. PROHIBITED: D' ≥ reject_threshold (preserves existing behaviour)
4. CONSTRAINED: catastrophic + Superordinate
5. CONSTRAINED: 2+ Coordinate conflicts
6. CONSTRAINED: D' ≥ modify_threshold (preserves existing behaviour)
7. CONSTRAINED: Superordinate at ProfessionalEthics–SafetyPhysical
8. FLOURISHING: default

Virtue drift detector (`normative/drift.gleam`): ring buffer of recent verdicts,
detects high prohibition/constraint rates, repeated axiom firing, and
over-restriction patterns.

Character spec (`normative/character.gleam`): loaded from `identity/character.json`
in identity directories using the same discovery pattern as `persona.md`. Contains
virtues (name + behavioural expressions) and highest endeavour (list of NPs).
`default_character()` provides a fallback with 5 virtues and 4 core commitments.

Every verdict includes a named axiom trail — the list of rules that fired during
resolution. This trail appears in the output gate explanation and cycle log,
making decisions auditable and inspectable.

Enabled by default (`normative_calculus_enabled = true`). Requires
`identity/character.json` — if the character spec is missing, falls back to
plain D' threshold comparison. Set `normative_calculus_enabled = false` in
`[dprime]` to disable explicitly.

**Meta observer** — Layer 3b post-cycle safety evaluation in `src/meta/`. Runs after
each cognitive cycle completes, analyzing patterns across gate decisions. Detectors
(`meta/detectors.gleam`) check for: rate limit violations (too many gates in a window),
cumulative risk drift, rejection pattern anomalies, Layer 3a persistence (repeated
threshold tightening), and high false positive rate (too many rejections flagged as
false positives, suggesting overly aggressive thresholds). The observer
(`meta/observer.gleam`) aggregates detector signals into `MetaIntervention` actions.
Integrated into the cognitive loop as a post-cycle hook — interventions are logged but
do not block the current cycle. The `report_false_positive` tool lets the agent flag
D' rejections as incorrect; these annotations persist to JSONL (`meta/log.gleam`) and
are factored into the repeated rejection detector (annotated cycles are excluded) and
the high false positive rate detector (escalates to user when >=50% of rejections in
the window are false positives).

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

**Local Podman sandbox** — `sandbox/manager.gleam` is an OTP actor managing a pool of
Podman containers for the coder agent. Two execution modes: `run_code` (synchronous
script execution) and `serve` (long-lived process with port forwarding). Port allocation
is deterministic: `host_port = port_base + slot * port_stride + index`, with container-
internal ports fixed at 47200-47204. All ports are mapped at container creation time.
The manager runs health checks every 30s and restarts failed containers. Startup
verifies `podman` binary, optionally starts podman machine on macOS, pulls the image
if missing, and sweeps stale `springdrift-sandbox-*` containers. When `sandbox_enabled`
is False (default), the coder agent falls back to `request_human_input` — no sandbox
code runs. Workspace dirs live at `.sandbox-workspaces/N/` in the project root
(a sibling of `.springdrift/`, deliberately separate to isolate ephemeral
container state from persistent agent memory). Add `.sandbox-workspaces/`
to `.gitignore`.
The coder agent has six sandbox tools: run_code (execute scripts), serve/stop_serve (long-lived processes), sandbox_status (slot states and ports), workspace_ls (list workspace files), and sandbox_exec (direct shell commands for git, pip, curl, etc.).

**Delegation management** — the cognitive loop tracks active agent delegations via
`active_delegations: Dict(String, DelegationInfo)` on `CognitiveState`. The agent
framework sends `AgentProgress` messages after each react-loop turn with turn count,
token usage, and last tool called. The Curator renders a `<delegations>` section in
the sensorium XML showing live agent state (name, turn N/M, tokens, elapsed time,
instruction summary). The `cancel_agent` tool sends `StopChild` to the supervisor to
kill a misbehaving agent. `DelegationInfo` tracks agent name, instruction, turn,
max_turns, tokens, last tool, started_at_ms, and depth. Delegation depth is capped
by `max_delegation_depth` config (default: 3). `AgentTask` carries a `depth: Int`
field set to 1 for cognitive-loop dispatches. Sub-agents (`request_human_input`
removed from all agents) report only through their return value — they cannot hijack
the user interaction channel. `builtin.agent_tools()` provides the safe tool subset
for sub-agents, excluding `request_human_input`.

**Parallel dispatch** — when the LLM requests multiple agent tool calls in a single
response, they are dispatched simultaneously. All agents run in parallel as independent
OTP processes. The `WaitingForAgents` status accumulates results in any order. When all
agents complete, results are combined into a single user message and the cognitive loop
re-thinks to synthesise. `DispatchStrategy` type (Parallel, Pipeline, Sequential) in
`agent/types.gleam` documents the three modes. Parallel is the default and already-
implemented behaviour; Pipeline and Sequential are used by the team orchestrator.

**Agent teams** — coordinated groups of agents working on the same problem with a
shared strategy. Teams are defined as `TeamSpec` in `src/agent/team.gleam` and appear
as tools (prefix `team_<name>`) alongside agent tools. When a team tool is called, the
cognitive loop spawns a team orchestrator process that coordinates member agents
internally, synthesises results via an LLM call, and sends `AgentComplete` back.

Four coordination strategies:
- **ParallelMerge**: all members work simultaneously, results merged by synthesis LLM
- **TeamPipeline**: members work in sequence, each receives the prior member's output
  as `<prior_stage_output>` context
- **DebateAndConsensus(max_rounds)**: members produce independent analyses, then
  debate disagreements over multiple rounds. Convergence detected by keyword overlap
  (>60% significant words). Forces synthesis after `max_rounds` if no consensus.
- **LeadWithSpecialists(lead)**: specialists work in parallel first, then the lead
  receives all specialist results as `<specialist_results>` context and produces the
  final output. No separate synthesis step — the lead's output IS the result.

Each `TeamMember` specifies `agent_name` (must match a registered agent), `role`
(injected as `<team_role>` in the instruction), and `perspective` (injected as
`<perspective>` overlay). `ContextScope` is SharedFacts or Independent.

Teams are registered via `team_specs: List(TeamSpec)` on `CognitiveConfig` and
`CognitiveState`. Team tools are generated automatically by `team.team_to_tool()`.
The team orchestrator receives `AgentComplete` messages from member agents on its own
`Subject(CognitiveMessage)` — the cognitive loop is unaware of the internal coordination.

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

**Web research tools** — the researcher agent has 10 web tools in 4 tiers:
Tier 1: `kagi_search`, `kagi_summarize` (Kagi API, requires `KAGI_API_KEY`).
Tier 2: `brave_web_search`, `brave_news_search`, `brave_llm_context`,
`brave_summarizer`, `brave_answer` (Brave API, requires `BRAVE_SEARCH_API_KEY`).
Tier 3: `jina_reader` (Jina, requires `JINA_API_KEY`).
Tier 4: `web_search` (DuckDuckGo, no key), `fetch_url` (raw HTTP GET, no key).
Tool modules: `tools/kagi.gleam`, `tools/brave.gleam`, `tools/jina.gleam`,
`tools/web.gleam`. A `web-research` skill teaches the agent the decision tree
for tool selection.

**Tasks and Endeavours** — `planner/types.gleam`, `planner/log.gleam`, `tools/planner.gleam`.
A Task is a unit of planned work with steps, dependencies, risks, and a forecast score.
An Endeavour is a living work programme with phases, work sessions, blockers, stakeholder
communication, and approval gates. Both persist as append-only JSONL operations in
`.springdrift/memory/planner/`, with current state derived by replaying operations
(`resolve_tasks`/`resolve_endeavours` — 12 EndeavourOp variants). The Planner agent
auto-creates Tasks via the output hook in `cognitive/agents.gleam` and manages endeavours
via 11 tools including `add_phase`, `advance_phase`, `schedule_work_session`,
`report_blocker`, `resolve_blocker`, and `get_endeavour_detail`. Quick planner tools
(`complete_task_step`, `activate_task`, `get_active_work`, `get_task_detail`) remain on
the cognitive loop for synchronous side-effect execution. The sensorium's `<tasks>`
section shows active work including endeavour phase progress, blocker count, and
next_session to the LLM on every cycle without tool calls.

**Autonomous endeavours** — an Endeavour has: goal + success_criteria, ordered Phases
(with status, milestone, estimated/actual sessions), WorkSessions (scheduled autonomous
work periods), Blockers (with requires_human flag), Stakeholders (with update preference),
and ApprovalConfig (auto/notify/require_approval per gate type: phase_transition,
budget_increase, external_communication, replan, completion). The Forecaster evaluates
endeavour health using D' scoring over phase completion rate, blocker accumulation,
scope drift, and replan frequency. Approval gates are enforced in the `advance_phase`
tool — if phase_transition requires approval, the tool returns a message asking the
agent to consult the operator instead of advancing.

**Sensory events** — `QueuedSensoryEvent` in `agent/types.gleam`. A new cognitive input
channel for ambient perception. Events accumulate in `pending_sensory_events` on
`CognitiveState` and are drained into the Curator's `CycleContext` at the start of
each cycle, then rendered as `<events>` in the sensorium XML. Events never trigger a
cycle — they're consumed passively when the next cycle runs. The Forecaster sends
replan suggestions as sensory events.

**Forecaster** — `planner/forecaster.gleam`. An OTP actor with `process.send_after`
self-tick that evaluates active tasks using heuristic D' scoring (reuses
`dprime/engine.compute_dprime`). When a task's D' score exceeds the replan threshold
(default 0.55), it sends a `QueuedSensoryEvent` to the cognitive loop. Enabled via
`forecaster_enabled` config. Does not use the Scheduler — ticks independently.

**Communications agent** — `agents/comms.gleam` + `comms/` + `tools/comms.gleam`.
Email via AgentMail API (HTTP client in `comms/email.gleam`). Enabled via
`comms_enabled` config (default: False). When enabled, the comms agent is added to
`default_agent_specs` in `springdrift.gleam`. Four tools: `send_email`, `list_contacts`,
`check_inbox`, `read_message`. Comms tools are NOT D'-exempt — they are
external-facing and pass through the full tool gate. Three-layer safety:
1. **Hard allowlist** — the tool executor checks `comms_allowed_recipients` before
   any send. Recipients not on the list are rejected immediately, no LLM evaluation.
2. **Deterministic rules** — 5 output rules in `dprime.json`: `comms-bearer-token`
   (block), `comms-localhost` (block), `comms-env-var-ref` (block),
   `comms-system-json` (escalate), `comms-system-jargon` (escalate).
3. **Agent override** — `comms` agent has tighter D' thresholds (0.30 modify / 0.50
   reject) with 4 features: `credential_exposure` (critical), `internal_url_exposure`
   (critical), `system_internals` (medium), `tone_appropriateness` (medium).

Messages persist as append-only JSONL in `.springdrift/memory/comms/YYYY-MM-DD-comms.jsonl`.
`CommsConfig` on `AppConfig` carries `inbox_id`, `api_key_env` (env var name, default
`AGENTMAIL_API_KEY`), `allowed_recipients`, `from_name`, and `max_outbound_per_hour`.

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
| `[forecaster]` | Plan-health Forecaster: enabled, tick_ms, threshold, min_cycles |
| `[agents.planner]` | Planner agent: max_tokens, max_turns, max_errors |
| `[agents.researcher]` | Researcher agent: max_tokens, max_turns, max_errors, max_context |
| `[agents.coder]` | Coder agent: max_tokens, max_turns, max_errors |
| `[agents.writer]` | Writer agent: max_tokens, max_turns, max_errors |
| `[web]` | Web GUI port |
| `[services]` | External API base URLs (DuckDuckGo, Brave, Jina, Kagi) |
| `[sandbox]` | Local Podman sandbox: enabled, pool_size, memory, ports, image |
| `[delegation]` | Agent delegation depth limits |
| `[comms]` | Communications agent: enabled, inbox_id, api_key_env, allowed_recipients, rate limit |
| `[remembrancer]` | Remembrancer agent: enabled, model, max_turns, consolidation_schedule, review_confidence_threshold, dormant_thread_days, min_pattern_cases |
| `[vertex]` | Google Vertex AI provider: project_id, location, endpoint |

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
    ├── dprime.json          # Optional — unified D' config (gates + agent_overrides + meta + shared)
    ├── schedule.toml        # Optional — recurring tasks with delivery config
    └── skills/              # Optional — profile-specific skills
        └── summarize/
            └── SKILL.md
```

CLI flags override config files. `--skills-dir` is repeatable and appends to the list.

## Skill directory format

```
.springdrift/skills/
├── self-diagnostic/      Observer: 7-step health check procedure
├── delegation-strategy/  Cognitive: when and how to delegate to agents
├── memory-management/    Cognitive + researcher + observer: which memory store for what
├── planner-patterns/     Planner + cognitive: task decomposition patterns
├── planner-management/   Planner + cognitive: forecaster introspection, feature tuning, endeavour lifecycle
├── code-review/          Coder: sandbox patterns and common failure modes
├── web-research/         Researcher + cognitive: web tool selection decision tree
└── shell-sandbox/        Coder: Docker sandbox usage guide
```

`SKILL.md` must open with `---`-fenced YAML frontmatter containing at least `name:`
and `description:`. Optional `agents:` field scopes the skill to specific agents
(comma-separated). Skills without `agents:` are injected for all agents. The
`skills.for_agent(all_skills, agent_name)` function filters at injection time.

```yaml
---
name: web-research
description: Search and extraction strategy
agents: researcher, cognitive
---
```

### Optional `skill.toml` sidecar

Skills may include a `skill.toml` alongside `SKILL.md` to extend the
metadata with versioning, status, context tags, provenance, and other
managed fields. Where both formats specify the same field, `skill.toml`
wins. Skills without a sidecar continue to work via frontmatter alone.

```toml
id = "web-research"             # Defaults to directory name
name = "Web Research Patterns"
description = "Decision tree for tool selection during web research"
version = 3                     # Defaults to 1
status = "active"               # active | archived (defaults to active)

[scoping]
agents = ["researcher", "cognitive"]   # Omit → ["cognitive"] (conservative)
contexts = ["research", "web"]         # Omit → [] (always inject)

[provenance]
author = "operator"             # operator | system | agent
# agent_name = "remembrancer"   # Required when author = "agent"
# cycle_id = "abc-123"          # Required when author = "agent"
created_at = "2026-03-20T10:00:00Z"
updated_at = "2026-03-25T16:00:00Z"
# derived_from = "case-id"      # CBR case ID(s) for auto-generated skills
```

`SkillMeta` (in `src/skills.gleam`) carries 13 fields covering id, name,
description, path, version, status, agents, contexts,
`token_cost_estimate` (computed at discovery from body length), author,
created_at, updated_at, and `derived_from`. The `for_agent` filter
honours three special tokens: `"all"` (cognitive + every specialist),
`"all_specialists"` (specialists only, not the cognitive loop), and an
empty list (legacy frontmatter "all" semantics for backward compat).
The `for_context(skills, query_domains)` filter selects skills whose
`contexts` overlap the active query's domain tags; an empty `contexts`
list means "always inject".

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
