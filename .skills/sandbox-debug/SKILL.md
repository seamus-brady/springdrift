---
name: sandbox-debug
description: Diagnose and recover from Docker sandbox failures. Use when the sandbox is unresponsive, commands fail unexpectedly, or the user asks about sandbox health.
---

# Sandbox Debug Skill

Use this skill when sandbox commands fail, the container appears stopped, or the user
reports that `run_shell` is returning errors.

## Diagnostic steps

### 1. Check container status
Call `sandbox_status` first. It returns the container ID and exposed ports.
If this tool itself fails with "Docker sandbox not available", the sandbox was never
started (Docker unavailable or no Dockerfile found) — there is nothing to restart.

### 2. Inspect container logs
Call `sandbox_logs` (optionally with `lines: 100`) to see what the container
process last printed. This can reveal:
- Application crashes inside the container
- Out-of-memory kills (OOMKilled)
- Failed entrypoint or init errors

### 3. Test command execution
Try a simple command via `run_shell`: `echo "ping"`. If this fails with
"Sandbox container stopped" or "No such container", the container has exited.

## Recovery

### Auto-restart
The system attempts an automatic restart when a `run_shell` command fails
because the container is gone. Watch for the message:
> "Sandbox container stopped. Use restart_sandbox to restart it."

This means the auto-restart also failed. Proceed with manual restart.

### Manual restart
Call `restart_sandbox`. This stops the current container (if any) and starts
a fresh one from the same image with the same ports. Files in `/workspace`
are preserved (they come from the host mount). Files in `/tmp` are lost.

After restart, verify with `sandbox_status` and a test `run_shell`.

### If restart fails
Check `springdrift.log` for `sandbox_restart_failed` or `sandbox_auto_restart_failed`
events. Common causes:
- **Port already allocated**: Another process on the host is using the sandbox ports.
  The user should stop the conflicting process or change `sandbox_ports` in config.
- **Docker daemon not running**: Docker Desktop or the Docker service needs to be started.
- **Image build failure**: The sandbox image needs rebuilding. This requires restarting
  the whole springdrift process.

## Telling the user

When informing the user about sandbox issues:
- Be specific: say which tool failed and what error it returned.
- Suggest the exact action: "I'll restart the sandbox now" or "Please check if Docker is running."
- Do not expose raw Docker daemon error messages verbatim — summarise them.
- After a successful restart, confirm with: "The sandbox has been restarted and is ready."

## Common error patterns

| Error text | Meaning | Action |
|---|---|---|
| "Docker sandbox not available" | sandbox was never started | Nothing to do; inform user |
| "Sandbox container stopped" | container exited; auto-restart failed | call `restart_sandbox` |
| "Restart failed" | `docker run` failed during restart | check ports / Docker daemon |
| "Restart timed out" | Docker took > 30s to start | retry once; otherwise inform user |
| "No such container" | container ID is stale | call `restart_sandbox` |
