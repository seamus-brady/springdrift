# Springdrift Setup Guide

## Prerequisites

### 1. Erlang/OTP and Gleam

Springdrift is written in Gleam, which compiles to Erlang/BEAM.

**macOS (Homebrew):**
```bash
brew install erlang gleam
```

**Linux (asdf):**
```bash
asdf plugin add erlang
asdf plugin add gleam
asdf install erlang 27.0
asdf install gleam 1.4.1
asdf global erlang 27.0
asdf global gleam 1.4.1
```

Verify installation:
```bash
gleam --version   # 1.x
erl -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'
```

### 2. Podman (for sandbox code execution)

The coder agent uses Podman containers for executing code.

**macOS:**
```bash
brew install podman
podman machine init
podman machine start
```

**Linux:**
```bash
# Debian/Ubuntu
sudo apt install podman

# Fedora
sudo dnf install podman
```

Verify:
```bash
podman --version
podman run --rm python:3.12-slim python3 -c "print('hello')"
```

The sandbox starts automatically if Podman is available. If not, the coder agent
degrades gracefully (works through reasoning only, no code execution).

### 3. Ollama (for CBR semantic embeddings)

Case-Based Reasoning uses Ollama for embedding similarity.

```bash
# macOS
brew install ollama

# Linux — see https://ollama.com/download
curl -fsSL https://ollama.ai/install.sh | sh
```

Start Ollama and pull the embedding model:
```bash
ollama serve &
ollama pull nomic-embed-text
```

Verify:
```bash
curl http://localhost:11434/api/embeddings -d '{"model":"nomic-embed-text","prompt":"test"}'
```

CBR embeddings are optional. Set `[cbr] embedding_enabled = false` in config to disable.
The system works without embeddings but retrieval quality is reduced (uses deterministic
field scoring only).

## API Keys

Set these environment variables for the LLM providers and web tools you want to use:

### LLM Providers (one required)

| Variable | Provider | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | Anthropic | For Claude models |
| `OPENROUTER_API_KEY` | OpenRouter | Access to multiple model providers |
| `OPENAI_API_KEY` | OpenAI | For GPT models |
| `MISTRAL_API_KEY` | Mistral | For Mistral models |

### Web Research Tools (optional)

| Variable | Service | Notes |
|---|---|---|
| `BRAVE_API_KEY` | Brave Search | Preferred web search (5 tools) |
| `JINA_API_KEY` | Jina Reader | Clean markdown from URLs |

DuckDuckGo web search and raw HTTP fetch work without any API key.

### Web GUI Auth (optional)

| Variable | Purpose |
|---|---|
| `SPRINGDRIFT_WEB_TOKEN` | Bearer token for web GUI authentication |

## First Run

### 1. Clone and build

```bash
git clone <repo-url>
cd springdrift
gleam build
```

### 2. Create config directory

```bash
cp -r .springdrift_example .springdrift
```

### 3. Configure provider

Edit `.springdrift/config.toml`:

```toml
provider = "anthropic"       # or "openrouter", "openai", "mistral"
task_model = "claude-haiku-4-5-20251001"
reasoning_model = "claude-sonnet-4-6"
```

### 4. Run

```bash
# Terminal UI mode
gleam run

# Web GUI mode (browser at http://localhost:12001)
gleam run -- --gui web

# Resume previous session
gleam run -- --resume
```

### 5. Verify startup

You should see output like:
```
Provider : Anthropic
CBR      : embeddings via Ollama (nomic-embed-text at http://localhost:11434)
Housekeeper: started
Sandbox  : started (pool=2)
  Agent  : planner started
  Agent  : researcher started
  Agent  : coder started
  Agent  : observer started
Narrative: .springdrift/memory/narrative
Mode     : cognitive (agents: planner, researcher, coder, observer)
```

If sandbox shows "unavailable", check that Podman is installed and running
(`podman machine start` on macOS).

## Directory Structure

After first run, Springdrift creates:

```
.springdrift/           # All persistent state (gitignored)
  config.toml           # Your configuration
  identity/             # Agent persona and session preamble
  memory/               # Narrative, CBR, facts, artifacts, planner, schedule
  logs/                 # System logs (date-rotated)
  schemas/              # XStructor XSD schemas
  skills/               # Skill definitions + operator guide
  profiles/             # Agent team configurations

.sandbox-workspaces/    # Ephemeral sandbox workspaces (gitignored)
```

## Configuration Reference

See `.springdrift_example/config.toml` for the complete reference with all
sections and defaults documented. Key sections:

| Section | Purpose |
|---|---|
| *(top-level)* | Provider, models, loop control |
| `[agent]` | Agent name and version |
| `[narrative]` | Memory and narrative settings |
| `[sandbox]` | Podman sandbox for code execution |
| `[cbr]` | Case-Based Reasoning and embeddings |
| `[scheduler]` | Autonomous task scheduling limits |
| `[forecaster]` | Plan health monitoring |
| `[delegation]` | Agent delegation depth limits |

## Troubleshooting

### Sandbox won't start

```
Sandbox  : unavailable (podman not found on PATH)
```
Install Podman. On macOS, also run `podman machine init && podman machine start`.

```
Sandbox  : unavailable (Failed to start any sandbox containers: ...)
```
Check `podman machine start` is running. Check the error message for details.

### CBR embedding fails at startup

```
CBR      : embeddings disabled (Ollama unreachable)
```
Start Ollama (`ollama serve`) and pull the model (`ollama pull nomic-embed-text`).
Or disable embeddings: `[cbr] embedding_enabled = false`.

### No LLM responses

Check your API key environment variable is set and the provider matches your config.
Try `provider = "mock"` to verify the system works without an API key.

## Development

```bash
gleam build     # Compile
gleam test      # Run tests (all must pass)
gleam format    # Format source files
gleam run       # Run the application
```
