#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift — Linux setup script (Ubuntu/Debian)
# Run from the repo root after cloning:
#   git clone https://github.com/seamus-brady/springdrift.git
#   cd springdrift
#   bash scripts/setup-linux.sh
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
ask_yn() { read -rp "  $1 [y/N]: " val; [[ "${val,,}" == "y" ]]; }

echo ""
echo -e "${BOLD}Springdrift — Linux Setup${NC}"
echo "─────────────────────────────────────────"
echo ""

# ── Check we're in the repo root ─────────────────────────────────────────────
if [[ ! -f "gleam.toml" ]]; then
  fail "Run this script from the springdrift repo root (where gleam.toml is)"
fi

# ── Detect distro ────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  DISTRO="$ID"
else
  DISTRO="unknown"
fi

if [[ "$DISTRO" != "ubuntu" && "$DISTRO" != "debian" ]]; then
  warn "This script is tested on Ubuntu/Debian. Your distro ($DISTRO) may need manual adjustments."
fi

# ── Dependencies ─────────────────────────────────────────────────────────────
echo -e "${BOLD}1. Dependencies${NC}"

# Erlang/OTP
if command -v erl &>/dev/null; then
  ok "Erlang/OTP ($(erl -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' -noshell 2>/dev/null || echo "installed"))"
else
  echo "  Installing Erlang/OTP..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq erlang-dev erlang-xmerl erlang-ssl erlang-inets erlang-parsetools erlang-tools
  ok "Erlang/OTP installed"
fi

# Gleam
if command -v gleam &>/dev/null; then
  ok "Gleam ($(gleam --version 2>/dev/null || echo "installed"))"
else
  echo "  Installing Gleam..."
  GLEAM_VERSION=$(curl -sfL https://api.github.com/repos/gleam-lang/gleam/releases/latest | grep -o '"tag_name": "v[^"]*"' | head -1 | tr -d '"' | cut -d'v' -f2)
  if [[ -z "$GLEAM_VERSION" ]]; then
    fail "Could not determine latest Gleam version. Install manually from https://gleam.run"
  fi
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  GLEAM_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64) GLEAM_ARCH="aarch64-unknown-linux-musl" ;;
    *) fail "Unsupported architecture: $ARCH" ;;
  esac
  curl -sfL "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-${GLEAM_ARCH}.tar.gz" | sudo tar xzf - -C /usr/local/bin
  ok "Gleam $GLEAM_VERSION installed"
fi

# Podman (optional)
SANDBOX_AVAILABLE=false
if command -v podman &>/dev/null; then
  ok "Podman (already installed)"
  SANDBOX_AVAILABLE=true
else
  if ask_yn "Install Podman? (isolated containers for code execution — the coder agent needs this)"; then
    sudo apt-get install -y -qq podman
    ok "Podman installed"
    SANDBOX_AVAILABLE=true
  else
    warn "Podman skipped — sandbox will be disabled"
  fi
fi

# Ollama (optional)
OLLAMA_AVAILABLE=false
if command -v ollama &>/dev/null; then
  ok "Ollama (already installed)"
  OLLAMA_AVAILABLE=true
else
  if ask_yn "Install Ollama? (local embeddings for case-based memory — significantly improves retrieval)"; then
    curl -fsSL https://ollama.com/install.sh | sh
    ok "Ollama installed"
    echo "  Run: ollama pull nomic-embed-text"
    OLLAMA_AVAILABLE=true
  else
    warn "Ollama skipped — CBR embeddings will be disabled"
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
echo "  Keys are stored in /etc/springdrift/env (root-readable only)."
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
    echo "  Ensure GOOGLE_APPLICATION_CREDENTIALS is set"
    ;;
  mistral)
    ask "Mistral API key" MISTRAL_KEY
    ;;
  local|mock)
    ok "No API key needed for $PROVIDER"
    ;;
esac

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
else
  cp -r .springdrift_example .springdrift
  ok "Created .springdrift/ from example"
fi

# ── Write config.toml ────────────────────────────────────────────────────────
CONFIG=".springdrift/config.toml"

if [[ ! -f "$CONFIG" ]] || grep -q "example" "$CONFIG" 2>/dev/null; then
  WEB_TOKEN=$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 48)

  RECIPIENTS_TOML="[]"
  if [[ -n "$COMMS_RECIPIENTS" ]]; then
    RECIPIENTS_TOML="[$(echo "$COMMS_RECIPIENTS" | sed 's/[[:space:]]*,[[:space:]]*/", "/g; s/^/"/; s/$/"/' )]"
  fi

  cat > "$CONFIG" << TOML
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift config — generated by setup-linux.sh
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

# ── Write env file ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}6. Environment${NC}"

sudo mkdir -p /etc/springdrift
{
  echo "# Springdrift environment — generated by setup-linux.sh"
  [[ -n "$ANTHROPIC_KEY" ]] && echo "ANTHROPIC_API_KEY=$ANTHROPIC_KEY"
  [[ -n "$MISTRAL_KEY" ]] && echo "MISTRAL_API_KEY=$MISTRAL_KEY"
  [[ -n "$VERTEX_PROJECT" ]] && echo "VERTEX_PROJECT_ID=$VERTEX_PROJECT"
  [[ -n "$BRAVE_KEY" ]] && echo "BRAVE_API_KEY=$BRAVE_KEY"
  [[ -n "$JINA_KEY" ]] && echo "JINA_API_KEY=$JINA_KEY"
  [[ -n "$AGENTMAIL_KEY" ]] && echo "AGENTMAIL_API_KEY=$AGENTMAIL_KEY"
  echo "SPRINGDRIFT_WEB_TOKEN=$WEB_TOKEN"
} | sudo tee /etc/springdrift/env > /dev/null
sudo chmod 600 /etc/springdrift/env
ok "API keys written to /etc/springdrift/env (root-readable only)"

# ── Systemd service ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}7. Systemd service${NC}"

INSTALL_DIR="$(pwd)"

# Create springdrift user if needed
if ! id springdrift &>/dev/null; then
  sudo useradd --system --shell /usr/sbin/nologin --home-dir "$INSTALL_DIR" springdrift
  ok "Created springdrift user"
else
  ok "springdrift user exists"
fi

# Set ownership
sudo chown -R springdrift:springdrift .springdrift/ 2>/dev/null || true
sudo chown -R springdrift:springdrift .sandbox-workspaces/ 2>/dev/null || true

cat << SERVICE | sudo tee /etc/systemd/system/springdrift.service > /dev/null
[Unit]
Description=Springdrift Agent
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=springdrift
Group=springdrift
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/build/erlang-shipment/entrypoint.sh run
Restart=on-failure
RestartSec=10
EnvironmentFile=/etc/springdrift/env

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR/.springdrift
ReadWritePaths=$INSTALL_DIR/.sandbox-workspaces
ReadWritePaths=$INSTALL_DIR/build

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
ok "Systemd service installed"

if ask_yn "Start Springdrift now?"; then
  sudo systemctl enable springdrift
  sudo systemctl start springdrift
  sleep 2
  if systemctl is-active --quiet springdrift; then
    ok "Springdrift is running"
  else
    warn "Service started but may still be initialising — check: journalctl -u springdrift -f"
  fi
else
  ok "Service installed but not started"
  echo "  Start with: sudo systemctl enable --now springdrift"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo -e "${BOLD}${GREEN}Setup complete!${NC}"
echo ""
echo "  Agent:     $AGENT_NAME"
echo "  Provider:  $PROVIDER"
echo "  Web GUI:   http://localhost:8080"
echo "  Auth:      $WEB_TOKEN"
echo ""
echo "  Manage:"
echo "    sudo systemctl start springdrift"
echo "    sudo systemctl stop springdrift"
echo "    sudo systemctl restart springdrift"
echo "    journalctl -u springdrift -f"
echo ""
echo "  Config:    .springdrift/config.toml"
echo "  API keys:  /etc/springdrift/env"
echo "  Tests:     gleam test"
echo ""
if $OLLAMA_AVAILABLE; then
  echo "  For CBR embeddings:"
  echo "    ollama pull nomic-embed-text"
  echo "    sudo systemctl restart springdrift"
  echo ""
fi
