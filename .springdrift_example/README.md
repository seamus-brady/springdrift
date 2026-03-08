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
├── session.json          Session persistence (auto-generated)
├── logs/                 System logs (date-rotated JSON-L, auto-generated)
├── memory/
│   ├── cycle-log/        Per-cycle request/response logs (auto-generated)
│   └── narrative/        Prime Narrative memory (auto-generated when enabled)
├── skills/               Local SKILL.md definitions
└── profiles/             Agent profile directories
```

Add `.springdrift/` to your `.gitignore` — it contains runtime state, logs, and
potentially sensitive session data that should not be committed.
