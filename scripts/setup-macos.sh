#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift — macOS setup script
# Run from the repo root after cloning:
#   git clone https://github.com/seamus-brady/springdrift.git
#   cd springdrift
#   bash scripts/setup-macos.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/setup-common.sh"

ask()  { read -rp "  $1: " "$2" <&3; }
ask_default() { read -rp "  $1 [$2]: " val <&3; eval "$3=\${val:-$2}"; }
ask_yn() { read -rp "  $1 [y/N]: " val <&3; [[ "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" == "y" ]]; }
ask_yn_default_yes() { read -rp "  $1 [Y/n]: " val <&3; [[ "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" != "n" ]]; }

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
    echo "    - Permission denied on .springdrift/ → sudo chown -R $(whoami) .springdrift/"
    echo "    - Gleam version → brew upgrade gleam (need >= $REQUIRED_GLEAM_MAJOR.$REQUIRED_GLEAM_MINOR.0)"
    echo "    - API keys not found → source .env before gleam run"
  fi
}
trap cleanup EXIT

echo ""
echo -e "${BOLD}Springdrift — macOS Setup${NC}"
echo "─────────────────────────────────────────"
echo ""

# ── Preflight checks ───────────────────────────────────────────────────────
echo -e "${BOLD}0. Preflight${NC}"

check_repo_root "." || fail "Run this script from the springdrift repo root (where gleam.toml is)"
ok "In repo root"

if [[ -d ".springdrift" ]]; then
  check_springdrift_writable ".springdrift" || fail ".springdrift/ exists but you don't have write permission. Fix with: sudo chown -R $(whoami) .springdrift/"
  ok ".springdrift/ exists and is writable"
else
  ok ".springdrift/ will be created from example"
fi

# ── Check Homebrew ───────────────────────────────────────────────────────────
echo ""
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
  command -v erl &>/dev/null || fail "Erlang installation failed — erl not found in PATH"
  ok "Erlang/OTP installed"
fi

# ── Gleam ────────────────────────────────────────────────────────────────────
if command -v gleam &>/dev/null; then
  GLEAM_VER=$(parse_gleam_version "$(gleam --version 2>/dev/null)")
  if gleam_version_ok "$GLEAM_VER"; then
    ok "Gleam ($GLEAM_VER)"
  else
    warn "Gleam ($GLEAM_VER) is too old — this project requires >= $REQUIRED_GLEAM_MAJOR.$REQUIRED_GLEAM_MINOR.0"
    if ask_yn "Upgrade Gleam via Homebrew?"; then
      brew upgrade gleam
      command -v gleam &>/dev/null || fail "Gleam upgrade failed"
      GLEAM_VER=$(parse_gleam_version "$(gleam --version 2>/dev/null)")
      gleam_version_ok "$GLEAM_VER" || fail "Gleam still too old after upgrade. Install latest manually from https://gleam.run"
      ok "Gleam upgraded ($GLEAM_VER)"
    else
      fail "Gleam >= $REQUIRED_GLEAM_MAJOR.$REQUIRED_GLEAM_MINOR.0 is required"
    fi
  fi
else
  echo -e "  Installing Gleam..."
  brew install gleam
  command -v gleam &>/dev/null || fail "Gleam installation failed — gleam not found in PATH"
  ok "Gleam installed ($(parse_gleam_version "$(gleam --version 2>/dev/null)"))"
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
    command -v podman &>/dev/null || fail "Podman installation failed"
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
    command -v ollama &>/dev/null || fail "Ollama installation failed"
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
echo "  Keys are stored in .env (gitignored). Source it before running."
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
  warn "Rename or delete it first if you want a fresh setup"
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
    "$BACKUP_REMOTE" "setup-macos.sh"
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
generate_env_file ".env" \
  "$ANTHROPIC_KEY" "$MISTRAL_KEY" "$VERTEX_PROJECT" \
  "$BRAVE_KEY" "$JINA_KEY" "$AGENTMAIL_KEY" "$WEB_TOKEN" "setup-macos.sh"
ok "Generated .env"

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

# ── Verify ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}6. Verification${NC}"
gleam build 2>&1 | tail -1
ok "Build passes"

echo ""
echo "─────────────────────────────────────────"
echo -e "${BOLD}${GREEN}Setup complete!${NC}"
echo ""
echo -e "  ${BOLD}To run Springdrift:${NC}"
echo ""
echo "    source .env"
echo "    gleam run"
echo ""
echo "  Web GUI will be at http://localhost:$WEB_PORT"
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
echo "  Setup log:     $SETUP_LOG"
echo ""
echo "  Troubleshooting:"
echo "    - Port in use?     Change [web] port in .springdrift/config.toml"
echo "    - Keys not found?  source .env before gleam run"
echo "    - Gleam too old?   brew upgrade gleam (need >= $REQUIRED_GLEAM_MAJOR.$REQUIRED_GLEAM_MINOR.0)"
echo ""
