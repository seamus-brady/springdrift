# Hot Reload Config — Reload Configuration Without Restart

**Status**: Planned
**Priority**: Medium — quality-of-life for long-running sessions
**Effort**: Medium (~200-300 lines)

## Problem

Changing any configuration value requires restarting the agent, which drops
the current session, resets all ETS indexes (requiring Librarian replay),
and interrupts any in-progress work. For a system designed to run
continuously, this is a significant operational gap.

Common cases where restart-free config changes matter:

- Adjusting D' thresholds after observing false positive patterns
- Switching models mid-session (already possible via `SetModel`, but not
  for agent-specific models)
- Changing scheduler rate limits during heavy autonomous work
- Tuning CBR retrieval weights after noticing poor case matches
- Enabling/disabling verbose logging for debugging

## Proposed Solution

### 1. Config Reload Message

Add a `ReloadConfig` variant to `CognitiveMessage`. On receipt:

1. Re-read and parse `config.toml` (reuse existing `parse_config_toml`)
2. Merge with CLI flags (CLI flags still take priority)
3. Diff against current `CognitiveState` config values
4. Apply safe changes immediately (thresholds, limits, weights, timeouts)
5. Log what changed via `slog`
6. Emit a sensory event summarising the changes

### 2. Safe vs Unsafe Fields

Not all config fields can be changed at runtime. Classify each field:

**Safe to reload** (no structural impact):
- D' thresholds, feature weights, gate configs
- Max tokens, max turns, agent turn limits
- Scheduler rate limits, token budgets
- CBR retrieval weights, min score
- Preamble budget, housekeeping thresholds
- Verbose logging, archivist model

**Unsafe (require restart):**
- Provider (different adapter, different connection)
- GUI mode (TUI vs web — different event loop)
- Sandbox config (container pool already running)
- Comms config (inbox poller already running)
- Profile (structural agent roster change)

Log a warning for unsafe fields that changed but weren't applied.

### 3. Trigger Mechanisms

- `reload_config` tool available to the cognitive loop
- Web GUI button on the admin panel
- TUI keybinding

## Open Questions

- Should the Curator re-render the system prompt immediately on reload,
  or wait for the next cycle?
- Should D' state (meta observer history, threshold tightening) reset on
  config reload, or preserve continuity?
