#!/usr/bin/env python3
"""
ACP probe — drives `opencode acp` over stdio and captures the full
JSON-RPC transcript.

Validates whether OpenCode 0.4.7's ACP mode is usable for the
Springdrift integration. Output drives the architectural decision:
ACP-shaped coder client vs. REST.

Args (positional):
  container_name    — running podman container
  provider_id       — e.g. "anthropic"
  model_id          — e.g. "claude-sonnet-4-20250514"
  transcript_path   — file to dump every JSON-RPC line into
  stderr_path       — file to dump opencode acp's stderr into

Exits:
  0 — full turn completed cleanly with stopReason
  1 — protocol failure (bad JSON, no response in window, etc.)
  2 — environment failure (couldn't spawn, etc.)
"""

import json
import os
import subprocess
import sys
import threading
import time

INIT_TIMEOUT_S = 10
SESSION_NEW_TIMEOUT_S = 10
PROMPT_TIMEOUT_S = 90  # real LLM call


def main():
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        sys.exit(2)

    container, provider_id, model_id, transcript_path, stderr_path = sys.argv[1:]

    # Open transcript + stderr capture before spawning so a fast failure
    # still leaves something on disk to inspect.
    transcript = open(transcript_path, "w", buffering=1)
    stderr_f = open(stderr_path, "wb", buffering=0)

    cmd = ["podman", "exec", "-i", container, "opencode", "acp"]
    print(f"[probe] spawning: {' '.join(cmd)}")
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr_f,
            bufsize=0,
        )
    except FileNotFoundError as e:
        print(f"[probe] spawn failed: {e}", file=sys.stderr)
        sys.exit(2)

    # Streaming notifications can arrive at any time. Read them on a
    # background thread into a deque so the main thread can match
    # specific ids while still capturing every line.
    inbox: list = []
    inbox_lock = threading.Lock()

    def reader():
        for line in proc.stdout:
            try:
                text = line.decode("utf-8", errors="replace").rstrip("\n")
            except Exception:
                continue
            transcript.write(f"<<< {text}\n")
            with inbox_lock:
                inbox.append(text)

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    def send(obj: dict):
        body = json.dumps(obj)
        transcript.write(f">>> {body}\n")
        try:
            proc.stdin.write((body + "\n").encode("utf-8"))
            proc.stdin.flush()
        except BrokenPipeError:
            print("[probe] stdin closed unexpectedly")
            sys.exit(1)

    def wait_for_id(target_id: int, timeout_s: int):
        """Pop messages from the inbox until we see one with .id == target_id.
        All other messages stay captured in the transcript and printed."""
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            with inbox_lock:
                # Find first matching message and consume it
                for i, raw in enumerate(inbox):
                    try:
                        msg = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    if msg.get("id") == target_id:
                        inbox.pop(i)
                        return msg
            time.sleep(0.05)
        return None

    def drain_notifications(label: str):
        """Print any inbox lines that aren't responses (no id field)."""
        with inbox_lock:
            kept = []
            for raw in inbox:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    print(f"[{label}] [non-JSON] {raw}")
                    continue
                if "method" in msg:
                    print(f"[{label}] notification {msg.get('method')}: "
                          f"{json.dumps(msg.get('params', {}))[:200]}")
                else:
                    kept.append(raw)
            inbox[:] = kept

    # ── 1. initialize ──────────────────────────────────────────────────────
    print("[probe] sending initialize...")
    send({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": 1,
            "clientCapabilities": {
                "fs": {"readTextFile": True, "writeTextFile": True},
                "terminal": True,
            },
            "clientInfo": {
                "name": "springdrift-probe",
                "version": "0.1.0",
            },
        },
    })
    init_resp = wait_for_id(1, INIT_TIMEOUT_S)
    if init_resp is None:
        print(f"[probe] FAIL: no response to initialize within {INIT_TIMEOUT_S}s")
        proc.terminate()
        sys.exit(1)
    print(f"[probe] initialize OK: protocolVersion="
          f"{init_resp.get('result', {}).get('protocolVersion')} "
          f"agent={init_resp.get('result', {}).get('agentInfo', {}).get('name')}")

    drain_notifications("post-init")

    # ── 2. session/new ──────────────────────────────────────────────────────
    # The spec uses `session/new` based on the prompt-turn doc's references.
    # If the agent uses a different method name we'll see a "method not found"
    # error here and learn the actual one.
    print("[probe] sending session/new...")
    send({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "session/new",
        "params": {
            "cwd": "/workspace/project",
            "mcpServers": [],
        },
    })
    sess_resp = wait_for_id(2, SESSION_NEW_TIMEOUT_S)
    if sess_resp is None:
        print(f"[probe] FAIL: no response to session/new within {SESSION_NEW_TIMEOUT_S}s")
        proc.terminate()
        sys.exit(1)

    if "error" in sess_resp:
        print(f"[probe] session/new returned error: {sess_resp['error']}")
        # Could be that the method is named differently — fail with the error
        # text in the transcript so we can iterate.
        proc.terminate()
        sys.exit(1)

    session_id = (
        sess_resp.get("result", {}).get("sessionId")
        or sess_resp.get("result", {}).get("id")
    )
    if not session_id:
        print(f"[probe] FAIL: no sessionId in session/new response: "
              f"{json.dumps(sess_resp)[:300]}")
        proc.terminate()
        sys.exit(1)
    print(f"[probe] session OK: sessionId={session_id}")

    drain_notifications("post-session-new")

    # ── 3. session/prompt ───────────────────────────────────────────────────
    print("[probe] sending session/prompt 'say pong'...")
    send({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "session/prompt",
        "params": {
            "sessionId": session_id,
            "prompt": [
                {"type": "text", "text": "Reply with the single word pong and nothing else."},
            ],
        },
    })

    # Stream notifications until id=3 response arrives.
    deadline = time.monotonic() + PROMPT_TIMEOUT_S
    notif_count = 0
    while time.monotonic() < deadline:
        with inbox_lock:
            consumed = []
            for i, raw in enumerate(inbox):
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if msg.get("id") == 3:
                    consumed.append(i)
                    print(f"[probe] prompt response: stopReason="
                          f"{msg.get('result', {}).get('stopReason')}")
                    drain_notifications("final-flush")
                    print(f"[probe] notifications received: {notif_count}")
                    print("[probe] PASS — full ACP turn completed")
                    proc.stdin.close()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.terminate()
                    sys.exit(0)
                if "method" in msg:
                    method = msg.get("method")
                    update_type = (
                        msg.get("params", {})
                        .get("update", {})
                        .get("sessionUpdate")
                    )
                    label = f"{method}"
                    if update_type:
                        label += f"/{update_type}"
                    snippet = json.dumps(msg.get("params", {}))[:150]
                    print(f"[probe] notif: {label} :: {snippet}")
                    consumed.append(i)
                    notif_count += 1
            for i in reversed(consumed):
                inbox.pop(i)
        time.sleep(0.05)

    print(f"[probe] FAIL: prompt did not complete within {PROMPT_TIMEOUT_S}s")
    print(f"[probe] notifications received before timeout: {notif_count}")
    proc.terminate()
    sys.exit(1)


if __name__ == "__main__":
    main()
