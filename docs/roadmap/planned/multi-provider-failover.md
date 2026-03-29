# Multi-Provider Retry and Failover — Specification

**Status**: Planned
**Date**: 2026-03-26
**Dependencies**: Vertex AI adapter (implemented), Per-provider config (implemented)

---

## Table of Contents

- [Overview](#overview)
- [Current State](#current-state)
- [Proposed Architecture](#proposed-architecture)
- [Provider Chain](#provider-chain)
- [Failover Decision Logic](#failover-decision-logic)
- [Model Remapping](#model-remapping)
- [Health Tracking](#health-tracking)
  - [Circuit Breaker](#circuit-breaker)
- [Provider Selection Strategy](#provider-selection-strategy)
- [Latency-Aware Routing](#latency-aware-routing)
- [Cost-Aware Routing](#cost-aware-routing)
- [Sensorium Integration](#sensorium-integration)
- [Configuration](#configuration)
- [Implementation Order](#implementation-order)
- [What This Enables](#what-this-enables)

---

## Overview

A single LLM provider is a single point of failure. Provider outages, rate limiting, quota exhaustion, and regional capacity constraints all cause downtime for the agent. Multi-provider failover gives the agent resilience by transparently routing requests across a chain of providers with health tracking, circuit breaking, and automatic model remapping.

## Current State

Springdrift has adapters for Anthropic, Vertex AI, OpenAI, Mistral, and local models. Only ONE provider is active at a time. The retry logic (`llm/retry.gleam`) retries the same provider with exponential backoff:

```
Attempt 1 → Provider → error → wait 500ms
Attempt 2 → Provider → error → wait 1000ms
Attempt 3 → Provider → error → wait 2000ms
→ ThinkError: exhausted retries
```

Model fallback exists (reasoning_model → task_model) but is same-provider. When the provider itself is down, the agent is down.

## Proposed Architecture

```
llm/router.gleam          — Provider chain, health tracking, failover logic
llm/health.gleam           — Per-provider health state, circuit breaker
llm/cost.gleam             — Per-provider cost tracking
```

The router wraps multiple providers and presents a single `Provider` interface to the cognitive loop. The cognitive loop doesn't know or care about failover.

```gleam
pub type ProviderRouter {
  ProviderRouter(
    chain: List(ProviderSlot),
    strategy: RoutingStrategy,
    health: Dict(String, ProviderHealth),
  )
}

pub type ProviderSlot {
  ProviderSlot(
    provider: Provider,
    priority: Int,
    models: ProviderModels,
    cost_per_input_token: Float,
    cost_per_output_token: Float,
    max_retries: Int,
    circuit_breaker: CircuitBreaker,
  )
}

pub type ProviderModels {
  ProviderModels(
    task_model: String,
    reasoning_model: String,
  )
}
```

## Provider Chain

Failover order defined in config. Example:

```toml
[[providers]]
name = "vertex"
priority = 1
task_model = "claude-haiku-4-5"
reasoning_model = "claude-opus-4-6"
cost_input = 0.25
cost_output = 1.25
max_retries = 2

[[providers]]
name = "anthropic"
priority = 2
task_model = "claude-haiku-4-5-20251001"
reasoning_model = "claude-opus-4-6"
cost_input = 0.25
cost_output = 1.25
max_retries = 3

[[providers]]
name = "mistral"
priority = 3
task_model = "mistral-small-latest"
reasoning_model = "mistral-large-latest"
cost_input = 0.10
cost_output = 0.30
max_retries = 2
```

## Failover Decision Logic

```
Request arrives at router
  → Select provider by strategy (priority, health, cost, latency)
  → Attempt call with per-provider retry + backoff
  → If all retries exhausted:
    → Record failure, check circuit breaker
    → If tripped: mark provider DEGRADED
    → Move to next provider in chain
    → Remap model names for the new provider
    → Retry
  → If all providers exhausted: return error
  → On success: record success, tag response with provider name
```

## Model Remapping

Different providers use different model names for equivalent capabilities. The router maps transparently:

```gleam
fn remap_model(
  request: LlmRequest,
  from: ProviderSlot,
  to: ProviderSlot,
) -> LlmRequest
```

The response is tagged: `[vertex unavailable, used anthropic:claude-haiku-4-5-20251001]`

When failing over to a provider with different capabilities entirely (e.g. Claude → Mistral), the response tag makes this visible. The `allow_cross_capability_failover` config controls whether this is permitted.

## Health Tracking

```gleam
pub type ProviderHealth {
  ProviderHealth(
    status: HealthStatus,
    consecutive_failures: Int,
    total_calls: Int,
    total_failures: Int,
    avg_latency_ms: Float,
    last_success: Option(String),
    last_failure: Option(String),
    last_error: Option(String),
  )
}

pub type HealthStatus {
  Healthy
  Degraded          // Circuit breaker tripped — skipped in normal routing
  Recovering        // After cooldown — testing with single request
  Unavailable       // Manually disabled or config error
}
```

### Circuit Breaker

```
Healthy → (consecutive_failures >= threshold) → Degraded
Degraded → (cooldown elapsed) → Recovering
Recovering → (test request succeeds) → Healthy
Recovering → (test request fails) → Degraded (reset cooldown)
```

```gleam
pub type CircuitBreaker {
  CircuitBreaker(
    failure_threshold: Int,        // Default: 5
    cooldown_ms: Int,              // Default: 60000
    half_open_max: Int,            // Default: 1
  )
}
```

## Provider Selection Strategy

```gleam
pub type RoutingStrategy {
  PriorityFailover        // Always use highest-priority healthy provider
  CostOptimised           // Use cheapest healthy provider
  LatencyOptimised        // Use lowest-latency healthy provider
  RoundRobin              // Distribute across healthy providers
  HybridCostPriority      // Cheapest for task_model, priority for reasoning_model
}
```

**PriorityFailover** (default): predictable, easy to reason about. Failover only on failure.

**HybridCostPriority**: saves money on high-volume cheap calls (D' scoring, classification) while using the preferred provider for complex reasoning.

## Latency-Aware Routing

Rolling average latency per provider per model. When P95 exceeds a threshold, proactively route to a faster provider before the request fails:

```toml
[providers.routing]
latency_threshold_ms = 30000
```

This handles the scenario where a provider isn't returning errors — it's just slow.

## Cost-Aware Routing

The router tracks per-provider token consumption and cost. This data feeds into SD Budget for analysis.

## Sensorium Integration

```xml
<providers active="vertex" healthy="2/3" strategy="priority_failover">
  <provider name="vertex" status="healthy" latency="230ms"
            cost_today="$1.24" calls="47"/>
  <provider name="anthropic" status="degraded" since="14:30"
            error="rate limited" next_test="2m"/>
  <provider name="mistral" status="healthy" latency="180ms"
            cost_today="$0.00" calls="0"/>
</providers>
```

## Configuration

```toml
[routing]
strategy = "priority_failover"
allow_cross_capability_failover = true
tag_responses = true
latency_threshold_ms = 30000

[routing.circuit_breaker]
failure_threshold = 5
cooldown_ms = 60000
```

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | Provider router with priority failover | Medium |
| 2 | Health tracking + circuit breaker | Medium |
| 3 | Model remapping across providers | Small |
| 4 | Latency tracking + proactive routing | Medium |
| 5 | Cost tracking per provider | Small |
| 6 | Config: provider chain in TOML | Medium |
| 7 | Sensorium: provider status | Small |
| 8 | Alternative routing strategies | Medium |

## What This Enables

The agent stays up when a provider goes down. Failover is transparent to the cognitive loop and invisible to the operator unless they check the sensorium. For enterprise deployment, multi-provider resilience is a hard requirement — a single-provider agent is not production-grade.
