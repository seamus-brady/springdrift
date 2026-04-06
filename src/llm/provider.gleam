// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import llm/types.{type LlmError, type LlmRequest, type LlmResponse}

/// A provider is a record of functions — Gleam's capability/record-of-functions pattern.
pub type Provider {
  Provider(name: String, chat: fn(LlmRequest) -> Result(LlmResponse, LlmError))
}

/// Pipeline-friendly helper: pipe a request into a provider
pub fn chat_with(
  request: LlmRequest,
  provider: Provider,
) -> Result(LlmResponse, LlmError) {
  provider.chat(request)
}

/// Get the provider's name
pub fn name(provider: Provider) -> String {
  provider.name
}
