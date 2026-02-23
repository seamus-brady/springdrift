import chat/service.{type AgentQuestion, type ChatMessage}
import etch/command
import etch/stdout
import etch/style
import etch/terminal
import gleam/erlang/process.{type Selector, type Subject}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import llm/response
import llm/types.{type LlmError, type LlmResponse, type Message, Assistant, Message, TextContent, User}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type AgentStatus {
  Idle
  WaitingForLlm
  WaitingForInput(question: String, reply_to: Subject(String))
}

type TuiMessage {
  StdinByte(byte: String)
  ChatResponse(result: Result(LlmResponse, LlmError))
  AgentQuestionReceived(question: String, reply_to: Subject(String))
}

type TuiState {
  TuiState(
    chat: Subject(ChatMessage),
    chat_reply: Subject(Result(LlmResponse, LlmError)),
    stdin_subj: Subject(TuiMessage),
    selector: Selector(TuiMessage),
    question_channel: Subject(AgentQuestion),
    provider_name: String,
    model: String,
    messages: List(Message),
    input_buf: String,
    scroll_offset: Int,
    width: Int,
    height: Int,
    status: AgentStatus,
    notice: String,
    spinner_frame: Int,
  )
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "read_char")
fn read_char() -> Result(String, Nil)

@external(erlang, "erlang", "halt")
fn do_halt(code: Int) -> Nil

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn start(
  chat: Subject(ChatMessage),
  provider_name: String,
  model: String,
) -> Nil {
  let size = terminal.window_size()
  let #(w, h) = result.unwrap(size, #(80, 24))
  let _ = terminal.enter_raw()
  stdout.execute([
    command.EnterAlternateScreen,
    command.HideCursor,
    command.Clear(terminal.All),
  ])
  let stdin_subj = process.new_subject()
  let chat_reply = process.new_subject()
  let question_channel = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(stdin_subj)
    |> process.select_map(chat_reply, ChatResponse)
    |> process.select_map(question_channel, fn(aq: AgentQuestion) {
      AgentQuestionReceived(question: aq.question, reply_to: aq.reply_to)
    })
  process.spawn_unlinked(fn() { stdin_loop(stdin_subj) })
  let state =
    TuiState(
      chat:,
      chat_reply:,
      stdin_subj:,
      selector:,
      question_channel:,
      provider_name:,
      model:,
      messages: [],
      input_buf: "",
      scroll_offset: 0,
      width: w,
      height: h,
      status: Idle,
      notice: "",
      spinner_frame: 0,
    )
  render(state)
  event_loop(state)
}

fn cleanup() -> Nil {
  stdout.execute([command.LeaveAlternateScreen, command.ShowCursor])
  let _ = terminal.exit_raw()
  Nil
}

// ---------------------------------------------------------------------------
// Stdin reader
// ---------------------------------------------------------------------------

fn stdin_loop(subj: Subject(TuiMessage)) -> Nil {
  case read_char() {
    Ok(byte) -> {
      process.send(subj, StdinByte(byte))
      stdin_loop(subj)
    }
    Error(_) -> Nil
  }
}

// ---------------------------------------------------------------------------
// Event loop
// ---------------------------------------------------------------------------

fn event_loop(state: TuiState) -> Nil {
  case state.status {
    WaitingForLlm ->
      case process.selector_receive(state.selector, 100) {
        Error(Nil) -> {
          let next =
            TuiState(..state, spinner_frame: state.spinner_frame + 1)
          render(next)
          event_loop(next)
        }
        Ok(msg) -> dispatch(state, msg)
      }
    _ -> dispatch(state, process.selector_receive_forever(state.selector))
  }
}

fn dispatch(state: TuiState, msg: TuiMessage) -> Nil {
  case msg {
    StdinByte(byte:) -> handle_stdin_byte(state, byte)
    ChatResponse(result:) -> handle_chat_response(state, result)
    AgentQuestionReceived(question:, reply_to:) ->
      handle_agent_question(state, question, reply_to)
  }
}

fn continue_loop(state: TuiState) -> Nil {
  render(state)
  event_loop(TuiState(..state, notice: ""))
}

fn do_exit(_state: TuiState) -> Nil {
  cleanup()
  do_halt(0)
}

fn handle_agent_question(
  state: TuiState,
  question: String,
  reply_to: Subject(String),
) -> Nil {
  continue_loop(TuiState(..state, status: WaitingForInput(question:, reply_to:)))
}

fn handle_stdin_byte(state: TuiState, byte: String) -> Nil {
  case byte {
    "\u{03}" | "\u{04}" -> do_exit(state)
    "\r" | "\n" -> handle_enter(state)
    "\u{7F}" | "\u{08}" -> continue_loop(handle_backspace(state))
    "\u{1B}" -> handle_escape(state)
    _ ->
      case is_printable(byte) {
        True ->
          continue_loop(
            TuiState(..state, input_buf: state.input_buf <> byte),
          )
        False -> event_loop(state)
      }
  }
}

fn handle_backspace(state: TuiState) -> TuiState {
  TuiState(..state, input_buf: string.drop_end(state.input_buf, 1))
}

fn handle_escape(state: TuiState) -> Nil {
  let first = process.receive(state.stdin_subj, 50)
  let second = process.receive(state.stdin_subj, 50)
  case first, second {
    Ok(StdinByte("[")), Ok(StdinByte("A")) -> continue_loop(scroll_up(state, 3))
    Ok(StdinByte("[")), Ok(StdinByte("B")) ->
      continue_loop(scroll_down(state, 3))
    Ok(StdinByte("[")), Ok(StdinByte("5")) -> {
      let _ = process.receive(state.stdin_subj, 50)
      continue_loop(scroll_up(state, 10))
    }
    Ok(StdinByte("[")), Ok(StdinByte("6")) -> {
      let _ = process.receive(state.stdin_subj, 50)
      continue_loop(scroll_down(state, 10))
    }
    _, _ -> event_loop(state)
  }
}

fn handle_command(state: TuiState, cmd: String) -> Nil {
  let state = TuiState(..state, input_buf: "")
  case cmd {
    "/exit" | "/quit" -> do_exit(state)
    _ -> {
      let notice = style.dim("  Unknown command: " <> cmd)
      continue_loop(TuiState(..state, notice:))
    }
  }
}

fn handle_enter(state: TuiState) -> Nil {
  case string.trim(state.input_buf) {
    "" -> event_loop(state)
    input_text ->
      case string.starts_with(input_text, "/") {
        True -> handle_command(state, input_text)
        False ->
          case state.status {
            WaitingForLlm ->
              continue_loop(
                TuiState(
                  ..state,
                  notice: style.dim("  Still waiting for response\u{2026}"),
                ),
              )
            WaitingForInput(question:, reply_to:) -> {
              let q_msg =
                Message(role: Assistant, content: [TextContent(text: question)])
              let a_msg =
                Message(role: User, content: [TextContent(text: input_text)])
              let msgs = list.append(state.messages, [q_msg, a_msg])
              process.send(reply_to, input_text)
              continue_loop(
                TuiState(
                  ..state,
                  messages: msgs,
                  input_buf: "",
                  status: WaitingForLlm,
                  scroll_offset: 0,
                ),
              )
            }
            Idle -> {
              let user_msg =
                Message(role: User, content: [TextContent(text: input_text)])
              let msgs = list.append(state.messages, [user_msg])
              let s1 =
                TuiState(
                  ..state,
                  messages: msgs,
                  input_buf: "",
                  status: WaitingForLlm,
                  scroll_offset: 0,
                )
              render(s1)
              process.send(
                state.chat,
                service.SendMessage(
                  text: input_text,
                  reply_to: state.chat_reply,
                  question_channel: state.question_channel,
                ),
              )
              event_loop(s1)
            }
          }
      }
  }
}

fn handle_chat_response(
  state: TuiState,
  result: Result(LlmResponse, LlmError),
) -> Nil {
  let reply_text = case result {
    Ok(resp) -> response.text(resp)
    Error(err) -> "[Error: " <> response.error_message(err) <> "]"
  }
  let asst = Message(role: Assistant, content: [TextContent(text: reply_text)])
  let new_state =
    TuiState(
      ..state,
      messages: list.append(state.messages, [asst]),
      status: Idle,
    )
  continue_loop(new_state)
}

fn scroll_up(state: TuiState, amount: Int) -> TuiState {
  let all_lines = build_message_lines(state)
  let total = list.length(all_lines)
  let available = state.height - 5
  let max_offset = int.max(0, total - available)
  TuiState(
    ..state,
    scroll_offset: int.min(state.scroll_offset + amount, max_offset),
  )
}

fn scroll_down(state: TuiState, amount: Int) -> TuiState {
  TuiState(..state, scroll_offset: int.max(0, state.scroll_offset - amount))
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn render(state: TuiState) -> Nil {
  stdout.execute([command.MoveTo(0, 0), command.Clear(terminal.All)])
  render_header(state)
  render_separator(state.width, 1)
  render_messages(state)
  render_separator(state.width, state.height - 3)
  render_input(state)
  render_footer(state)
}

fn render_header(state: TuiState) -> Nil {
  let header =
    style.bold(" Springdrift ")
    <> style.dim("── ")
    <> state.provider_name
    <> " │ "
    <> state.model
  stdout.execute([command.MoveTo(0, 0), command.Print(header)])
}

fn render_separator(width: Int, row: Int) -> Nil {
  let line = string.repeat("─", width)
  stdout.execute([command.MoveTo(0, row), command.Print(line)])
}

fn render_messages(state: TuiState) -> Nil {
  let all_lines = build_message_lines(state)
  let available = state.height - 5
  let total = list.length(all_lines)
  let end_idx = int.max(0, total - state.scroll_offset)
  let start_idx = int.max(0, end_idx - available)
  let window =
    all_lines
    |> list.drop(start_idx)
    |> list.take(available)
  print_lines(window, 2)
}

fn print_lines(lines: List(String), start_row: Int) -> Nil {
  case lines {
    [] -> Nil
    [line, ..rest] -> {
      stdout.execute([command.MoveTo(0, start_row), command.Print(line)])
      print_lines(rest, start_row + 1)
    }
  }
}

fn build_message_lines(state: TuiState) -> List(String) {
  let msg_lines =
    list.flat_map(state.messages, fn(msg) {
      let label = case msg.role {
        User -> style.bold(style.cyan("  You"))
        Assistant -> style.bold(style.green("  Assistant"))
      }
      let text = extract_text(msg)
      let content_lines = render_markdown(text, state.width - 4)
      list.flatten([[""], [label], content_lines])
    })
  case state.status {
    WaitingForLlm -> {
      let label = style.bold(style.green("  Assistant"))
      let frames = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]
      let frame =
        list.drop(frames, state.spinner_frame % 8)
        |> list.first()
        |> result.unwrap("⣾")
      list.append(msg_lines, [
        "",
        label,
        style.dim("    " <> frame <> " Thinking\u{2026}"),
      ])
    }
    WaitingForInput(question:, ..) -> {
      let label = style.bold(style.green("  Assistant"))
      list.append(msg_lines, [
        "",
        label,
        style.bold(style.yellow("    ? " <> question)),
      ])
    }
    Idle -> msg_lines
  }
}

fn extract_text(msg: Message) -> String {
  list.filter_map(msg.content, fn(block) {
    case block {
      TextContent(text:) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("")
}

fn render_input(state: TuiState) -> Nil {
  let max_display = int.max(1, state.width - 6)
  let buf_len = string.length(state.input_buf)
  let display_input = case buf_len > max_display {
    True -> string.slice(state.input_buf, buf_len - max_display, max_display)
    False -> state.input_buf
  }
  let line =
    "  " <> style.bold("> ") <> display_input <> style.blinking("\u{2588}")
  stdout.execute([command.MoveTo(0, state.height - 2), command.Print(line)])
}

fn render_footer(state: TuiState) -> Nil {
  let footer = case state.notice {
    "" ->
      case state.status {
        Idle -> style.dim("  Enter: send   PgUp/PgDn: scroll   /exit: quit")
        WaitingForLlm -> style.dim("  Waiting for response\u{2026}   Ctrl-C: quit")
        WaitingForInput(..) ->
          style.dim("  Enter: answer question   Ctrl-C: quit")
      }
    msg -> style.yellow(msg)
  }
  stdout.execute([command.MoveTo(0, state.height - 1), command.Print(footer)])
}

// ---------------------------------------------------------------------------
// Text wrapping
// ---------------------------------------------------------------------------

fn wrap_text(text: String, max_width: Int) -> List(String) {
  string.split(text, "\n")
  |> list.flat_map(fn(line) { wrap_line(line, max_width) })
}

fn wrap_line(line: String, max_width: Int) -> List(String) {
  do_wrap(string.split(line, " "), max_width, "", [])
}

fn do_wrap(
  words: List(String),
  max_width: Int,
  current: String,
  acc: List(String),
) -> List(String) {
  case words {
    [] ->
      case current {
        "" -> list.reverse(acc)
        _ -> list.reverse([current, ..acc])
      }
    [word, ..rest] -> {
      let candidate = case current {
        "" -> word
        _ -> current <> " " <> word
      }
      case string.length(candidate) > max_width {
        True ->
          case current {
            // Word itself exceeds max_width; force it on its own line
            "" -> do_wrap(rest, max_width, "", [word, ..acc])
            // Current line is full; wrap
            _ -> do_wrap([word, ..rest], max_width, "", [current, ..acc])
          }
        False -> do_wrap(rest, max_width, candidate, acc)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Markdown rendering
// ---------------------------------------------------------------------------

// Renders a markdown string into display lines, each prefixed with 4 spaces.
// max_width is the available characters *excluding* the 4-space indent.
fn render_markdown(text: String, max_width: Int) -> List(String) {
  string.split(text, "\n")
  |> process_md_lines(False, max_width, [])
  |> list.reverse
}

fn process_md_lines(
  lines: List(String),
  in_code: Bool,
  max_width: Int,
  acc: List(String),
) -> List(String) {
  case lines {
    [] -> acc
    [line, ..rest] ->
      case in_code {
        True -> {
          let t = string.trim(line)
          case string.starts_with(t, "```") || string.starts_with(t, "~~~") {
            True -> process_md_lines(rest, False, max_width, acc)
            False ->
              process_md_lines(rest, True, max_width, [
                "    " <> style.cyan(line),
                ..acc
              ])
          }
        }
        False ->
          case string.trim(line) {
            "" -> process_md_lines(rest, False, max_width, ["", ..acc])
            _ -> {
              let #(next_in_code, rendered) = render_md_line(line, max_width)
              process_md_lines(
                rest,
                next_in_code,
                max_width,
                list.append(list.reverse(rendered), acc),
              )
            }
          }
      }
  }
}

fn render_md_line(line: String, max_width: Int) -> #(Bool, List(String)) {
  let t = string.trim(line)
  case string.starts_with(t, "```") || string.starts_with(t, "~~~") {
    True -> #(True, [])
    False -> render_md_block(line, max_width)
  }
}

fn render_md_block(line: String, max_width: Int) -> #(Bool, List(String)) {
  case string.starts_with(line, "### ") {
    True -> #(False, [
      "    " <> style.bold(apply_inline(string.drop_start(line, 4))),
    ])
    False ->
      case string.starts_with(line, "## ") {
        True -> #(False, [
          "    " <> style.bold(apply_inline(string.drop_start(line, 3))),
        ])
        False ->
          case string.starts_with(line, "# ") {
            True -> #(False, [
              "    " <> style.bold(apply_inline(string.drop_start(line, 2))),
            ])
            False -> render_md_leaf(line, max_width)
          }
      }
  }
}

fn render_md_leaf(line: String, max_width: Int) -> #(Bool, List(String)) {
  case string.starts_with(line, "> ") {
    True -> #(False, [
      "    " <> style.dim("│ ") <> apply_inline(string.drop_start(line, 2)),
    ])
    False ->
      case
        string.starts_with(line, "- ")
        || string.starts_with(line, "* ")
        || string.starts_with(line, "+ ")
      {
        True -> #(
          False,
          render_list_item(string.drop_start(line, 2), max_width),
        )
        False ->
          case is_hr(string.trim(line)) {
            True -> #(False, ["    " <> string.repeat("─", max_width)])
            False -> {
              let wrapped = wrap_text(line, max_width)
              #(False, list.map(wrapped, fn(l) { "    " <> apply_inline(l) }))
            }
          }
      }
  }
}

fn render_list_item(content: String, max_width: Int) -> List(String) {
  list.index_map(wrap_text(content, max_width - 2), fn(line, i) {
    case i {
      0 -> "    \u{2022} " <> apply_inline(line)
      _ -> "      " <> apply_inline(line)
    }
  })
}

fn is_hr(line: String) -> Bool {
  let s = string.replace(line, " ", "")
  case string.length(s) >= 3 {
    False -> False
    True -> is_all_char(s, "-") || is_all_char(s, "=")
  }
}

fn is_all_char(s: String, c: String) -> Bool {
  string.starts_with(s, c) && string.replace(s, c, "") == ""
}

fn apply_inline(text: String) -> String {
  scan_inline(text, "")
}

fn scan_inline(rest: String, acc: String) -> String {
  case rest {
    "" -> acc
    _ ->
      case string.starts_with(rest, "**") {
        True -> {
          let after = string.drop_start(rest, 2)
          case str_split_once(after, "**") {
            Ok(#(inner, tail)) ->
              scan_inline(tail, acc <> style.bold(scan_inline(inner, "")))
            Error(_) -> scan_inline(string.drop_start(rest, 2), acc <> "**")
          }
        }
        False ->
          case string.starts_with(rest, "*") {
            True -> {
              let after = string.drop_start(rest, 1)
              case str_split_once(after, "*") {
                Ok(#(inner, tail)) ->
                  scan_inline(tail, acc <> style.italic(scan_inline(inner, "")))
                Error(_) -> scan_inline(string.drop_start(rest, 1), acc <> "*")
              }
            }
            False ->
              case string.starts_with(rest, "`") {
                True -> {
                  let after = string.drop_start(rest, 1)
                  case str_split_once(after, "`") {
                    Ok(#(code, tail)) ->
                      scan_inline(tail, acc <> style.cyan(code))
                    Error(_) ->
                      scan_inline(string.drop_start(rest, 1), acc <> "`")
                  }
                }
                False -> {
                  let ch = string.slice(rest, 0, 1)
                  scan_inline(string.drop_start(rest, 1), acc <> ch)
                }
              }
          }
      }
  }
}

// Split on the first occurrence of sep, rejoining later parts with sep.
fn str_split_once(s: String, sep: String) -> Result(#(String, String), Nil) {
  case string.split(s, sep) {
    [] | [_] -> Error(Nil)
    [before, ..rest] -> Ok(#(before, string.join(rest, sep)))
  }
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

fn is_printable(byte: String) -> Bool {
  case string.to_utf_codepoints(byte) {
    [cp] -> {
      let code = string.utf_codepoint_to_int(cp)
      code >= 32 && code <= 126
    }
    _ -> False
  }
}
