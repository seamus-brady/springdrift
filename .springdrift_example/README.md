# .springdrift directory

Copy this directory to `.springdrift/` in your project root to get started:

```bash
cp -r .springdrift_example .springdrift
```

Then edit `.springdrift/config.toml` with your provider and API key.

## Directory layout

```
.springdrift/
├── config.toml          Project-level config (overrides ~/.config/springdrift/config.toml)
├── identity/            Agent identity files (persona + session preamble template)
│   ├── persona.md       First-person character text (supports {{agent_name}} slot)
│   └── session_preamble.md  Dynamic session context with {{slot}} and [OMIT IF] rules
├── identity.json        Stable agent UUID (auto-generated on first run)
├── session.json         Session persistence (auto-generated)
├── logs/                System logs (date-rotated JSON-L, auto-generated)
├── memory/
│   ├── cycle-log/       Per-cycle request/response logs (auto-generated)
│   ├── narrative/       Prime Narrative memory (auto-generated)
│   ├── cbr/             Case-Based Reasoning cases (auto-generated)
│   └── facts/           Key-value fact store (auto-generated)
├── skills/              Local SKILL.md definitions
└── profiles/            Agent profile directories
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

Identity files are searched in order: `.springdrift/identity/` (local override) then
`~/.config/springdrift/identity/` (user default). If neither exists, the agent falls
back to the configured system prompt.

## Included examples

- **`identity/`** — default persona and session preamble template.
- **`profiles/market-monitor/`** — example profile that tracks commercial property
  prices in Dublin and Cork with daily scheduled jobs and report delivery.
- **`dprime.example.json`** — example D' safety gate configuration with seven
  features and tuned thresholds.
