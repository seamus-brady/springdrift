/// E2B Code Interpreter — cloud sandbox for executing AI-generated code.
///
/// Creates an ephemeral E2B sandbox, runs code via the code-interpreter
/// Jupyter endpoint, and tears down the sandbox. Requires E2B_API_KEY.
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import slog

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const api_host = "api.e2b.app"

const jupyter_port = "49999"

const default_template = "code-interpreter-v1"

const sandbox_timeout_ms = 120_000

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

/// Returns E2B tools only if E2B_API_KEY is set. When the key is missing,
/// returns an empty list so the coder agent never sees run_code.
pub fn all() -> List(Tool) {
  case is_available() {
    True -> [run_code_tool()]
    False -> []
  }
}

/// Check whether E2B is configured (API key present).
pub fn is_available() -> Bool {
  case get_env("E2B_API_KEY") {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn run_code_tool() -> Tool {
  tool.new("run_code")
  |> tool.with_description(
    "Execute code in a secure cloud sandbox (E2B). Supports Python by default. The sandbox is ephemeral — created fresh for each call and destroyed after. Combine multiple operations into a single code block when possible. Returns stdout, stderr, and any results or errors.",
  )
  |> tool.add_string_param(
    "code",
    "The code to execute. For Python, you can use print() for output and import any standard library module.",
    True,
  )
  |> tool.add_string_param(
    "language",
    "Programming language: python (default), javascript, r, java, bash",
    False,
  )
  |> tool.build()
}

pub fn is_e2b_tool(name: String) -> Bool {
  name == "run_code"
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(call: ToolCall) -> ToolResult {
  slog.debug("e2b", "execute", "tool=" <> call.name, None)
  case call.name {
    "run_code" -> run_code(call)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// Sandbox types
// ---------------------------------------------------------------------------

type SandboxInfo {
  SandboxInfo(sandbox_id: String, access_token: String, domain: String)
}

// ---------------------------------------------------------------------------
// run_code implementation
// ---------------------------------------------------------------------------

fn run_code(call: ToolCall) -> ToolResult {
  let decoder = {
    use code <- decode.field("code", decode.string)
    use language <- decode.optional_field("language", "python", decode.string)
    decode.success(#(code, language))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid run_code input: missing code parameter",
      )
    Ok(#(code, language)) ->
      case do_run_code(code, language) {
        Ok(output) -> ToolSuccess(tool_use_id: call.id, content: output)
        Error(msg) -> ToolFailure(tool_use_id: call.id, error: msg)
      }
  }
}

fn do_run_code(code: String, language: String) -> Result(String, String) {
  use api_key <- result.try({
    case get_env("E2B_API_KEY") {
      Ok(key) -> Ok(key)
      Error(_) -> {
        let msg =
          "E2B_API_KEY is not set. Add it to your environment to use run_code."
        slog.log_error("e2b", "do_run_code", msg, None)
        Error(msg)
      }
    }
  })

  // 1. Create sandbox
  use sandbox <- result.try({
    case create_sandbox(api_key) {
      Ok(sb) -> {
        slog.debug("e2b", "run_code", "Created sandbox " <> sb.sandbox_id, None)
        Ok(sb)
      }
      Error(msg) -> {
        slog.log_error(
          "e2b",
          "run_code",
          "Sandbox creation failed: " <> msg,
          None,
        )
        Error(msg)
      }
    }
  })

  // 2. Execute code (always clean up sandbox afterward)
  let exec_result = execute_code(sandbox, code, language)
  case exec_result {
    Error(msg) ->
      slog.log_error("e2b", "run_code", "Execution failed: " <> msg, None)
    Ok(_) -> slog.debug("e2b", "run_code", "Execution succeeded", None)
  }

  // 3. Kill sandbox (best effort — don't fail if this errors)
  let _ = kill_sandbox(api_key, sandbox.sandbox_id)
  slog.debug("e2b", "run_code", "Killed sandbox " <> sandbox.sandbox_id, None)

  exec_result
}

// ---------------------------------------------------------------------------
// REST API — sandbox lifecycle
// ---------------------------------------------------------------------------

fn create_sandbox(api_key: String) -> Result(SandboxInfo, String) {
  let body =
    json.object([
      #("templateID", json.string(default_template)),
      #("timeout", json.int(sandbox_timeout_ms)),
    ])
    |> json.to_string

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host(api_host)
    |> request.set_path("/sandboxes")
    |> request.set_scheme(http.Https)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("x-api-key", api_key)

  case httpc.send(req) {
    Error(e) -> Error("E2B create sandbox HTTP error: " <> string.inspect(e))
    Ok(resp) ->
      case resp.status {
        200 | 201 -> parse_create_response(resp.body)
        status ->
          Error(
            "E2B create sandbox returned "
            <> int.to_string(status)
            <> ": "
            <> resp.body,
          )
      }
  }
}

fn parse_create_response(body: String) -> Result(SandboxInfo, String) {
  let decoder = {
    use sandbox_id <- decode.field("sandboxID", decode.string)
    use access_token <- decode.field("envdAccessToken", decode.string)
    use domain <- decode.field("domain", decode.string)
    decode.success(SandboxInfo(sandbox_id:, access_token:, domain:))
  }
  case json.parse(body, decoder) {
    Ok(info) -> Ok(info)
    Error(_) -> Error("E2B: failed to parse create sandbox response: " <> body)
  }
}

fn kill_sandbox(api_key: String, sandbox_id: String) -> Result(Nil, String) {
  let req =
    request.new()
    |> request.set_method(http.Delete)
    |> request.set_host(api_host)
    |> request.set_path("/sandboxes/" <> sandbox_id)
    |> request.set_scheme(http.Https)
    |> request.set_header("x-api-key", api_key)

  case httpc.send(req) {
    Error(e) -> Error("E2B kill sandbox HTTP error: " <> string.inspect(e))
    Ok(_) -> Ok(Nil)
  }
}

// ---------------------------------------------------------------------------
// Code execution via Jupyter endpoint
// ---------------------------------------------------------------------------

fn execute_code(
  sandbox: SandboxInfo,
  code: String,
  language: String,
) -> Result(String, String) {
  let host = sandbox.sandbox_id <> "-" <> jupyter_port <> "." <> sandbox.domain

  let body =
    json.object([
      #("code", json.string(code)),
      #("language", json.string(language)),
    ])
    |> json.to_string

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host(host)
    |> request.set_path("/execute")
    |> request.set_scheme(http.Https)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("x-access-token", sandbox.access_token)

  case httpc.send(req) {
    Error(e) -> Error("E2B execute HTTP error: " <> string.inspect(e))
    Ok(resp) ->
      case resp.status {
        200 -> parse_execution_response(resp.body)
        status ->
          Error(
            "E2B execute returned "
            <> int.to_string(status)
            <> ": "
            <> resp.body,
          )
      }
  }
}

/// Parse the JSONL execution response — each line is a JSON object with a "type" field.
fn parse_execution_response(body: String) -> Result(String, String) {
  let lines =
    body
    |> string.split("\n")
    |> list.filter(fn(line) { string.trim(line) != "" })

  let #(stdout_parts, stderr_parts, result_parts, error_parts) =
    list.fold(lines, #([], [], [], []), fn(acc, line) {
      let #(outs, errs, results, errors) = acc
      case parse_output_line(line) {
        Ok(#("stdout", text)) -> #([text, ..outs], errs, results, errors)
        Ok(#("stderr", text)) -> #(outs, [text, ..errs], results, errors)
        Ok(#("result", text)) -> #(outs, errs, [text, ..results], errors)
        Ok(#("error", text)) -> #(outs, errs, results, [text, ..errors])
        _ -> acc
      }
    })

  let sections = []
  let sections = case list.reverse(error_parts) {
    [] -> sections
    parts -> list.append(sections, ["ERROR:\n" <> string.join(parts, "\n")])
  }
  let sections = case list.reverse(stderr_parts) {
    [] -> sections
    parts -> list.append(sections, ["STDERR:\n" <> string.join(parts, "\n")])
  }
  let sections = case list.reverse(stdout_parts) {
    [] -> sections
    parts -> list.append(sections, ["STDOUT:\n" <> string.join(parts, "\n")])
  }
  let sections = case list.reverse(result_parts) {
    [] -> sections
    parts -> list.append(sections, ["RESULT:\n" <> string.join(parts, "\n")])
  }

  case sections {
    [] -> Ok("Code executed successfully (no output).")
    _ -> Ok(string.join(sections, "\n\n"))
  }
}

/// Parse a single JSONL output line from the execute endpoint.
fn parse_output_line(line: String) -> Result(#(String, String), Nil) {
  // Try to extract type and text/content from each line
  let type_decoder = {
    use output_type <- decode.field("type", decode.string)
    decode.success(output_type)
  }
  case json.parse(line, type_decoder) {
    Error(_) -> Error(Nil)
    Ok(output_type) ->
      case output_type {
        "stdout" | "stderr" -> {
          let text_decoder = {
            use text <- decode.field("text", decode.string)
            decode.success(text)
          }
          case json.parse(line, text_decoder) {
            Ok(text) -> Ok(#(output_type, text))
            Error(_) -> Error(Nil)
          }
        }
        "result" -> {
          // Results can have various formats; extract text representation
          let result_decoder = {
            use data <- decode.field(
              "data",
              decode.list({
                use text <- decode.optional_field("text", "", decode.string)
                use mime <- decode.optional_field("type", "", decode.string)
                decode.success(#(mime, text))
              }),
            )
            decode.success(data)
          }
          case json.parse(line, result_decoder) {
            Ok(data_items) -> {
              let texts =
                list.filter_map(data_items, fn(item) {
                  let #(_mime, text) = item
                  case text {
                    "" -> Error(Nil)
                    t -> Ok(t)
                  }
                })
              case texts {
                [] -> Error(Nil)
                _ -> Ok(#("result", string.join(texts, "\n")))
              }
            }
            Error(_) -> Error(Nil)
          }
        }
        "error" -> {
          let error_decoder = {
            use name <- decode.optional_field("name", "", decode.string)
            use value <- decode.optional_field("value", "", decode.string)
            use traceback <- decode.optional_field(
              "traceback",
              "",
              decode.string,
            )
            decode.success(#(name, value, traceback))
          }
          case json.parse(line, error_decoder) {
            Ok(#(name, value, traceback)) -> {
              let msg = case traceback {
                "" -> name <> ": " <> value
                tb -> name <> ": " <> value <> "\n" <> tb
              }
              Ok(#("error", msg))
            }
            Error(_) -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
  }
}
