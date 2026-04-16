# SD Designer — Installation Configuration Tool

**Status**: Planned
**Date**: 2026-03-26
**Dependencies**: None — generates configuration files, does not require a running Springdrift instance

---

## Table of Contents

- [Overview](#overview)
- [Design Principles](#design-principles)
- [Modes](#modes)
  - [Interactive Wizard](#interactive-wizard)
  - [From Design File](#from-design-file)
  - [Inspect Existing](#inspect-existing)
  - [Export Design](#export-design)
- [Wizard Flow](#wizard-flow)
  - [Step 1: Basics](#step-1-basics)
  - [Step 2: LLM Provider](#step-2-llm-provider)
  - [Step 3: GUI](#step-3-gui)
  - [Step 4: Identity & Persona](#step-4-identity-persona)
  - [Step 5: D' Safety Configuration](#step-5-d-safety-configuration)
  - [Step 6: Sandbox](#step-6-sandbox)
  - [Step 7: Memory & Embeddings](#step-7-memory-embeddings)
  - [Step 8: Scheduler](#step-8-scheduler)
  - [Step 9: Skills](#step-9-skills)
  - [Step 10: Review & Generate](#step-10-review-generate)
- [Domain Presets](#domain-presets)
  - [General (default)](#general-default)
  - [Legal](#legal)
  - [Insurance](#insurance)
  - [Research](#research)
  - [Engineering](#engineering)
  - [Custom](#custom)
- [Design File Format](#design-file-format)
  - [Replay](#replay)
- [Inspect Command](#inspect-command)
- [Architecture](#architecture)
  - [Dependencies](#dependencies)
  - [Installation](#installation)
- [Relationship to SD Audit](#relationship-to-sd-audit)
- [Implementation Estimate](#implementation-estimate)


## Overview

A guided configuration tool that produces a complete, valid `.springdrift/` directory from a series of questions. Replaces the manual process of copying `.springdrift_example/`, editing TOML, writing persona files, and configuring D' rules by hand.

SD Designer is the front door for new users. It turns "read the CLAUDE.md and figure it out" into "answer these questions and you're running."

---

## Design Principles

1. **Generates files, doesn't run the agent.** SD Designer produces a `.springdrift/` directory. Springdrift reads it on startup. Clean separation.
2. **Opinionated defaults, full override.** Every question has a sensible default. An operator can press Enter through the whole wizard and get a working installation. Power users can customise everything.
3. **Domain-aware presets.** Selecting a domain (legal, insurance, research, engineering, general) seeds appropriate D' features, CBR categories, persona traits, and skill templates.
4. **Validates before writing.** Checks API keys, tests provider connectivity, validates TOML/JSON syntax, warns about missing dependencies (Podman, Ollama).
5. **Reproducible.** The wizard state can be saved as a design file (TOML) and replayed. `sd-designer apply design.toml` reproduces the exact same installation.

---

## Modes

### Interactive Wizard

```sh
sd-designer init
```

Guided step-by-step configuration with prompts, defaults, and validation.

### From Design File

```sh
sd-designer apply design.toml
```

Non-interactive — reads a design file and generates the installation. For automation, CI/CD, and reproducible deployments.

### Inspect Existing

```sh
sd-designer inspect .springdrift/
```

Reads an existing installation and reports: what's configured, what's missing, what's misconfigured, what could be improved.

### Export Design

```sh
sd-designer export .springdrift/ > design.toml
```

Reverse-engineers a design file from an existing installation. Useful for replication and backup.

---

## Wizard Flow

### Step 1: Basics

```
SD Designer — New Springdrift Installation
==========================================

Agent name: [Springdrift] > Curragh
Agent version: [] > Mk-2

Domain preset:
  1. General (default)
  2. Legal
  3. Insurance
  4. Research
  5. Engineering
  6. Custom

Select [1]: > 2

This will configure D' features, persona traits, and skill templates
for legal domain work. You can customise everything afterwards.
```

### Step 2: LLM Provider

```
LLM Provider
=============

Provider:
  1. Anthropic (direct API)
  2. Google Vertex AI
  3. OpenAI
  4. OpenRouter
  5. Mistral
  6. Local (Ollama)
  7. Mock (testing)

Select [1]: > 1

Anthropic API key:
  Found ANTHROPIC_API_KEY in environment ✓

Task model (fast, for simple queries):
  [claude-haiku-4-5-20251001] >

Reasoning model (powerful, for complex queries):
  [claude-opus-4-6] >

Testing connection... ✓ Connected to Anthropic API
```

For Vertex AI:
```
Vertex AI Configuration
========================

GCP Project ID: > springdrift
Location: [europe-west1] >
Endpoint: [europe-west1-aiplatform.googleapis.com] >

Authentication:
  1. Service account key file (recommended for production)
  2. Application Default Credentials
  3. Manual token (testing only)

Select [1]: > 1

Key file path: > /path/to/sa-key.json
  Reading key file... ✓
  Client email: agent@springdrift.iam.gserviceaccount.com
  Minting test token... ✓
  Testing API access... ✓ Connected to Vertex AI
```

### Step 3: GUI

```
User Interface
===============

GUI mode:
  1. Web (browser-based, recommended)
  2. TUI (terminal)

Select [1]: >

Web port: [12001] >
Authentication:
  Set SPRINGDRIFT_WEB_TOKEN for access control? [y/N]: > y
  Token: > (auto-generated: sd_a7b3c9d2e1f4...)
```

### Step 4: Identity & Persona

```
Agent Identity
===============

The persona defines how the agent thinks about itself and communicates.

Use domain preset persona (Legal)? [Y/n]: >

Generating persona for legal domain...

Preview:
  "I am Curragh. I am a legal knowledge worker agent built on the
   Springdrift framework. I research case law, track regulatory
   positions, and build institutional memory from matter outcomes.
   I lead with evidence, qualify uncertainty, and never present
   reconstructed information as verified fact."

Accept? [Y/n]: >
Customise? (opens in $EDITOR) [y/N]: >
```

### Step 5: D' Safety Configuration

```
Safety Configuration (D')
==========================

Use domain preset D' config (Legal)? [Y/n]: >

Legal preset includes:
  Input gate:
    ✓ prompt_injection (high, not critical — operator meta-discussion allowed)
    ✓ harmful_request (high, critical)
    ✓ scope_violation (medium)
    ✓ confidentiality_breach (high, critical) — legal-specific
    Thresholds: modify 0.45, reject 0.75

  Tool gate:
    ✓ data_exfiltration (high, critical)
    ✓ unauthorized_write (high, critical)
    ✓ cross_matter_access (high, critical) — legal-specific
    Thresholds: modify 0.35, reject 0.55

  Output gate:
    ✓ unsourced_claim (high, critical)
    ✓ accuracy (high, critical)
    ✓ certainty_overstatement (medium)
    ✓ client_confidentiality (high, critical) — legal-specific
    ✓ privilege_leak (high, critical) — legal-specific
    Thresholds: modify 0.40, reject 0.75
    Min reject: 0.65 (floor)

  Deterministic rules:
    ✓ Credential patterns (block)
    ✓ Internal URL patterns (block)
    ✓ Client name patterns in outbound (escalate) — legal-specific
    ✓ Opposing counsel references (escalate) — legal-specific

  Canary probes: enabled on input + tool gates
  Meta observer: enabled, decay 1 day, tighten factor 0.90

Accept? [Y/n]: >
```

### Step 6: Sandbox

```
Code Execution Sandbox
=======================

Enable Podman sandbox for coder agent? [Y/n]: >

Checking Podman... ✓ podman version 5.8.1
Checking podman machine... ✓ running

Pool size: [2] >
Container image: [python:3.12-slim] >
Memory per container: [512] MB >
```

If Podman not found:
```
Checking Podman... ✗ not found

The coder agent needs Podman for sandboxed code execution.
Without it, the coder will ask the operator to run code manually.

Install Podman? See: https://podman.io/getting-started/installation
Continue without sandbox? [Y/n]: >
```

### Step 7: Memory & Embeddings

```
Memory Configuration
=====================

CBR embedding (requires Ollama):
  Checking Ollama... ✓ running at http://localhost:11434
  Checking model nomic-embed-text... ✓ available

  Enable CBR embeddings? [Y/n]: >

CBR retrieval cap: [4] cases (per Memento paper recommendation)
Fact confidence decay half-life: [30] days
CBR confidence decay half-life: [60] days
```

If Ollama not found:
```
  Checking Ollama... ✗ not found

  CBR will use keyword matching only (no semantic similarity).
  This works well — embeddings are an optional enhancement.

  Continue without embeddings? [Y/n]: >
```

### Step 8: Scheduler

```
Scheduler
==========

Max autonomous cycles per hour: [20] >
Max tokens per hour: [500000] >

The agent can schedule its own work. These limits prevent runaway costs.
```

### Step 9: Skills

```
Skills
=======

Use domain preset skills (Legal)? [Y/n]: >

Installing skills:
  ✓ web-research — tool selection decision tree
  ✓ legal-research — case law search patterns, citation formats
  ✓ matter-analysis — due diligence patterns, risk clause identification
  ✓ regulatory-tracking — position tracking, audit trail patterns

Custom skills directory: [] >
```

### Step 10: Review & Generate

```
Review
=======

Agent:      Curragh (Mk-2)
Domain:     Legal
Provider:   Anthropic (claude-haiku-4-5 / claude-opus-4-6)
GUI:        Web on port 12001 (authenticated)
Sandbox:    Podman (2 containers, 512MB each)
Embeddings: Ollama (nomic-embed-text)
D':         Legal preset (5 input features, 4 tool features, 6 output features)
Scheduler:  20 cycles/hr, 500K tokens/hr
Skills:     4 domain skills + web-research

Generate installation? [Y/n]: >

Writing .springdrift/config.toml... ✓
Writing .springdrift/dprime.json... ✓
Writing .springdrift/identity/persona.md... ✓
Writing .springdrift/identity/session_preamble.md... ✓
Writing .springdrift/skills/web-research/SKILL.md... ✓
Writing .springdrift/skills/legal-research/SKILL.md... ✓
Writing .springdrift/skills/matter-analysis/SKILL.md... ✓
Writing .springdrift/skills/regulatory-tracking/SKILL.md... ✓
Creating .springdrift/memory/ directories... ✓
Saving design to .springdrift/design.toml... ✓

Done! Start the agent with:
  gleam run

Web GUI at:
  http://localhost:12001
```

---

## Domain Presets

### General (default)

Standard configuration — research, planning, coding, writing. Default D' features, generic persona, web-research skill only.

### Legal

- Persona: legal knowledge worker, evidence-led, citation-focused
- D' features: client confidentiality, privilege leak, cross-matter access, unsourced claims, opposing counsel references
- Deterministic rules: client name patterns, internal reference numbers
- Skills: legal-research, matter-analysis, regulatory-tracking
- CBR categories weighted toward: Strategy (precedent), Pitfall (failed arguments), DomainKnowledge (statute interpretation)

### Insurance

- Persona: underwriting analyst, risk-focused, actuarial awareness
- D' features: policyholder data exposure, risk assessment accuracy, regulatory compliance, claims data confidentiality
- Deterministic rules: policy number patterns, national ID patterns, health data indicators
- Skills: underwriting-patterns, claims-analysis, regulatory-filings
- CBR categories weighted toward: Strategy (successful risk assessments), Pitfall (claims that exceeded reserves), DomainKnowledge (policy interpretation)

### Research

- Persona: research analyst, source-focused, uncertainty-aware
- D' features: unsourced claims, certainty overstatement, accuracy, source reliability
- Lighter safety posture — fewer blocks, more modifications
- Skills: web-research, academic-search, data-analysis
- CBR categories weighted toward: Strategy (successful research approaches), Troubleshooting (dead-end searches)

### Engineering

- Persona: engineering assistant, specification-focused, risk-aware
- D' features: estimation accuracy, scope creep, safety compliance
- Sandbox enabled by default with extended timeout
- Skills: estimation-patterns, specification-review, risk-register
- CBR categories weighted toward: CodePattern (reusable solutions), Pitfall (estimation errors), DomainKnowledge (standards and regulations)

### Custom

Start from General, customise everything. For operators who know exactly what they want.

---

## Design File Format

The design file captures the complete wizard state in TOML:

```toml
[meta]
version = 1
generated_by = "sd-designer 0.1.0"
generated_at = "2026-03-26T22:00:00Z"

[agent]
name = "Curragh"
version = "Mk-2"
domain = "legal"

[provider]
type = "anthropic"
task_model = "claude-haiku-4-5-20251001"
reasoning_model = "claude-opus-4-6"

[provider.vertex]
# Only present if type = "vertex"
project_id = "springdrift"
location = "europe-west1"
endpoint = "europe-west1-aiplatform.googleapis.com"
credentials = "/path/to/sa-key.json"

[gui]
mode = "web"
port = 12001
authenticated = true

[sandbox]
enabled = true
pool_size = 2
memory_mb = 512
image = "python:3.12-slim"

[memory]
embeddings = true
embedding_model = "nomic-embed-text"
cbr_max_results = 4
fact_decay_half_life = 30
cbr_decay_half_life = 60

[scheduler]
max_cycles_per_hour = 20
max_tokens_per_hour = 500000

[dprime]
preset = "legal"
# Override individual settings below if needed
# [dprime.overrides.input]
# reject_threshold = 0.80

[persona]
preset = "legal"
# Custom persona text (overrides preset if set)
# custom = "I am Curragh..."

[skills]
preset = "legal"
# Additional skill directories
# extra_dirs = ["/path/to/custom/skills"]
```

### Replay

```sh
# Generate from design file (non-interactive)
sd-designer apply design.toml

# Generate with overrides
sd-designer apply design.toml --set provider.type=vertex --set agent.name=Atlas
```

---

## Inspect Command

```sh
$ sd-designer inspect .springdrift/

SD Designer — Installation Inspection
======================================

Agent: Curragh (Mk-2)
Provider: anthropic ✓
  Task model: claude-haiku-4-5-20251001 ✓
  Reasoning model: claude-opus-4-6 ✓
  API key: ANTHROPIC_API_KEY set ✓

Config: .springdrift/config.toml ✓
  All bare keys before first [section] ✓
  Known sections only ✓
  No unknown keys ✓

D' Config: .springdrift/dprime.json ✓
  Input gate: 4 features ✓
  Tool gate: 4 features ✓
  Output gate: 5 features ✓
  Deterministic: 13 rules (3 input, 6 tool, 4 output) ✓
  Meta observer: enabled ✓

Identity:
  persona.md: present ✓ (427 chars)
  session_preamble.md: present ✓

Skills: 2 found
  ✓ web-research
  ✓ HOW_TO

Sandbox:
  Podman: ✓ version 5.8.1
  Pool size: 2
  Image: python:3.12-slim ✓

Memory:
  Narrative: 89 entries (7 days)
  CBR: 134 cases
  Facts: 267 active
  Ollama embeddings: ✓ connected

Warnings:
  ⚠ Output gate min_reject_threshold not set (defaults to 0.40 — consider 0.65)
  ⚠ No custom skills beyond defaults — consider adding domain-specific skills
  ⚠ Scheduler has 14 completed jobs that could be cleaned up

Recommendations:
  → Set [vertex] config for EU data residency (currently using direct Anthropic API)
  → Consider enabling narrative summaries for long-running installation
  → Fact provenance coverage is 79% — older facts lack source tracking
```

---

## Architecture

```
sd-designer/
├── pyproject.toml
├── sd_designer/
│   ├── __init__.py
│   ├── cli.py                # Click CLI: init, apply, inspect, export
│   ├── wizard/
│   │   ├── flow.py           # Wizard step orchestration
│   │   ├── basics.py         # Step 1: name, domain
│   │   ├── provider.py       # Step 2: LLM provider
│   │   ├── gui.py            # Step 3: interface
│   │   ├── identity.py       # Step 4: persona
│   │   ├── dprime.py         # Step 5: safety config
│   │   ├── sandbox.py        # Step 6: code execution
│   │   ├── memory.py         # Step 7: CBR, embeddings, decay
│   │   ├── scheduler.py      # Step 8: autonomy limits
│   │   ├── skills.py         # Step 9: skill selection
│   │   └── review.py         # Step 10: review and generate
│   ├── presets/
│   │   ├── general/
│   │   │   ├── dprime.json
│   │   │   ├── persona.md
│   │   │   └── skills/
│   │   ├── legal/
│   │   │   ├── dprime.json
│   │   │   ├── persona.md
│   │   │   └── skills/
│   │   ├── insurance/
│   │   │   ├── dprime.json
│   │   │   ├── persona.md
│   │   │   └── skills/
│   │   ├── research/
│   │   │   ├── dprime.json
│   │   │   ├── persona.md
│   │   │   └── skills/
│   │   └── engineering/
│   │       ├── dprime.json
│   │       ├── persona.md
│   │       └── skills/
│   ├── generators/
│   │   ├── config_toml.py    # Generate config.toml from design
│   │   ├── dprime_json.py    # Generate dprime.json from design + preset
│   │   ├── persona.py        # Generate persona.md from preset + customisation
│   │   ├── preamble.py       # Generate session_preamble.md
│   │   ├── skills.py         # Copy/generate skill files
│   │   └── directories.py    # Create directory structure
│   ├── validators/
│   │   ├── provider.py       # Test API connectivity
│   │   ├── podman.py         # Check Podman installation
│   │   ├── ollama.py         # Check Ollama + model availability
│   │   ├── toml.py           # TOML syntax validation
│   │   └── json.py           # JSON syntax validation
│   ├── inspector/
│   │   ├── inspect.py        # Read existing installation
│   │   ├── recommendations.py # Generate improvement suggestions
│   │   └── export.py         # Reverse-engineer design file
│   └── design.py             # Design file parser/writer
└── tests/
    ├── test_wizard.py
    ├── test_generators.py
    ├── test_validators.py
    ├── test_presets.py
    └── test_inspector.py
```

### Dependencies

```toml
[project]
requires-python = ">=3.10"
dependencies = [
    "click>=8.0",
    "tomli>=2.0",        # TOML reading (Python 3.10 compat)
    "tomli-w>=1.0",      # TOML writing
]
```

Minimal dependencies. No LLM calls. No pandas. Just CLI prompts, file generation, and validation.

### Installation

```sh
pip install sd-designer
# or from the repo:
pip install -e tools/sd-designer/
```

Lives in `tools/sd-designer/` alongside `tools/sd-audit/`.

---

## Relationship to SD Audit

| | SD Designer | SD Audit |
|---|---|---|
| When | Before first run | After agent has been running |
| Purpose | Configure a new installation | Analyse an existing installation's logs |
| Reads | Nothing (or existing installation for inspect) | JSONL log files |
| Writes | `.springdrift/` configuration files | Never writes to `.springdrift/` |
| Audience | New operator setting up an agent | Auditor, analyst, regulator reviewing agent behaviour |

Together they bookend the lifecycle: SD Designer creates the installation, Springdrift runs it, SD Audit examines what happened.

---

## Implementation Estimate

| Component | Effort |
|---|---|
| CLI framework + wizard flow | Small |
| 10 wizard steps | Medium (each step is ~50-80 lines) |
| 5 domain presets (dprime.json + persona + skills) | Medium |
| Generators (config, dprime, persona, dirs) | Medium |
| Validators (provider, podman, ollama) | Small |
| Inspector + recommendations | Medium |
| Design file parser/writer/exporter | Small |
| Tests | Medium |

Total: ~2000-2500 lines of Python. Straightforward CLI — the complexity is in the domain presets and validation, not the tooling.
