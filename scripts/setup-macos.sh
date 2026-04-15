#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift — macOS setup script
# Run from the repo root after cloning:
#   git clone https://github.com/seamus-brady/springdrift.git
#   cd springdrift
#   bash scripts/setup-macos.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; exit 1; }
ask()  { read -rp "  $1: " "$2"; }
ask_default() { read -rp "  $1 [$2]: " val; eval "$3=\${val:-$2}"; }
ask_yn() { read -rp "  $1 [y/N]: " val; [[ "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" == "y" ]]; }
ask_yn_default_yes() { read -rp "  $1 [Y/n]: " val; [[ "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" != "n" ]]; }

echo ""
echo -e "${BOLD}Springdrift — macOS Setup${NC}"
echo "─────────────────────────────────────────"
echo ""

# ── Check we're in the repo root ─────────────────────────────────────────────
if [[ ! -f "gleam.toml" ]]; then
  fail "Run this script from the springdrift repo root (where gleam.toml is)"
fi

# ── Check Homebrew ───────────────────────────────────────────────────────────
echo -e "${BOLD}1. Dependencies${NC}"
if ! command -v brew &>/dev/null; then
  fail "Homebrew is required. Install from https://brew.sh"
fi
ok "Homebrew"

# ── Erlang/OTP ───────────────────────────────────────────────────────────────
if command -v erl &>/dev/null; then
  ok "Erlang/OTP ($(erl -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' -noshell 2>/dev/null || echo "installed"))"
else
  echo -e "  Installing Erlang/OTP..."
  brew install erlang
  ok "Erlang/OTP installed"
fi

# ── Gleam ────────────────────────────────────────────────────────────────────
if command -v gleam &>/dev/null; then
  ok "Gleam ($(gleam --version 2>/dev/null || echo "installed"))"
else
  echo -e "  Installing Gleam..."
  brew install gleam
  ok "Gleam installed"
fi

# ── Podman (optional) ────────────────────────────────────────────────────────
if command -v podman &>/dev/null; then
  ok "Podman (already installed)"
  SANDBOX_AVAILABLE=true
else
  if ask_yn "Install Podman? (isolated containers for code execution — the coder agent needs this)"; then
    brew install podman
    podman machine init --cpus 2 --memory 2048 || true
    podman machine start || true
    ok "Podman installed"
    SANDBOX_AVAILABLE=true
  else
    warn "Podman skipped — sandbox will be disabled"
    SANDBOX_AVAILABLE=false
  fi
fi

# ── Ollama (optional) ────────────────────────────────────────────────────────
if command -v ollama &>/dev/null; then
  ok "Ollama (already installed)"
  OLLAMA_AVAILABLE=true
else
  if ask_yn "Install Ollama? (local embeddings for case-based memory — significantly improves retrieval)"; then
    brew install ollama
    ok "Ollama installed"
    echo "  Run 'ollama serve' in another terminal, then 'ollama pull nomic-embed-text'"
    OLLAMA_AVAILABLE=true
  else
    warn "Ollama skipped — CBR embeddings will be disabled"
    OLLAMA_AVAILABLE=false
  fi
fi

# ── Build ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}2. Building Springdrift${NC}"
gleam build 2>&1 | tail -1
ok "Build complete"

# ── Configuration ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}3. Configuration${NC}"
echo ""

# Agent name
ask_default "Agent name" "Springdrift" AGENT_NAME

# Provider (default anthropic)
echo ""
echo "  LLM Providers: anthropic (default), vertex, mistral, local, mock"
ask_default "Provider" "anthropic" PROVIDER

# API keys
echo ""
echo -e "${BOLD}4. API Keys${NC}"
echo "  Keys are stored in .env (gitignored), not in config files."
echo ""

ANTHROPIC_KEY=""
VERTEX_PROJECT=""
MISTRAL_KEY=""

case "$PROVIDER" in
  anthropic)
    ask "Anthropic API key" ANTHROPIC_KEY
    [[ -z "$ANTHROPIC_KEY" ]] && fail "Anthropic API key is required"
    ;;
  vertex)
    ask "GCP project ID" VERTEX_PROJECT
    echo "  Ensure GOOGLE_APPLICATION_CREDENTIALS is set in your environment"
    ;;
  mistral)
    ask "Mistral API key" MISTRAL_KEY
    ;;
  local|mock)
    ok "No API key needed for $PROVIDER"
    ;;
esac

# Optional keys
BRAVE_KEY=""
JINA_KEY=""
echo ""
echo "  Optional services (press Enter to skip any):"
echo "  Brave Search — better web search. Free tier: https://brave.com/search/api/"
ask "  Brave Search API key" BRAVE_KEY
echo "  Jina Reader — cleaner URL extraction. Free tier: https://jina.ai/reader/"
ask "  Jina Reader API key" JINA_KEY

# Comms
echo ""
echo "  AgentMail — email send/receive. Free at https://agentmail.to"
COMMS_ENABLED=false
COMMS_ADDRESS=""
COMMS_RECIPIENTS=""
AGENTMAIL_KEY=""
if ask_yn "Enable email (AgentMail)?"; then
  COMMS_ENABLED=true
  ask "Agent email address (e.g. myagent@agentmail.to)" COMMS_ADDRESS
  ask "Allowed recipients (comma-separated emails)" COMMS_RECIPIENTS
  ask "AgentMail API key" AGENTMAIL_KEY
fi

# Git backup remote
echo ""
echo "  Git backup — agent memory is backed up to a git repo automatically."
echo "  Provide a private GitHub/GitLab repo URL for remote backup (optional)."
BACKUP_REMOTE=""
ask "  Git remote URL (e.g. git@github.com:user/myagent-data.git, press Enter to skip)" BACKUP_REMOTE

# ── Generate .springdrift/ ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}5. Setting up .springdrift/${NC}"

if [[ -d ".springdrift" ]]; then
  warn ".springdrift/ already exists — preserving existing config"
  warn "Rename or delete it first if you want a fresh setup"
else
  cp -r .springdrift_example .springdrift
  ok "Created .springdrift/ from example"
fi

# ── Write config.toml ────────────────────────────────────────────────────────
CONFIG=".springdrift/config.toml"

# Only write if we created fresh
if [[ ! -f "$CONFIG" ]] || [[ "$(head -1 "$CONFIG")" == *"example"* ]]; then
  # Generate web token
  WEB_TOKEN=$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 48)

  # Format allowed recipients as TOML array
  RECIPIENTS_TOML="[]"
  if [[ -n "$COMMS_RECIPIENTS" ]]; then
    RECIPIENTS_TOML="[$(echo "$COMMS_RECIPIENTS" | sed 's/[[:space:]]*,[[:space:]]*/", "/g; s/^/"/; s/$/"/' )]"
  fi

  cat > "$CONFIG" << TOML
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift config — generated by setup-macos.sh
# ─────────────────────────────────────────────────────────────────────────────

provider = "$PROVIDER"
max_tokens = 4096
max_turns = 8
max_consecutive_errors = 3
gui = "web"
log_verbose = false
dprime_config = ".springdrift/dprime.json"

[agent]
name = "$AGENT_NAME"
version = "Springdrift Mk-3"

[anthropic]
task_model = "claude-haiku-4-5-20251001"
reasoning_model = "claude-opus-4-6"

[narrative]
threading = true
summaries = false

[dprime]
normative_calculus_enabled = true

[sandbox]
enabled = $SANDBOX_AVAILABLE

[cbr]
# embedding_enabled = $OLLAMA_AVAILABLE

[comms]
enabled = $COMMS_ENABLED
$(if $COMMS_ENABLED; then
  echo "from_address = \"$COMMS_ADDRESS\""
  echo "allowed_recipients = $RECIPIENTS_TOML"
  echo "from_name = \"$AGENT_NAME\""
fi)

[web]
# port = 8080

[scheduler]
# max_autonomous_cycles_per_hour = 20

[backup]
enabled = true
mode = "periodic"
# interval_ms = 300000
$(if [[ -n "$BACKUP_REMOTE" ]]; then echo "remote_url = \"$BACKUP_REMOTE\""; fi)

[forecaster]
# enabled = false
TOML

  ok "Generated $CONFIG"
fi

# ── Initialise git backup repo ───────────────────────────────────────────────
if [[ ! -d ".springdrift/.git" ]]; then
  (cd .springdrift && git init -q && git add -A && git commit -q -m "Initial setup")
  ok "Initialised git backup repo in .springdrift/"
else
  ok "Git backup repo already exists"
fi
if [[ -n "$BACKUP_REMOTE" ]]; then
  (cd .springdrift && git remote add origin "$BACKUP_REMOTE" 2>/dev/null || git remote set-url origin "$BACKUP_REMOTE")
  ok "Git remote set to $BACKUP_REMOTE"
fi

# ── Write .env ───────────────────────────────────────────────────────────────
ENV_FILE=".env"
{
  echo "# Springdrift environment — generated by setup-macos.sh"
  echo "# Source this file before running: source .env && gleam run"
  echo ""
  [[ -n "$ANTHROPIC_KEY" ]] && echo "export ANTHROPIC_API_KEY=\"$ANTHROPIC_KEY\""
  [[ -n "$MISTRAL_KEY" ]] && echo "export MISTRAL_API_KEY=\"$MISTRAL_KEY\""
  [[ -n "$VERTEX_PROJECT" ]] && echo "export VERTEX_PROJECT_ID=\"$VERTEX_PROJECT\""
  [[ -n "$BRAVE_KEY" ]] && echo "export BRAVE_API_KEY=\"$BRAVE_KEY\""
  [[ -n "$JINA_KEY" ]] && echo "export JINA_API_KEY=\"$JINA_KEY\""
  [[ -n "$AGENTMAIL_KEY" ]] && echo "export AGENTMAIL_API_KEY=\"$AGENTMAIL_KEY\""
  echo "export SPRINGDRIFT_WEB_TOKEN=\"$WEB_TOKEN\""
} > "$ENV_FILE"
ok "Generated $ENV_FILE"

# Ensure .env is gitignored
if ! grep -q "^\.env$" .gitignore 2>/dev/null; then
  echo ".env" >> .gitignore
  ok "Added .env to .gitignore"
fi

# ── Verify ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}6. Verification${NC}"
gleam build 2>&1 | tail -1
ok "Build passes"

echo ""
echo "─────────────────────────────────────────"
echo -e "${BOLD}${GREEN}Setup complete!${NC}"
echo ""
echo "  To run Springdrift:"
echo ""
echo "    source .env"
echo "    gleam run"
echo ""
echo "  Web GUI will be at http://localhost:8080"
echo "  Auth token: $WEB_TOKEN"
echo ""
if $OLLAMA_AVAILABLE; then
  echo "  For CBR embeddings, in another terminal:"
  echo "    ollama serve"
  echo "    ollama pull nomic-embed-text"
  echo ""
fi
echo "  To run tests:  gleam test"
echo "  To format:     gleam format"
echo ""
