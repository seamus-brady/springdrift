# LLM Provider Layer Architecture

The LLM layer provides a provider-agnostic abstraction over multiple AI model
APIs. All LLM work in Springdrift flows through this layer -- no module outside
`src/llm/` calls a provider SDK directly.

---

## 1. Provider Abstraction

`src/llm/provider.gleam` defines the core abstraction:

```gleam
pub type Provider {
  Provider(
    name: String,
    chat: fn(LlmRequest) -> Result(LlmResponse, LlmError),
  )
}
```

A provider is a record of functions -- Gleam's capability pattern. The `chat`
function is the only interface: send a request, get a response or error.

`chat_with(request, provider)` is a pipe-friendly helper:

```gleam
request.new(model, max_tokens)
|> request.with_system("You are helpful.")
|> request.with_user_message("Hello")
|> provider.chat_with(my_provider)
```

## 2. Request Builder

`src/llm/request.gleam` provides a pipe-friendly builder API:

| Function | Purpose |
|---|---|
| `new(model, max_tokens)` | Create request with defaults (all optionals None) |
| `with_system(prompt)` | Set system prompt |
| `with_messages(msgs)` | Replace message list |
| `with_message(msg)` | Append a single message |
| `with_user_message(text)` | Append a user text message |
| `with_assistant_message(text)` | Append an assistant text message |
| `with_tool_results(assistant_content, results)` | Add tool call/result turn pair |
| `with_tools(tools)` | Set available tools |
| `with_tool_choice(choice)` | Set tool choice strategy |
| `with_temperature(t)` | Set sampling temperature |
| `with_top_p(p)` | Set top-p sampling |
| `with_stop_sequences(seqs)` | Set stop sequences |
| `with_thinking_budget(tokens)` | Enable extended thinking with a token budget |

## 3. Core Types

Defined in `src/llm/types.gleam`:

### Messages

```gleam
pub type Role { User | Assistant }
pub type Message { Message(role: Role, content: List(ContentBlock)) }
```

### Content Blocks

```gleam
pub type ContentBlock {
  TextContent(text: String)
  ImageContent(media_type: String, data: String)
  ToolUseContent(id: String, name: String, input_json: String)
  ToolResultContent(tool_use_id: String, content: String, is_error: Bool)
  ThinkingContent(text: String)
}
```

`ThinkingContent` captures extended thinking output from reasoning models.

### Tools

```gleam
pub type Tool {
  Tool(
    name: String,
    description: Option(String),
    parameters: List(#(String, ParameterSchema)),
    required_params: List(String),
  )
}
```

`ParameterSchema` uses typed property variants (`StringProperty`, `NumberProperty`,
etc.) rather than stringly-typed schemas.

### Tool Calls and Results

```gleam
pub type ToolCall { ToolCall(id: String, name: String, input_json: String) }
pub type ToolResult {
  ToolSuccess(tool_use_id: String, content: String)
  ToolFailure(tool_use_id: String, error: String)
}
```

### Tool Choice

```gleam
pub type ToolChoice {
  AutoToolChoice    // Model decides
  AnyToolChoice     // Model must use a tool
  NoToolChoice      // No tools available
  SpecificToolChoice(name: String)  // Force a specific tool
}
```

### Response

```gleam
pub type LlmResponse {
  LlmResponse(
    id: String,
    content: List(ContentBlock),
    model: String,
    stop_reason: Option(StopReason),
    usage: Usage,
  )
}
```

Stop reasons: `EndTurn`, `MaxTokens`, `StopSequenceReached`, `ToolUseRequested`.

### Usage

```gleam
pub type Usage {
  Usage(
    input_tokens: Int,
    output_tokens: Int,
    thinking_tokens: Int,
    cache_creation_tokens: Int,
    cache_read_tokens: Int,
  )
}
```

Tracks prompt caching tokens (creation + read) alongside standard input/output.

### Errors

```gleam
pub type LlmError {
  ApiError(status_code: Int, message: String)
  NetworkError(reason: String)
  ConfigError(reason: String)
  DecodeError(reason: String)
  TimeoutError
  RateLimitError(message: String)
  UnknownError(reason: String)
}
```

## 4. Response Helpers

`src/llm/response.gleam` provides convenience functions:

| Function | Purpose |
|---|---|
| `text(response)` | Join all TextContent blocks into a single string |
| `needs_tool_execution(response)` | True if stop_reason is ToolUseRequested |
| `tool_calls(response)` | Extract all ToolCall records |
| `first_tool_call(response)` | First tool call or Error(Nil) |
| `was_truncated(response)` | True if stop_reason is MaxTokens |

## 5. Tool Definition Builder

`src/llm/tool.gleam` provides a builder for tool definitions, used by all tool
modules to construct `Tool` records with typed parameter schemas.

## 6. Adapters

Each adapter translates between the shared `LlmRequest`/`LlmResponse` types and
a specific provider's API:

### Anthropic (`src/llm/adapters/anthropic.gleam`)

- **API**: Direct HTTP to `https://api.anthropic.com/v1/messages`
- **Auth**: `ANTHROPIC_API_KEY` environment variable
- **Features**: Prompt caching (`cache_control: ephemeral` on system + tools),
  extended thinking (`thinking_budget_tokens`)
- **Implementation**: Raw HTTP via FFI (bypasses the `anthropic_gleam` SDK to
  support caching and thinking, which the SDK doesn't expose)

### OpenAI / OpenRouter (`src/llm/adapters/openai.gleam`)

- **API**: OpenAI-compatible REST via the `gllm` package
- **Auth**: `OPENAI_API_KEY` or `OPENROUTER_API_KEY`
- **Base URLs**: `openai_base_url` or `openrouter_base_url`
- **Note**: `gllm` 1.0.0 is optimised for OpenRouter's response format; direct
  OpenAI calls may need adjustment

### Vertex AI (`src/llm/adapters/vertex.gleam`)

- **API**: Vertex AI `rawPredict` endpoint with Anthropic message format
- **Auth**: Service account key file (JWT → OAuth2 exchange) or `VERTEX_AI_TOKEN`
  env var
- **Key differences**: model in URL path (not body), `anthropic_version` in body
  (not header), Bearer token auth (not x-api-key)
- **Config**: `vertex_project_id`, `vertex_location` (default: europe-west1),
  `vertex_endpoint`

### Mock (`src/llm/adapters/mock.gleam`)

- **Purpose**: Testing without network calls
- **Behaviour**: Injectable responses via function closures
- **Usage**: Primary tool for unit testing LLM-dependent behaviour

## 7. Retry Logic

`src/llm/retry.gleam` provides `call_with_retry(request, provider, config)`:

### RetryConfig

```gleam
pub type RetryConfig {
  RetryConfig(
    max_retries: Int,          // Default: 3
    initial_delay_ms: Int,     // Default: 500
    rate_limit_delay_ms: Int,  // Default: 5000
    overload_delay_ms: Int,    // Default: 2000
    max_delay_ms: Int,         // Default: 60000
  )
}
```

### Retry Strategy

- **Retryable errors**: 429, 500, 503, 529, `RateLimitError`, `NetworkError`,
  `TimeoutError`
- **Non-retryable**: 400, 401, 403, `ConfigError`, `DecodeError`
- **Backoff**: exponential with error-specific initial delays:
  - 429 (rate limit): starts at `rate_limit_delay_ms` (5s)
  - 529 (Anthropic overload): starts at `overload_delay_ms` (2s)
  - Other transient: starts at `initial_delay_ms` (500ms)
- **Cap**: delay never exceeds `max_delay_ms` (60s)

Configurable via `[retry]` section in config.toml.

## 8. Model Fallback

At the cognitive loop level (not in the LLM layer itself), when retry is exhausted
for a non-task-model and the error was retryable, the loop automatically falls back
to `task_model` with a `[model_x unavailable, used model_y]` prefix on the response.

## 9. Key Source Files

| File | Purpose |
|---|---|
| `llm/types.gleam` | Shared types: Message, ContentBlock, LlmRequest/Response/Error, Tool, Usage |
| `llm/request.gleam` | Pipe-friendly request builder |
| `llm/response.gleam` | Response helpers (text extraction, tool call detection) |
| `llm/tool.gleam` | Tool definition builder API |
| `llm/provider.gleam` | Provider abstraction (name + chat function) |
| `llm/retry.gleam` | Retry with exponential backoff |
| `llm/adapters/anthropic.gleam` | Anthropic API (raw HTTP, caching, thinking) |
| `llm/adapters/openai.gleam` | OpenAI / OpenRouter via gllm |
| `llm/adapters/vertex.gleam` | Google Vertex AI (Anthropic models via rawPredict) |
| `llm/adapters/mock.gleam` | Test/fallback provider with injectable responses |
