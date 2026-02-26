---
name: shell-sandbox
description: Run shell commands in a sandboxed Docker container with the project directory mounted at /workspace.
---

# Shell Sandbox

You have access to a `run_shell` tool that executes commands in an isolated
Debian (bookworm-slim) container.

## Environment
- Working directory: `/workspace` (the project root, mounted read-write)
- Available tools: bash, curl, wget, git, python3, pip, jq, ripgrep, fd
- Network: outbound allowed (git clone, curl, pip install all work)
- State **persists** across `run_shell` calls within a session — file writes,
  installed packages, and directory changes are remembered

## Companion host tools
For simple file reads and writes without a shell, prefer:
- `read_file` / `write_file` / `list_directory` — direct host filesystem access,
  no Docker overhead, work even if Docker is unavailable
- `fetch_url` — HTTP GET on the host, faster than curl in the container

## Management tools
- `sandbox_status` — check if the container is running and which ports are exposed
- `sandbox_logs` — view last N lines of container-level output (default 50)
- `restart_sandbox` — stop and restart the container (preserves /workspace files)

## Conventions
- Use `set -e` in scripts to fail fast
- Pipe long output through `head -50` or `tail -50` to stay within context limits
- Prefer composable commands over long one-liners
- Check exit codes explicitly when error handling matters
