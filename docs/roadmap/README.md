# Springdrift Roadmap

Design specs and implementation records for Springdrift development.

Each document captures the motivation, design decisions, and implementation
details for a feature or subsystem. Implemented features include the final
architecture; planned features include the design proposal and open questions.

## Implemented (37)

| Feature | Category |
|---|---|
| [Theoretical foundations](implemented/theoretical-foundations.md) | Foundations |
| [Cognitive loop](implemented/cognitive-loop.md) | Core |
| [Specialist agents](implemented/specialist-agents.md) | Core |
| [Agent boundary enforcement](implemented/agent-boundary-enforcement.md) | Core |
| [Parallel agent dispatch](implemented/parallel-agent-dispatch.md) | Core |
| [Agent teams](implemented/agent-teams.md) | Core |
| [Deputy agents](implemented/deputy-agents.md) | Core |
| [Frontdoor architecture](implemented/frontdoor-architecture.md) | Core |
| [D' safety overhaul](implemented/dprime-safety-overhaul.md) | Safety |
| [D' enhancements](implemented/dprime-enhancements.md) | Safety |
| [D' canary probes](implemented/dprime-canary-probes.md) | Safety |
| [Output gate overreach](implemented/output-gate-overreach.md) | Safety |
| [Prime Narrative memory](implemented/prime-narrative-memory.md) | Memory |
| [CBR retrieval system](implemented/cbr-retrieval-system.md) | Memory |
| [CBR and metacognition enhancements](implemented/cbr-and-metacognition-enhancements.md) | Memory |
| [Virtual memory management](implemented/virtual-memory-management.md) | Memory |
| [Housekeeper and redaction](implemented/housekeeper-redaction.md) | Memory |
| [Librarian ETS reconciliation](implemented/librarian-ets-reconciliation.md) | Memory |
| [Remembrancer](implemented/remembrancer.md) | Memory |
| [Remembrancer follow-ups](implemented/remembrancer-followups.md) | Memory |
| [Commitment tracker (captures)](implemented/commitment-tracker.md) | Work management |
| [Tasks, endeavours, and scheduler](implemented/tasks-endeavours-scheduler.md) | Work management |
| [Autonomous endeavours](implemented/autonomous-endeavours.md) | Work management |
| [DAG introspection](implemented/dag-introspection.md) | Observability |
| [Observer and sensorium HUD](implemented/observer-sensorium-hud.md) | Observability |
| [Cross-cycle pattern detection](implemented/cross-cycle-pattern-detection.md) | Observability |
| [Meta-learning](implemented/meta-learning.md) | Meta-learning |
| [XStructor structured output](implemented/xstructor-structured-output.md) | Infrastructure |
| [Local Podman sandbox](implemented/local-podman-sandbox.md) | Infrastructure |
| [Web research tools](implemented/web-research-tools.md) | Infrastructure |
| [Vertex AI adapter](implemented/vertex-ai-adapter.md) | Infrastructure |
| [Git backup and restore](implemented/git-backup-restore.md) | Infrastructure |
| [Web GUI enhancements](implemented/web-gui-enhancements.md) | Interfaces |
| [Skills management](implemented/skills-management.md) | Skills |
| [Self-diagnostic skill](implemented/self-diagnostic-skill.md) | Skills |
| [Communications agent](implemented/comms-agent.md) | Comms |
| [Bug fixes (March 2026)](implemented/Bug%20fixes%2027-03-26.md) | Fixes |

## Planned (26)

| Feature | Category |
|---|---|
| [Fluency / Grounding separation](planned/fluency-grounding-separation.md) | Safety |
| [Provenance-aware output gate](planned/provenance-aware-output-gate.md) | Safety |
| [Federated instances](planned/federated-instances.md) | Core |
| [External agent integration](planned/external-agent-integration.md) | Core |
| [Multi-tenant](planned/multi-tenant.md) | Core |
| [Document library](planned/document-library.md) | Memory |
| [Knowledge management](planned/knowledge-management.md) | Memory |
| [Learner ingestion](planned/learner-ingestion.md) | Memory |
| [Extended housekeeper window](planned/housekeeper-extended-window.md) | Memory |
| [CBR graph projection](planned/cbr-graph-projection.md) | Memory |
| [Metacognition reporting](planned/metacognition-reporting.md) | Observability |
| [Cycles spanning midnight](planned/cycles-spanning-midnight.md) | Observability |
| [Empirical evaluation](planned/empirical-evaluation.md) | Evaluation |
| [Multi-provider failover](planned/multi-provider-failover.md) | Infrastructure |
| [Hot reload config](planned/hot-reload-config.md) | Infrastructure |
| [Multi-language sandbox](planned/sandbox-multi-language.md) | Infrastructure |
| [Git tools and skills](planned/git-tools-and-skills.md) | Skills |
| [OAuth authentication](planned/oauth-authentication.md) | Interfaces |
| [Web GUI v2](planned/web-gui-v2.md) | Interfaces |
| [Web UI attentiveness](planned/web-ui-attentiveness.md) | Interfaces |
| [File uploads](planned/file-uploads.md) | Interfaces |
| [Mail attachments](planned/mail-attachments.md) | Comms |
| [SD Audit](planned/sd-audit.md) | Tooling |
| [SD Budget](planned/sd-budget.md) | Tooling |
| [SD Designer](planned/sd-designer.md) | Tooling |
| [SD Install](planned/sd-install.md) | Tooling |

## Archived

Specs superseded by newer designs or cut from scope. Preserved for reference.

| Feature | Category | Superseded by |
|---|---|---|
| [Commitment tracker (full GTD)](archived/commitment-tracker-gtd.md) | Work management | MVP commitment tracker (captures) |
