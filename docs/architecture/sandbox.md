# Sandbox Architecture

The sandbox subsystem provides isolated code execution for the coder agent using
local Podman containers. It supports two execution modes: synchronous script
execution and long-lived processes with port forwarding.

---

## 1. Overview

The sandbox (`src/sandbox/`) is an OTP actor managing a pool of Podman containers.
When the coder agent needs to run code, it dispatches requests through sandbox
tools that route to the manager process. When `sandbox_enabled` is False (default),
the coder agent falls back to `request_human_input` -- no sandbox code runs.

```
Coder Agent ──→ Sandbox Tools ──→ SandboxManager (OTP actor)
                                       │
                              ┌────────┼────────┐
                              ▼        ▼        ▼
                          Slot 0   Slot 1   Slot N
                         (Podman)  (Podman)  (Podman)
                              │
                     .sandbox-workspaces/N/
```

## 2. Container Lifecycle

### Startup Sequence

1. **Check podman** -- verify `podman` binary exists and get version
2. **Start machine** (macOS only) -- if `sandbox_auto_machine` is True, start
   `podman machine` if not already running
3. **Ensure image** -- pull `sandbox_image` if not present (default:
   `python:3.12-slim`, configurable, 5-minute timeout)
4. **Sweep stale** -- remove any leftover `springdrift-sandbox-*` containers
5. **Create workspace dirs** -- absolute paths for bind mounts (relative paths
   resolve inside the podman machine VM, not on the host)
6. **Start containers** -- create `sandbox_pool_size` containers with port mappings

### Container Configuration

Each container is started with:
- Memory limit: `sandbox_memory_mb` (default 512MB)
- CPU limit: `sandbox_cpus` (default "1")
- Bind mount: `.sandbox-workspaces/N/` → `/workspace` in container
- Port mappings: deterministic allocation (see below)
- `--rm` flag: container cleaned up on stop

### Health Checks

The manager runs health checks every 30 seconds and restarts failed containers.
Container state is tracked per-slot in the `slots` dictionary.

## 3. Execution Modes

### run_code (synchronous)

Executes a script in a container and returns stdout/stderr:

1. Write script content to the slot's workspace directory
2. Execute via `podman exec` with `sandbox_exec_timeout_ms` timeout (default 60s)
3. Capture stdout, stderr, and exit code
4. Return combined output to the tool

### serve (long-lived)

Starts a long-lived process (e.g. Flask server) with port forwarding:

1. Write application code to workspace
2. Start process in background inside the container
3. Port forwarding makes the service accessible on the host
4. Returns the host port for access

### stop_serve

Stops a running serve process in a slot.

## 4. Port Allocation

Port allocation is deterministic to avoid collisions:

```
host_port = port_base + (slot_index * port_stride) + port_offset
```

| Config | Default | Purpose |
|---|---|---|
| `sandbox_port_base` | 10000 | Starting host port |
| `sandbox_port_stride` | 100 | Gap between slots |
| `sandbox_ports_per_slot` | 5 | Ports per container |

Container-internal ports are fixed at 47200--47204.

Example with defaults:
- Slot 0: host ports 10000--10004 → container ports 47200--47204
- Slot 1: host ports 10100--10104 → container ports 47200--47204

All ports are mapped at container creation time.

## 5. Workspace Directories

Each slot has a dedicated workspace at `.sandbox-workspaces/N/` in the project
root (a sibling of `.springdrift/`, deliberately separate to isolate ephemeral
container state from persistent agent memory). Add `.sandbox-workspaces/` to
`.gitignore`.

Workspaces are bind-mounted into containers at `/workspace`. Files written by
the coder agent persist across executions within the same session.

## 6. Tools

Six tools defined in `src/tools/sandbox.gleam`:

| Tool | Purpose |
|---|---|
| `run_code` | Execute a script (Python, Bash, etc.) synchronously |
| `serve` | Start a long-lived process with port forwarding |
| `stop_serve` | Stop a running serve process |
| `sandbox_status` | Get slot states and port mappings |
| `workspace_ls` | List files in a slot's workspace directory |
| `sandbox_exec` | Direct shell command execution (git, pip, curl, etc.) |

## 7. Manager Messages

The sandbox manager's API is `SandboxMessage`:

| Message | Purpose |
|---|---|
| `Execute(script, language, slot, reply_to)` | Run code synchronously |
| `Serve(script, language, slot, port, reply_to)` | Start long-lived process |
| `StopServe(slot, reply_to)` | Stop serve process |
| `Status(reply_to)` | Get all slot states |
| `WorkspaceLs(slot, reply_to)` | List workspace files |
| `SandboxExec(command, slot, reply_to)` | Run shell command |
| `HealthCheck` | Periodic container health verification |

## 8. Configuration

All sandbox config lives in the `[sandbox]` TOML section:

| Field | Default | Purpose |
|---|---|---|
| `enabled` | True | Enable sandbox (False = coder uses request_human_input) |
| `pool_size` | 2 | Number of containers (max 3) |
| `memory_mb` | 512 | Memory limit per container |
| `cpus` | "1" | CPU limit per container |
| `image` | "python:3.12-slim" | Container image |
| `exec_timeout_ms` | 60000 | Per-execution timeout |
| `port_base` | 10000 | Host port base for serve mode |
| `port_stride` | 100 | Host port stride per slot |
| `ports_per_slot` | 5 | Ports forwarded per slot |
| `auto_machine` | True | Auto-start podman machine on macOS |

## 9. FFI Layer

`src/sandbox/podman_ffi.gleam` provides FFI declarations for subprocess execution:

- `run_cmd(command, args, timeout_ms)` -- execute a command with timeout
- `which(name)` -- locate a binary on PATH

`src/sandbox/diagnostics.gleam` provides startup checks:

- `check_podman()` -- verify podman binary and version
- `check_machine_status()` -- check podman machine state (macOS)
- `start_machine()` -- start podman machine
- `check_image(name)` -- verify image exists locally
- `pull_image(name, timeout)` -- pull image from registry
- `sweep_stale_containers()` -- remove leftover springdrift containers

## 10. Key Source Files

| File | Purpose |
|---|---|
| `sandbox/types.gleam` | `SandboxConfig`, `SandboxSlot`, `SandboxMessage`, `SandboxManager` |
| `sandbox/manager.gleam` | OTP actor: container lifecycle, execution dispatch, health checks |
| `sandbox/podman_ffi.gleam` | FFI for subprocess execution |
| `sandbox/diagnostics.gleam` | Startup verification and container cleanup |
| `tools/sandbox.gleam` | Tool definitions for coder agent |
