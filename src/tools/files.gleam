/// Filesystem tools: read_file, write_file, list_directory.
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import simplifile
import slog

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [read_file_tool(), write_file_tool(), list_directory_tool()]
}

fn read_file_tool() -> Tool {
  tool.new("read_file")
  |> tool.with_description("Read the contents of a file at the given path")
  |> tool.add_string_param("path", "Path to the file to read", True)
  |> tool.build()
}

fn write_file_tool() -> Tool {
  tool.new("write_file")
  |> tool.with_description(
    "Write content to a file at the given path, creating parent directories as needed",
  )
  |> tool.add_string_param("path", "Path to the file to write", True)
  |> tool.add_string_param("content", "Content to write to the file", True)
  |> tool.build()
}

fn list_directory_tool() -> Tool {
  tool.new("list_directory")
  |> tool.with_description(
    "List the entries in a directory. Returns newline-separated entry names.",
  )
  |> tool.add_string_param(
    "path",
    "Path to the directory to list (defaults to current directory if empty)",
    True,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(call: ToolCall, write_anywhere: Bool) -> ToolResult {
  slog.debug("files", "execute", "tool=" <> call.name, option.None)
  case call.name {
    "read_file" -> run_read_file(call)
    "write_file" -> run_write_file(call, write_anywhere)
    "list_directory" -> run_list_directory(call)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// read_file
// ---------------------------------------------------------------------------

fn run_read_file(call: ToolCall) -> ToolResult {
  let decoder = {
    use path <- decode.field("path", decode.string)
    decode.success(path)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid read_file input: missing path",
      )
    Ok(path) ->
      case simplifile.read(path) {
        Error(e) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "read_file: " <> simplifile.describe_error(e),
          )
        Ok(content) -> ToolSuccess(tool_use_id: call.id, content:)
      }
  }
}

// ---------------------------------------------------------------------------
// write_file
// ---------------------------------------------------------------------------

fn run_write_file(call: ToolCall, write_anywhere: Bool) -> ToolResult {
  let decoder = {
    use path <- decode.field("path", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(#(path, content))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid write_file input: missing path or content",
      )
    Ok(#(path, content)) ->
      case write_anywhere || is_within_cwd(path) {
        False ->
          ToolFailure(
            tool_use_id: call.id,
            error: "write_file: path is outside the current working directory (use --allow-write-anywhere to override)",
          )
        True -> {
          let dir = parent_dir(path)
          let _ = case dir {
            "" -> Ok(Nil)
            _ -> simplifile.create_directory_all(dir)
          }
          case simplifile.write(path, content) {
            Error(e) ->
              ToolFailure(
                tool_use_id: call.id,
                error: "write_file: " <> simplifile.describe_error(e),
              )
            Ok(_) ->
              ToolSuccess(tool_use_id: call.id, content: "Written: " <> path)
          }
        }
      }
  }
}

/// Returns true if `path` resolves to a location within the current working
/// directory. Absolute paths outside CWD return false.
fn is_within_cwd(path: String) -> Bool {
  case simplifile.current_directory() {
    Error(_) -> False
    Ok(cwd) -> {
      let abs = case string.starts_with(path, "/") {
        True -> path
        False -> cwd <> "/" <> path
      }
      string.starts_with(abs, cwd <> "/") || abs == cwd
    }
  }
}

/// Extract the parent directory portion of a path.
fn parent_dir(path: String) -> String {
  let parts = string.split(path, "/")
  case list.length(parts) {
    0 | 1 -> ""
    _ -> {
      let dir_parts = list.take(parts, list.length(parts) - 1)
      string.join(dir_parts, "/")
    }
  }
}

// ---------------------------------------------------------------------------
// list_directory
// ---------------------------------------------------------------------------

fn run_list_directory(call: ToolCall) -> ToolResult {
  let decoder = {
    use path <- decode.field("path", decode.string)
    decode.success(path)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid list_directory input: missing path",
      )
    Ok(raw_path) -> {
      let path = case raw_path {
        "" -> "."
        p -> p
      }
      case simplifile.read_directory(path) {
        Error(e) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "list_directory: " <> simplifile.describe_error(e),
          )
        Ok(entries) ->
          ToolSuccess(tool_use_id: call.id, content: string.join(entries, "\n"))
      }
    }
  }
}
