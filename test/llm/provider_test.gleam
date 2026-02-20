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
