# Springdrift — Claude Code Guide

## Project overview

Springdrift is a terminal-UI chatbot written in **Gleam** (compiled to Erlang/OTP).
It implements a [12-Factor Agents](https://github.com/humanlayer/12-factor-agents)
style ReAct loop: the LLM reasons, calls tools, observes results, and repeats until
it can give a final answer. The TUI runs in alternate-screen raw mode with a two-tab
interface (Chat and Log).

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
├── springdrift.gleam          Entry point — config, provider selection, wiring
├── springdrift_ffi.erl        Erlang FFI (stdin, env, args, spinner, UUID, datetime)
├── config.gleam               Three-layer config (CLI flags > local JSON > user JSON)
├── storage.gleam              Session persistence — ~/.config/springdrift/session.json
├── cycle_log.gleam            Per-cycle JSON-L logging + log reading + rewind helpers
│
├── chat/service.gleam         OTP actor owning ChatState; react_loop (max 5 turns)
├── tools/builtin.gleam        Built-in tools: calculator, get_today_date, request_human_input
├── tui.gleam                  Alternate-screen TUI; Chat tab + Log tab with cycle rewind
│
└── llm/
    ├── types.gleam            Shared types: Message, ContentBlock, LlmRequest/Response/Error, Tool
    ├── request.gleam          Pipe-friendly request builder
    ├── response.gleam         Response helpers (text extraction, tool call detection)
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

Three long-lived processes and one per-turn worker:

| Process | Lifetime | Role |
|---|---|---|
| TUI event loop | App | Render, raw stdin, message dispatch |
| Service actor | App | Owns `ChatState`; serialises all conversation writes |
| Stdin reader | App | Blocking `read_char` loop → `StdinByte` messages to selector |
| HTTP worker | Per turn | Blocking LLM calls + tool execution inside `react_loop` |

All cross-process communication uses typed `Subject(T)` channels. No shared mutable
state, no locks.

## Patterns to follow

**Provider abstraction** — all LLM work goes through `llm/provider.gleam`. Never call
an SDK directly from outside an adapter module.

**`use x <- decode.field(name, decoder)` decoders** — the standard pattern for all
JSON decoding. See `storage.gleam` and `cycle_log.gleam` for examples. Each field
accessor in a `case` arm extracts from the same root dynamic value.

**Pipe-friendly builders** — `llm/request.gleam` exports `new/2` plus `with_*`
functions. Build requests by piping: `request.new(model, max_tokens) |> request.with_system(...) |> ...`.

**Actor messages as the API surface** — public API of the service is the `ChatMessage`
type. Add new capabilities by adding variants, not by exposing internal functions.

**Cycle logging** — every call to `react_loop` must thread the `cycle_id: String`
parameter and log `llm_request`, `llm_response`, `tool_call`, and `tool_result` events
via `cycle_log.*`. Do not add LLM calls that bypass this logging.

## Config file format

Local `.springdrift.json` (or `~/.config/springdrift/config.json`):

```json
{
  "provider": "anthropic",
  "model": "claude-sonnet-4-20250514",
  "system_prompt": "You are a helpful assistant.",
  "max_tokens": 2048
}
```

CLI flags override config files. Supported flags: `--provider`, `--model`, `--system`,
`--max-tokens`, `--resume`.
