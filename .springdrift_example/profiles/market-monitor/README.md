# Market Monitor Example

This profile monitors commercial property prices in Dublin and Cork, running daily
and delivering reports to a file and a webhook.

## Setup

1. Copy this directory to your profiles path:
   ```
   cp -r examples/market-monitor ~/.springdrift/profiles/market-monitor
   ```

2. Set your API key:
   ```
   export ANTHROPIC_API_KEY=sk-ant-...
   ```

3. Start Springdrift pointing at your profiles directory:
   ```
   gleam run -- --profiles ~/.springdrift/profiles
   ```

## What it does

- Runs the two research queries every 24 hours
- Assigns each cycle to a conversation thread by domain and location
- Tracks data points (prices, yields) between cycles and notes changes
- Delivers a markdown report to `./reports/dublin/` and posts JSON to your webhook

## Narrative memory

Each run is saved to `prime-narrative/` in JSONL format. The threading system
automatically links related cycles so the agent accumulates context across runs.
You can query past narrative entries directly from the JSONL files or via the
built-in narrative summary API.
