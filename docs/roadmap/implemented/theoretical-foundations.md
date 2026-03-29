# Theoretical Foundations — Academic References

**Status**: Reference document
**Date**: 2026-03-26

---

## Table of Contents

- [Overview](#overview)
- [Aaron Sloman — H-CogAff Architecture](#aaron-sloman-h-cogaff-architecture)
- [Lee Roy Beach — Image Theory and The Psychology of Narrative Thought](#lee-roy-beach-image-theory-and-the-psychology-of-narrative-thought)
  - [D' as the Synthesis](#d-as-the-synthesis)
- [Roger Schank — Case-Based Reasoning and Dynamic Memory](#roger-schank-case-based-reasoning-and-dynamic-memory)
- [Lawrence Becker — A New Stoicism](#lawrence-becker-a-new-stoicism)
- [Prototype Lineage — TallMountain, Meek, PaperWings](#prototype-lineage-tallmountain-meek-paperwings)
  - [TallMountain AI (Raku & Python)](#tallmountain-ai-raku-python)
  - [PromptBouncer](#promptbouncer)
  - [Meek (Modern Perl)](#meek-modern-perl)
  - [PaperWings (Gleam)](#paperwings-gleam)
- [Agnar Aamodt & Enric Plaza — CBR Cycle](#agnar-aamodt-enric-plaza-cbr-cycle)
- [Sànchez-Marrè — CBR for Environmental Decision Support](#snchez-marr-cbr-for-environmental-decision-support)
- [Contemporary Papers (2025-2026)](#contemporary-papers-2025-2026)
  - [Three-Paper Integration (Curragh's research)](#three-paper-integration-curraghs-research)
  - [Three-Paper Review (Implementation enhancements)](#three-paper-review-implementation-enhancements)
- [Mapping Summary](#mapping-summary)
- [Prototype Lineage](#prototype-lineage)


## Overview

Springdrift's architecture draws on seven years of research across cognitive science, AI safety, decision theory, and case-based reasoning. This document maps the theoretical influences to their implementation in the system.

---

## Aaron Sloman — H-CogAff Architecture

**Key work**: "The Cognition and Affect Project" (University of Birmingham); "Varieties of Meta-cognition in Natural and Artificial Systems"

**Influence**: The three-layer cognitive architecture that structures the D' safety system and the agent's metacognitive capabilities.

| Sloman Layer | Purpose | Springdrift Implementation |
|---|---|---|
| Reactive | Fast, pattern-based responses | D' deterministic pre-filter (`dprime/deterministic.gleam`), reactive gate layer in `dprime/gate.gleam` |
| Deliberative | Goal-directed reasoning with world models | D' deliberative gate layer (LLM-based scoring), query complexity classification, agent delegation |
| Meta-management | Self-monitoring, self-modification, reasoning about own processing | Meta observer (`meta/observer.gleam`), sensorium vitals (uncertainty, prediction_error, novelty), Forecaster, escalation criteria |

**What Sloman provides**: The principle that a cognitive system needs layers that operate at different time scales and abstraction levels. The reactive layer handles millisecond pattern matching. The deliberative layer handles seconds-scale reasoning. The meta-management layer handles minutes-to-hours pattern detection across cycles. Each layer can intervene in the layers below it.

**Specific implementation**: The D' gate's three evaluation layers (`evaluate_reactive` → `evaluate_deliberative` → meta-management check) directly implement Sloman's hierarchy. The meta observer's `should_intervene` function is Sloman's meta-management layer making decisions about whether the deliberative layer is stuck.

---

## Lee Roy Beach — Image Theory and The Psychology of Narrative Thought

**Key work**: "Image Theory: Decision Making in Personal and Organizational Contexts" (1990); "The Psychology of Narrative Thought" (2010); "Leadership and the Art of Change" (2006)

**Influence**: The structural decision-making framework that gives D' its gate architecture and the narrative-centred memory model.

Image Theory proposes three images that guide decision-making:
1. **Value Image** — principles and standards (what matters)
2. **Trajectory Image** — goals and plans (where we're going)
3. **Strategic Image** — tactics and actions (how to get there)

**Decisions are made by screening** — testing whether a candidate action is compatible with the images — not by optimising a utility function.

**The Psychology of Narrative Thought** extends this: humans understand their world through narrative — stories about what happened, why, and what it means. Memory, planning, and decision-making are all narrative processes.

| Beach Concept | Springdrift Implementation |
|---|---|
| Value Image | D' features (prompt_injection, harmful_request, unsourced_claim, etc.) — the standards against which all actions are evaluated |
| Trajectory Image | Tasks and Endeavours (`planner/types.gleam`) — the agent's goals and plans |
| Strategic Image | CBR cases and the agent's approach selection — how the agent decides to pursue goals |
| Screening (compatibility test) | D' gate decision: Accept/Modify/Reject based on whether the action is compatible with the value image |
| Adoption decision | Query complexity classification → model selection; the choice of WHICH approach to use |
| Progress decision | Forecaster health evaluation; the assessment of whether the current plan is working |
| Narrative thought | Prime Narrative — the agent's memory is structured as first-person stories about what happened each cycle, not as a knowledge graph |
| Narrative as sense-making | Archivist Reflector phase — "what happened, what worked, what failed" is narrative sense-making |

**What Beach provides**: The structural insight that D' implements. Safety evaluation is not optimisation — it's compatibility testing. D' doesn't compute the "optimal" response; it tests whether a response is compatible with defined standards. The gate returns Accept/Modify/Reject (compatible, fixable, incompatible) rather than a utility score. The narrative memory model comes from Beach's later work on narrative thought as the fundamental mode of human cognition.

### D' as the Synthesis

**D' (D-prime) is a simplified version of Becker's Normative Calculus with the structural decision-making of Beach's Psychology of Narrative Thought.**

From Becker: the normative framework — the agent evaluates its outputs against its values (features), self-corrects when inconsistent (MODIFY), and refuses when fundamentally incompatible (REJECT). The three-layer gate (reactive/deliberative/meta) is the normative calculus operationalised via Sloman's cognitive architecture.

From Beach: the decision structure — screening rather than optimising, images as the basis for evaluation, and narrative as the memory substrate. The D' features ARE Beach's Value Image. The gate decision IS Beach's screening test. The Prime Narrative IS Beach's narrative thought.

---

## Roger Schank — Case-Based Reasoning and Dynamic Memory

**Key work**: "Dynamic Memory: A Theory of Reminding and Learning in Computers and People" (1982); "Tell Me a Story: Narrative and Intelligence" (1995)

**Influence**: The CBR memory system and the narrative-based agent memory architecture.

| Schank Concept | Springdrift Implementation |
|---|---|
| Scripts (stereotyped action sequences) | CBR cases with `CbrSolution.steps` — reusable action sequences for known problem types |
| Memory Organisation Packets (MOPs) | CBR categories (Strategy, CodePattern, Troubleshooting, Pitfall, DomainKnowledge) |
| Expectation failures as learning signals | CBR cases created from both successes and failures; `CbrOutcome.pitfalls` captures what went wrong |
| Reminding (retrieval as the basis of reasoning) | CBR retrieval with weighted multi-signal scoring — the agent reasons by finding similar past situations |
| Story-based memory | Prime Narrative — the agent's memory is structured as a first-person narrative log, not a knowledge graph |
| Dynamic memory (memory that changes through use) | CBR self-improvement: usage stats, utility-weighted retrieval, harmful case deprecation |

**What Schank provides**: The principle that intelligent systems remember by storing experiences as stories, and reason by finding relevant stories. The Prime Narrative (append-only JSONL of what happened each cycle) is Schank's dynamic memory. CBR retrieval is Schank's reminding process. The Archivist's two-phase pipeline (reflect on what happened, then structure it for storage) is Schank's learning-through-reminding.

---

## Lawrence Becker — A New Stoicism

**Key work**: "A New Stoicism" (1998, revised 2017)

**Influence**: The normative framework underlying the agent's self-governance, D' gate evaluation, and the relationship between the agent's rational capacity and its constraints.

Becker's modern Stoic framework argues that rational agents should:
1. Follow the facts (virtue as rational agency aligned with reality)
2. Accept what cannot be changed while acting on what can
3. Maintain internal consistency between values, judgments, and actions

| Becker Concept | Springdrift Implementation |
|---|---|
| Virtue as rational agency | The agent's self-model: accuracy, transparency about confidence, honest acknowledgement of limitations (persona.md) |
| Following the facts | Output gate enforcing evidence-based claims: unsourced_claim, accuracy, certainty_overstatement features |
| Normative calculus | D' feature scoring as a normative evaluation — not "is this dangerous?" but "is this consistent with the agent's standards?" |
| Self-governance through reason | Meta-management layer: the agent monitors its own processing and self-corrects (meta observer, report_false_positive) |
| Appropriate response to externals | Confidence decay: older information is treated with less certainty, matching the Stoic principle of proportioning belief to evidence |

**What Becker provides**: The philosophical foundation for why D' is a compatibility test (Beach) rather than a utility optimiser. The agent doesn't maximise a reward function — it evaluates whether its outputs are consistent with its values (the feature set). When they're not, it self-corrects (MODIFY) or refuses (REJECT). This is Becker's "following the facts" operationalised as a safety system.

**Connection to TallMountain**: Springdrift's D' system descends from TallMountain AI's normative calculus — a multi-stage cognitive pipeline (reactive, deliberative, normative) for safety enforcement. TallMountain implemented Becker's framework explicitly; Springdrift inherits the architecture.

---

## Prototype Lineage — TallMountain, Meek, PaperWings

Springdrift is the culmination of seven years and ~50 prototypes. Three prior projects directly inform the current architecture:

### TallMountain AI (Raku & Python)

A normative calculus ethical LLM AI agent implementing multi-stage cognitive pipeline (reactive, deliberative, normative) for safety enforcement. TallMountain was the first implementation of the three-layer gate architecture that became D' in Springdrift.

| TallMountain | Springdrift |
|---|---|
| Reactive pipeline stage | D' reactive gate layer + deterministic pre-filter |
| Deliberative pipeline stage | D' deliberative gate layer (LLM scoring) |
| Normative pipeline stage | D' meta-management + meta observer |
| Risk assessment | D' feature scoring with importance weighting |
| Go/No-Go safety decisions | Accept/Modify/Reject gate decisions |

### PromptBouncer

Prototype defense tool for LLM systems against prompt-based attacks. Real-time threat assessment with Go/No-Go safety decisions. Directly influenced the D' canary probes and deterministic pre-filter.

### Meek (Modern Perl)

Advanced LLM agent with REACT loops, dynamic tool use, and Toolformer-inspired workflows. Proved out the ReAct loop pattern and tool dispatch architecture that Springdrift uses.

### PaperWings (Gleam)

Vector Symbolic Architecture associative memory with biologically-inspired forgetting mechanisms. Became the CBR retrieval engine in Springdrift:

| PaperWings | Springdrift |
|---|---|
| VSA structural distance | CBR case similarity scoring in `cbr/bridge.gleam` |
| High-dimensional associative memory | Inverted index + embedding-based retrieval |
| Biologically-inspired forgetting | Confidence decay with half-life (`dprime/decay.gleam`), housekeeping pruning |
| Case encoding/retrieval | Full CBR cycle: retrieve, reuse, revise, retain |

---

---

## Agnar Aamodt & Enric Plaza — CBR Cycle

**Key work**: "Case-Based Reasoning: Foundational Issues, Methodological Variations, and System Approaches" (1994)

**Influence**: The four-phase CBR cycle that structures `cbr/bridge.gleam`.

| CBR Phase | Springdrift Implementation |
|---|---|
| **Retrieve** | `bridge.retrieve_cases` — weighted 6-signal fusion (field score, index overlap, recency, domain, embedding, utility) |
| **Reuse** | Cognitive loop and agents apply retrieved cases as context — cases injected into system prompt by Curator |
| **Revise** | Archivist post-cycle evaluation: did the approach work? Usage stats updated. |
| **Retain** | Archivist generates new CbrCase from cycle outcome, appends to JSONL |

---

## Sànchez-Marrè — CBR for Environmental Decision Support

**Key work**: Referenced in `cbr-review.md` — CBR cycle phases adapted for agent systems

**Influence**: The specific implementation of retain, retrieve, reuse, revise in the CBR bridge, and the deduplication/pruning strategy in housekeeping.

---

## Contemporary Papers (2025-2026)

### Three-Paper Integration (Curragh's research)

| Paper | ArXiv | Influence |
|---|---|---|
| CCA (Cognitive Control Architecture) | 2512.06716 | Intent Graph, Parameter Provenance Placeholders, 4-dimensional Adjudicator → fact provenance, D' feature scoring |
| SOFAI-LM (IBM Research) | 2508.17959 | S1/S2 metacognition, episodic memory confidence decay → query complexity classification, confidence decay, escalation criteria |
| Nowaczyk (Agentic Architecture) | 2512.09458 | Interface contracts, Verifier/Critic, versioned policies → deterministic pre-filter, per-agent D' overrides |

### Three-Paper Review (Implementation enhancements)

| Paper | ArXiv | Influence |
|---|---|---|
| Memento | 2508.16153 | Learned case retrieval policy, K=4 optimal → CBR utility scoring, retrieval cap |
| ACE (Agentic Context Engineering) | 2510.04618 | Reflector/Curator separation, hit/harm counters, delta updates → Archivist split, CBR usage stats, budget-triggered housekeeping |
| System M (Dupoux/LeCun/Malik) | 2603.15381 | Meta-controller on epistemic signals, Evo/Devo → canonical meta-states (uncertainty, prediction_error, novelty) in sensorium |

---

## Mapping Summary

| System Component | Primary Theoretical Influence |
|---|---|
| D' as a whole | Becker (normative calculus) + Beach (screening/narrative thought) — simplified and operationalised via Sloman's architecture |
| D' three-layer gate | Sloman (H-CogAff reactive/deliberative/meta), descended from TallMountain AI |
| D' feature screening | Beach (Image Theory value image, compatibility test) |
| D' self-governance | Becker (virtue as rational agency, following the facts) |
| CBR memory | Schank (dynamic memory, reminding), Aamodt & Plaza (CBR cycle), descended from PaperWings |
| Prime Narrative | Schank (story-based memory) + Beach (narrative thought as cognition) |
| Sensorium | Sloman (meta-management perception) |
| Tasks and Forecaster | Beach (trajectory image, progress decisions) |
| Meta observer | Sloman (meta-management), System M paper |
| Confidence decay | SOFAI-LM (episodic memory decay), PaperWings (biologically-inspired forgetting) |
| Deterministic pre-filter | CCA (rule-based safety layer), Nowaczyk (interface contracts), descended from PromptBouncer |
| Archivist split | ACE (Reflector/Curator separation) |
| CBR self-improvement | Memento (learned retrieval policy) |
| Virtual memory | Letta (fixed-budget context slots) |
| Canary probes | Original design, descended from PromptBouncer |
| ReAct loop | Descended from Meek (Perl prototype) |

## Prototype Lineage

```
TallMountain AI (Raku/Python)  →  D' normative calculus, three-layer gate
PromptBouncer                  →  Canary probes, deterministic pre-filter
Meek (Perl)                    →  ReAct loop, tool dispatch
PaperWings (Gleam)             →  CBR retrieval, VSA distance, forgetting
        ↓
    Springdrift (Gleam/OTP) — 7 years, ~50 prototypes
```
