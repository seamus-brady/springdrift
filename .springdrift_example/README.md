# .springdrift directory

Copy this directory to `.springdrift/` in your project root to get started:

```bash
cp -r .springdrift_example .springdrift
```

Then edit `.springdrift/config.toml` with your provider and API key.

## Directory layout

Everything the system generates lives inside `.springdrift/`. This makes backup
simple — copy one directory and you have everything.

```
.springdrift/
├── config.toml              Project-level config (overrides ~/.config/springdrift/config.toml)
├── identity/                Agent identity files (persona + session preamble + character)
│   ├── persona.md           First-person character text (supports {{agent_name}} slot)
│   ├── session_preamble.md  Dynamic session context with {{slot}} and [OMIT IF] rules
│   └── character.json       Character spec for normative calculus (virtues + highest endeavour)
├── identity.json            Stable agent UUID (auto-generated on first run)
├── session.json             Session persistence (auto-generated)
├── skills/                  Skill definitions + operator guide
│   ├── HOW_TO.md            Operator guide — tool selection heuristics and usage patterns
│   ├── web-research/        Web research tool selection decision tree
│   │   └── SKILL.md
│   └── shell-sandbox/       Shell sandbox usage guide
│       └── SKILL.md
├── logs/                    System logs (date-rotated JSON-L, auto-generated)
├── memory/
│   ├── cycle-log/           Per-cycle request/response logs (auto-generated)
│   ├── narrative/           Prime Narrative memory (auto-generated)
│   ├── cbr/                 Case-Based Reasoning cases (auto-generated)
│   ├── facts/               Key-value fact store (auto-generated)
│   ├── artifacts/           Large content storage (auto-generated)
│   ├── planner/             Tasks and endeavours (auto-generated)
│   ├── schedule/            Operator-visible scheduler state (auto-generated)
│   ├── comms/               Sent and received emails (auto-generated)
│   ├── captures/            Commitment-tracker items (auto-generated)
│   ├── affect/              Functional emotion snapshots (auto-generated)
│   ├── learning_goals/      Agent-set learning goals (auto-generated)
│   ├── strategies/          Strategy Registry events (auto-generated)
│   ├── consolidation/       Remembrancer run records (auto-generated)
│   ├── skills/              Skill lifecycle log (auto-generated)
│   └── meta_learning/       BEAM worker sidecar (auto-generated)
├── knowledge/               Document library (auto-generated on first use)
├── schemas/                 XStructor XSD schemas (auto-generated, compiled at runtime)
├── scheduler/
│   └── outputs/             Operator-initiated scheduler output (auto-generated)
├── meta_learning/
│   └── outputs/             Meta-learning worker output (auto-generated)
└── dprime.json              D' safety gate configuration
```

Add `.springdrift/` to your `.gitignore` — it contains runtime state, logs, and
potentially sensitive session data that should not be committed.

## Identity files

The `identity/` directory contains two files that define the agent's persona and
session context:

- **`persona.md`** — fixed first-person character text. Supports `{{agent_name}}`
  substitution from the `[agent]` config section. This text forms the opening of
  the system prompt and rarely changes between sessions.

- **`session_preamble.md`** — dynamic template populated by the Curator each turn.
  Uses `{{slot}}` placeholders (e.g. `{{active_thread_count}}`, `{{today_cycles}}`)
  and `[OMIT IF X]` rules to conditionally hide empty sections. The rendered
  preamble is wrapped in `<memory>` tags and appended after the persona.

- **`character.json`** — character specification for the normative calculus. Defines
  the agent's virtues (named behavioural expressions) and highest endeavour (normative
  propositions). Loaded by default (normative calculus is enabled by default).
  Controls how the output gate reasons about quality decisions using Stoic
  virtue ethics — each gate verdict includes a named axiom trail. The operator
  controls strictness by choosing `required` (categorical) vs `ought` (advisory)
  operators on each proposition.

Identity files are searched in order: `.springdrift/identity/` (local override) then
`~/.config/springdrift/identity/` (user default). If neither exists, the agent falls
back to the configured system prompt.

## Skills and HOW_TO.md

Skills live in `.springdrift/skills/`. Each skill is a directory containing a `SKILL.md`
file with YAML frontmatter (`name:`, `description:`) and Markdown instructions.

`HOW_TO.md` is the operator guide — it contains tool selection heuristics, agent usage
patterns, and degradation paths. It lives in the skills directory and is served via the
`how_to` tool so the LLM can orient itself when unsure which tool to use.

Included skills:
- **`web-research/`** — decision tree for the 10 web tools (Kagi, Brave tiers, Jina, fallbacks)
- **`shell-sandbox/`** — Podman sandbox usage guide (environment, conventions)

## Scheduler configuration

The `[scheduler]` section in `config.toml` controls resource limits for autonomous
scheduler execution:

```toml
[scheduler]
# Max autonomous cycles the scheduler may fire per hour (default: 20, 0 = unlimited)
# max_autonomous_cycles_per_hour = 20

# Max total tokens (input + output) per hour (default: 500000, 0 = unlimited)
# autonomous_token_budget_per_hour = 500000
```

Scheduler reports are delivered to `.springdrift/scheduler/outputs/` by default.
This can be overridden per-job in a profile's schedule configuration.

## Included examples

- **`identity/`** — default persona, session preamble template, and character spec.
- **`skills/`** — HOW_TO.md operator guide + web-research and shell-sandbox skills.
- **`dprime.json`** — D' safety gate configuration (input + tool + output gates,
  per-agent overrides, deterministic rules).
- **`planner_features.json`** — Forecaster feature weights for plan-health scoring.
- **`identity/character.json`** — example character spec with 5 virtues and 4 normative
  commitments for the output gate's normative calculus.

Profiles (advanced agent team configurations) are documented in CLAUDE.md but not
included in the starter template. Create a `profiles/` directory if needed.
