# Springdrift — Theoretical Background and References

## Prototype Lineage

Springdrift is the culmination of seven years and approximately 50 prototypes.
Four prior projects directly inform the current architecture:

**TallMountain AI** (Raku & Python) — a normative calculus ethical LLM agent
implementing a multi-stage cognitive pipeline (reactive, deliberative, normative)
for safety enforcement. TallMountain was the first implementation of the
three-layer gate architecture that became D' in Springdrift, and the source of
the Stoic normative calculus now ported to Gleam.

**PromptBouncer** — prototype defence tool for LLM systems against prompt-based
attacks. Real-time threat assessment with go/no-go safety decisions. Directly
influenced D' canary probes and the deterministic pre-filter.

**Meek** (Modern Perl) — advanced LLM agent with ReAct loops, dynamic tool use,
and Toolformer-inspired workflows. Proved out the ReAct loop pattern and tool
dispatch architecture.

**PaperWings** (Gleam) — Vector Symbolic Architecture associative memory with
biologically-inspired forgetting mechanisms. Became the CBR retrieval engine:
VSA structural distance became case similarity scoring, high-dimensional
associative memory became the inverted index, and biologically-inspired
forgetting became confidence decay with half-life.

---

## Classical Cognitive Science

### Aaron Sloman — H-CogAff Architecture

Sloman's three-layer cognitive architecture (reactive, deliberative,
meta-management) is the structural template for the D' safety system. The
reactive layer handles fast pattern-matching (canary probes, deterministic
rules). The deliberative layer does model-based reasoning (LLM scoring with
importance weighting). The meta-management layer monitors its own performance
(sliding window, stall detection, threshold adaptation).

The sensorium — the agent's ambient self-perception XML block injected each
cycle — is Sloman's meta-management perception operationalised.

- Sloman, A. (2001). Beyond shallow models of emotion. *Cognitive Processing*, 2(1), 177-198.
- Sloman, A., & Chrisley, R. (2003). Virtual machines and consciousness. *Journal of Consciousness Studies*, 10(4-5), 133-172.
- Sloman, A. (2008). Varieties of meta-cognition in natural and artificial systems. *International Workshop on Meta-Cognition and Metareasoning in Agents*.

### Lee Roy Beach — Image Theory and Narrative Thought

Beach's Image Theory models human decision-making as a screening process: new
options are tested for compatibility against existing standards (the "value
image") rather than optimised across alternatives. An option that violates any
standard is rejected without further analysis.

Springdrift adopts this as the D' discrepancy score — a weighted sum of how far
an action deviates from configured standards. The Prime Narrative system
implements Beach's "narrative image" — past decisions forming a story that
constrains future ones.

- Beach, L. R. (1990). *Image Theory: Decision Making in Personal and Organizational Contexts*. Lawrence Erlbaum.
- Beach, L. R. (2006). *Leadership and the Art of Change*. Sage.
- Beach, L. R. (2010). *The Psychology of Narrative Thought: How the Stories We Tell Ourselves Shape Our Lives*. Xlibris.

### Jerome Bruner — Narrative Construction of Reality

Bruner argued that humans organise experience primarily through narrative —
constructing stories that link events by causality, intention, and temporal
sequence rather than by logical categorisation. The Prime Narrative system
makes this explicit: every cycle is a structured entry with intent, outcome,
entities, and confidence.

- Bruner, J. (1991). The narrative construction of reality. *Critical Inquiry*, 18(1), 1-21.

### Roger Schank — Dynamic Memory and Scripts

Schank's dynamic memory theory — that memory is organised around scripts,
MOPs (memory organisation packets), and reminding — directly influenced the
CBR case structure. Cases capture problem-solution-outcome patterns analogous
to Schank's scripts. The narrative threading system (linking related cycles by
domain/location/keyword overlap) implements Schank's reminding mechanism.

- Schank, R. C. (1982). *Dynamic Memory: A Theory of Reminding and Learning in Computers and People*. Cambridge University Press.
- Schank, R. C. (1995). Tell Me a Story: Narrative and Intelligence. *Northwestern University Press*.
- Schank, R. C., & Abelson, R. P. (1995). Knowledge and memory: The real story. In R. S. Wyer (Ed.), *Advances in Social Cognition*, Vol. 8 (pp. 1-85). Lawrence Erlbaum.

---

## Philosophy of Ethics

### Lawrence C. Becker — A New Stoicism

The normative calculus is adapted from Becker's reconstruction of Stoic ethics
for modern use. Becker's framework provides: normative operators (Required,
Ought, Indifferent), ordinal levels for ranking normative domains, modality
(Possible/Impossible), and six axioms governing conflict resolution between
normative propositions.

The key insight from Becker is that the agent doesn't maximise a reward
function — it evaluates whether its outputs are consistent with its values
(the character specification). When they're not, it self-corrects or refuses.
This is Becker's "following the facts" operationalised as a safety system.

The eudaimonic design inverts the typical safety approach: instead of evaluating
input against rules (deontology), it evaluates output against character (virtue
ethics). The question is not "is this request allowed?" but "is this response
consistent with who I am?"

- Becker, L. C. (1998). *A New Stoicism*. Princeton University Press.
- Becker, L. C. (2017). *A New Stoicism* (Revised edition). Princeton University Press.

---

## Foundational AI

### Aamodt & Plaza — Case-Based Reasoning

The four-phase CBR cycle (Retrieve, Reuse, Revise, Retain) structures the
entire CBR subsystem. Retrieve uses a 6-signal weighted fusion. Reuse injects
cases as context via the Curator. Revise evaluates outcomes post-cycle. Retain
generates new cases from cycle outcomes.

- Aamodt, A., & Plaza, E. (1994). Case-based reasoning: Foundational issues, methodological variations, and system approaches. *AI Communications*, 7(1), 39-59.

### Sànchez-Marrè — CBR for Environmental Decision Support

Influenced the specific implementation of retain, retrieve, reuse, revise in
the CBR bridge, and the deduplication/pruning strategy in housekeeping.

---

## Contemporary AI Papers (2025-2026)

### D' Safety Enhancements — Three-Paper Integration

| Paper | Authors | arXiv | Influence on Springdrift |
|---|---|---|---|
| CCA (Cognitive Control Architecture) | — | [2512.06716](https://arxiv.org/abs/2512.06716) | Intent Graph, Parameter Provenance Placeholders, 4-dimensional Adjudicator → fact provenance, D' feature scoring |
| SOFAI-LM | IBM Research | [2508.17959](https://arxiv.org/abs/2508.17959) | S1/S2 metacognition, episodic memory confidence decay → query complexity classification, confidence decay, escalation criteria |
| Nowaczyk (Agentic Architecture) | Nowaczyk et al. | [2512.09458](https://arxiv.org/abs/2512.09458) | BDI-style componentisation, explicit interface contracts, Verifier/Critic → deterministic pre-filter, per-agent D' overrides |

### CBR and Metacognition Enhancements — Three-Paper Review

| Paper | Authors | arXiv | Influence on Springdrift |
|---|---|---|---|
| Memento | Huichi Zhou et al. (UCL, Huawei Noah's Ark) | [2508.16153](https://arxiv.org/abs/2508.16153) | Learned case retrieval policy via soft Q-learning; K=4 optimal retrieval cap → CBR utility scoring, retrieval cap |
| ACE (Agentic Context Engineering) | Zhang et al. (Stanford, SambaNova, UC Berkeley) | [2510.04618](https://arxiv.org/abs/2510.04618) | Reflector/Curator separation, hit/harm counters, delta context updates → Archivist two-phase pipeline, CBR usage stats, budget-triggered housekeeping |
| System M ("Why AI Systems Don't Learn") | Dupoux (FAIR/META), LeCun (NYU), Malik (UC Berkeley) | [2603.15381](https://arxiv.org/abs/2603.15381) | Three-system cognitive architecture (A/B/M), meta-controller on epistemic signals → canonical meta-states (uncertainty, prediction_error, novelty) in sensorium |

---

## Design Patterns and Standards

### 12-Factor Agents (HumanLayer)

The founding design principle of the project. Springdrift implements a
12-Factor Agents style ReAct loop — the cognitive loop is the core, with
tool dispatch, agent delegation, and safety gates as composable layers.

- HumanLayer. *12-Factor Agents*. https://github.com/humanlayer/12-factor-agents

### agentskills.io

Skills use the agentskills.io open standard for skill definitions — YAML
frontmatter with name/description, Markdown instruction body.

- agentskills.io. https://agentskills.io

### Letta (Virtual Context Window)

The Curator's virtual memory management — fixed-budget context slots with
priority-based truncation — follows the Letta pattern for managed context
windows. Named slots (identity, sensorium, threads, facts, CBR cases, working
memory) are prioritised and truncated under budget pressure.

---

## Mapping Summary

| System Component | Primary Theoretical Influence |
|---|---|
| D' safety system | Becker (normative calculus) + Beach (screening/narrative thought), operationalised via Sloman's architecture |
| D' three-layer gate | Sloman (H-CogAff reactive/deliberative/meta), descended from TallMountain AI |
| D' feature screening | Beach (Image Theory value image, compatibility test) |
| D' self-governance | Becker (virtue as rational agency, following the facts) |
| Normative calculus | Becker (A New Stoicism, §6.2-6.7), ported from TallMountain |
| Character specification | Becker (eudaimonic character, highest endeavour) |
| CBR memory | Schank (dynamic memory, reminding), Aamodt & Plaza (CBR cycle), descended from PaperWings |
| Prime Narrative | Schank (story-based memory) + Beach (narrative thought as cognition) |
| Narrative threading | Schank (reminding by similarity) + Bruner (narrative construction) |
| Sensorium | Sloman (meta-management perception) |
| Meta-states | System M paper (epistemic signals: uncertainty, prediction_error, novelty) |
| Archivist two-phase pipeline | ACE paper (Reflector/Curator separation) |
| CBR retrieval cap (K=4) | Memento paper (context pollution beyond 4 cases) |
| CBR utility scoring | Memento paper (learned retrieval policy) + ACE (hit/harm counters) |
| Confidence decay | SOFAI-LM (episodic memory confidence decay) |
| Fact provenance | CCA (Parameter Provenance Placeholders) |
| Deterministic pre-filter | Nowaczyk (Verifier/Critic), descended from PromptBouncer |
| Query complexity classification | SOFAI-LM (S1/S2 metacognitive escalation) |
| Tasks and Forecaster | Beach (trajectory image, progress decisions) |
| ReAct loop | 12-Factor Agents, descended from Meek |
| Skills | agentskills.io standard |
| Virtual memory management | Letta pattern |
