import gleeunit
import gleeunit/should
import llm/types.{
  Assistant, Message, TextContent, ToolResultContent, ToolUseContent, User,
}
import storage

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// save + load roundtrip (envelope format)
// ---------------------------------------------------------------------------

pub fn save_and_load_roundtrip_test() {
  let messages = [
    Message(role: User, content: [TextContent(text: "Hello")]),
    Message(role: Assistant, content: [TextContent(text: "Hi there!")]),
  ]
  let assert Ok(_) = storage.save(messages)
  let loaded = storage.load()
  loaded |> should.equal(messages)
}

pub fn save_and_load_with_tool_use_test() {
  let messages = [
    Message(role: User, content: [TextContent(text: "What is 2+2?")]),
    Message(role: Assistant, content: [
      TextContent(text: "Let me calculate that."),
      ToolUseContent(
        id: "tool_1",
        name: "calculator",
        input_json: "{\"expression\":\"2+2\"}",
      ),
    ]),
    Message(role: User, content: [
      ToolResultContent(tool_use_id: "tool_1", content: "4", is_error: False),
    ]),
    Message(role: Assistant, content: [TextContent(text: "2+2 = 4")]),
  ]
  let assert Ok(_) = storage.save(messages)
  let loaded = storage.load()
  loaded |> should.equal(messages)
}

pub fn save_and_load_empty_messages_test() {
  let messages = []
  let assert Ok(_) = storage.save(messages)
  let loaded = storage.load()
  loaded |> should.equal([])
}

// ---------------------------------------------------------------------------
// Legacy format backward compatibility
// ---------------------------------------------------------------------------

pub fn load_legacy_format_test() {
  // Simulate the old format: a plain JSON array of messages (no envelope)
  let legacy_json =
    "[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]},{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Hi!\"}]}]"

  // Write the legacy format directly to the session path
  // We use save first to ensure the directory exists, then overwrite
  let assert Ok(_) = storage.save([])
  let path = storage.session_path_for_test()
  let assert Ok(_) = simplifile.write(path, legacy_json)

  let loaded = storage.load()
  loaded
  |> should.equal([
    Message(role: User, content: [TextContent(text: "Hello")]),
    Message(role: Assistant, content: [TextContent(text: "Hi!")]),
  ])
}

// ---------------------------------------------------------------------------
// Corrupt JSON returns empty list
// ---------------------------------------------------------------------------

pub fn load_corrupt_json_returns_empty_test() {
  // Write garbage to the session file
  let assert Ok(_) = storage.save([])
  let path = storage.session_path_for_test()
  let assert Ok(_) = simplifile.write(path, "this is not json at all {{{")

  let loaded = storage.load()
  loaded |> should.equal([])
}

pub fn load_partial_json_returns_empty_test() {
  let assert Ok(_) = storage.save([])
  let path = storage.session_path_for_test()
  let assert Ok(_) = simplifile.write(path, "{\"version\": 1, \"saved_at\":")

  let loaded = storage.load()
  loaded |> should.equal([])
}

// ---------------------------------------------------------------------------
// Clear
// ---------------------------------------------------------------------------

pub fn clear_then_load_returns_empty_test() {
  let messages = [
    Message(role: User, content: [TextContent(text: "Hello")]),
  ]
  let assert Ok(_) = storage.save(messages)
  let assert Ok(_) = storage.clear()
  let loaded = storage.load()
  loaded |> should.equal([])
}

import simplifile
