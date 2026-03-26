# XStructor — XML-Validated Structured LLM Output — Implementation Record

**Status**: Implemented
**Date**: 2026-03-18
**Source**: xstructor.py (Python prototype), xstructor/schemas.gleam

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Why XML, Not JSON](#why-xml-not-json)
- [Workflow](#workflow)
- [Call Sites](#call-sites)
- [Response Cleaning](#response-cleaning)
- [Flat Extraction](#flat-extraction)
- [Configuration](#configuration)
- [What Makes This Different](#what-makes-this-different)


## Overview

XStructor is the system that makes Springdrift reliable rather than probabilistic. Every structured LLM output — safety scores, narrative entries, CBR cases, summaries — is validated against an XSD schema before the system acts on it. If the LLM returns malformed output, XStructor retries automatically. If all retries fail, the caller gets a clean error, not garbage data.

This replaces the common pattern of parsing JSON from LLM responses with regex hacks and prayer. LLMs frequently produce malformed JSON — missing brackets, trailing commas, markdown wrappers. XStructor sidesteps this entirely: the LLM produces XML (which it does more reliably than JSON), and `xmerl` (Erlang's standard XML library) validates it against a compiled XSD schema.

## Architecture

```
xstructor.gleam       — Core: compile_schema, generate, clean_response, extract, validate
xstructor_ffi.erl     — Erlang FFI using xmerl: compile_schema, validate_xml, extract_elements
xstructor/schemas.gleam — XSD schemas + XML examples for all structured call sites
```

## Why XML, Not JSON

1. **LLMs produce valid XML more reliably than valid JSON.** XML is more forgiving of whitespace and less sensitive to exact punctuation (no trailing comma problem, no quote escaping issues).

2. **XSD validation is a solved problem.** Erlang's `xmerl` library (part of OTP, no external deps) compiles XSD schemas and validates XML documents in a single call. There is no equivalent zero-dependency JSON schema validator in the BEAM ecosystem.

3. **Schema-first means contract-first.** The XSD defines exactly what fields are required, what types they are, and what the valid structure looks like. The LLM is given the schema and an example in its system prompt. The validator checks conformance. There is no ambiguity about what constitutes valid output.

4. **Retry is principled.** When validation fails, XStructor retries with the same prompt. The error message from `xmerl` is specific ("unexpected end of tag at line 25, column 4") which could be fed back to the LLM in a future enhancement. Currently, retries use the same prompt — the LLM usually gets it right on the second or third attempt.

## Workflow

1. Define an XSD schema and XML example in `schemas.gleam`
2. Compile the schema at startup: `xstructor.compile_schema(schemas_dir, name, xsd_content)`
3. Build a config: `XStructorConfig(schema, system_prompt, xml_example, max_retries, max_tokens)`
4. Call `xstructor.generate(config, user_prompt, provider, model)`:
   - Makes the LLM call
   - Cleans the response (strips markdown fences, XML declarations, noise)
   - Validates against the compiled XSD schema
   - On failure: retries up to `max_retries` times
   - On success: returns `XStructorResult` with validated XML and retry count
5. Extract fields: `xstructor.extract(xml)` returns a flat `Dict(String, String)` with dotted paths

## Call Sites

| Call Site | Schema | Purpose | Fallback |
|---|---|---|---|
| D' candidates (`deliberative.gleam`) | `candidates.xsd` | Extract candidate discrepancies | Situation model as single candidate |
| D' forecasts (`scorer.gleam`) | `forecasts.xsd` | Score feature magnitudes | Cautious fallback (critical=2, non-critical=1) |
| Narrative entries (`archivist.gleam`) | `narrative_entry.xsd` | Extract cycle narrative | Fallback entry with low confidence |
| CBR cases (`archivist.gleam`) | `cbr_case.xsd` | Extract problem-solution-outcome | No case generated |
| Narrative summaries (`summary.gleam`) | `summary.xsd` | Periodic narrative summaries | No summary generated |

Every call site has a defined fallback for when XStructor fails entirely. The system degrades gracefully — it never crashes on malformed LLM output.

## Response Cleaning

`clean_response` handles the common ways LLMs wrap XML:

- Strips `` ```xml ... ``` `` markdown code fences
- Strips `<?xml ...?>` declarations
- Strips leading/trailing prose ("Here's the XML:", "I hope this helps!")
- Trims whitespace

This runs before validation, so the XSD only sees clean XML.

## Flat Extraction

`extract` converts nested XML into a flat `Dict(String, String)` with dotted paths:

```xml
<entry>
  <summary>The agent researched Dublin rents</summary>
  <intent>
    <goal>Market analysis</goal>
    <domain>Real estate</domain>
  </intent>
</entry>
```

Becomes:
```
"entry.summary" → "The agent researched Dublin rents"
"entry.intent.goal" → "Market analysis"
"entry.intent.domain" → "Real estate"
```

Repeated elements use indexed paths: `"items.item.0"`, `"items.item.1"`.

This flat representation is easy to pattern-match in Gleam without building a full XML DOM.

## Configuration

```toml
[xstructor]
# Max validation+retry attempts (default: 3)
# max_retries = 3
```

Compiled schemas cached at `.springdrift/schemas/` — compiled once at startup, reused across all calls.

## What Makes This Different

Most agent frameworks extract structured data from LLMs using one of:
1. **JSON mode** — relies on the LLM producing valid JSON (often doesn't)
2. **Function calling** — provider-specific, ties you to one API
3. **Regex extraction** — brittle, no validation
4. **JSON repair heuristics** — fixing malformed JSON with regex (fragile, error-prone)

XStructor uses none of these. It uses a standard schema language (XSD), a standard validation library (xmerl), and a standard data format (XML) that LLMs produce reliably. The result is structured output you can trust — validated against a contract, with automatic retry, and graceful fallback.

This is the foundation that makes D' scoring reliable (the scorer's feature magnitudes are always valid integers 0-3), narrative entries well-formed (the Archivist's output always has the required fields), and CBR cases structured (problem-solution-outcome is always complete).
