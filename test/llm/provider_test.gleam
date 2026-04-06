// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleeunit
import gleeunit/should
import llm/adapters/mock
import llm/provider
import llm/request

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn chat_with_pipeline_test() {
  let p = mock.provider_with_text("Hello!")
  request.new("test-model", 1024)
  |> request.with_user_message("Hi")
  |> provider.chat_with(p)
  |> should.be_ok
}

pub fn name_returns_mock_name_test() {
  let p = mock.provider_with_text("Hello!")
  provider.name(p) |> should.equal("mock")
}
