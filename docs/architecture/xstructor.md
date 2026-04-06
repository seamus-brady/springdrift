# XStructor Architecture

XStructor is Springdrift's XML-schema-validated structured output system. It
replaces JSON parsing from LLM responses with XSD validation and automatic retry,
providing reliable structured extraction from natural language models.

---

## 1. Design Rationale

LLMs produce unreliable JSON: missing commas, unescaped quotes, truncated output,
hallucinated fields. JSON repair heuristics are fragile and model-dependent.

XStructor takes a different approach:
- **XSD schemas** define the expected structure formally
- **XML output** is validated against the schema by Erlang's `xmerl` library
- **Validation errors** are fed back to the LLM as retry context
- **Flat extraction** converts validated XML to `Dict(String, String)` with dotted paths

This gives compile-time-like guarantees on LLM output structure.

## 2. Workflow

```
1. Define schema (XSD + example)
            │
            ▼
2. compile_schema(dir, name, xsd)  →  SchemaState (opaque Erlang term)
            │
            ▼
3. generate(config, prompt, provider, model)
            │
            ├──→ LLM call with schema in system prompt
            │         │
            │         ▼
            │    clean_response (strip code fences, XML declarations)
            │         │
            │         ▼
            │    validate(xml, schema)
            │         │
            │    ┌────┴────┐
            │    ▼         ▼
            │  Valid    Invalid
            │    │         │
            │    │    append error as user message
            │    │    retry LLM call (up to max_retries)
            │    │         │
            │    ▼         ▼
            │  extract(xml)  →  Dict(String, String)
            │
            ▼
4. XStructorResult { xml, elements, retries_used }
```

## 3. API

### compile_schema

```gleam
pub fn compile_schema(
  schema_dir: String,  // e.g. ".springdrift/schemas/"
  name: String,        // e.g. "narrative_entry.xsd"
  content: String,     // XSD content
) -> Result(SchemaState, String)
```

Writes the XSD to disk and compiles it via `xmerl_xsd:process_schema/1`. The
returned `SchemaState` is an opaque Erlang term used for subsequent validation.
Compiled schemas are written to `.springdrift/schemas/`.

### generate

```gleam
pub fn generate(
  config: XStructorConfig,
  user_prompt: String,
  provider: Provider,
  model: String,
) -> Result(XStructorResult, String)
```

The main entry point. Makes an LLM call with the schema and example in the system
prompt, cleans the response, validates against the schema, and retries on error.

### XStructorConfig

```gleam
pub type XStructorConfig {
  XStructorConfig(
    schema: SchemaState,       // Compiled XSD
    system_prompt: String,     // Includes schema + example
    xml_example: String,       // Example output for the LLM
    max_retries: Int,          // Default: 3 (from config)
    max_tokens: Int,           // Max output tokens for the LLM
  )
}
```

### XStructorResult

```gleam
pub type XStructorResult {
  XStructorResult(
    xml: String,                        // Validated XML
    elements: Dict(String, String),     // Flat extraction with dotted paths
    retries_used: Int,                  // How many retries were needed
  )
}
```

### extract

```gleam
pub fn extract(xml: String) -> Result(Dict(String, String), String)
```

Converts validated XML to a flat dictionary with dotted paths:

```
<root>
  <child>
    <value>hello</value>
  </child>
  <items>
    <item>a</item>
    <item>b</item>
  </items>
</root>
```

Produces:
```
"root.child.value" → "hello"
"root.items.item.0" → "a"
"root.items.item.1" → "b"
```

Repeated elements use indexed paths (`.0`, `.1`, ...).

### extract_list

```gleam
pub fn extract_list(elements: Dict(String, String), prefix: String) -> List(String)
```

Convenience for extracting repeated elements. Given a prefix like `"root.items"`,
returns all values with matching indexed paths in order.

## 4. Response Cleaning

`clean_response` strips common LLM output artifacts:

1. Trim whitespace
2. Strip code fences (` ```xml ... ``` `)
3. Strip XML declarations (`<?xml ...?>`)
4. Trim again

This handles the common case where LLMs wrap XML output in markdown code blocks.

## 5. Retry Mechanism

When validation fails:

1. The validation error message is appended as a user message:
   `"XML validation failed: {error}. Fix the XML and try again."`
2. The LLM's previous (invalid) response is included as assistant context
3. The LLM is called again with this correction context
4. This repeats up to `max_retries` times (configurable, default 3)

This feedback loop lets the LLM see exactly what went wrong and self-correct.

## 6. Schemas

`src/xstructor/schemas.gleam` contains all XSD schemas and XML examples used across
the system. Each call site has a matching schema:

| Call site | Schema | Purpose |
|---|---|---|
| D' scorer | `dprime_candidates.xsd` | Structured candidates for deliberative layer |
| D' scorer | `dprime_forecasts.xsd` | Structured forecasts with magnitude scores |
| Archivist | `narrative_entry.xsd` | Narrative entry generation |
| Archivist | `cbr_case.xsd` | CBR case extraction |
| Archivist | `narrative_summary.xsd` | Periodic narrative summaries |
| Planner | `plan.xsd` | Structured task plans with steps and dependencies |
| Appraiser | `pre_mortem.xsd` | Pre-mortem analysis |
| Appraiser | `post_mortem.xsd` | Post-mortem evaluation |

`schemas.build_system_prompt(base_prompt, xsd, example)` assembles the system prompt
with the schema and example injected in a format the LLM can follow.

## 7. Erlang FFI

`src/xstructor_ffi.erl` provides four functions via Erlang's `xmerl` library:

| Function | Purpose |
|---|---|
| `write_schema_file(Path, Content)` | Write XSD to disk |
| `compile_schema(Path)` | Compile XSD via `xmerl_xsd:process_schema/1` |
| `validate_xml(Xml, Schema)` | Validate XML against compiled schema |
| `extract_elements(Xml)` | Parse XML and extract element paths + values |

`xmerl` is part of Erlang/OTP's standard library -- no external dependencies.

## 8. Configuration

| Field | Config section | Default | Purpose |
|---|---|---|---|
| `xstructor_max_retries` | `[xstructor]` | 3 | Max validation + retry attempts |

## 9. Key Source Files

| File | Purpose |
|---|---|
| `xstructor.gleam` | Core: compile, generate, validate, extract, clean, retry |
| `xstructor/schemas.gleam` | XSD schemas + XML examples for all call sites |
| `xstructor_ffi.erl` | Erlang FFI for xmerl operations |
