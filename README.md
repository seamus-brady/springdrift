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
`--resume` to reload it. `/clear` resets both the in-memory state and the file.

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
| `/clear` | Clear conversation history and saved session |
| `/model` | Toggle between task model and reasoning model |

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
springdrift.gleam         Entry point — config, provider selection, skills, wiring
├── config.gleam          3-layer config (CLI flags > local JSON > user JSON)
├── storage.gleam         Session save/load/clear  (~/.config/springdrift/session.json)
├── skills.gleam          Skill discovery, frontmatter parsing, XML injection
│
├── chat/service.gleam    OTP actor — owns ChatState; serialises conversation writes
│   └── react_loop        Iterative tool execution with max_turns + circuit breaker
│
├── query_complexity.gleam  LLM-based + heuristic query classifier (Simple | Complex)
├── context.gleam           Sliding-window context trim helper
├── cycle_log.gleam         Per-cycle JSON-L logging + log reading + rewind helpers
│
├── tools/builtin.gleam   Built-in tools: calculator, get_today_date,
│                         request_human_input, read_skill
│
├── tui.gleam             Alternate-screen TUI — Chat tab + Log tab, markdown renderer
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
| Service actor | App | Owns `ChatState`, serialises all conversation writes |
| Stdin reader | App | Blocking `read_char` loop → `StdinByte` to selector |
| HTTP worker | Per turn | Blocking LLM calls + tool execution inside `react_loop` |

All cross-process communication uses typed `Subject(T)` channels — no shared
mutable state, no locks.

### Message flow

```
User input → TUI
  → service.SendMessage(text, reply_to, channels…)
  → Service appends user message, classifies complexity, picks model
  → Spawns HTTP worker: react_loop (blocking)
      → LLM call
      → If tool calls: execute, log, recurse
      → If done: send LlmComplete back to service
  → Service stores final_messages, saves to disk
  → Reply sent to TUI → render
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
| 10 — Small focused agents | N/A | General-purpose chatbot, not an orchestrator |
| 11 — Trigger from anywhere | N/A | TUI only; no webhook/event integration |
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
