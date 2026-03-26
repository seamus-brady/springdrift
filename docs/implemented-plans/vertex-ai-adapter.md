# Google Vertex AI Adapter — Implementation Record

**Status**: Implemented, pending GCP quota approval
**Date**: 2026-03-23 to 2026-03-24

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Authentication Flow](#authentication-flow)
- [Vertex AI Specifics](#vertex-ai-specifics)
- [Tool Call Handling](#tool-call-handling)
- [Configuration](#configuration)
- [Per-Provider Model Config](#per-provider-model-config)
- [Known Issues](#known-issues)
- [FFI Additions](#ffi-additions)


## Overview

New LLM provider adapter for Anthropic Claude models on Google Vertex AI. Supports service account JWT authentication with automatic token refresh. Designed for EU data residency (GDPR) and to avoid Anthropic API 529 overload errors during US peak hours.

## Architecture

```
llm/adapters/vertex.gleam — Full adapter: auth, URL construction, request/response encoding
springdrift_ffi.erl       — RSA-SHA256 signing, ETS token cache, Content-Type extraction
```

## Authentication Flow

Three auth strategies, tried in order:

1. **Service account key file** (`[vertex] credentials` in config) — reads JSON key, signs JWT with RSA-SHA256 via Erlang `public_key`, exchanges for OAuth2 access token at `https://oauth2.googleapis.com/token`, caches in ETS with 50-minute expiry (tokens last 60 min)
2. **GOOGLE_APPLICATION_CREDENTIALS env var** — same as above, path from env
3. **VERTEX_AI_TOKEN env var** — static bearer token (for testing)

## Vertex AI Specifics

| | Anthropic Direct | Vertex AI |
|---|---|---|
| URL | `api.anthropic.com/v1/messages` | `REGION-aiplatform.googleapis.com/v1/projects/PROJECT/locations/REGION/publishers/anthropic/models/MODEL:rawPredict` |
| Auth | `x-api-key` header | `Authorization: Bearer` (OAuth2 token) |
| API version | `anthropic-version` header | `anthropic_version` in request body (`vertex-2023-10-16`) |
| Model | In request body | In URL path |
| Request format | Anthropic Messages API | Same |
| Response format | Anthropic standard | Same |

## Tool Call Handling

Vertex returns `input` as a JSON object (not string). The adapter uses `raw_json` FFI (identity cast to gleam_json's opaque Json type) for encoding, and `json_encode_term` for decoding dynamic→string.

## Configuration

```toml
[vertex]
project_id = "springdrift"
location = "europe-west1"
endpoint = "europe-west1-aiplatform.googleapis.com"
credentials = "/path/to/service-account-key.json"
task_model = "claude-haiku-4-5"
reasoning_model = "claude-opus-4-6"
```

## Per-Provider Model Config

All providers support per-section model config:

```toml
provider = "vertex"

[vertex]
task_model = "claude-haiku-4-5"
reasoning_model = "claude-opus-4-6"

[anthropic]
task_model = "claude-haiku-4-5-20251001"
reasoning_model = "claude-opus-4-6"

[mistral]
task_model = "mistral-small-latest"
reasoning_model = "mistral-large-latest"
```

Priority: CLI flag > top-level config > provider section > hardcoded default.

## Known Issues

- GCP quota must be requested per model per region (default is 0 for new projects)
- Vertex model names differ from direct Anthropic API names (e.g. `claude-haiku-4-5` vs `claude-haiku-4-5-20251001`)
- The `http_post` FFI now extracts Content-Type from headers (previously hardcoded to `application/json`, which broke the OAuth2 form-urlencoded token exchange)

## FFI Additions

| Function | Purpose |
|---|---|
| `sign_rs256(pem, message)` | RSA-SHA256 signing for JWT |
| `unix_now()` | UTC unix timestamp in seconds |
| `ets_new/insert/lookup` | Token cache |
| `json_encode_term(term)` | Dynamic → JSON string |
| `identity(x)` | Type coercion for raw JSON embedding |
| `extract_content_type(headers)` | Content-Type from header list |
