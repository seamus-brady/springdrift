#!/usr/bin/env bash
# Ensure Ollama is running and the embedding model is available.
# Called before springdrift startup.

set -euo pipefail

MODEL="${SPRINGDRIFT_EMBED_MODEL:-nomic-embed-text}"
OLLAMA_URL="${OLLAMA_HOST:-http://localhost:11434}"

# 1. Check if ollama binary exists
if ! command -v ollama &>/dev/null; then
  echo "FATAL: ollama not found on PATH."
  echo "  Install: https://ollama.com/download"
  exit 1
fi

# 2. Check if ollama is already serving
if curl -sf "${OLLAMA_URL}/api/tags" &>/dev/null; then
  echo "ollama: already running"
else
  echo "ollama: not running — starting..."
  ollama serve &>/dev/null &
  OLLAMA_PID=$!

  # Wait up to 10s for it to become reachable
  for i in $(seq 1 20); do
    if curl -sf "${OLLAMA_URL}/api/tags" &>/dev/null; then
      echo "ollama: started (pid ${OLLAMA_PID})"
      break
    fi
    sleep 0.5
  done

  if ! curl -sf "${OLLAMA_URL}/api/tags" &>/dev/null; then
    echo "FATAL: ollama failed to start within 10s"
    exit 1
  fi
fi

# 3. Ensure the embedding model is pulled
if ollama list 2>/dev/null | grep -q "^${MODEL}"; then
  echo "ollama: ${MODEL} available"
else
  echo "ollama: pulling ${MODEL}..."
  ollama pull "${MODEL}"
  echo "ollama: ${MODEL} ready"
fi
