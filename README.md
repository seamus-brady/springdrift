# Springdrift

A terminal-UI chatbot written in **Gleam/OTP** that implements the
[12-Factor Agents](https://github.com/humanlayer/12-factor-agents) principles.
It runs a ReAct loop — the model reasons, calls tools, observes results, and
repeats until it can give a final answer — all inside a full alternate-screen
TUI with a two-tab interface.

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

On a Complex classification, the app can optionally switch to `reasoning_model`.
If `prompt_on_complex` is true (the default), it asks the user first via an
inline TUI prompt. The `/model` command lets you toggle between the two models
manually at any time.

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

### Log tab with cycle browser and rewind
Press **Tab** in the TUI to open the Log tab. Use `↑`/`↓` to browse past
cycles. Each entry shows timestamp, tools used, token counts, and truncated
input/response text. Press **Enter** to rewind the conversation to that cycle —
the service state is restored and you continue from that point.

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

### Safety circuit breakers
- **Max turns** (`--max-turns`, default 5): prevents infinite tool loops.
- **Consecutive errors** (`--max-errors`, default 3): aborts if the same tool
  keeps failing without making progress.

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
gleam run -- --config /path/to/my.json

# Start with an extra skill directory
gleam run -- --skills-dir ~/my-skills

# Print resolved config and exit
gleam run -- --print-config
```

### TUI keyboard shortcuts

| Key | Action |
|---|---|
| Enter | Send message (or answer agent question) |
| Tab | Switch between Chat and Log tabs |
| PgUp / PgDn | Scroll message history |
| ↑ / ↓ | (Log tab) Select cycle |
| Enter | (Log tab) Rewind to selected cycle |
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
2. `.springdrift.json` (current directory)
3. `~/.config/springdrift/config.json`

### All config fields

```json
{
  "provider":               "anthropic",
  "model":                  "claude-sonnet-4-20250514",
  "system_prompt":          "You are a helpful assistant.",
  "max_tokens":             1024,
  "max_turns":              5,
  "max_consecutive_errors": 3,
  "max_context_messages":   50,
  "task_model":             "claude-haiku-4-5-20251001",
  "reasoning_model":        "claude-opus-4-6",
  "prompt_on_complex":      true,
  "log_verbose":            false,
  "skills_dirs":            ["/path/to/skills"]
}
```

### CLI flags

```
--provider <name>         anthropic | openrouter | openai | mock
--model <name>            Any model identifier
--system <prompt>         System prompt string
--max-tokens <n>          Max output tokens per LLM call (default: 1024)
--max-turns <n>           Max react-loop turns per message (default: 5)
--max-errors <n>          Max consecutive tool failures before abort (default: 3)
--max-context <n>         Max messages in context window (default: unlimited)
--task-model <name>       Model for simple queries
--reasoning-model <name>  Model for complex queries
--no-model-prompt         Auto-switch to reasoning model without prompting
--config <path>           Load an additional config file
--verbose                 Log full LLM request/response payloads
--skills-dir <path>       Add a skill directory (repeatable)
--resume                  Reload previous session
--print-config            Print resolved config and exit
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
├── config.gleam          3-layer config (CLI flags > local TOML > user TOML)
├── storage.gleam         Session save/load/clear  (~/.config/springdrift/session.json)
├── skills.gleam          Skill discovery, frontmatter parsing, XML injection
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
│   └── coder.gleam       Coding agent (files+shell+builtin, max_turns=10)
│
├── query_complexity.gleam  LLM-based + heuristic query classifier (Simple | Complex)
├── context.gleam           Sliding-window context trim helper
├── cycle_log.gleam         Per-cycle JSON-L logging + log reading + rewind helpers
│
├── tools/
│   ├── builtin.gleam     calculator, get_current_datetime, request_human_input, read_skill
│   ├── files.gleam       read_file, write_file, list_directory
│   ├── web.gleam         fetch_url
│   └── shell.gleam       run_shell (delegates to sandbox)
│
├── tui.gleam             Alternate-screen TUI — Chat + Log tabs
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
