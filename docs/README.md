# Springdrift Documentation

## Background

- [Theoretical references and intellectual lineage](background/references.md) -- all academic papers, prototype history, and design pattern sources with full citations and arXiv links

## Implemented Plans

Architecture and design documents for completed work.

- [Theoretical foundations](implemented-plans/theoretical-foundations.md) -- master mapping of cognitive science, philosophy, and contemporary AI papers to Springdrift components
- [Cognitive loop](implemented-plans/cognitive-loop.md) -- core ReAct loop, message handling, model switching, fallback
- [Specialist agents](implemented-plans/specialist-agents.md) -- planner, researcher, coder, writer, observer agent specs
- [Agent boundary enforcement](implemented-plans/agent-boundary-enforcement.md) -- delegation depth, sub-agent tool restrictions, structured output
- [D' safety overhaul](implemented-plans/dprime-safety-overhaul.md) -- unified gate config, three-layer H-CogAff architecture
- [D' enhancements](implemented-plans/dprime-enhancements.md) -- CCA/SOFAI-LM/Nowaczyk paper integration, confidence decay, provenance, escalation
- [D' canary probes](implemented-plans/dprime-canary-probes.md) -- hijack and leakage detection with fresh tokens
- [Output gate overreach](implemented-plans/output-gate-overreach.md) -- analysis of false positive loop, interactive/autonomous split
- [Prime Narrative memory](implemented-plans/prime-narrative-memory.md) -- narrative entries, threading, Archivist two-phase pipeline
- [CBR retrieval system](implemented-plans/cbr-retrieval-system.md) -- 6-signal weighted fusion, inverted index, embedding integration
- [CBR and metacognition enhancements](implemented-plans/cbr-and-metacognition-enhancements.md) -- Memento/ACE/System M three-paper integration
- [Virtual memory management](implemented-plans/virtual-memory-management.md) -- Letta-style context window, priority slots, budget enforcement
- [DAG introspection](implemented-plans/dag-introspection.md) -- cycle tree, tool call tracking, per-cycle telemetry
- [Observer and sensorium HUD](implemented-plans/observer-sensorium-hud.md) -- ambient perception, meta-states, agent health vitals
- [Tasks, endeavours, and scheduler](implemented-plans/tasks-endeavours-scheduler.md) -- planned work, forecaster, autonomous scheduling
- [XStructor structured output](implemented-plans/xstructor-structured-output.md) -- XML schema validation replacing JSON parsing
- [Local Podman sandbox](implemented-plans/local-podman-sandbox.md) -- container pool, port allocation, workspace isolation
- [Web research tools](implemented-plans/web-research-tools.md) -- DuckDuckGo, Brave, Jina, fetch_url
- [Web GUI enhancements](implemented-plans/web-gui-enhancements.md) -- admin dashboard, D' config panel, scheduler tabs
- [Vertex AI adapter](implemented-plans/vertex-ai-adapter.md) -- Google Cloud rawPredict integration
- [Housekeeper and redaction](implemented-plans/housekeeper-redaction.md) -- CBR dedup, pruning, fact conflict resolution, secret redaction

## Future Plans

Design specs and proposals for planned work.

- [Market analysis](future-plans/market-analysis.md) -- commercial positioning, vertical analysis (legal, insurance), competitive landscape
- [Parallel agents and federation](future-plans/parallel-agents-and-federation.md) -- parallel dispatch, agent teams, distributed Erlang federation
- [Learner ingestion](future-plans/learner-ingestion.md) -- top-down knowledge acquisition from operator-supplied materials
- [Metacognition reporting](future-plans/metacognition-reporting.md) -- drift persistence, gate aggregation, character spec effectiveness
- [Output gate overreach](future-plans/output-gate-overreach.md) -- ongoing analysis of output gate design
- [Multi-tenant](future-plans/multi-tenant.md) -- namespace partitioning, conflict management
- [Knowledge management](future-plans/knowledge-management.md) -- structured knowledge base
- [Empirical evaluation](future-plans/empirical-evaluation.md) -- paper-quality metrics and benchmarks
- [Remembrancer](future-plans/remembrancer.md) -- memory consolidation and sleep-like processing
- [Comms agent](future-plans/comms-agent.md) -- external communication capabilities
- [External agent integration](future-plans/external-agent-integration.md) -- interop with other agent systems
- [Multi-provider failover](future-plans/multi-provider-failover.md) -- automatic LLM provider switching
- [Git backup and restore](future-plans/git-backup-restore.md) -- automated git persistence
- [OAuth authentication](future-plans/oauth-authentication.md) -- web GUI authentication
- [Web GUI v2](future-plans/web-gui-v2.md) -- next-generation web interface
- [Skills management](future-plans/skills-management.md) -- skill discovery, versioning, sharing
- [Provenance-aware output gate](future-plans/provenance-aware-output-gate.md) -- context-sensitive output evaluation
- [Self-diagnostic skill](future-plans/self-diagnostic-skill.md) -- automated health checks
- [Autonomous endeavours](future-plans/autonomous-endeavours.md) -- self-directed long-term goals
- [SD Audit](future-plans/sd-audit.md) -- compliance and audit tooling
- [SD Budget](future-plans/sd-budget.md) -- token and cost management
- [SD Designer](future-plans/sd-designer.md) -- profile and config design tool
- [SD Install](future-plans/sd-install.md) -- installation and deployment tooling
