# Springdrift Documentation

## Background

- [Theoretical references and intellectual lineage](background/references.md) -- all academic papers, prototype history, and design pattern sources with full citations and arXiv links

## Implemented Plans

Architecture and design documents for completed work.

- [Theoretical foundations](roadmap/implemented/theoretical-foundations.md) -- master mapping of cognitive science, philosophy, and contemporary AI papers to Springdrift components
- [Cognitive loop](roadmap/implemented/cognitive-loop.md) -- core ReAct loop, message handling, model switching, fallback
- [Specialist agents](roadmap/implemented/specialist-agents.md) -- planner, researcher, coder, writer, observer agent specs
- [Agent boundary enforcement](roadmap/implemented/agent-boundary-enforcement.md) -- delegation depth, sub-agent tool restrictions, structured output
- [D' safety overhaul](roadmap/implemented/dprime-safety-overhaul.md) -- unified gate config, three-layer H-CogAff architecture
- [D' enhancements](roadmap/implemented/dprime-enhancements.md) -- CCA/SOFAI-LM/Nowaczyk paper integration, confidence decay, provenance, escalation
- [D' canary probes](roadmap/implemented/dprime-canary-probes.md) -- hijack and leakage detection with fresh tokens
- [Output gate overreach](roadmap/implemented/output-gate-overreach.md) -- analysis of false positive loop, interactive/autonomous split
- [Prime Narrative memory](roadmap/implemented/prime-narrative-memory.md) -- narrative entries, threading, Archivist two-phase pipeline
- [CBR retrieval system](roadmap/implemented/cbr-retrieval-system.md) -- 6-signal weighted fusion, inverted index, embedding integration
- [CBR and metacognition enhancements](roadmap/implemented/cbr-and-metacognition-enhancements.md) -- Memento/ACE/System M three-paper integration
- [Virtual memory management](roadmap/implemented/virtual-memory-management.md) -- Letta-style context window, priority slots, budget enforcement
- [DAG introspection](roadmap/implemented/dag-introspection.md) -- cycle tree, tool call tracking, per-cycle telemetry
- [Observer and sensorium HUD](roadmap/implemented/observer-sensorium-hud.md) -- ambient perception, meta-states, agent health vitals
- [Tasks, endeavours, and scheduler](roadmap/implemented/tasks-endeavours-scheduler.md) -- planned work, forecaster, autonomous scheduling
- [XStructor structured output](roadmap/implemented/xstructor-structured-output.md) -- XML schema validation replacing JSON parsing
- [Local Podman sandbox](roadmap/implemented/local-podman-sandbox.md) -- container pool, port allocation, workspace isolation
- [Web research tools](roadmap/implemented/web-research-tools.md) -- DuckDuckGo, Brave, Jina, fetch_url
- [Web GUI enhancements](roadmap/implemented/web-gui-enhancements.md) -- admin dashboard, D' config panel, scheduler tabs
- [Vertex AI adapter](roadmap/implemented/vertex-ai-adapter.md) -- Google Cloud rawPredict integration
- [Housekeeper and redaction](roadmap/implemented/housekeeper-redaction.md) -- CBR dedup, pruning, fact conflict resolution, secret redaction
- [Git backup and restore](roadmap/implemented/git-backup-restore.md) -- automated git backup, periodic commits, remote push
- [Self-diagnostic skill](roadmap/implemented/self-diagnostic-skill.md) -- seven-step health check using existing introspection tools

## Future Plans

Design specs and proposals for planned work.

- [Market analysis](roadmap/market-analysis.md) -- commercial positioning, vertical analysis (legal, insurance), competitive landscape
- [Parallel agents and federation](roadmap/parallel-agents-and-federation.md) -- parallel dispatch, agent teams, distributed Erlang federation
- [Learner ingestion](roadmap/learner-ingestion.md) -- top-down knowledge acquisition from operator-supplied materials
- [Metacognition reporting](roadmap/metacognition-reporting.md) -- drift persistence, gate aggregation, character spec effectiveness
- [Output gate overreach](roadmap/output-gate-overreach.md) -- ongoing analysis of output gate design
- [Multi-tenant](roadmap/multi-tenant.md) -- namespace partitioning, conflict management
- [Knowledge management](roadmap/knowledge-management.md) -- structured knowledge base
- [Empirical evaluation](roadmap/empirical-evaluation.md) -- paper-quality metrics and benchmarks
- [Remembrancer](roadmap/remembrancer.md) -- memory consolidation and sleep-like processing
- [Comms agent](roadmap/comms-agent.md) -- external communication capabilities
- [External agent integration](roadmap/external-agent-integration.md) -- interop with other agent systems
- [Multi-provider failover](roadmap/multi-provider-failover.md) -- automatic LLM provider switching
- [OAuth authentication](roadmap/oauth-authentication.md) -- web GUI authentication
- [Web GUI v2](roadmap/web-gui-v2.md) -- next-generation web interface
- [Skills management](roadmap/skills-management.md) -- skill discovery, versioning, sharing
- [Provenance-aware output gate](roadmap/provenance-aware-output-gate.md) -- context-sensitive output evaluation
- [Autonomous endeavours](roadmap/autonomous-endeavours.md) -- self-directed long-term goals
- [SD Audit](roadmap/sd-audit.md) -- compliance and audit tooling
- [SD Budget](roadmap/sd-budget.md) -- token and cost management
- [SD Designer](roadmap/sd-designer.md) -- profile and config design tool
- [SD Install](roadmap/sd-install.md) -- installation and deployment tooling
- [Librarian ETS reconciliation](roadmap/librarian-ets-reconciliation.md) -- periodic cache-vs-disk sync for missed notifications
- [Commitment tracker](roadmap/commitment-tracker.md) -- detect promises and reminders in output, create scheduled follow-ups
- [Cross-cycle pattern detection](roadmap/cross-cycle-pattern-detection.md) -- review_recent tool, detect_patterns tool, sensorium performance summary
