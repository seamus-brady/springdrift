# Multi-Language Sandbox — JavaScript and Gleam Container Images

**Status**: Planned
**Priority**: Medium — extends coder agent to more languages
**Effort**: Medium (~200-300 lines + Dockerfiles)

## Problem

The sandbox currently uses a single container image (`python:3.12-slim`).
The coder agent can only execute Python scripts. For a general-purpose
agent, this is limiting — many tasks require JavaScript/Node.js (web
scraping, API prototyping, data transformation) or Gleam (the agent's
own language, useful for self-modification experiments and testing).

## Proposed Solution

### 1. Additional Dockerfiles

Create container images for each supported language:

```
sandbox/
├── Dockerfile.python     # Existing — Python 3.12 slim
├── Dockerfile.node       # Node.js 22 LTS slim
└── Dockerfile.gleam      # Gleam 1.x + Erlang/OTP 27
```

**Python image** (existing): `python:3.12-slim` + pip, common packages
pre-installed (requests, pandas, beautifulsoup4).

**Node.js image**: `node:22-slim` + npm, common packages pre-installed
(axios, cheerio, lodash). Include TypeScript support (`tsx` for direct
execution).

**Gleam image**: `ghcr.io/gleam-lang/gleam:v1.9-erlang` or custom build.
Includes `gleam build` and `gleam run` support. Useful for testing Gleam
snippets, running evals, or prototyping changes to Springdrift itself.

### 2. Language Selection

Extend `sandbox_image` config to support multiple images:

```toml
[sandbox]
images = { python = "springdrift-python:latest", node = "springdrift-node:latest", gleam = "springdrift-gleam:latest" }
default_image = "python"
```

The `run_code` tool gains an optional `language` parameter. The sandbox
manager selects the appropriate image when creating a container. If a
container with the wrong image is already in the pool, it's recycled and
a new one created.

### 3. Pool Management

Each language could have its own pool slot, or slots could be shared with
on-demand image switching. Shared slots are simpler but have container
startup latency on language switch. Dedicated slots use more resources
but are instant.

Start with shared slots (simpler, pool_size is already small).

### 4. Language Detection

The coder agent should be able to auto-detect the language from the code
content (shebangs, file extensions, syntax patterns) rather than requiring
explicit specification every time.

## Open Questions

- Should each language have pre-installed packages, or start minimal?
- Gleam image size — the Erlang/OTP runtime is large (~400MB). Worth it?
- Should the `serve` mode support all languages (Node.js Express, Gleam
  mist alongside Python Flask)?
- How to handle language-specific workspace setup (package.json, gleam.toml)?
