# Configuration Architecture

Springdrift uses a three-layer configuration system with TOML files and CLI flags.
All fields are optional with sensible defaults applied at startup.

---

## 1. Priority Layers

Configuration is resolved highest-to-lowest:

| Priority | Source | Purpose |
|---|---|---|
| 1 (highest) | CLI flags | Per-invocation overrides |
| 2 | Local config | `.springdrift/config.toml` in working directory |
| 3 (lowest) | User config | `~/.config/springdrift/config.toml` |

CLI flags always win. Local config overrides user config. Unset fields fall back
to built-in defaults applied in `springdrift.gleam` at startup.

## 2. AppConfig Record

`src/config.gleam` defines `AppConfig` with all fields as `Option(T)`:

```gleam
pub type AppConfig {
  AppConfig(
    provider: Option(String),
    task_model: Option(String),
    reasoning_model: Option(String),
    max_tokens: Option(Int),
    thinking_budget_tokens: Option(Int),
    max_turns: Option(Int),
    // ... 80+ fields
  )
}
```

Defaults are applied at usage sites via `option.unwrap(cfg.field, default_value)`,
not in the config record itself. This preserves the distinction between "not set"
and "set to default".

## 3. TOML Structure

The config file is organised into sections:

| Section | Purpose |
|---|---|
| *(top-level)* | Provider, models, loop control, logging, D', GUI |
| `[agent]` | Agent name and version |
| `[narrative]` | Narrative and archival settings |
| `[timeouts]` | All timeout values (ms) |
| `[retry]` | LLM retry: max retries, backoff delays |
| `[limits]` | Size limits: artifacts, fetch, TUI, WebSocket, query results |
| `[scoring.threading]` | Thread assignment overlap weights and threshold |
| `[cbr]` | CBR retrieval: signal weights, min score, embedding config |
| `[housekeeping]` | Dedup similarity, pruning confidence, fact threshold |
| `[scheduler]` | Autonomous cycle and token budgets |
| `[xstructor]` | XStructor XML validation settings |
| `[forecaster]` | Plan-health Forecaster: enabled, tick, threshold |
| `[agents.planner]` | Planner agent: max_tokens, max_turns, max_errors |
| `[agents.researcher]` | Researcher agent settings |
| `[agents.coder]` | Coder agent settings |
| `[agents.writer]` | Writer agent settings |
| `[agents.project_manager]` | Project Manager agent settings |
| `[web]` | Web GUI port |
| `[services]` | External API base URLs |
| `[sandbox]` | Podman sandbox settings |
| `[delegation]` | Agent delegation depth limits |
| `[comms]` | Communications agent settings |
| `[vertex]` | Google Vertex AI provider settings |
| `[appraisal]` | Appraiser pre/post-mortem settings |
| `[teams.*]` | Team template definitions |

## 4. Loading Pipeline

```
CLI flags (parse_args)
      │
      ▼
merge(cli_config, load_toml(".springdrift/config.toml"))
      │
      ▼
merge(result, load_toml("~/.config/springdrift/config.toml"))
      │
      ▼
merge(result, load_toml(config_path))  ← optional --config flag
      │
      ▼
Final AppConfig (all Option(T), defaults applied at usage sites)
```

### merge

`merge(a, b)` takes two `AppConfig` records and produces one, preferring `a`'s
values when both are `Some`. List fields (`skills_dirs`) are concatenated rather
than replaced.

### parse_config_toml

`parse_config_toml(content)` parses TOML content using the `tom` library and
maps keys to `AppConfig` fields:

- **Unknown keys** are logged as warnings via `slog`
- **Numeric values** are range-checked (must be positive)
- **Provider** is validated against known options (anthropic, openrouter, openai,
  mistral, vertex, local, mock)
- **GUI mode** is validated (tui, web)
- **Parse failures** are logged instead of crashing

### known_keys

A static list of all valid TOML keys, used for unknown-key detection. When adding
a new config field, it must be added to `known_keys`.

## 5. Validation Rules

| Rule | Enforcement |
|---|---|
| Positive integers | Range check on parse |
| Valid provider names | Checked against enum |
| Valid GUI mode | Checked against enum |
| Unknown keys | Warning logged |
| Missing required for provider | Runtime error (e.g. no API key) |

## 6. Skills Directory Accumulation

`--skills-dir` is repeatable and appends to the list:

```sh
gleam run -- --skills-dir ./custom-skills --skills-dir ~/shared-skills
```

Default skills directories are always included:
1. `~/.config/springdrift/skills`
2. `.springdrift/skills`

Additional directories from CLI and config are appended.

## 7. Team Templates

Team configurations can be defined in TOML under `[teams.*]` sections:

```toml
[teams.research_review]
description = "Research team with peer review"
members = [
  ["researcher", "Lead Researcher", "Find and verify information"],
  ["observer", "Reviewer", "Check methodology and sources"],
]
strategy = "debate_and_consensus"
# synthesis_model = "claude-sonnet-4-6"  # Optional, defaults to task_model
```

Parsed into `TeamTemplateConfig` records and converted to `TeamSpec` at startup.

## 8. Example Configs

Two reference configs are maintained:

| File | Purpose |
|---|---|
| `.springdrift/config.toml` | Live configuration (may be modified) |
| `.springdrift_example/config.toml` | Template with all sections documented |

Both must be kept in sync for structural changes (sections, key names). The example
config includes comments explaining each field and its default value.

## 9. Adding a New Config Field

Checklist:

1. Add the field to `AppConfig` in `src/config.gleam` (as `Option(T)`)
2. Add it to `default()` (return `None`)
3. Add it to `merge()` (prefer `a` over `b`)
4. Add it to `toml_to_config()` (parse from TOML)
5. Add the key to `known_keys`
6. Add a commented entry in both config.toml files with the default value
7. Apply the default at the usage site: `option.unwrap(cfg.field, default_value)`
8. Update CLAUDE.md Config fields table

## 10. Key Source Files

| File | Purpose |
|---|---|
| `config.gleam` | `AppConfig`, TOML parsing, merge, validation |
| `springdrift.gleam` | Default application at startup |
| `.springdrift/config.toml` | Live configuration |
| `.springdrift_example/config.toml` | Reference template |
