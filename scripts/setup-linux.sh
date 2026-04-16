#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift — Linux setup script (Ubuntu/Debian)
# Run from the repo root after cloning:
#   git clone https://github.com/seamus-brady/springdrift.git
#   cd springdrift
#   bash scripts/setup-linux.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/setup-common.sh"

ask()  { read -rp "  $1: " "$2" <&3; }
ask_default() { read -rp "  $1 [$2]: " val <&3; eval "$3=\${val:-$2}"; }
ask_yn() { read -rp "  $1 [y/N]: " val <&3; [[ "${val,,}" == "y" ]]; }

SETUP_LOG=".springdrift-setup.log"
exec 3<&0
exec 0< /dev/null
if [[ -t 3 ]]; then
  exec > >(tee -a "$SETUP_LOG") 2>&1
fi

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo ""
    echo -e "${RED}Setup failed at step above.${NC}"
    echo "  Full log saved to: $SETUP_LOG"
    echo ""
    echo "  Common fixes:"
    echo "    - Permission denied → don't run as root; use a normal user with sudo"
    echo "    - Port in use → change [web] port in .springdrift/config.toml"
    echo "    - Gleam version → install latest from https://gleam.run"
    echo "    - API keys not found → source /etc/springdrift/env or .env before gleam run"
  fi
}
trap cleanup EXIT

echo ""
echo -e "${BOLD}Springdrift — Linux Setup${NC}"
echo "─────────────────────────────────────────"
echo ""

# ── Preflight checks ───────────────────────────────────────────────────────
echo -e "${BOLD}0. Preflight${NC}"

check_repo_root "." || fail "Run this script from the springdrift repo root (where gleam.toml is)"
ok "In repo root"

check_not_root || fail "Do not run this script as root. Run as a normal user — it will sudo when needed."
ok "Running as $(whoami) (not root)"

if [[ -d ".springdrift" ]]; then
  check_springdrift_writable ".springdrift" || fail ".springdrift/ exists but you don't have write permission. Fix with: sudo chown -R $(whoami) .springdrift/"
  ok ".springdrift/ exists and is writable"
else
  ok ".springdrift/ will be created from example"
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
echo ""
echo -e "${BOLD}1. Dependencies${NC}"

# Erlang/OTP
if command -v erl &>/dev/null; then
  ok "Erlang/OTP ($(erl -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' -noshell 2>/dev/null || echo "installed"))"
else
  echo "  Installing Erlang/OTP..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq erlang-dev erlang-xmerl erlang-ssl erlang-inets erlang-parsetools erlang-tools
  command -v erl &>/dev/null || fail "Erlang installation failed — erl not found in PATH"
  ok "Erlang/OTP installed"
fi

# Gleam
install_gleam_linux() {
  local GLEAM_VERSION
  GLEAM_VERSION=$(curl -sfL https://api.github.com/repos/gleam-lang/gleam/releases/latest | grep -o '"tag_name": "v[^"]*"' | head -1 | tr -d '"' | cut -d'v' -f2)
  if [[ -z "$GLEAM_VERSION" ]]; then
    fail "Could not determine latest Gleam version. Install manually from https://gleam.run"
  fi
  local ARCH
  ARCH=$(uname -m)
  local GLEAM_ARCH
  case "$ARCH" in
    x86_64)  GLEAM_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64) GLEAM_ARCH="aarch64-unknown-linux-musl" ;;
    *) fail "Unsupported architecture: $ARCH" ;;
  esac
  curl -sfL "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-${GLEAM_ARCH}.tar.gz" | sudo tar xzf - -C /usr/local/bin
  command -v gleam &>/dev/null || fail "Gleam installation failed — gleam not found in PATH"
  ok "Gleam $GLEAM_VERSION installed"
}

if command -v gleam &>/dev/null; then
  GLEAM_VER=$(parse_gleam_version "$(gleam --version 2>/dev/null)")
  if gleam_version_ok "$GLEAM_VER"; then
    ok "Gleam ($GLEAM_VER)"
  else
    warn "Gleam ($GLEAM_VER) is too old — this project requires >= $REQUIRED_GLEAM_MAJOR.$REQUIRED_GLEAM_MINOR.0"
    if ask_yn "Upgrade Gleam to latest?"; then
      install_gleam_linux
    else
      fail "Gleam >= $REQUIRED_GLEAM_MAJOR.$REQUIRED_GLEAM_MINOR.0 is required"
    fi
  fi
else
  echo "  Installing Gleam..."
  install_gleam_linux
fi

# Podman (optional)
SANDBOX_AVAILABLE=false
if command -v podman &>/dev/null; then
  ok "Podman (already installed)"
  SANDBOX_AVAILABLE=true
else
  if ask_yn "Install Podman? (isolated containers for code execution — the coder agent needs this)"; then
    sudo apt-get install -y -qq podman
    command -v podman &>/dev/null || fail "Podman installation failed"
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
    command -v ollama &>/dev/null || fail "Ollama installation failed"
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
ok "Build complete (Gleam $(parse_gleam_version "$(gleam --version 2>/dev/null)"))"

# ── Configuration ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}3. Configuration${NC}"
echo ""

ask_default "Agent name" "Springdrift" AGENT_NAME

echo ""
echo "  LLM Providers: anthropic (default), vertex, mistral, local, mock"
ask_default "Provider" "anthropic" PROVIDER

echo ""
echo -e "${BOLD}4. API Keys${NC}"
echo "  Keys are stored in /etc/springdrift/env (for systemd) and .env (for manual runs)."
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
WEB_TOKEN=$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 48)

if [[ ! -f "$CONFIG" ]] || grep -q "example" "$CONFIG" 2>/dev/null; then
  RECIPIENTS_TOML=$(format_recipients_toml "$COMMS_RECIPIENTS")

  generate_config "$CONFIG" "$PROVIDER" "$AGENT_NAME" "$SANDBOX_AVAILABLE" \
    "$OLLAMA_AVAILABLE" "$COMMS_ENABLED" "$COMMS_ADDRESS" "$RECIPIENTS_TOML" \
    "$BACKUP_REMOTE" "setup-linux.sh"
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

# ── Write env files ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}6. Environment${NC}"

# Systemd env file
sudo mkdir -p /etc/springdrift
generate_systemd_env_file "/tmp/springdrift-env.tmp" \
  "$ANTHROPIC_KEY" "$MISTRAL_KEY" "$VERTEX_PROJECT" \
  "$BRAVE_KEY" "$JINA_KEY" "$AGENTMAIL_KEY" "$WEB_TOKEN"
sudo mv /tmp/springdrift-env.tmp /etc/springdrift/env
sudo chmod 600 /etc/springdrift/env
ok "API keys written to /etc/springdrift/env (systemd)"

# .env for manual runs
generate_env_file ".env" \
  "$ANTHROPIC_KEY" "$MISTRAL_KEY" "$VERTEX_PROJECT" \
  "$BRAVE_KEY" "$JINA_KEY" "$AGENTMAIL_KEY" "$WEB_TOKEN" "setup-linux.sh"
ok "API keys written to .env (manual runs)"

if ! grep -q "^\.env$" .gitignore 2>/dev/null; then
  echo ".env" >> .gitignore
  ok "Added .env to .gitignore"
fi

verify_env_file ".env" "$PROVIDER" || fail "API key verification failed — .env does not contain required keys"
ok "API keys verified"

# ── Check port availability ─────────────────────────────────────────────────
WEB_PORT=12001
if check_port_available "$WEB_PORT"; then
  ok "Port $WEB_PORT is available"
else
  warn "Port $WEB_PORT is already in use. Change [web] port in .springdrift/config.toml"
fi

# ── Systemd service ──────────────────────────────────────────────────────────
if [[ "${SPRINGDRIFT_SKIP_SYSTEMD:-0}" == "1" ]]; then
  ok "Systemd setup skipped (SPRINGDRIFT_SKIP_SYSTEMD=1)"
else
echo ""
echo -e "${BOLD}7. Systemd service${NC}"

INSTALL_DIR="$(pwd)"

if ! id springdrift &>/dev/null; then
  sudo useradd --system --shell /usr/sbin/nologin --home-dir "$INSTALL_DIR" springdrift
  ok "Created springdrift user"
else
  ok "springdrift user exists"
fi

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
  sleep 3
  if systemctl is-active --quiet springdrift; then
    ok "Springdrift is running"
    if command -v curl &>/dev/null; then
      sleep 2
      if curl -sf --max-time 5 "http://localhost:${WEB_PORT}" > /dev/null 2>&1; then
        ok "Web GUI responding at http://localhost:${WEB_PORT}"
      else
        warn "Service is running but web GUI not yet responding — it may still be starting up"
        echo "    Check: journalctl -u springdrift -f"
      fi
    fi
  else
    warn "Service failed to start"
    echo "    Check: journalctl -u springdrift --no-pager -n 20"
  fi
else
  ok "Service installed but not started"
  echo "  Start with: sudo systemctl enable --now springdrift"
fi

fi # end SPRINGDRIFT_SKIP_SYSTEMD guard

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo -e "${BOLD}${GREEN}Setup complete!${NC}"
echo ""
echo "  Agent:     $AGENT_NAME"
echo "  Provider:  $PROVIDER"
echo "  Web GUI:   http://localhost:$WEB_PORT"
echo "  Auth:      $WEB_TOKEN"
echo ""
echo "  Manage:"
echo "    sudo systemctl start springdrift"
echo "    sudo systemctl stop springdrift"
echo "    sudo systemctl restart springdrift"
echo "    journalctl -u springdrift -f"
echo ""
echo "  Config:    .springdrift/config.toml"
echo "  API keys:  /etc/springdrift/env (systemd) or .env (manual runs)"
echo ""
echo -e "  ${BOLD}For manual runs:${NC}"
echo "    source .env && gleam run"
echo ""
echo "  Tests:     gleam test"
echo "  Setup log: $SETUP_LOG"
echo ""
if $OLLAMA_AVAILABLE; then
  echo "  For CBR embeddings:"
  echo "    ollama pull nomic-embed-text"
  echo "    sudo systemctl restart springdrift"
  echo ""
fi

echo "  Troubleshooting:"
echo "    - Port in use?     Change [web] port in .springdrift/config.toml"
echo "    - Keys not found?  source .env before gleam run (or check /etc/springdrift/env for systemd)"
echo "    - Gleam too old?   gleam --version (need >= $REQUIRED_GLEAM_MAJOR.$REQUIRED_GLEAM_MINOR.0)"
echo "    - Service crash?   journalctl -u springdrift --no-pager -n 50"
echo ""
