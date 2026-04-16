# SD Install — VPS Deployment Script

**Status**: Partially Implemented
**Date**: 2026-03-26 (spec), 2026-03-29 (setup scripts)
**Dependencies**: SD Designer (planned, deferred — setup scripts handle config interactively)

---

## Implementation Status

**Two setup scripts implemented** in `scripts/`:

- `scripts/setup-macos.sh` — Homebrew-based, writes `.env`, no systemd
- `scripts/setup-linux.sh` — apt-based, writes `/etc/springdrift/env`, systemd service

Both scripts handle:
- Dependency installation (Erlang/OTP, Gleam, optional Podman/Ollama)
- Interactive config prompts (agent name, provider, API keys, optional services)
- Config generation (`.springdrift/config.toml` from prompts)
- API key management (env file, not in config)
- Auto-generated `SPRINGDRIFT_WEB_TOKEN`
- Build verification

**Deferred from original spec:**
- One-line curl install (requires hosting)
- SD Designer integration (interactive prompts replace it for now)
- Python tooling (SD Audit, SD Budget — not yet built)
- TLS/certbot setup
- Upgrade script
- RHEL/Rocky support

---

## Table of Contents

- [Overview](#overview)
- [What It Does](#what-it-does)
- [One-Line Install](#one-line-install)
- [Phases](#phases)
  - [Phase 1: System Dependencies](#phase-1-system-dependencies)
  - [Phase 2: Springdrift Binary](#phase-2-springdrift-binary)
  - [Phase 3: Python Tooling](#phase-3-python-tooling)
  - [Phase 4: SD Designer Handoff](#phase-4-sd-designer-handoff)
  - [Phase 5: Service Setup](#phase-5-service-setup)
  - [Phase 6: Verification](#phase-6-verification)
- [Platform Support](#platform-support)
- [Unattended Mode](#unattended-mode)
- [What It Installs](#what-it-installs)
- [What It Does NOT Do](#what-it-does-not-do)
- [Security](#security)
- [Upgrade Path](#upgrade-path)
- [Relationship to Other Specs](#relationship-to-other-specs)
- [Implementation](#implementation)

---

## Overview

A single shell script that takes a fresh VPS (Ubuntu/Debian) from bare metal to a running Springdrift instance in under 10 minutes. Installs all dependencies, downloads the release, runs SD Designer for configuration, sets up systemd services, and verifies the installation.

The operator runs one command. The script handles the rest. SD Designer handles the decisions.

---

## What It Does

```
Fresh VPS
  → Install system dependencies (Erlang/OTP, Gleam, Podman, Ollama)
  → Download Springdrift release
  → Install Python tooling (SD Audit, SD Budget, SD Backup, SD Designer)
  → Run SD Designer interactive wizard (or apply a design file)
  → Set up systemd service
  → Initialise git backup repo
  → Configure TLS (Let's Encrypt via built-in SSL)
  → Verify everything works
  → Print access instructions
```

---

## One-Line Install

```sh
curl -fsSL https://get.springdrift.dev | bash -s -- --design design.toml
```

The design file is required. Run `sd-designer init` on your workstation first to produce it.
```

---

## Phases

### Phase 1: System Dependencies

```sh
# Detect OS
# Install Erlang/OTP (from Erlang Solutions repo or ASDF)
# Install Gleam (from GitHub releases)
# Install Podman (from system repo) — optional, for sandbox
# Install Ollama (from install script) — optional, for embeddings
# Install Python 3.10+ (usually present)
# Install git (for backup)
# Install Nginx (optional, for TLS reverse proxy)
```

Each dependency check is idempotent — if already installed, skip.

```
Installing dependencies...
  Erlang/OTP 27:  ✓ already installed
  Gleam 1.x:      ✓ installing from GitHub... done
  Podman 5.x:     ✓ installing from apt... done
  Ollama:          ✓ installing... done
  Python 3.12:    ✓ already installed
  Git:            ✓ already installed
  Certbot:        ✓ installing for TLS certificates... done
```

### Phase 2: Springdrift Binary

```sh
# Create springdrift user (non-root)
# Clone or download release to /opt/springdrift/
# Build: gleam build (or download pre-compiled BEAM files)
# Set permissions
```

```
Installing Springdrift...
  Creating user:       springdrift
  Downloading release: v1.0.0... done
  Building:            gleam build... done
  Install location:    /opt/springdrift/
```

### Phase 3: Python Tooling

```sh
# Create virtualenv
# pip install sd-audit sd-budget sd-backup sd-designer
# Add to PATH
```

```
Installing Python tools...
  SD Designer:  ✓
  SD Audit:     ✓
  SD Budget:    ✓
  SD Backup:    ✓
```

### Phase 4: Apply Design File

The installer takes a design file produced by SD Designer. It does NOT run SD Designer — the operator runs SD Designer beforehand (on their workstation, in CI, or anywhere) and provides the output.

```sh
# Design file is required
sd-install --design /path/to/design.toml

# Or from a URL
sd-install --design https://internal.corp/springdrift/legal-design.toml
```

`sd-designer apply` produces the `.springdrift/` directory from the design file. `sd-install` copies that directory to the target location and sets permissions.

The separation is deliberate: SD Designer is an interactive tool the operator runs locally. SD Install is an automated deployment script that runs on the server. They don't run on the same machine.

See: [SD Designer spec](sd-designer.md)

### Phase 5: Service Setup

```sh
# Create systemd service file
# Enable and start the service
# Set up log rotation
# Initialise git backup repo (agent manages its own backup schedule)
```

#### systemd service

```ini
[Unit]
Description=Springdrift Agent
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=springdrift
Group=springdrift
WorkingDirectory=/opt/springdrift
ExecStart=/opt/springdrift/build/erlang-shipment/entrypoint.sh run
Restart=on-failure
RestartSec=10
Environment=HOME=/opt/springdrift

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/springdrift/.springdrift
ReadWritePaths=/opt/springdrift/.sandbox-workspaces

[Install]
WantedBy=multi-user.target
```

#### Backup

No cron job needed. Springdrift manages its own backup schedule internally via the Backup Actor (see [Git Backup spec](git-backup-restore.md)). The installer only initialises the git repo — the agent handles commit timing and push scheduling from `backup.toml`.

#### TLS (if domain provided)

Mist serves HTTPS directly — no reverse proxy needed. Erlang/OTP has native SSL support.

```sh
# Obtain certificate via certbot
certbot certonly --standalone -d agent.example.com

# Mist configured to use the certificate
# TLS config added to config.toml by SD Designer
```

Certificate auto-renewal managed by certbot's built-in systemd timer. Mist reloads certificates on SIGHUP.

### Phase 6: Verification

```sh
# Check service is running
# Check web GUI responds
# Check Podman sandbox (if enabled)
# Check Ollama (if enabled)
# Run sd-backup verify
# Print summary
```

```
Verification
=============
  Service:     ✓ springdrift.service active (running)
  Web GUI:     ✓ http://localhost:12001 responding
  Sandbox:     ✓ Podman healthy, 2 containers ready
  Embeddings:  ✓ Ollama responding, nomic-embed-text loaded
  Backup:      ✓ Git repo initialised, first commit created

  ╔═══════════════════════════════════════════════════╗
  ║  Springdrift is running!                          ║
  ║                                                   ║
  ║  Agent:    Atlas                                  ║
  ║  Web GUI:  https://agent.example.com              ║
  ║  Provider: Anthropic (claude-haiku / claude-opus) ║
  ║  Domain:   Legal                                  ║
  ║                                                   ║
  ║  Manage:   sudo systemctl [start|stop|restart]    ║
  ║            springdrift                             ║
  ║  Logs:     journalctl -u springdrift -f            ║
  ║  Audit:    sd-audit summary                       ║
  ║  Budget:   sd-budget summary                      ║
  ║  Backup:   sd-backup status                       ║
  ╚═══════════════════════════════════════════════════╝
```

---

## Platform Support

| Platform | Status |
|---|---|
| Ubuntu 22.04+ | Primary target |
| Debian 12+ | Supported |
| RHEL/Rocky/Alma 9+ | Planned (yum/dnf variants) |
| macOS | SD Designer + manual setup (no systemd) |
| Docker | Separate Dockerfile (future) |

---

## Unattended Mode

For automation (Terraform, Ansible, cloud-init):

```sh
curl -fsSL https://get.springdrift.dev | bash -s -- \
  --design https://internal.corp/springdrift/legal-design.toml \
  --domain agent.example.com \
  --tls
```

The design file contains all configuration. Environment variables provide secrets (API keys, tokens) that should not be in the design file.

The install script is fully non-interactive when a design file is provided.

---

## What It Installs

| Component | Location | Purpose |
|---|---|---|
| Springdrift | `/opt/springdrift/` | The agent |
| SD Designer | `/usr/local/bin/sd-designer` | Configuration wizard |
| SD Audit | `/usr/local/bin/sd-audit` | Log analysis |
| SD Budget | `/usr/local/bin/sd-budget` | Cost management |
| SD Backup | `/usr/local/bin/sd-backup` | Backup/restore |
| Agent data | `/opt/springdrift/.springdrift/` | Configuration + memory |
| Systemd service | `/etc/systemd/system/springdrift.service` | Service management |
| TLS certs | `/etc/letsencrypt/live/{domain}/` | HTTPS certificates (optional) |

## What It Does NOT Do

- **Does not install on the current user's machine.** Uses a dedicated `springdrift` system user.
- **Does not store credentials in files.** API keys are set as environment variables in the systemd service file (root-only readable).
- **Does not expose the agent without TLS.** If a domain is provided, TLS is mandatory via Mist's native SSL. No reverse proxy. Without a domain, the agent listens on localhost only.
- **Does not install Nginx or any reverse proxy.** Mist serves everything directly.
- **Does not run as root.** The agent runs as the `springdrift` user with minimal privileges.
- **Does not make configuration decisions.** That's SD Designer's job.

---

## Security

- Dedicated non-root user
- systemd hardening (NoNewPrivileges, ProtectSystem, ProtectHome)
- ReadWritePaths restricted to `.springdrift/` and `.sandbox-workspaces/`
- API keys in environment variables, not files
- TLS via Mist native SSL (no reverse proxy)
- Podman containers with restricted capabilities
- Web GUI authentication via `SPRINGDRIFT_WEB_TOKEN`

---

## Upgrade Path

```sh
# Download new version
sd-install upgrade

# Or manually:
cd /opt/springdrift
git pull
gleam build
sudo systemctl restart springdrift
```

The upgrade script:
1. Stops the service
2. Creates a backup (`sd-backup run`)
3. Downloads the new release
4. Builds
5. Runs `sd-designer inspect` to check config compatibility
6. Starts the service
7. Verifies

Rollback: `sd-backup restore --commit <pre-upgrade-commit>`

---

## Relationship to Other Specs

| Spec | Relationship |
|---|---|
| [SD Designer](sd-designer.md) | Installer hands off to Designer for all configuration decisions |
| [SD Audit](sd-audit.md) | Installed as part of the Python tooling suite |
| [SD Budget](sd-budget.md) | Installed as part of the Python tooling suite |
| [SD Backup](git-backup-restore.md) | Git repo initialised during install; agent manages its own backup schedule |
| [Multi-Tenant](multi-tenant.md) | Installer supports single-tenant; multi-tenant migration via `--migrate-to-multi-tenant` |
| [Web GUI v2](web-gui-v2.md) | TLS configured for the web GUI via Mist native SSL |
| [OAuth Authentication](oauth-authentication.md) | OAuth providers configured during install |
| [Multi-Provider Failover](multi-provider-failover.md) | Multiple provider credentials can be set during install |

---

## Implementation

Single bash script (~500-700 lines) plus an `upgrade` companion script (~100 lines). No external dependencies beyond `curl` and `bash`.

```
tools/sd-install/
├── install.sh           # Main install script
├── upgrade.sh           # Upgrade script
├── templates/
│   ├── springdrift.service   # systemd unit template
│   ├── certbot-renew.sh      # Certificate renewal hook
│   └── logrotate.conf        # Log rotation template
└── README.md
```

The script is hosted at `get.springdrift.dev` and versioned in the Springdrift repo at `tools/sd-install/`.
