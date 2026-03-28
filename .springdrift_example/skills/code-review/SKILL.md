---
name: code-review
description: Patterns for code execution in the Podman sandbox. Covers run_code, serve mode, workspace management, and common failure modes.
agents: coder
---

## Code Execution Patterns

### Sandbox Basics

You execute code in isolated Podman containers. Two modes:

| Mode | Tool | Use For |
|---|---|---|
| Run and capture | `run_code` | Scripts that produce output and exit |
| Serve | `serve` / `stop_serve` | Long-running processes (Flask, HTTP servers) |

Check sandbox status with `sandbox_status` before starting.

### Writing Scripts

Always:
- Use stdlib only unless you install dependencies first (`sandbox_exec("pip install X")`)
- Write self-contained scripts — don't assume state from previous runs
- Include error handling — uncaught exceptions produce unhelpful output
- Print results explicitly — the sandbox captures stdout

Never:
- Assume network access (containers are isolated)
- Write to locations outside the workspace directory
- Run scripts that take longer than 60 seconds (timeout)
- Assume packages are installed — check with `sandbox_exec("pip list")`

### Common Failure Modes

1. **"Talking but not coding"** — you respond with text about what you'd do
   instead of actually calling `run_code`. If your task is to execute code,
   call `run_code`.

2. **Import failures** — the container has Python stdlib only. Flask, requests,
   pandas, etc. must be installed first via `sandbox_exec("pip install X")`.

3. **Script too large** — if your script exceeds ~200 lines, split it into
   multiple `run_code` calls. Write helpers to a file first, then import them.

4. **Workspace state** — use `workspace_ls` to see what files exist. Use
   `sandbox_exec("cat file.py")` to read files in the workspace.

### Port Forwarding (Serve Mode)

When using `serve`, ports are mapped deterministically:
- Container-internal ports: 47200-47204
- Host ports: calculated from slot number

After starting a server with `serve`, verify it's running with
`sandbox_status`. Stop it with `stop_serve` when done.

### Verification

After `run_code`:
- Check the exit code (0 = success)
- Read stderr for warnings even if exit code is 0
- Verify the output matches expectations
- Don't assume success from a "succeeded" status — inspect the actual output
