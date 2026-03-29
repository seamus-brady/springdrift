# Local Podman Sandbox — Implementation Record

**Status**: Implemented
**Date**: 2026-03-22
**Replaced**: Dead E2B cloud sandbox integration

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Port Allocation](#port-allocation)
- [Coder Agent Tools](#coder-agent-tools)
- [Key Decisions](#key-decisions)
- [Configuration](#configuration)


## Overview

Replaced the non-functional E2B cloud sandbox with a local Podman-based sandbox supporting two execution modes:

1. **Run-and-capture** (`run_code`) — execute a script, return stdout/stderr
2. **Run-and-serve** (`serve`) — start a long-lived process with port forwarding

## Architecture

```
sandbox/manager.gleam  — OTP actor managing container pool
sandbox/types.gleam    — SandboxConfig, SandboxSlot, SandboxMessage
sandbox/podman_ffi.gleam — FFI for subprocess execution
sandbox/diagnostics.gleam — Startup checks, image pull, stale container sweep
tools/sandbox.gleam    — 6 agent-facing tools
```

## Port Allocation

Deterministic: `host_port = port_base + slot * port_stride + index`

| Slot | Host Ports | Container Ports |
|---|---|---|
| 0 | 10000-10004 | 47200-47204 |
| 1 | 10100-10104 | 47200-47204 |

All ports mapped at container creation time.

## Coder Agent Tools

| Tool | Purpose |
|---|---|
| `run_code` | Execute scripts (Python, etc.) |
| `serve` / `stop_serve` | Long-lived processes with port forwarding |
| `sandbox_status` | Slot states and port mappings |
| `workspace_ls` | List workspace files |
| `sandbox_exec` | Direct shell commands (git, pip, curl) |

## Key Decisions

- Workspace at `.sandbox-workspaces/N/` (outside `.springdrift/` for security)
- Absolute paths for podman bind mounts (macOS podman machine requires `/Users/` paths)
- Health checks every 30s with crash log capture via `podman logs`
- Pool size default 2 (serve needs a slot, can't be the only one)
- No `--read-only` (Python needs writable root for `__pycache__`)

## Configuration

```toml
[sandbox]
enabled = true
pool_size = 2
memory_mb = 512
cpus = "1"
image = "python:3.12-slim"
exec_timeout_ms = 60000
port_base = 10000
port_stride = 100
ports_per_slot = 5
auto_machine = true
```
