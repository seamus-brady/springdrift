# Springdrift Documentation

## Background

- [Theoretical references and intellectual lineage](background/references.md) -- all academic papers, prototype history, and design pattern sources with full citations and arXiv links

## Implemented

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
- [Communications agent](roadmap/implemented/comms-agent.md) -- email via AgentMail, inbox poller, web admin tab, three-layer D' safety
- [Cross-cycle pattern detection](roadmap/implemented/cross-cycle-pattern-detection.md) -- review_recent, detect_patterns, sensorium performance summary
- [Autonomous endeavours](roadmap/implemented/autonomous-endeavours.md) -- self-directed long-horizon work management with phases, blockers, approval gates
- [Parallel agent dispatch](roadmap/implemented/parallel-agent-dispatch.md) -- simultaneous agent execution, result collection
- [Agent teams](roadmap/implemented/agent-teams.md) -- coordinated multi-agent groups with four strategies (ParallelMerge, Pipeline, Debate, LeadWithSpecialists)
- [Librarian ETS reconciliation](roadmap/implemented/librarian-ets-reconciliation.md) -- periodic cache-vs-disk sync
- [Bug fixes (March 2026)](roadmap/implemented/Bug%20fixes%2027-03-26.md) -- D' false positives, DAG finalisation, archivist wiring, comms fixes

## Roadmap

Design specs and proposals for planned work.

- [Federated instances](roadmap/planned/federated-instances.md) -- distributed Erlang, cross-instance communication
- [Learner ingestion](roadmap/planned/learner-ingestion.md) -- top-down knowledge acquisition from operator-supplied materials
- [Metacognition reporting](roadmap/planned/metacognition-reporting.md) -- drift persistence, gate aggregation (partially addressed)
- [Multi-tenant](roadmap/planned/multi-tenant.md) -- namespace partitioning, conflict management
- [Knowledge management](roadmap/planned/knowledge-management.md) -- structured knowledge base
- [Empirical evaluation](roadmap/planned/empirical-evaluation.md) -- paper-quality metrics and benchmarks
- [Remembrancer](roadmap/planned/remembrancer.md) -- memory consolidation and sleep-like processing
- [External agent integration](roadmap/planned/external-agent-integration.md) -- A2A protocol, MCP interop
- [Multi-provider failover](roadmap/planned/multi-provider-failover.md) -- automatic LLM provider switching
- [OAuth authentication](roadmap/planned/oauth-authentication.md) -- web GUI authentication
- [Web GUI v2](roadmap/planned/web-gui-v2.md) -- next-generation web interface
- [Skills management](roadmap/planned/skills-management.md) -- skill discovery, versioning, sharing
- [Provenance-aware output gate](roadmap/planned/provenance-aware-output-gate.md) -- context-sensitive output evaluation
- [Commitment tracker](roadmap/planned/commitment-tracker.md) -- detect promises in output, create follow-ups
- [Hot reload config](roadmap/planned/hot-reload-config.md) -- reload configuration without restart
- [Document library](roadmap/planned/document-library.md) -- notes, journals, project updates, agent-managed documents
- [Mail attachments](roadmap/planned/mail-attachments.md) -- send and receive email attachments
- [File uploads](roadmap/planned/file-uploads.md) -- operator file upload via web GUI
- [Extended housekeeper window](roadmap/planned/housekeeper-extended-window.md) -- housekeeping beyond 30-day replay window
- [Multi-language sandbox](roadmap/planned/sandbox-multi-language.md) -- JavaScript/Node.js and Gleam container images
- [Git tools and skills](roadmap/planned/git-tools-and-skills.md) -- version control integration for coder agent
- [SD Audit](roadmap/planned/sd-audit.md) -- JSONL log analysis toolkit
- [SD Budget](roadmap/planned/sd-budget.md) -- token and cost management
- [SD Designer](roadmap/planned/sd-designer.md) -- configuration wizard
- [SD Install](roadmap/planned/sd-install.md) -- deployment automation (partially implemented: setup scripts)
