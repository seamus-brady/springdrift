import agent/types as agent_types
import etch/command
import etch/stdout
import etch/style
import etch/terminal
import gleam/erlang/process.{type Selector, type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm/types.{
  type Message, type Usage, Assistant, Message, TextContent, User,
}
import narrative/librarian.{type LibrarianMessage}
import narrative/log as narrative_log
import narrative/types as narrative_types
import slog.{type LogEntry}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type Tab {
  ChatTab
  LogTab
  NarrativeTab
}

type AgentStatus {
  Idle
  WaitingForLlm
  WaitingForInput(question: String)
}

type TuiMessage {
  StdinByte(byte: String)
  CognitiveReplyReceived(response: String, model: String, usage: Option(Usage))
  NotificationReceived(notification: agent_types.Notification)
}

type TuiState {
  TuiState(
    cognitive: Subject(agent_types.CognitiveMessage),
    cognitive_reply: Subject(agent_types.CognitiveReply),
    stdin_subj: Subject(TuiMessage),
    selector: Selector(TuiMessage),
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
    log_entries: List(LogEntry),
    log_scroll: Int,
    last_usage: Option(Usage),
    narrative_dir: String,
    narrative_entries: List(narrative_types.NarrativeEntry),
    narrative_scroll: Int,
    librarian: Option(Subject(LibrarianMessage)),
    input_limit: Int,
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
  cognitive: Subject(agent_types.CognitiveMessage),
  notify: Subject(agent_types.Notification),
  provider_name: String,
  task_model: String,
  reasoning_model: String,
  initial_messages: List(Message),
  narrative_dir: String,
  lib: Option(Subject(LibrarianMessage)),
  input_limit: Int,
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
  let cognitive_reply: Subject(agent_types.CognitiveReply) =
    process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(stdin_subj)
    |> process.select_map(cognitive_reply, fn(cr: agent_types.CognitiveReply) {
      CognitiveReplyReceived(
        response: cr.response,
        model: cr.model,
        usage: cr.usage,
      )
    })
    |> process.select_map(notify, fn(n: agent_types.Notification) {
      NotificationReceived(notification: n)
    })
  process.spawn_unlinked(fn() { stdin_loop(stdin_subj) })
  let resume_notice = case initial_messages {
    [] -> ""
    msgs ->
      "  Resumed: " <> int.to_string(list.length(msgs)) <> " messages loaded"
  }
  let state =
    TuiState(
      cognitive:,
      cognitive_reply:,
      stdin_subj:,
      selector:,
      provider_name:,
      model: task_model,
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
      log_entries: [],
      log_scroll: 0,
      last_usage: None,
      narrative_dir:,
      narrative_entries: [],
      narrative_scroll: 0,
      librarian: lib,
      input_limit:,
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
    CognitiveReplyReceived(response:, model:, usage:) ->
      handle_cognitive_reply(state, response, model, usage)
    NotificationReceived(notification:) ->
      handle_notification(state, notification)
  }
}

fn continue_loop(state: TuiState) -> Nil {
  render(state)
  event_loop(TuiState(..state, notice: ""))
}

fn do_exit(_state: TuiState) -> Nil {
  throw_tui_exit()
}

fn handle_cognitive_reply(
  state: TuiState,
  response: String,
  model: String,
  usage: Option(Usage),
) -> Nil {
  let asst = Message(role: Assistant, content: [TextContent(text: response)])
  let notice = case model != state.model {
    True -> style.dim("  \u{21AA} " <> model)
    False -> ""
  }
  continue_loop(
    TuiState(
      ..state,
      messages: list.append(state.messages, [asst]),
      status: Idle,
      spinner_label: "",
      model:,
      notice:,
      last_usage: usage,
    ),
  )
}

fn handle_notification(
  state: TuiState,
  notification: agent_types.Notification,
) -> Nil {
  case notification {
    agent_types.QuestionForHuman(question:, ..) ->
      continue_loop(TuiState(..state, status: WaitingForInput(question:)))
    agent_types.SaveWarning(message:) ->
      continue_loop(
        TuiState(
          ..state,
          notice: style.yellow(
            "  Warning: session not saved \u{2014} " <> message,
          ),
        ),
      )
    agent_types.ToolCalling(name:) ->
      continue_loop(TuiState(..state, spinner_label: name))
    agent_types.SafetyGateNotice(decision:, score:, explanation:) -> {
      let score_str = float.to_string(score)
      let truncated_explanation = case string.length(explanation) > 60 {
        True -> string.slice(explanation, 0, 57) <> "..."
        False -> explanation
      }
      let detail = " (" <> score_str <> "): " <> truncated_explanation
      let badge = case decision {
        "ACCEPT" -> style.green("[D' ACCEPT" <> detail <> "]")
        "MODIFY" -> style.yellow("[D' MODIFY" <> detail <> "]")
        "REJECT" -> style.red("[D' REJECT" <> detail <> "]")
        _ -> style.dim("[D' " <> decision <> detail <> "]")
      }
      continue_loop(TuiState(..state, notice: "  " <> badge))
    }
    agent_types.AgentLifecycleNotice(event_type:, agent_name:) -> {
      let label = agent_name <> " " <> event_type
      continue_loop(TuiState(..state, spinner_label: label))
    }
    agent_types.InputQueued(position:, queue_size: _) ->
      continue_loop(
        TuiState(
          ..state,
          notice: style.dim(
            "  Queued (position " <> int.to_string(position) <> ")",
          ),
        ),
      )
    agent_types.InputQueueFull(queue_cap:) ->
      continue_loop(
        TuiState(
          ..state,
          notice: style.yellow(
            "  Input queue full (" <> int.to_string(queue_cap) <> " pending)",
          ),
        ),
      )
    agent_types.SchedulerReminder(name: _, title:, body: _) ->
      continue_loop(
        TuiState(..state, notice: style.yellow("  Reminder: " <> title)),
      )
    agent_types.SchedulerJobStarted(name:, kind:) ->
      continue_loop(
        TuiState(
          ..state,
          spinner_label: "scheduler:" <> name <> " (" <> kind <> ")",
        ),
      )
    agent_types.SchedulerJobCompleted(name:, result_preview: _) ->
      continue_loop(
        TuiState(
          ..state,
          notice: style.dim("  Scheduler job '" <> name <> "' completed"),
        ),
      )
    agent_types.SchedulerJobFailed(name:, reason:) ->
      continue_loop(
        TuiState(
          ..state,
          notice: style.yellow(
            "  Scheduler job '" <> name <> "' failed: " <> reason,
          ),
        ),
      )
    agent_types.PlannerNotification(task_id: _, title:, action:) ->
      continue_loop(
        TuiState(
          ..state,
          notice: style.dim("  Planner: " <> action <> " — " <> title),
        ),
      )
    agent_types.SandboxStarted(pool_size:, port_range:) ->
      continue_loop(
        TuiState(
          ..state,
          notice: style.dim(
            "  Sandbox started (pool="
            <> int.to_string(pool_size)
            <> ", ports="
            <> port_range
            <> ")",
          ),
        ),
      )
    agent_types.SandboxContainerFailed(slot:, reason:) ->
      continue_loop(
        TuiState(
          ..state,
          notice: style.yellow(
            "  Sandbox slot " <> int.to_string(slot) <> " failed: " <> reason,
          ),
        ),
      )
    agent_types.SandboxUnavailable(reason:) ->
      continue_loop(
        TuiState(
          ..state,
          notice: style.yellow("  Sandbox unavailable: " <> reason),
        ),
      )
  }
}

fn handle_stdin_byte(state: TuiState, byte: String) -> Nil {
  case byte {
    "\u{03}" | "\u{04}" -> do_exit(state)
    "\u{09}" -> switch_tab(state)
    "\r" | "\n" -> handle_enter(state)
    "\u{7F}" | "\u{08}" ->
      case state.tab {
        ChatTab -> continue_loop(handle_backspace(state))
        _ -> event_loop(state)
      }
    "\u{1B}" -> handle_escape(state)
    _ ->
      case state.tab {
        ChatTab ->
          case is_printable(byte) {
            True ->
              case string.byte_size(state.input_buf) < state.input_limit {
                True ->
                  continue_loop(
                    TuiState(..state, input_buf: state.input_buf <> byte),
                  )
                False -> event_loop(state)
              }
            False -> event_loop(state)
          }
        _ -> event_loop(state)
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
        NarrativeTab -> continue_loop(narrative_nav_up(state))
        ChatTab -> continue_loop(scroll_up(state, 3))
      }
    Ok(StdinByte("[")), Ok(StdinByte("B")) ->
      case state.tab {
        LogTab -> continue_loop(log_nav_down(state))
        NarrativeTab -> continue_loop(narrative_nav_down(state))
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
    "/model" -> {
      let new_model = case state.model == state.task_model {
        True -> state.reasoning_model
        False -> state.task_model
      }
      process.send(state.cognitive, agent_types.SetModel(model: new_model))
      let label = case new_model == state.task_model {
        True -> "task"
        False -> "reasoning"
      }
      let notice = style.dim("  Model: " <> new_model <> " (" <> label <> ")")
      continue_loop(TuiState(..state, model: new_model, notice:))
    }
    "/clear" -> {
      process.send(state.cognitive, agent_types.RestoreMessages(messages: []))
      let notice = style.dim("  Conversation cleared")
      continue_loop(
        TuiState(
          ..state,
          messages: [],
          scroll_offset: 0,
          last_usage: None,
          notice:,
        ),
      )
    }
    _ -> {
      let notice = style.dim("  Unknown command: " <> cmd)
      continue_loop(TuiState(..state, notice:))
    }
  }
}

fn handle_enter(state: TuiState) -> Nil {
  case state.tab {
    LogTab -> handle_log_enter(state)
    NarrativeTab -> continue_loop(TuiState(..state, tab: ChatTab))
    ChatTab -> handle_chat_enter(state)
  }
}

fn handle_chat_enter(state: TuiState) -> Nil {
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
            WaitingForInput(question:) -> {
              let q_msg =
                Message(role: Assistant, content: [
                  TextContent(text: question),
                ])
              let a_msg =
                Message(role: User, content: [TextContent(text: input_text)])
              let msgs = list.append(state.messages, [q_msg, a_msg])
              process.send(
                state.cognitive,
                agent_types.UserAnswer(answer: input_text),
              )
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
                state.cognitive,
                agent_types.UserInput(
                  text: input_text,
                  reply_to: state.cognitive_reply,
                ),
              )
              event_loop(s1)
            }
          }
      }
  }
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
  stdout.execute([command.MoveTo(0, 0)])
  render_header(state)
  render_separator(state.width, 1)
  case state.tab {
    ChatTab -> {
      render_messages(state)
      render_separator(state.width, state.height - 3)
      render_input(state)
    }
    LogTab -> render_log(state)
    NarrativeTab -> render_narrative(state)
  }
  render_footer(state)
}

fn render_header(state: TuiState) -> Nil {
  let tab_bar = case state.tab {
    ChatTab ->
      style.bold("[Chat]")
      <> "  "
      <> style.dim("[Log]")
      <> "  "
      <> style.dim("[Narrative]")
    LogTab ->
      style.dim("[Chat]")
      <> "  "
      <> style.bold("[Log]")
      <> "  "
      <> style.dim("[Narrative]")
    NarrativeTab ->
      style.dim("[Chat]")
      <> "  "
      <> style.dim("[Log]")
      <> "  "
      <> style.bold("[Narrative]")
  }
  let header =
    style.bold(" Springdrift ")
    <> style.dim("── ")
    <> state.provider_name
    <> " │ "
    <> state.model
    <> "    "
    <> tab_bar
  print_at(0, 0, header)
}

fn render_separator(width: Int, row: Int) -> Nil {
  let line = string.repeat("─", width)
  print_at(0, row, line)
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
  // Clear any remaining rows in the content area
  clear_rows(2 + list.length(window), 2 + available)
}

fn print_lines(lines: List(String), start_row: Int) -> Nil {
  case lines {
    [] -> Nil
    [line, ..rest] -> {
      print_at(0, start_row, line)
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
    WaitingForInput(question:) -> {
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
  print_at(0, state.height - 2, line)
}

fn render_footer(state: TuiState) -> Nil {
  let footer = case state.notice {
    "" ->
      case state.tab {
        LogTab -> style.dim("  ↑↓: scroll   Enter/Tab: switch tab")
        NarrativeTab ->
          style.dim(
            "  ↑↓: scroll   Enter/Tab: switch tab   "
            <> int.to_string(list.length(state.narrative_entries))
            <> " entries",
          )
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
                "Enter: send   PgUp/PgDn: scroll   /exit: quit   /model: toggle model   Tab: log",
              )
            }
            WaitingForLlm ->
              style.dim("  Waiting for response\u{2026}   Ctrl-C: quit")
            WaitingForInput(..) ->
              style.dim("  Enter: answer question   Ctrl-C: quit")
          }
      }
    msg -> style.yellow(msg)
  }
  print_at(0, state.height - 1, footer)
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

/// Move to (col, row), clear the line, then print text.
fn print_at(col: Int, row: Int, text: String) -> Nil {
  stdout.execute([
    command.MoveTo(col, row),
    command.Clear(terminal.CurrentLine),
    command.Print(text),
  ])
}

/// Clear rows from `from` (inclusive) to `to` (exclusive).
fn clear_rows(from: Int, to: Int) -> Nil {
  case from >= to {
    True -> Nil
    False -> {
      stdout.execute([
        command.MoveTo(0, from),
        command.Clear(terminal.CurrentLine),
      ])
      clear_rows(from + 1, to)
    }
  }
}

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
      let entries = slog.load_entries()
      continue_loop(
        TuiState(..state, tab: LogTab, log_entries: entries, log_scroll: 0),
      )
    }
    LogTab -> {
      let entries = case state.librarian {
        Some(l) -> librarian.load_all(l)
        None -> narrative_log.load_all(state.narrative_dir)
      }
      continue_loop(
        TuiState(
          ..state,
          tab: NarrativeTab,
          narrative_entries: entries,
          narrative_scroll: 0,
        ),
      )
    }
    NarrativeTab -> continue_loop(TuiState(..state, tab: ChatTab))
  }
}

fn log_nav_up(state: TuiState) -> TuiState {
  TuiState(..state, log_scroll: state.log_scroll + 3)
}

fn log_nav_down(state: TuiState) -> TuiState {
  TuiState(..state, log_scroll: int.max(0, state.log_scroll - 3))
}

fn handle_log_enter(state: TuiState) -> Nil {
  // Enter on log tab switches back to chat (no rewind from system log)
  continue_loop(TuiState(..state, tab: ChatTab))
}

fn render_log(state: TuiState) -> Nil {
  let entries = state.log_entries
  let available = state.height - 3
  case list.length(entries) {
    0 -> {
      print_at(0, 2, style.dim("  No log entries today."))
      clear_rows(3, 2 + available)
    }
    total -> {
      // Scroll from the bottom (most recent entries last)
      let end_idx = int.max(0, total - state.log_scroll)
      let start_idx = int.max(0, end_idx - available)
      let visible =
        entries
        |> list.drop(start_idx)
        |> list.take(available)
      print_log_entries(visible, 2, state.width)
      let used_rows = list.length(visible)
      clear_rows(2 + used_rows, 2 + available)
    }
  }
}

fn print_log_entries(entries: List(LogEntry), row: Int, width: Int) -> Nil {
  case entries {
    [] -> Nil
    [entry, ..rest] -> {
      let time = string.slice(entry.timestamp, 11, 8)
      let level_badge = case entry.level {
        slog.Debug -> style.dim("[DBG]")
        slog.Info -> style.cyan("[INF]")
        slog.Warn -> style.yellow("[WRN]")
        slog.LogError -> style.red("[ERR]")
      }
      let cycle_part = case entry.cycle_id {
        None -> ""
        Some(id) -> style.dim(" " <> string.slice(id, 0, 8))
      }
      let mod_fn = style.dim(entry.module <> "::" <> entry.function)
      let msg_max = int.max(10, width - 40)
      let msg = truncate_text(entry.message, msg_max)
      let line =
        "  "
        <> time
        <> " "
        <> level_badge
        <> " "
        <> mod_fn
        <> " "
        <> msg
        <> cycle_part
      print_at(0, row, line)
      print_log_entries(rest, row + 1, width)
    }
  }
}

fn truncate_text(text: String, max_width: Int) -> String {
  case string.length(text) > max_width {
    True -> string.slice(text, 0, int.max(0, max_width - 1)) <> "\u{2026}"
    False -> text
  }
}

// ---------------------------------------------------------------------------
// Narrative tab
// ---------------------------------------------------------------------------

fn narrative_nav_up(state: TuiState) -> TuiState {
  TuiState(..state, narrative_scroll: state.narrative_scroll + 3)
}

fn narrative_nav_down(state: TuiState) -> TuiState {
  TuiState(..state, narrative_scroll: int.max(0, state.narrative_scroll - 3))
}

fn render_narrative(state: TuiState) -> Nil {
  let entries = state.narrative_entries
  let available = state.height - 3
  case entries {
    [] -> {
      print_at(0, 2, style.dim("  No narrative entries."))
      clear_rows(3, 2 + available)
    }
    _ -> {
      let lines = build_narrative_lines(entries, state.width)
      let total = list.length(lines)
      let end_idx = int.max(0, total - state.narrative_scroll)
      let start_idx = int.max(0, end_idx - available)
      let visible =
        lines
        |> list.drop(start_idx)
        |> list.take(available)
      print_lines(visible, 2)
      let used = list.length(visible)
      clear_rows(2 + used, 2 + available)
    }
  }
}

fn build_narrative_lines(
  entries: List(narrative_types.NarrativeEntry),
  width: Int,
) -> List(String) {
  list.flat_map(entries, fn(entry) { narrative_entry_lines(entry, width) })
}

fn narrative_entry_lines(
  entry: narrative_types.NarrativeEntry,
  width: Int,
) -> List(String) {
  let cycle_short = string.slice(entry.cycle_id, 0, 8)
  let time = case string.length(entry.timestamp) >= 19 {
    True -> string.slice(entry.timestamp, 0, 19)
    False -> entry.timestamp
  }
  let status_badge = case entry.outcome.status {
    narrative_types.Success -> style.green("[OK]")
    narrative_types.Partial -> style.yellow("[~~]")
    narrative_types.Failure -> style.red("[!!]")
  }
  let thread_info = case entry.thread {
    Some(t) ->
      style.dim(
        " [" <> t.thread_name <> " #" <> int.to_string(t.position) <> "]",
      )
    None -> ""
  }
  let header_line =
    "  "
    <> style.cyan(cycle_short)
    <> " "
    <> style.dim(time)
    <> " "
    <> status_badge
    <> thread_info

  let summary_max = int.max(20, width - 4)
  let summary_line = "    " <> truncate_text(entry.summary, summary_max)

  let delegation_lines = case entry.delegation_chain {
    [] -> []
    delegations ->
      list.map(delegations, fn(d) {
        "    "
        <> style.dim("\u{2514} ")
        <> d.agent_human_name
        <> ": "
        <> truncate_text(d.outcome, int.max(10, width - 30))
      })
  }

  [header_line, summary_line, ..delegation_lines]
}
