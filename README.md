# springdrift

Autonomous agent for extended, independent operation

```
brew install beam
brew install erlang elixir rebar3
brew install gleam

```


## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```

## Usage

```sh
gleam run -- [OPTIONS]
```

### Options

| Flag | Description | Default |
|---|---|---|
| `--provider <name>` | `anthropic`, `openrouter`, `openai` | auto-detect |
| `--model <name>` | Model identifier | provider default |
| `--system <prompt>` | System prompt | `"You are a helpful assistant."` |
| `--max-tokens <n>` | Max output tokens per LLM call | 1024 |
| `--max-turns <n>` | Max react-loop turns per message | 5 |
| `--max-errors <n>` | Max consecutive tool failures before abort | 3 |
| `--max-context <n>` | Max messages kept in context | unlimited |
| `--resume` | Resume previous session | — |
| `--data-dir <path>` | Directory for session and cycle-log files | `~/.config/springdrift` |

### Data file locations

By default springdrift writes session and cycle-log files to `~/.config/springdrift`:

```
~/.config/springdrift/session.json
~/.config/springdrift/cycle-log/YYYY-MM-DD.jsonl
```

For local development it is convenient to keep these files inside your project:

```sh
# Via CLI flag
gleam run -- --data-dir .springdrift

# Via environment variable
SPRINGDRIFT_DATA_DIR=.springdrift gleam run
```

You can add `.springdrift/` to your `.gitignore` if you do not want to commit logs.

### Config files

Config is loaded in priority order (highest first):

1. CLI flags
2. `.springdrift.json` (current directory)
3. `~/.config/springdrift/config.json`

Example `.springdrift.json`:

```json
{
  "provider": "anthropic",
  "model": "claude-sonnet-4-20250514",
  "system_prompt": "You are a helpful assistant.",
  "max_tokens": 2048,
  "max_turns": 5,
  "max_consecutive_errors": 3,
  "max_context_messages": 50
}
```
