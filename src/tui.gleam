import chat/service.{
  type AgentQuestion, type ChatMessage, type ModelSwitchQuestion,
  type ServiceReply, type ToolEvent, ToolCalling,
}
import cycle_log.{type CycleData}
import etch/command
import etch/stdout
import etch/style
import etch/terminal
import gleam/erlang/process.{type Selector, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm/response
import llm/types.{
  type LlmError, type LlmResponse, type Message, type Usage, Assistant, Message,
  TextContent, User,
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type Tab {
  ChatTab
  LogTab
}

type AgentStatus {
  Idle
  WaitingForLlm
  WaitingForInput(question: String, reply_to: Subject(String))
  WaitingForModelSwitch(
    suggested_model: String,
    reply_to: Subject(service.ModelSwitchAnswer),
  )
}

type TuiMessage {
  StdinByte(byte: String)
  ChatResponse(
    result: Result(LlmResponse, LlmError),
    final_model: String,
    save_error: option.Option(String),
  )
  AgentQuestionReceived(question: String, reply_to: Subject(String))
  ToolEventReceived(name: String)
  ModelSwitchReceived(
    suggested_model: String,
    reply_to: Subject(service.ModelSwitchAnswer),
  )
}

type TuiState {
  TuiState(
    chat: Subject(ChatMessage),
    chat_reply: Subject(ServiceReply),
    stdin_subj: Subject(TuiMessage),
    selector: Selector(TuiMessage),
    question_channel: Subject(AgentQuestion),
    tool_channel: Subject(ToolEvent),
    model_question_channel: Subject(ModelSwitchQuestion),
    provider_name: String,
    model: String,
    task_model: String,
    reasoning_model: String,
    messages: List(Message),
    input_buf: String,
    scroll_offset: Int,
    width: Int,
    height: Int,
    status: AgentStatus,
    notice: String,
    spinner_frame: Int,
    spinner_label: String,
    tab: Tab,
    log_cycles: List(CycleData),
    log_selected: Int,
    last_usage: Option(Usage),
  )
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "read_char")
fn read_char() -> Result(String, Nil)

@external(erlang, "erlang", "halt")
fn do_halt(code: Int) -> Nil

@external(erlang, "springdrift_ffi", "tui_run")
fn tui_run(loop: fn() -> Nil, cleanup: fn() -> Nil) -> Nil

@external(erlang, "springdrift_ffi", "throw_tui_exit")
fn throw_tui_exit() -> Nil

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn start(
  chat: Subject(ChatMessage),
  provider_name: String,
  model: String,
  task_model: String,
  reasoning_model: String,
  initial_messages: List(Message),
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
  let tool_channel = process.new_subject()
  let model_question_channel = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(stdin_subj)
    |> process.select_map(chat_reply, fn(sr: ServiceReply) {
      ChatResponse(
        result: sr.llm_result,
        final_model: sr.final_model,
        save_error: sr.save_error,
      )
    })
    |> process.select_map(question_channel, fn(aq: AgentQuestion) {
      AgentQuestionReceived(question: aq.question, reply_to: aq.reply_to)
    })
    |> process.select_map(tool_channel, fn(te: ToolEvent) {
      case te {
        ToolCalling(name:) -> ToolEventReceived(name:)
      }
    })
    |> process.select_map(
      model_question_channel,
      fn(mq: service.ModelSwitchQuestion) {
        ModelSwitchReceived(
          suggested_model: mq.suggested_model,
          reply_to: mq.reply_to,
        )
      },
    )
  process.spawn_unlinked(fn() { stdin_loop(stdin_subj) })
  let resume_notice = case initial_messages {
    [] -> ""
    msgs ->
      "  Resumed: " <> int.to_string(list.length(msgs)) <> " messages loaded"
  }
  let state =
    TuiState(
      chat:,
      chat_reply:,
      stdin_subj:,
      selector:,
      question_channel:,
      tool_channel:,
      model_question_channel:,
      provider_name:,
      model:,
      task_model:,
      reasoning_model:,
      messages: initial_messages,
      input_buf: "",
      scroll_offset: 0,
      width: w,
      height: h,
      status: Idle,
      notice: resume_notice,
      spinner_frame: 0,
      spinner_label: "",
      tab: ChatTab,
      log_cycles: [],
      log_selected: 0,
      last_usage: None,
    )
  render(state)
  tui_run(fn() { event_loop(state) }, cleanup)
  do_halt(0)
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
          let next = TuiState(..state, spinner_frame: state.spinner_frame + 1)
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
    ChatResponse(result:, final_model:, save_error:) ->
      handle_chat_response(state, result, final_model, save_error)
    AgentQuestionReceived(question:, reply_to:) ->
      handle_agent_question(state, question, reply_to)
    ToolEventReceived(name:) -> handle_tool_event(state, name)
    ModelSwitchReceived(suggested_model:, reply_to:) ->
      continue_loop(
        TuiState(
          ..state,
          status: WaitingForModelSwitch(suggested_model:, reply_to:),
        ),
      )
  }
}

fn continue_loop(state: TuiState) -> Nil {
  render(state)
  event_loop(TuiState(..state, notice: ""))
}

fn do_exit(_state: TuiState) -> Nil {
  throw_tui_exit()
}

fn handle_agent_question(
  state: TuiState,
  question: String,
  reply_to: Subject(String),
) -> Nil {
  continue_loop(
    TuiState(..state, status: WaitingForInput(question:, reply_to:)),
  )
}

fn handle_tool_event(state: TuiState, name: String) -> Nil {
  continue_loop(TuiState(..state, spinner_label: name))
}

fn handle_stdin_byte(state: TuiState, byte: String) -> Nil {
  case byte {
    "\u{03}" | "\u{04}" -> do_exit(state)
    "\u{09}" -> switch_tab(state)
    "\r" | "\n" -> handle_enter(state)
    "\u{7F}" | "\u{08}" ->
      case state.tab {
        LogTab -> event_loop(state)
        ChatTab -> continue_loop(handle_backspace(state))
      }
    "\u{1B}" -> handle_escape(state)
    _ ->
      case state.tab {
        LogTab -> event_loop(state)
        ChatTab ->
          case is_printable(byte) {
            True ->
              continue_loop(
                TuiState(..state, input_buf: state.input_buf <> byte),
              )
            False -> event_loop(state)
          }
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
    Ok(StdinByte("[")), Ok(StdinByte("A")) ->
      case state.tab {
        LogTab -> continue_loop(log_nav_up(state))
        ChatTab -> continue_loop(scroll_up(state, 3))
      }
    Ok(StdinByte("[")), Ok(StdinByte("B")) ->
      case state.tab {
        LogTab -> continue_loop(log_nav_down(state))
        ChatTab -> continue_loop(scroll_down(state, 3))
      }
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
    "/clear" -> {
      process.send(state.chat, service.ClearHistory)
      let notice = style.dim("  Conversation cleared")
      continue_loop(TuiState(..state, messages: [], scroll_offset: 0, notice:))
    }
    "/model" -> {
      let new_model = case state.model == state.task_model {
        True -> state.reasoning_model
        False -> state.task_model
      }
      process.send(state.chat, service.SetModel(model: new_model))
      let label = case new_model == state.task_model {
        True -> "task"
        False -> "reasoning"
      }
      let notice = style.dim("  Model: " <> new_model <> " (" <> label <> ")")
      continue_loop(TuiState(..state, model: new_model, notice:))
    }
    _ -> {
      let notice = style.dim("  Unknown command: " <> cmd)
      continue_loop(TuiState(..state, notice:))
    }
  }
}

fn handle_enter(state: TuiState) -> Nil {
  case state.tab {
    LogTab -> handle_log_rewind(state)
    ChatTab -> handle_chat_enter(state)
  }
}

fn handle_chat_enter(state: TuiState) -> Nil {
  case state.status {
    WaitingForModelSwitch(suggested_model:, reply_to:) -> {
      let input = string.lowercase(string.trim(state.input_buf))
      let accept = case input {
        "n" | "no" -> False
        _ -> True
      }
      let answer = case accept {
        True -> service.AcceptModelSwitch
        False -> service.DeclineModelSwitch
      }
      process.send(reply_to, answer)
      let new_model = case accept {
        True -> suggested_model
        False -> state.model
      }
      let notice = case accept {
        True -> style.dim("  Switched to: " <> suggested_model)
        False -> style.dim("  Kept: " <> state.model)
      }
      continue_loop(
        TuiState(
          ..state,
          input_buf: "",
          status: WaitingForLlm,
          model: new_model,
          notice:,
        ),
      )
    }
    _ ->
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
                    Message(role: Assistant, content: [
                      TextContent(text: question),
                    ])
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
                      tool_channel: state.tool_channel,
                      model_question_channel: state.model_question_channel,
                    ),
                  )
                  event_loop(s1)
                }
                WaitingForModelSwitch(..) -> event_loop(state)
              }
          }
      }
  }
}

fn handle_chat_response(
  state: TuiState,
  result: Result(LlmResponse, LlmError),
  final_model: String,
  save_error: option.Option(String),
) -> Nil {
  let #(reply_text, usage) = case result {
    Ok(resp) -> #(response.text(resp), Some(resp.usage))
    Error(err) -> #("[Error: " <> response.error_message(err) <> "]", None)
  }
  let asst = Message(role: Assistant, content: [TextContent(text: reply_text)])
  let notice = case save_error {
    None -> ""
    Some(msg) -> style.yellow("  Warning: session not saved \u{2014} " <> msg)
  }
  let new_state =
    TuiState(
      ..state,
      messages: list.append(state.messages, [asst]),
      status: Idle,
      spinner_label: "",
      model: final_model,
      last_usage: usage,
      notice:,
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
  case state.tab {
    ChatTab -> {
      render_messages(state)
      render_separator(state.width, state.height - 3)
      render_input(state)
    }
    LogTab -> render_log(state)
  }
  render_footer(state)
}

fn render_header(state: TuiState) -> Nil {
  let tab_bar = case state.tab {
    ChatTab -> style.bold("[Chat]") <> "  " <> style.dim("[Log]")
    LogTab -> style.dim("[Chat]") <> "  " <> style.bold("[Log]")
  }
  let header =
    style.bold(" Springdrift ")
    <> style.dim("── ")
    <> state.provider_name
    <> " │ "
    <> state.model
    <> "    "
    <> tab_bar
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
      case text {
        "" -> []
        _ -> {
          let content_lines = render_markdown(text, state.width - 4)
          list.flatten([[""], [label], content_lines])
        }
      }
    })
  case state.status {
    WaitingForLlm -> {
      let label = style.bold(style.green("  Assistant"))
      let frames = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]
      let frame =
        list.drop(frames, state.spinner_frame % 8)
        |> list.first()
        |> result.unwrap("⣾")
      let action = case state.spinner_label {
        "" -> "Thinking\u{2026}"
        name -> "Using: " <> name
      }
      list.append(msg_lines, [
        "",
        label,
        style.dim("    " <> frame <> " " <> action),
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
    WaitingForModelSwitch(suggested_model:, ..) -> {
      let label = style.bold(style.green("  Assistant"))
      let msg =
        "Complex query — switch to reasoning model? ("
        <> suggested_model
        <> ")  y/Enter=yes  n=no"
      list.append(msg_lines, [
        "",
        label,
        style.bold(style.yellow("    \u{2699} " <> msg)),
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
      case state.tab {
        LogTab ->
          style.dim("  ↑↓: select   Enter: rewind to here   Tab: back to chat")
        ChatTab ->
          case state.status {
            Idle -> {
              let token_info = case state.last_usage {
                None -> ""
                Some(u) ->
                  style.dim(
                    "↑"
                    <> int.to_string(u.input_tokens)
                    <> "t ↓"
                    <> int.to_string(u.output_tokens)
                    <> "t   ",
                  )
              }
              token_info
              <> style.dim(
                "Enter: send   PgUp/PgDn: scroll   /exit: quit   /clear: new session   /model: toggle model   Tab: log",
              )
            }
            WaitingForLlm ->
              style.dim("  Waiting for response\u{2026}   Ctrl-C: quit")
            WaitingForInput(..) ->
              style.dim("  Enter: answer question   Ctrl-C: quit")
            WaitingForModelSwitch(..) ->
              style.dim(
                "  y/Enter: switch to reasoning model   n: keep current   Ctrl-C: quit",
              )
          }
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

// ---------------------------------------------------------------------------
// Log tab
// ---------------------------------------------------------------------------

fn switch_tab(state: TuiState) -> Nil {
  case state.tab {
    ChatTab -> {
      let cycles = cycle_log.load_cycles()
      let last = int.max(0, list.length(cycles) - 1)
      continue_loop(
        TuiState(..state, tab: LogTab, log_cycles: cycles, log_selected: last),
      )
    }
    LogTab -> continue_loop(TuiState(..state, tab: ChatTab))
  }
}

fn log_nav_up(state: TuiState) -> TuiState {
  TuiState(..state, log_selected: int.max(0, state.log_selected - 1))
}

fn log_nav_down(state: TuiState) -> TuiState {
  let max_idx = int.max(0, list.length(state.log_cycles) - 1)
  TuiState(..state, log_selected: int.min(max_idx, state.log_selected + 1))
}

fn handle_log_rewind(state: TuiState) -> Nil {
  case state.log_cycles {
    [] ->
      continue_loop(
        TuiState(..state, notice: style.dim("  No cycles to rewind to")),
      )
    _ -> {
      let msgs =
        cycle_log.messages_for_rewind(state.log_cycles, state.log_selected)
      process.send(state.chat, service.RestoreMessages(messages: msgs))
      let num = int.to_string(state.log_selected + 1)
      let notice = style.dim("  Rewound to cycle #" <> num)
      continue_loop(
        TuiState(
          ..state,
          tab: ChatTab,
          messages: msgs,
          scroll_offset: 0,
          notice:,
        ),
      )
    }
  }
}

fn render_log(state: TuiState) -> Nil {
  let cycles = state.log_cycles
  // 3 lines per cycle: header + user + asst
  let cycle_height = 3
  let available = state.height - 3
  let max_visible = int.max(1, available / cycle_height)
  case list.length(cycles) {
    0 ->
      stdout.execute([
        command.MoveTo(0, 2),
        command.Print(style.dim("  No cycles logged today.")),
      ])
    _ -> {
      let page = state.log_selected / max_visible
      let top = page * max_visible
      let visible = cycles |> list.drop(top) |> list.take(max_visible)
      print_log_cycles(visible, top, state.log_selected, 2, state.width)
    }
  }
}

fn print_log_cycles(
  cycles: List(CycleData),
  base_idx: Int,
  selected: Int,
  row: Int,
  width: Int,
) -> Nil {
  case cycles {
    [] -> Nil
    [c, ..rest] -> {
      let sel = base_idx == selected
      let indicator = case sel {
        True -> "▶ "
        False -> "  "
      }
      let time = string.slice(c.timestamp, 11, 8)
      let tools_part = case c.tool_names {
        [] -> ""
        names -> style.dim("  [" <> string.join(names, ", ") <> "]")
      }
      let token_part = case c.input_tokens + c.output_tokens {
        0 -> ""
        _ ->
          style.dim(
            "  ↑"
            <> int.to_string(c.input_tokens)
            <> "t ↓"
            <> int.to_string(c.output_tokens)
            <> "t",
          )
      }
      let complexity_part = case c.complexity {
        None -> ""
        Some("complex") -> style.dim("  \u{26A1}complex")
        Some("simple") -> style.dim("  \u{00B7}simple")
        Some(other) -> style.dim("  " <> other)
      }
      let hdr_text =
        indicator
        <> "#"
        <> int.to_string(base_idx + 1)
        <> "  "
        <> time
        <> tools_part
        <> token_part
        <> complexity_part
      let hdr_line = case sel {
        True -> style.bold(hdr_text)
        False -> style.dim(hdr_text)
      }
      let user_text = truncate_text("    You: " <> c.human_input, width - 2)
      let asst_text = case c.response_text {
        "" -> style.dim("    Asst: \u{2026}")
        t -> style.dim("    Asst: ") <> truncate_text(t, width - 11)
      }
      stdout.execute([
        command.MoveTo(0, row),
        command.Print(hdr_line),
        command.MoveTo(0, row + 1),
        command.Print(user_text),
        command.MoveTo(0, row + 2),
        command.Print(asst_text),
      ])
      print_log_cycles(rest, base_idx + 1, selected, row + 3, width)
    }
  }
}

fn truncate_text(text: String, max_width: Int) -> String {
  case string.length(text) > max_width {
    True -> string.slice(text, 0, int.max(0, max_width - 1)) <> "\u{2026}"
    False -> text
  }
}
