# Level 3: Federated Instances

**Status**: Planned (deferred)
**Date**: 2026-03-26
**Dependencies**: Parallel dispatch (implemented), Agent teams (implemented)
**Effort**: Large (~800-1000 lines)
**Note**: Useful when multiple specialised instances exist. Single-operator setups benefit more from Levels 1-2 and autonomous endeavours first.

---

## Concept

Multiple Springdrift instances running as independent nodes in a distributed Erlang cluster. Each instance has its own:
- Cognitive loop and agent roster
- Memory (narrative, CBR, facts)
- Identity and persona
- D' safety configuration

Instances communicate via a typed federation protocol. Each instance treats incoming messages from other instances as untrusted — they pass through the D' input gate.

No multi-tenant dependency. Each node is one agent with one operator.

## Why Distributed Erlang

The BEAM provides:
- **Location transparency**: `process.send(subject, message)` works identically whether the subject is local or on a remote node
- **Node discovery**: `net_kernel:connect_node/1` establishes connections
- **Process monitoring**: `process.monitor` works across nodes — crash detection is automatic
- **No serialisation overhead for Erlang terms**: messages between nodes use the Erlang external term format natively

Two Springdrift instances on different machines communicate using the exact same `Subject(CognitiveMessage)` mechanism used internally. No HTTP APIs, no message queues, no serialisation layers.

## Federation Protocol

```gleam
pub type FederatedMessage {
  /// Request: ask another instance for information
  FederatedQuery(
    from_instance: InstanceId,
    query: String,
    context: String,
    reply_to: Subject(FederatedReply),
  )
  /// Response: answer from another instance
  FederatedReply(
    from_instance: InstanceId,
    response: String,
    confidence: Float,
    sources: List(String),
  )
  /// Broadcast: share a finding with all federated instances
  FederatedBroadcast(
    from_instance: InstanceId,
    finding: String,
    domain: String,
    relevance: Float,
  )
  /// Handshake: establish trust between instances
  FederatedHandshake(
    instance_id: InstanceId,
    instance_name: String,
    capabilities: List(String),   // ["legal", "insurance", "research"]
    dprime_config_hash: String,   // Prove safety configuration is adequate
  )
}

pub type InstanceId {
  InstanceId(
    node: String,                 // Erlang node name
    agent_uuid: String,
  )
}
```

## Trust Model

Federated instances don't blindly trust each other:

1. **Handshake**: Instances exchange capabilities and D' config hashes. An instance can refuse federation with another whose safety config doesn't meet minimum standards.
2. **Input gate on all received messages**: Every `FederatedQuery` and `FederatedBroadcast` passes through the receiving instance's D' input gate. Injection attempts from a compromised instance are caught.
3. **Provenance tracking**: Facts derived from federated queries are tagged with `derivation: FederatedQuery` and `source_agent: "instance:{name}"`. The receiving instance knows which facts came from which source.
4. **Confidence discounting**: Federated information carries a confidence discount (configurable, default 0.8x). The receiving instance's facts from its own experience are weighted higher than second-hand information.

## Example: Legal + Insurance Collaboration

```
Node 1: Legal Springdrift (persona: "Atlas", domain: legal)
  - Case law CBR, regulatory compliance memory
  - D' configured for legal sensitivity (client confidentiality)

Node 2: Insurance Springdrift (persona: "Beacon", domain: insurance)
  - Underwriting CBR, claims outcome memory
  - D' configured for actuarial accuracy

Scenario: Coverage dispute involving both contract law and insurance policy interpretation

Atlas queries Beacon:
  "What is the typical claims outcome for professional indemnity policies
   where the insured's contract included a limitation of liability clause?"

Beacon's D' input gate evaluates → ACCEPT (legitimate insurance query)
Beacon searches its CBR → finds relevant cases
Beacon's D' output gate evaluates the response → ACCEPT
Response sent back to Atlas with confidence 0.75 and source cases

Atlas integrates Beacon's response, applies 0.8x confidence discount (effective 0.60),
tags the derived fact with provenance: FederatedQuery from Beacon
```

## Federation Manager (`src/federation/manager.gleam`)

OTP actor managing federated connections:

```gleam
pub type FederationMessage {
  Connect(node: String, reply_to: Subject(Result(InstanceId, String)))
  Disconnect(instance_id: InstanceId)
  Query(to: InstanceId, query: String, context: String, reply_to: Subject(FederatedReply))
  Broadcast(finding: String, domain: String)
  ListPeers(reply_to: Subject(List(PeerInfo)))
  HandleIncoming(msg: FederatedMessage)
}

pub type PeerInfo {
  PeerInfo(
    instance_id: InstanceId,
    name: String,
    capabilities: List(String),
    connected_since: String,
    messages_exchanged: Int,
    trust_score: Float,           // Computed from successful exchanges
  )
}
```

## Sensorium Integration

```xml
<federation peers="2">
  <peer name="Beacon" domain="insurance" trust="0.85" last_exchange="2m ago"/>
  <peer name="Sentinel" domain="compliance" trust="0.92" last_exchange="15m ago"/>
</federation>
```

## Web GUI: Federation Tab

Admin tab showing:
- Connected peers with trust scores
- Message exchange history
- Per-peer query/response latency
- Trust score evolution over time

## BEAM Capabilities Exploited

| BEAM Feature | How It's Used |
|---|---|
| Lightweight processes | Each federated connection is its own process |
| Process isolation | Compromised peer can't crash local instance |
| Location transparency | Federation uses the same Subject channels as local dispatch |
| Node monitoring | Peer disconnection detected automatically |
| Mailbox backpressure | Per-peer rate limiting prevents flooding |
| Selective receive | Federation manager waits for specific peer responses |

## Security Considerations

- Inter-instance messages pass through D' input gate
- Handshake requires D' config validation — inadequate safety config refused
- Confidence discounting on federated information
- Provenance tracking on all federated facts
- Per-peer message rate caps prevent flooding
- Deterministic pre-filter on inter-instance content blocks credential leakage

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | Federation protocol types, handshake, trust model | Medium (~200 lines) |
| 2 | Federation manager OTP actor | Medium (~250 lines) |
| 3 | D' for federation — input gate on inter-instance messages | Small (~50 lines) |
| 4 | Distributed Erlang wiring — node connection, process monitoring | Medium (~150 lines) |
| 5 | Sensorium + web GUI | Medium (~200 lines) |
