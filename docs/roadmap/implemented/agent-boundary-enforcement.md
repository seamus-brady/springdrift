# Agent Boundary Enforcement — Implementation Record

**Status**: Implemented
**Date**: 2026-03-22

---

## Table of Contents

- [Overview](#overview)
- [Changes](#changes)
  - [request_human_input Restricted to Cognitive Loop](#requesthumaninput-restricted-to-cognitive-loop)
  - [Delegation Management](#delegation-management)
  - [Agent Tool Names in Registry](#agent-tool-names-in-registry)
  - [Persona Guidance](#persona-guidance)


## Overview

Enforced boundaries between sub-agents and the cognitive loop. Prevented sub-agents from hijacking the user interaction channel or escalating beyond their delegation scope.

## Changes

### request_human_input Restricted to Cognitive Loop
- Removed `request_human_input` from all sub-agent tool sets
- Added `builtin.agent_tools()` that excludes `request_human_input`
- Sub-agents (planner, researcher, coder, writer, observer) report only through their return value
- The cognitive loop is the single point of user interaction

### Delegation Management
- `DelegationInfo` tracks: agent name, instruction, turn, max_turns, tokens, last tool, started_at, depth, violation_count
- `AgentProgress` messages after each react-loop turn
- `<delegations>` section in sensorium XML showing live agent state
- `cancel_agent` tool to stop misbehaving agents
- Depth capped by `max_delegation_depth` config (default: 3)

### Agent Tool Names in Registry
- `RegistryEntry` includes `tool_names: List(String)`
- `AgentStarted`/`AgentRestarted` lifecycle events carry tool lists
- `introspect` tool shows each agent's available tools

### Persona Guidance
- Persona updated: "I am the single point of control for all delegations"
- Agent reviews sub-agent results before passing to user
- Delegation management behaviour driven by persona, not a separate appraisal agent
